#!/usr/bin/env zsh
# Fake curl for ghw tests. Understands the exact arg layout ghw_api emits:
#   -sS -X METHOD -H ... -D hdrfile -o bodyfile -w %{http_code} [-H ct -d body] URL
# Looks up the response via stub_route from $GHW_STUB_ROUTES, logs the request
# to $GHW_STUB_LOG, writes headers/body files, prints the status code.
set -u
method=GET body="" hdr=/dev/null out=/dev/null url=""
while (( $# )); do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -D) hdr=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -d) body=$2; shift 2 ;;
    -H|-w) shift 2 ;;
    -sS) shift ;;
    *) url=$1; shift ;;
  esac
done
print -r -- "${method} ${url} ${body}" >> "$GHW_STUB_LOG"
RESP_STATUS=200 RESP_BODY="{}" RESP_HEADERS=""
source "$GHW_STUB_ROUTES"
stub_route "$method" "$url" "$body"
print -r -- "$RESP_HEADERS" > "$hdr"
print -rn -- "$RESP_BODY" > "$out"
print -rn -- "$RESP_STATUS"
