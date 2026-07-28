#!/usr/bin/env zsh
# ghw api — single curl wrapper for all GitHub API traffic.
# Serial by construction: one request per call, callers loop.
# Return codes: 0 = 2xx, 3 = plain 403 (permission), 4 = 404, 1 = exhausted retries.

: ${GHW_API_ROOT:=https://api.github.com}
: ${GHW_MKTEMP:=$(whence -p mktemp || echo /usr/bin/mktemp)}
: ${GHW_CAT:=$(whence -p cat || echo /bin/cat)}
: ${GHW_RM:=$(whence -p rm || echo /bin/rm)}
: ${GHW_AWK:=$(whence -p awk || echo /usr/bin/awk)}
: ${GHW_JQ:=$(whence -p jq || echo /opt/homebrew/bin/jq)}

_ghw_hdr() {  # $1 header-name (lowercase), $2 header-file — prints value or ""
  $GHW_AWK -v h="$1:" 'tolower($1)==h { v=$2; gsub("\r","",v); print v; exit }' "$2"
}

ghw_api() {  # $1 METHOD, $2 path, $3 optional JSON body
  local method="$1" path="$2" body="${3:-}"
  local url="${GHW_API_ROOT}${path}"
  local hdr_file body_file http_code status_file
  local -i attempt=0 rl_attempt=0
  typeset -g GHW_LAST_STATUS GHW_LAST_HEADERS
  hdr_file=$($GHW_MKTEMP); body_file=$($GHW_MKTEMP); status_file=$($GHW_MKTEMP)
  while true; do
    (( attempt++ ))
    local -a args
    args=(-sS -X "$method" -H "Authorization: Bearer ${GHW_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -D "$hdr_file" -o "$body_file" -w '%{http_code}')
    if [[ -n "$body" ]]; then
      args+=(-H "Content-Type: application/json" -d "$body")
    fi
    # Capture status code to temp file instead of command substitution
    ${=GHW_CURL:-curl} "${args[@]}" "$url" 2>/dev/null > "$status_file" || true
    http_code=$(<"$status_file")
    [[ -z "$http_code" ]] && http_code=000
    # Set global variables (works even in subshell due to direct assignment)
    GHW_LAST_STATUS="$http_code"
    GHW_LAST_HEADERS="$(<"$hdr_file")"
    case "$http_code" in
      2*)
        $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 0 ;;
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
          $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 1
        else                                        # real permission error
          $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 3
        fi ;;
      404)
        $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 4 ;;
      5*|000)
        if (( attempt <= 3 )); then
          local backoff=$(( 2 ** (attempt - 1) )); (( backoff > 60 )) && backoff=60
          ${=GHW_SLEEP:-sleep} "$backoff"; continue
        fi
        $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 1 ;;
      *)
        $GHW_CAT "$body_file"; $GHW_RM -f "$hdr_file" "$body_file" "$status_file"; return 1 ;;
    esac
  done
}

ghw_api_paged() {  # $1 path — GETs all pages, prints one merged JSON array
  local path="$1" sep="?" out="[]" chunk len
  local -i page=1
  [[ "$path" == *\?* ]] && sep="&"
  while true; do
    chunk=$(ghw_api GET "${path}${sep}per_page=100&page=${page}") || return $?
    # DEBUG: echo "DEBUG chunk='$chunk', len=${#chunk}" >&2
    out=$(print -r -- "$out" | $GHW_JQ --argjson c "$chunk" '. + $c')
    len=$(print -r -- "$chunk" | $GHW_JQ 'length')
    (( len < 100 )) && break
    (( page++ ))
  done
  print -r -- "$out"
}
