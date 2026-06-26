#!/usr/bin/env bash
# Vérifie que la lecture locale produit les mêmes lignes que l'ancien chemin Neon.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
chk() { if [ "$1" = "$2" ]; then echo "  ok: $3"; else echo "  FAIL: $3 (attendu '$2', obtenu '$1')"; fail=1; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/gis_mappings.json" <<'JSON'
{
  "gis_clients": [
    { "client_name": "acme", "env_id": "ACM_pre-acme" },
    { "client_name": "", "env_id": "x" }
  ],
  "gis_siren_testpilote": [
    { "client": "acme", "siren_testpilote": "123456789_TESTPILOTE\n987654321_TESTPILOTE" }
  ]
}
JSON
export GIS_MAPPINGS_FILE="$TMP/gis_mappings.json"

# Extrait les fonctions du script sans exécuter main (awk sur les 3 fonctions contiguës)
source <(awk '/^neon_query\(\)/{f=1} f{print} f&&/^\}/{c++} c==3{exit}' ./ligne_full_check.sh)

echo "Test 1: neon_query renvoie {rows} pour gis_clients"
chk "$(neon_query 'SELECT client_name, env_id FROM gis_clients' | jq -r '.rows[0].client_name')" "acme" "client_name lu"

echo "Test 2: db_fetch_clients nettoie et filtre les lignes vides"
chk "$(db_fetch_clients)" "acme|ACM_pre-acme" "une seule ligne client valide"

echo "Test 3: db_fetch_test_sirens éclate le multi-SIREN (\\n littéral)"
chk "$(db_fetch_test_sirens | sort | tr '\n' ';')" "acme|123456789_TESTPILOTE;acme|987654321_TESTPILOTE;" "deux sirens éclatés"

[ "$fail" = "0" ] && echo "TOUS LES TESTS PASSENT" || { echo "ÉCHECS"; exit 1; }
