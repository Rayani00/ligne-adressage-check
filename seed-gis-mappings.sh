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

clients_file="$(mktemp)"; sirens_file="$(mktemp)"
trap 'rm -f "$clients_file" "$sirens_file"' EXIT
neon 'SELECT client_name, env_id FROM gis_clients'              | jq '.rows' > "$clients_file"
neon 'SELECT client, siren_testpilote FROM gis_siren_testpilote' | jq '.rows' > "$sirens_file"
jq -n --slurpfile c "$clients_file" --slurpfile s "$sirens_file" \
  '{gis_clients: $c[0], gis_siren_testpilote: $s[0]}' > "$out"
echo "Écrit $out : $(jq '.gis_clients|length' "$out") clients, $(jq '.gis_siren_testpilote|length' "$out") lignes siren."
