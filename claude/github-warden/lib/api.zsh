#!/usr/bin/env zsh
# ghw api — single curl wrapper for all GitHub API traffic.
# Serial by construction: one request per call, callers loop.
# Return codes: 0 = 2xx, 3 = plain 403 (permission), 4 = 404, 1 = exhausted retries.

: ${GHW_API_ROOT:=https://api.github.com}

_ghw_hdr() {  # $1 header-name (lowercase), $2 header-file — prints value or ""
  awk -v h="$1:" 'tolower($1)==h { v=$2; gsub("\r","",v); print v; exit }' "$2"
}

ghw_api() {  # $1 METHOD, $2 endpoint, $3 optional JSON body
  local method="$1" endpoint="$2" body="${3:-}"
  local url="${GHW_API_ROOT}${endpoint}"
  local hdr_file body_file http_code
  local -i attempt=0 rl_attempt=0
  hdr_file=$(mktemp); body_file=$(mktemp)
  while true; do
    (( attempt++ ))
    local -a args
    args=(-sS -X "$method" -H "Authorization: Bearer ${GHW_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -D "$hdr_file" -o "$body_file" -w '%{http_code}')
    if [[ -n "$body" ]]; then
      args+=(-H "Content-Type: application/json" -d "$body")
    fi
    http_code=$(${=GHW_CURL:-curl} "${args[@]}" "$url" 2>/dev/null) || http_code=000
    typeset -g GHW_LAST_STATUS="$http_code"
    typeset -g GHW_LAST_HEADERS="$(<"$hdr_file")"
    case "$http_code" in
      2*)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 0 ;;
      403)
        local remaining retry_after reset now wait
        remaining=$(_ghw_hdr x-ratelimit-remaining "$hdr_file")
        retry_after=$(_ghw_hdr retry-after "$hdr_file")
        if [[ "$remaining" == 0 ]]; then            # primary limit: sleep to reset
          reset=$(_ghw_hdr x-ratelimit-reset "$hdr_file")
          now=$(date +%s); wait=$(( reset - now )); (( wait < 1 )) && wait=1
          ${=GHW_SLEEP:-sleep} "$wait"; continue
        elif [[ -n "$retry_after" ]]; then          # secondary limit: honor header
          ${=GHW_SLEEP:-sleep} "$retry_after"
          if (( ++rl_attempt < 5 )); then continue; fi
          cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1
        else                                        # real permission error
          cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 3
        fi ;;
      404)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 4 ;;
      5*|000)
        if (( attempt <= 3 )); then
          local backoff=$(( 2 ** (attempt - 1) )); (( backoff > 60 )) && backoff=60
          ${=GHW_SLEEP:-sleep} "$backoff"; continue
        fi
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1 ;;
      *)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1 ;;
    esac
  done
}

ghw_api_paged() {  # $1 endpoint — GETs all pages, prints one merged JSON array
  local endpoint="$1" sep="?" out="[]" chunk len
  local -i page=1
  [[ "$endpoint" == *\?* ]] && sep="&"
  while true; do
    chunk=$(ghw_api GET "${endpoint}${sep}per_page=100&page=${page}") || return $?
    out=$(print -r -- "$out" | jq --argjson c "$chunk" '. + $c') || return 1
    len=$(print -r -- "$chunk" | jq 'length') || return 1
    [[ "$len" == <-> ]] || return 1
    (( len < 100 )) && break
    (( page++ ))
  done
  print -r -- "$out"
}
