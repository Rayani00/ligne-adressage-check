#!/usr/bin/env bash

#############################################################################
# ligne_full_check.sh
#
# Verifie peppol, Harmony-connector et legalRef pour un ou plusieurs SIREN_SUFIX.
#
# Mode mono-SIREN (sortie console) :
#   . ./script.env
#   ./ligne_full_check.sh 432526903_TESTPILOTE             # DEBUG (defaut)
#   ./ligne_full_check.sh 432526903_TESTPILOTE false       # ERROR_ONLY
#
# Mode batch (rapport markdown) :
#   ./ligne_full_check.sh -i sirens.txt -o rapport.md
#   ./ligne_full_check.sh -s 123_TEST,456_TEST -o rapport.md
#
# Options :
#   -i, --input-file <path>      Fichier contenant un SIREN par ligne.
#   -s, --sirens A,B,C           Liste de SIRENs separes par virgule.
#   -o, --output-markdown <path> Chemin du rapport markdown (defaut: ./rapport.md).
#   -h, --help                   Affiche cette aide.
#
# Le fichier d'entree tolere les formats bruites (texte parasite, parentheses
# de fin, espace parasite avant '_') ainsi que les commentaires '#'. Doublons
# dedupliques automatiquement, lignes non reconnues affichees en fin de run.
#
# Le fichier script.env (meme dossier) est charge automatiquement s'il existe ;
# il peut aussi etre source manuellement avant l'execution.
#############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

BOLD='\033[1m'
ERROR='\033[1;31m'
RESET='\033[0m'

SCHEME='iso6523-actorid-upis'

DEBUG_MODE='true'
INPUT_FILE=''
OUTPUT_MARKDOWN=''
SIRENS_CLI=''
POSITIONAL_SIREN=''

trap 'echo -e "${ERROR}ERROR:${RESET} line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

#############################################################################
# Helpers
#############################################################################

log() {
  if [[ "$DEBUG_MODE" == 'true' && -z "$OUTPUT_MARKDOWN" ]]; then
    printf '\n%b%s%b\n' "$BOLD" "$1" "$RESET"
  fi
}

err() {
  printf '\n%bERROR:%b %b' "$ERROR" "$RESET" "$1" >&2
}

usage() {
  sed -n '4,/^#####/p' "$0" | sed -e 's/^# \?//' -e '/^####/d'
  exit "${1:-0}"
}

# Extrait le pattern SIREN_SUFIX d'une ligne, ou rien si non trouve.
clean_siren() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && return 0
  [[ "$line" =~ ^# ]] && return 0
  line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')"
  if [[ "$line" =~ ([0-9]{9,10})[[:space:]]*_([^[:space:]]+) ]]; then
    printf '%s_%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# Formate des requetes capturees en markdown.
# Chaque argument : "label|method|url|body|header"
md_format_requests() {
  [[ "$#" -eq 0 ]] && return 0
  printf '\n*Requetes effectuees* :\n'
  local req label method url body header
  for req in "$@"; do
    IFS='|' read -r label method url body header <<< "$req"
    if [[ -n "$label" ]]; then
      printf -- '- **%s** : `%s %s`\n' "$label" "$method" "$url"
    else
      printf -- '- `%s %s`\n' "$method" "$url"
    fi
    [[ -n "$body" ]]   && printf -- '  - body : `%s`\n' "$body"
    [[ -n "$header" ]] && printf -- '  - header : `%s`\n' "$header"
  done
}

status_icon() {
  case "$1" in
    OK)      printf 'OK' ;;
    'N/A')   printf 'N/A' ;;
    ERROR)   printf 'KO' ;;
    NOT_RUN) printf -- '-' ;;
    *)       printf '%s' "$1" ;;
  esac
}

get_access_token() {
  local client_id="$1" client_secret="$2"
  curl -fsSX POST \
    "https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=client_credentials' \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" \
  | jq -er '.access_token'
}

#############################################################################
# Coeur : check un SIREN. Stdout :
#   - mode markdown (details_file fourni) : ligne de statut "p|h|l|env|pa"
#   - mode console : sortie log/err identique a la version mono-SIREN
#############################################################################

check_one_siren() {
  local siren="$1"
  local details_file="${2:-}"
  local mode='console'
  [[ -n "$details_file" ]] && mode='markdown'

  # Subshell pour isoler set +e et trap - ERR ; ne tue pas le parent.
  (
    trap - ERR
    set +e

    local participant="0225:$siren"

    local peppol_status='NOT_RUN' peppol_error=''
    local inference_status='NOT_RUN' inference_error=''
    local harmony_status='NOT_RUN' harmony_error=''
    local legalref_status='NOT_RUN' legalref_error=''
    local env_name='-' pa_name='-'

    local -a peppol_reqs=() harmony_reqs=() legalref_reqs=()

    local smp_url='' smp_certificate='' doc_number='0' ap_url='' ap_cert_subject=''
    local sub_domain='' domain='' url_path='' first_level=''
    local harmony_connector_url='' harmony_endpoint=''
    local legalref_sub_domain='' legalref_endpoint=''
    local participant_routing='' legalref_ligne=''

    # ----- Peppol -----
    local hash dns_name
    hash=$(printf '%s' "$participant" \
      | tr '[:upper:]' '[:lower:]' \
      | openssl dgst -sha256 -binary \
      | base32 \
      | tr '[:upper:]' '[:lower:]' \
      | tr -d '=\n')
    dns_name="${hash}.${SCHEME}.participant.sml.test.tech.peppol.org"

    peppol_reqs+=("DNS NAPTR (dig)|dig NAPTR|${dns_name}||")

    smp_url=$(dig +short NAPTR "$dns_name" 2>/dev/null | awk -F'!' '/Meta:SMP/ { print $3 }')

    if [[ -z "$smp_url" ]]; then
      peppol_status='ERROR'
      peppol_error="No Meta:SMP record found for \"${participant}\""
    else
      local smp_endpoint="${smp_url}/${SCHEME}::${participant}"
      peppol_reqs+=("SMP racine|GET|${smp_endpoint}||")
      local smp_response curl_rc
      smp_response=$(curl -fsS "$smp_endpoint" 2>&1); curl_rc=$?
      if [[ $curl_rc -ne 0 ]]; then
        peppol_status='ERROR'
        peppol_error="Failed to fetch SMP: ${smp_response}"
      else
        doc_number=$(printf '%s' "$smp_response" | xmllint --xpath 'count(//*[local-name()="ServiceMetadataReference"])' - 2>/dev/null || echo '0')
        if [[ -z "$doc_number" || "$doc_number" -lt 1 ]]; then
          peppol_status='ERROR'
          peppol_error="No ServiceMetadataReference found for \"${participant}\""
        else
          local first_doc
          first_doc=$(printf '%s' "$smp_response" | xmllint --xpath 'string((//*[local-name()="ServiceMetadataReference"])[1]/@href)' - 2>/dev/null)
          peppol_reqs+=("SMP doc|GET|${first_doc}||")
          local first_doc_response
          first_doc_response=$(curl -fsS "$first_doc" 2>&1); curl_rc=$?
          if [[ $curl_rc -ne 0 ]]; then
            peppol_status='ERROR'
            peppol_error="Failed to fetch SMP doc: ${first_doc_response}"
          else
            ap_url=$(printf '%s' "$first_doc_response" | xmllint --xpath 'string(//*[local-name()="EndpointReference"]/*[local-name()="Address"])' - 2>/dev/null)
            smp_certificate=$(printf '%s' "$first_doc_response" | xmllint --xpath 'string(//*[local-name()="X509SubjectName"])' - 2>/dev/null)
            ap_cert_subject=$(
              printf '%s' "$first_doc_response" \
                | xmllint --xpath 'string(//*[local-name()="Certificate"])' - 2>/dev/null \
                | { echo "-----BEGIN CERTIFICATE-----"; cat; echo "-----END CERTIFICATE-----"; } \
                | openssl x509 -noout -subject 2>/dev/null \
                | sed 's/^subject=//' \
                | head -1
            )
            peppol_status='OK'
          fi
        fi
      fi
    fi

    # ----- Inference + Harmony + LegalRef (si Peppol OK) -----
    if [[ "$peppol_status" == 'OK' ]]; then
      local tmp="${ap_url#https://}"
      sub_domain="${tmp%%/*}"
      domain="${sub_domain#*.}"
      url_path="/${tmp#*/}"
      env_name="${ap_url#https://gis-platform-}"
      env_name="${env_name%%.*}"

      case "$domain" in
        generix.biz)             pa_name='gnx' ;;
        fulll.house)             pa_name='fulll' ;;
        pbis.qa-mypbconnect.com) pa_name='pitney-bowes' ;;
        treso2.com)              pa_name='pytheas' ;;
        *)
          inference_status='ERROR'
          inference_error="Unknown domain: \"${domain}\""
          ;;
      esac

      if [[ "$inference_status" != 'ERROR' ]]; then
        first_level="${url_path%/harmonypdpap/services/msh}"
        if [[ -n "$first_level" && "$first_level" != "$url_path" ]]; then
          pa_name="${first_level#/}"
        fi
        inference_status='OK'
      fi

      if [[ "$inference_status" == 'OK' ]]; then
        # ----- Harmony -----
        harmony_connector_url="${pa_name}-harmonyconnector-fr-${env_name}.apps.prd.openshift.vmwr/${pa_name}"
        harmony_endpoint="https://${harmony_connector_url}/harmonyconnector-fr/v1/participants/${participant}"

        harmony_reqs+=("Token Keycloak|POST|https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token|grant_type=client_credentials&client_id=\$HARMONY_CONNECTOR_CLIENT_ID&client_secret=***|")
        harmony_reqs+=("Routing|GET|${harmony_endpoint}||Authorization: Bearer <token>")

        local h_token h_response rc
        h_token=$(get_access_token "$HARMONY_CONNECTOR_CLIENT_ID" "$HARMONY_CONNECTOR_CLIENT_SECRET" 2>&1); rc=$?
        if [[ $rc -ne 0 ]]; then
          harmony_status='ERROR'
          harmony_error="Token failed: $h_token"
        else
          h_response=$(curl -fsS "$harmony_endpoint" -H 'Accept: application/json' -H "Authorization: Bearer $h_token" 2>&1); rc=$?
          if [[ $rc -ne 0 ]]; then
            harmony_status='ERROR'
            harmony_error="$h_response"
          else
            harmony_status='OK'
            participant_routing="$h_response"
          fi
        fi

        # ----- legalRef -----
        case "${env_name}:${pa_name}" in
          uat:gnx)          legalref_sub_domain='legalref-api-uat-ppd.staging.apps.generix.biz' ;;
          uat:pitney-bowes) legalref_sub_domain='legalref-api-uat-pitneybowes.staging.apps.generix.biz' ;;
          uat:fulll|uat:pytheas|uat:b4value|uat:fiteco|uat:spendesk) legalref_sub_domain='N/A' ;;
          pre:gnx)          legalref_sub_domain='legalref-api-ppd.staging.apps.generix.biz' ;;
          pre:fulll)        legalref_sub_domain='legalref-api-pprd-fulll.staging.apps.generix.biz' ;;
          pre:pitney-bowes) legalref_sub_domain='legalref-api-pprd-pitneybowes.staging.apps.generix.biz' ;;
          pre:pytheas)      legalref_sub_domain='legalref-api-pprd-pytheas.staging.apps.generix.biz' ;;
          pre:b4value)      legalref_sub_domain='legalref-api-pprd-b4value.staging.apps.generix.biz' ;;
          pre:fiteco)       legalref_sub_domain='legalref-api-pprd-fiteco.staging.apps.generix.biz' ;;
          pre:spendesk)     legalref_sub_domain='legalref-api-pprd-spendesk.staging.apps.generix.biz' ;;
          prd:gnx)          legalref_sub_domain='legalref-api.apps.generix.biz' ;;
          prd:fulll)        legalref_sub_domain='legalref-api-fulll.apps.generix.biz' ;;
          prd:pitney-bowes) legalref_sub_domain='legalref-api-pitneybowes.apps.generix.biz' ;;
          prd:pytheas)      legalref_sub_domain='legalref-api-pytheas.apps.generix.biz' ;;
          prd:b4value)      legalref_sub_domain='legalref-api-b4value.apps.generix.biz' ;;
          prd:fiteco)       legalref_sub_domain='legalref-api-fiteco.apps.generix.biz' ;;
          prd:spendesk)     legalref_sub_domain='legalref-api-spendesk.apps.generix.biz' ;;
          *)
            legalref_status='ERROR'
            legalref_error="Unsupported ENV/PA combination: \"${env_name}/${pa_name}\""
            ;;
        esac

        if [[ "$legalref_status" != 'ERROR' ]]; then
          if [[ "$legalref_sub_domain" == 'N/A' ]]; then
            legalref_status='N/A'
          else
            legalref_endpoint="https://${legalref_sub_domain}/ppf/annuaire-public/v2/ligne-annuaire/code:${siren}"
            legalref_reqs+=("Token Keycloak|POST|https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token|grant_type=client_credentials&client_id=\$LEGALREF_CLIENT_ID&client_secret=***|")
            legalref_reqs+=("Ligne annuaire|GET|${legalref_endpoint}||Authorization: Bearer <token>")

            local l_token l_response
            l_token=$(get_access_token "$LEGALREF_CLIENT_ID" "$LEGALREF_CLIENT_SECRET" 2>&1); rc=$?
            if [[ $rc -ne 0 ]]; then
              legalref_status='ERROR'
              legalref_error="Token failed: $l_token"
            else
              l_response=$(curl -fsS "$legalref_endpoint" -H 'Accept: application/json' -H "Authorization: Bearer $l_token" 2>&1); rc=$?
              if [[ $rc -ne 0 ]]; then
                legalref_status='ERROR'
                legalref_error="$l_response"
              else
                legalref_status='OK'
                legalref_ligne="$l_response"
              fi
            fi
          fi
        fi
      fi
    fi

    #-------------------------------------------------------------------------
    # Rendu
    #-------------------------------------------------------------------------
    if [[ "$mode" == 'markdown' ]]; then
      {
        printf '\n### %s\n\n' "$siren"

        # Peppol
        printf '**Peppol** : %s\n' "$peppol_status"
        if [[ ${#peppol_reqs[@]} -gt 0 ]]; then
          md_format_requests "${peppol_reqs[@]}"
        fi
        if [[ "$peppol_status" == 'ERROR' ]]; then
          printf '\n```\n%s\n```\n' "$peppol_error"
        elif [[ "$peppol_status" == 'OK' ]]; then
          printf '\n```json\n'
          jq -n \
            --arg smp "$smp_url" \
            --arg cert "$smp_certificate" \
            --argjson doc "${doc_number:-0}" \
            --arg ap "$ap_url" \
            --arg apcert "$ap_cert_subject" \
            '{SMP_URL:$smp, SMP_CERTIFICATE:$cert, DOC_NUMBER:$doc, AP_URL:$ap, AP_CERTIFICATE_SUBJECT:$apcert}'
          printf '```\n'
        fi

        # Inference
        if [[ "$inference_status" != 'NOT_RUN' ]]; then
          printf '\n**ENV / PA inferes** : %s\n' "$inference_status"
          if [[ "$inference_status" == 'ERROR' ]]; then
            printf '\n```\n%s\n```\n' "$inference_error"
          else
            printf '\n```json\n'
            jq -n \
              --arg env "$env_name" \
              --arg sub "$sub_domain" \
              --arg dom "$domain" \
              --arg pa "$pa_name" \
              '{ENV:$env, SUB_DOMAIN:$sub, DOMAIN:$dom, PA:$pa}'
            printf '```\n'
          fi
        fi

        # Harmony
        if [[ "$harmony_status" != 'NOT_RUN' ]]; then
          printf '\n**Harmony-connector** : %s\n' "$harmony_status"
          [[ -n "$harmony_connector_url" ]] && printf -- '- URL : %s\n' "$harmony_connector_url"
          if [[ ${#harmony_reqs[@]} -gt 0 ]]; then
            md_format_requests "${harmony_reqs[@]}"
          fi
          if [[ "$harmony_status" == 'ERROR' ]]; then
            printf '\n```\n%s\n```\n' "$harmony_error"
          elif [[ "$harmony_status" == 'OK' && -n "$participant_routing" ]]; then
            printf '\n```json\n%s\n```\n' "$(printf '%s' "$participant_routing" | jq .)"
          fi
        fi

        # LegalRef
        if [[ "$legalref_status" != 'NOT_RUN' ]]; then
          printf '\n**legalRef** : %s\n' "$legalref_status"
          [[ -n "$legalref_sub_domain" ]] && printf -- '- Sous-domaine : %s\n' "$legalref_sub_domain"
          if [[ ${#legalref_reqs[@]} -gt 0 ]]; then
            md_format_requests "${legalref_reqs[@]}"
          fi
          if [[ "$legalref_status" == 'ERROR' ]]; then
            printf '\n```\n%s\n```\n' "$legalref_error"
          elif [[ "$legalref_status" == 'OK' && -n "$legalref_ligne" ]]; then
            printf '\n```json\n%s\n```\n' "$(printf '%s' "$legalref_ligne" | jq .)"
          fi
        fi
      } >> "$details_file"

      printf '%s|%s|%s|%s|%s\n' "$peppol_status" "$harmony_status" "$legalref_status" "$env_name" "$pa_name"
    else
      # Console mode : reprend l'esprit du script mono-SIREN d'origine
      log "------------------- Checking ${siren} -------------------"

      if [[ "$peppol_status" == 'ERROR' ]]; then
        err "${peppol_error}\n"
        exit 1
      fi

      log "# Peppol informations for \"${participant}\""
      log "$(jq -nC --arg smp "$smp_url" --arg cert "$smp_certificate" --argjson doc "${doc_number:-0}" \
            --arg ap "$ap_url" --arg apcert "$ap_cert_subject" \
            '{SMP_URL:$smp, SMP_CERTIFICATE:$cert, DOC_NUMBER:$doc, AP_URL:$ap, AP_CERTIFICATE_SUBJECT:$apcert}')"

      if [[ "$inference_status" == 'ERROR' ]]; then
        err "${inference_error}\n"
        exit 1
      fi
      log "# Inferring ENV: \"${env_name}\" and PA: \"${pa_name}\" from peppol infos for \"${participant}\""
      log "$(jq -nC --arg env "$env_name" --arg sub "$sub_domain" --arg dom "$domain" --arg pa "$pa_name" \
            '{ENV:$env, SUB_DOMAIN:$sub, DOMAIN:$dom, PA:$pa}')"

      log "# Harmony-connector routing for \"${participant}\" from \"${harmony_connector_url}\""
      if [[ "$harmony_status" == 'ERROR' ]]; then
        err "No Harmony-connector routing found for \"${participant}\" \n       ${harmony_connector_url}\n"
      else
        log "$(printf '%s' "$participant_routing" | jq -C .)"
      fi

      log "# legalRef informations for \"${siren}\" from \"${legalref_sub_domain}\""
      if [[ "$legalref_status" == 'ERROR' ]]; then
        err "No legalRef line found for \"${siren}\": ${legalref_error}\n"
      elif [[ "$legalref_status" == 'OK' ]]; then
        log "$(printf '%s' "$legalref_ligne" | jq -C .)"
      fi
    fi
  )
}

#############################################################################
# Dispatch
#############################################################################

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      -i|--input-file)      INPUT_FILE="${2:?missing path}"; shift 2 ;;
      -o|--output-markdown) OUTPUT_MARKDOWN="${2:?missing path}"; shift 2 ;;
      -s|--sirens)          SIRENS_CLI="${2:?missing list}"; shift 2 ;;
      --) shift; break ;;
      -*) err "Unknown option: $1\n"; exit 1 ;;
      *)
        if [[ -z "$POSITIONAL_SIREN" ]]; then
          POSITIONAL_SIREN="$1"
        else
          DEBUG_MODE="$1"
        fi
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${script_dir}/script.env" ]]; then
    # shellcheck disable=SC1091
    source "${script_dir}/script.env"
  fi

  for c in curl jq base32 xmllint openssl dig; do
    command -v "$c" >/dev/null || { err "Missing required command: $c\n"; exit 1; }
  done

  for v in HARMONY_CONNECTOR_CLIENT_ID HARMONY_CONNECTOR_CLIENT_SECRET LEGALREF_CLIENT_ID LEGALREF_CLIENT_SECRET; do
    [[ -z "${!v:-}" ]] && { err "Missing env var: $v\n  source ./script.env first, or define it in the environment.\n"; exit 1; }
  done

  local batch_mode='false'
  if [[ -n "$INPUT_FILE" || -n "$OUTPUT_MARKDOWN" || -n "$SIRENS_CLI" ]]; then
    batch_mode='true'
  fi

  if [[ "$batch_mode" == 'false' ]]; then
    [[ -z "$POSITIONAL_SIREN" ]] && { err "Missing SIREN argument\n"; usage 1; }
    check_one_siren "$POSITIONAL_SIREN" ''
    exit 0
  fi

  # ---- Mode batch ----
  local -a raw_lines=() cleaned=() skipped=()
  if [[ -n "$INPUT_FILE" ]]; then
    [[ ! -f "$INPUT_FILE" ]] && { err "Input file not found: $INPUT_FILE\n"; exit 1; }
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      raw_lines+=("$line")
    done < "$INPUT_FILE"
  fi
  if [[ -n "$SIRENS_CLI" ]]; then
    local IFS_BAK="$IFS"
    IFS=','
    local s
    for s in $SIRENS_CLI; do raw_lines+=("$s"); done
    IFS="$IFS_BAK"
  fi
  if [[ -n "$POSITIONAL_SIREN" ]]; then
    raw_lines+=("$POSITIONAL_SIREN")
  fi

  declare -A seen
  local line cleaned_one
  for line in "${raw_lines[@]}"; do
    cleaned_one=$(clean_siren "$line")
    if [[ -z "$cleaned_one" ]]; then
      if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
        skipped+=("$line")
      fi
      continue
    fi
    if [[ -z "${seen[$cleaned_one]:-}" ]]; then
      seen[$cleaned_one]=1
      cleaned+=("$cleaned_one")
    fi
  done

  if [[ ${#cleaned[@]} -eq 0 ]]; then
    err "No valid SIREN found after cleaning\n"
    exit 1
  fi

  [[ -z "$OUTPUT_MARKDOWN" ]] && OUTPUT_MARKDOWN="${script_dir}/rapport.md"

  printf '\nMode batch : %d SIREN(s) a verifier.\n' "${#cleaned[@]}"
  if [[ ${#skipped[@]} -gt 0 ]]; then
    printf '  %d ligne(s) ignoree(s) (format non reconnu).\n' "${#skipped[@]}"
  fi
  printf '\n'

  local details_tmp
  details_tmp=$(mktemp)
  trap 'rm -f "$details_tmp"' EXIT

  local -a summary_rows=()
  local idx=0 total=${#cleaned[@]}
  local siren status_line p h l e pa
  for siren in "${cleaned[@]}"; do
    idx=$((idx+1))
    status_line=$(check_one_siren "$siren" "$details_tmp" 2>/dev/null | tail -1)
    summary_rows+=("${siren}|${status_line}")
    IFS='|' read -r p h l e pa <<< "$status_line"
    printf '[%d/%d] %s  peppol=%s harmony=%s legalref=%s\n' "$idx" "$total" "$siren" "$p" "$h" "$l"
  done

  local ok_count=0 ko_count=0 row _siren
  for row in "${summary_rows[@]}"; do
    IFS='|' read -r _siren p h l _ _ <<< "$row"
    if [[ "$p" == 'OK' && "$h" == 'OK' && ( "$l" == 'OK' || "$l" == 'N/A' ) ]]; then
      ok_count=$((ok_count+1))
    else
      ko_count=$((ko_count+1))
    fi
  done

  {
    printf "# Rapport ligne d'adressage\n\n"
    printf -- '- Date : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf -- '- Total SIRENs : %d\n' "$total"
    printf -- '- Verts (3 checks OK) : %d\n' "$ok_count"
    printf -- '- Avec au moins un KO : %d\n\n' "$ko_count"
    printf '## Resume\n\n'
    printf '| # | SIREN | Peppol | Harmony | LegalRef | ENV | PA |\n'
    printf '|---|-------|--------|---------|----------|-----|----|\n'
    idx=0
    for row in "${summary_rows[@]}"; do
      idx=$((idx+1))
      IFS='|' read -r _siren p h l e pa <<< "$row"
      printf '| %d | %s | %s | %s | %s | %s | %s |\n' \
        "$idx" "$_siren" "$(status_icon "$p")" "$(status_icon "$h")" "$(status_icon "$l")" "$e" "$pa"
    done
    printf '\n## Details\n'
    cat "$details_tmp"
  } > "$OUTPUT_MARKDOWN"

  printf '\nRapport ecrit : %s\n' "$OUTPUT_MARKDOWN"
  if [[ ${#skipped[@]} -gt 0 ]]; then
    printf '\nLignes ignorees :\n'
    for s in "${skipped[@]}"; do printf '  - %s\n' "$s"; done
  fi
}

main "$@"
