#!/usr/bin/env bash
# Dumpe gis_clients + gis_siren_testpilote depuis Neon vers gis_mappings.json.
# Prérequis : NEON_DATABASE_URL défini (source ./script.env), curl + jq.
# Usage : ./seed-gis-mappings.sh [fichier_sortie]   (défaut: ./gis_mappings.json)
set -Eeuo pipefail
out="${1:-$(dirname "$0")/gis_mappings.json}"
: "${NEON_DATABASE_URL:?NEON_DATABASE_URL non défini (source ./script.env)}"
host="$(printf '%s' "$NEON_DATABASE_URL" | sed -E 's#^[a-z]+://[^@]+@([^/?]+).*#\1#')"
endpoint="https://${host}/sql"

neon() {
  curl -fsSX POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H "Neon-Connection-String: ${NEON_DATABASE_URL}" \
    -H 'Neon-Array-Mode: false' \
    -d "$(jq -nc --arg q "$1" '{query:$q, params:[]}')"
}

clients="$(neon 'SELECT client_name, env_id FROM gis_clients' | jq '.rows')"
sirens="$(neon 'SELECT client, siren_testpilote FROM gis_siren_testpilote' | jq '.rows')"
jq -n --argjson c "$clients" --argjson s "$sirens" \
  '{gis_clients: $c, gis_siren_testpilote: $s}' > "$out"
echo "Écrit $out : $(jq '.gis_clients|length' "$out") clients, $(jq '.gis_siren_testpilote|length' "$out") lignes siren."
