#!/usr/bin/env bash

#############################################################################
# Check peppol, Harmony-connector, and legalRef for a given SIREN_SUFIX
# Usage : 
#         - Set secrets : . ./.env
#         - DEBUG       : ./ligne_full_check.sh 432526903_TESTPILOTE
#         - ERROR_ONLY  : ./ligne_full_check.sh 432526903_TESTPILOTE false
#############################################################################

set -Eeuo pipefail

IFS=$'\n\t'
BOLD='\033[1m'
ERROR='\033[1;31m'
RESET='\033[0m'

trap 'echo -e "${ERROR}ERROR: line=$LINENO ${RESET} cmd=$BASH_COMMAND" >&2' ERR

log() {
  [[ "${DEBUG:-false}" == "true" ]] \
  && printf '\n%b%s%b %b\n' "$BOLD" "$1" "$RESET" \
  || return 0
}

error() {
  printf '\n%bERROR:%b %b' "$ERROR" "$RESET" "$1" >&2

}

# Check pre requisits 

for c in curl jq base32 xmllint openssl dig; do
  command -v "${c}" >/dev/null || {
    error "Missing required command: ${c}\n"
    exit 1
  }
done

# Check ENVVAR secrets have been set 

for v in HARMONY_CONNECTOR_CLIENT_ID HARMONY_CONNECTOR_CLIENT_SECRET LEGALREF_CLIENT_ID LEGALREF_CLIENT_SECRET; do
  [[ -z "${!v:-}" ]] && {
    echo "Missing env var: $v"
    echo "Usage: $> . ./.env && $0 <SIREN> [DEBUG=true|false]"
    exit 1
  }
done

readonly SIREN="${1:?Usage: $0 <SIREN> [DEBUG=true|false]}"
readonly DEBUG="${2:-true}"
readonly SCHEME='iso6523-actorid-upis'
readonly PARTICIPANT="0225:${SIREN}"

log "------------------- Checking ${SIREN} -------------------"


#############################################################################
# Check peppol
#############################################################################

HASH=$(printf "%s" "$PARTICIPANT" \
  | tr '[:upper:]' '[:lower:]' \
  | openssl dgst -sha256 -binary \
  | base32 \
  | tr '[:upper:]' '[:lower:]' \
  | tr -d '=\n')

DOMAIN="${HASH}.${SCHEME}.participant.sml.test.tech.peppol.org"

SMP_URL="$(dig +short NAPTR "$DOMAIN" | awk -F'!' '/Meta:SMP/ { print $3 }')"

if [[ -z "$SMP_URL" ]]; then
  error "No Meta:SMP record found for \"${PARTICIPANT}\" "
  exit 1
fi

SMP_RESPONSE="$(curl -fsS "${SMP_URL}/${SCHEME}::${PARTICIPANT}")"

DOC_NUMBER="$(printf '%s' "${SMP_RESPONSE}" \
| xmllint --xpath 'count(//*[local-name()="ServiceMetadataReference"])' -)"

FIRST_DOC="$(printf '%s' "${SMP_RESPONSE}" \
| xmllint --xpath 'string((//*[local-name()="ServiceMetadataReference"])[1]/@href)' -)"

FIRST_DOC_RESPONSE="$(curl -fsS "${FIRST_DOC}")"

AP_URL="$(echo "$FIRST_DOC_RESPONSE" \
| xmllint --xpath 'string(//*[local-name()="EndpointReference"]/*[local-name()="Address"])' -)"

SMP_CERTIFICATE="$(printf '%s' "$FIRST_DOC_RESPONSE" \
| xmllint --xpath 'string(//*[local-name()="X509SubjectName"])' -)"
  
AP_CERTIFICATE_SUBJECT="$(
  printf '%s' "$FIRST_DOC_RESPONSE" \
  | xmllint --xpath 'string(//*[local-name()="Certificate"])' - \
  | {
      echo "-----BEGIN CERTIFICATE-----"
      cat
      echo "-----END CERTIFICATE-----"
    } \
  | openssl x509 -noout -subject \
  | sed 's/^subject=//'
)"

log "# Peppol informations for \"${PARTICIPANT}\""

PEPPOL_INFO="$(echo '{
  "SMP_URL": "'$SMP_URL'",
  "SMP_CERTIFICATE": "'$SMP_CERTIFICATE'",
  "DOC_NUMBER": '$DOC_NUMBER',
  "AP_URL": "'$AP_URL'",
  "AP_CERTIFICATE_SUBJECT": "'$AP_CERTIFICATE_SUBJECT}'"
}' | jq -C .)"

log "$PEPPOL_INFO"

#############################################################################
# Guessing ENV and PA
#############################################################################

TMP="${AP_URL#https://}"
SUB_DOMAIN="${TMP%%/*}"
DOMAIN=${SUB_DOMAIN#*.}
URL_PATH="/${TMP#*/}"
ENV="${AP_URL#https://gis-platform-}"
ENV="${ENV%%.*}"


case "$DOMAIN" in
  generix.biz)
    PA="gnx"
    ;;
  fulll.house)
    PA="fulll"
    ;;
  pbis.qa-mypbconnect.com)
    PA="pitney-bowes"
    ;;
  treso2.com)
    PA="pytheas"
    ;;
  *)
    error "${RESET}Unknown domain: \"${DOMAIN}\""
    exit 1
    ;;
esac

FIRST_LEVEL="${URL_PATH%*/harmonypdpap/services/msh}"

[[ -z "$FIRST_LEVEL" ]] || PA="${FIRST_LEVEL#/*}"

INFERRED="$(echo '{"ENV": "'$ENV'", "SUB_DOMAIN": "'$SUB_DOMAIN'", "DOMAIN": "'$DOMAIN'", "PA": "'$PA'"}' | jq -C .)"

log "# Inferring ENV: \"${ENV}\" and PA: \"${PA}\" from peppol infos for \"${PARTICIPANT}\""

log "${INFERRED}" 

#############################################################################
# Check Harmony-connector routing is done 
#############################################################################

KC_INSTANCE='auth.apps.generix.biz'
REALM='bo-generix'
CLIENT_ID="${HARMONY_CONNECTOR_CLIENT_ID}"
CLIENT_SECRET="${HARMONY_CONNECTOR_CLIENT_SECRET}"

access_token="$(
  curl -fsSX 'POST' \
    'https://'${KC_INSTANCE}'/auth/realms/'${REALM}'/protocol/openid-connect/token' \
    -H 'accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=client_credentials' \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
  | jq -erc '.access_token'
)"

HARMONY_CONNECTOR_URL="${PA}-harmonyconnector-fr-${ENV}.apps.prd.openshift.vmwr/${PA}"
HARMONY_CONNECTOR_ENDPOINT="https://${HARMONY_CONNECTOR_URL}/harmonyconnector-fr/v1/participants/${PARTICIPANT}"

log "# Harmony-connector routing for \"${PARTICIPANT}\" from \"${HARMONY_CONNECTOR_URL}\""

PARTICIPANT_ROUTING="$(
  curl -fsS "${HARMONY_CONNECTOR_ENDPOINT}" \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${access_token}" \
  || {
       error "No Harmony-connector routing found for \"${PARTICIPANT}\" \n       ${HARMONY_CONNECTOR_URL}\n"
       #exit 1
     }
)"

log "$(printf '%s' "$PARTICIPANT_ROUTING" | jq -C .)"

#############################################################################
# Check legalRef
#############################################################################

KC_INSTANCE='auth.apps.generix.biz'
REALM='bo-generix'
CLIENT_ID="${LEGALREF_CLIENT_ID}"
CLIENT_SECRET="${LEGALREF_CLIENT_SECRET}"

access_token="$(
  curl -fsSX 'POST' \
    'https://'${KC_INSTANCE}'/auth/realms/'${REALM}'/protocol/openid-connect/token' \
    -H 'accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=client_credentials' \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
  | jq -erc '.access_token'
)"

case "${ENV}:${PA}" in
  uat:gnx)          LEGALREF_SUB_DOMAIN="legalref-api-uat-ppd.staging.apps.generix.biz" ;;
  uat:pitney-bowes) LEGALREF_SUB_DOMAIN="legalref-api-uat-pitneybowes.staging.apps.generix.biz" ;;
  uat:fulll|uat:pytheas|uat:b4value|uat:fiteco|uat:spendesk)
                   LEGALREF_SUB_DOMAIN="N/A" ;;

  pre:gnx)          LEGALREF_SUB_DOMAIN="legalref-api-ppd.staging.apps.generix.biz" ;;
  pre:fulll)        LEGALREF_SUB_DOMAIN="legalref-api-pprd-fulll.staging.apps.generix.biz" ;;
  pre:pitney-bowes) LEGALREF_SUB_DOMAIN="legalref-api-pprd-pitneybowes.staging.apps.generix.biz" ;;
  pre:pytheas)      LEGALREF_SUB_DOMAIN="legalref-api-pprd-pytheas.staging.apps.generix.biz" ;;
  pre:b4value)      LEGALREF_SUB_DOMAIN="legalref-api-pprd-b4value.staging.apps.generix.biz" ;;
  pre:fiteco)       LEGALREF_SUB_DOMAIN="legalref-api-pprd-fiteco.staging.apps.generix.biz" ;;
  pre:spendesk)     LEGALREF_SUB_DOMAIN="legalref-api-pprd-spendesk.staging.apps.generix.biz" ;;

  prd:gnx)          LEGALREF_SUB_DOMAIN="legalref-api.apps.generix.biz" ;;
  prd:fulll)        LEGALREF_SUB_DOMAIN="legalref-api-fulll.apps.generix.biz" ;;
  prd:pitney-bowes) LEGALREF_SUB_DOMAIN="legalref-api-pitneybowes.apps.generix.biz" ;;
  prd:pytheas)      LEGALREF_SUB_DOMAIN="legalref-api-pytheas.apps.generix.biz" ;;
  prd:b4value)      LEGALREF_SUB_DOMAIN="legalref-api-b4value.apps.generix.biz" ;;
  prd:fiteco)       LEGALREF_SUB_DOMAIN="legalref-api-fiteco.apps.generix.biz" ;;
  prd:spendesk)     LEGALREF_SUB_DOMAIN="legalref-api-spendesk.apps.generix.biz" ;;

  *)
    error "Unsupported ENV/PA combination: \"${ENV}/${PA}\""
    exit 1
    ;;
esac

log "# legalRef informations for \"${SIREN}\" from \"${LEGALREF_SUB_DOMAIN}\""

LEGALREF_LIGNE="$(
  curl -fsS "https://${LEGALREF_SUB_DOMAIN}/ppf/annuaire-public/v2/ligne-annuaire/code:${SIREN}" \
    -H 'Authorization: Bearer '${access_token} \
    -H 'accept: application/json' \
  || {
       error "No legalRef line found for \"${SIREN}\"\n"
       #exit 1
     }
)"

log "$(printf '%s' "$LEGALREF_LIGNE" | jq -C .)"

