#!/usr/bin/env zsh
# dve doctor — probe the Devin service key against each endpoint and report which
# scopes it actually holds. Deterministic and local: no agent launch, no token cost.
# Maps HTTP status codes to a per-scope verdict. Mutates nothing.
#
# Requires dve_resolve_service_key (from lib/key-resolve.zsh) to be sourced already.

# _dve_http <method> <url> <data-or-empty> <auth-header-or-empty> -> prints HTTP code
_dve_http() {
  local method=$1 url=$2 data=$3 auth=$4
  local -a args
  args=(-sS -o /dev/null -w '%{http_code}' -X "$method")
  [[ -n "$auth" ]] && args+=(-H "$auth")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
  curl "${args[@]}" "$url" 2>/dev/null || print -rn -- "000"
}

# _dve_classify <code> <present-code>... -> ok | missing | ratelimited | unreachable | unexpected:<code>
_dve_classify() {
  local code=$1; shift
  local p
  for p in "$@"; do
    [[ "$code" == "$p" ]] && { print -r -- ok; return 0 }
  done
  case "$code" in
    401|403) print -r -- missing ;;
    429)     print -r -- ratelimited ;;
    000|"")  print -r -- unreachable ;;
    *)       print -r -- "unexpected:${code}" ;;
  esac
}

# _dve_line <label> <code> <verdict> -> prints a report line; returns 0 only when ok
_dve_line() {
  local label=$1 code=$2 verdict=$3 sym
  case "$verdict" in
    ok)          sym="✅ present" ;;
    missing)     sym="❌ missing (key lacks this scope)" ;;
    ratelimited) sym="⚠️  rate-limited (429) — inconclusive, retry later" ;;
    unreachable) sym="⚠️  unreachable — network or endpoint error" ;;
    *)           sym="⚠️  ${verdict}" ;;
  esac
  print -r -- "  ${label}  [${code}]  ${sym}"
  [[ "$verdict" == ok ]]
}

dve_doctor() {
  local base="${DVE_API_BASE:-https://server.codeium.com}"
  local key today billing code verdict
  integer fails=0

  if ! key=$(dve_resolve_service_key); then
    print -ru2 -- "dve doctor: no Devin service key found (see 'dve help' for setup)."
    return 1
  fi

  today=$(date +%F)
  billing=$(jq -n --arg k "$key" '{service_key: $k}')

  print -r -- "dve doctor — probing the service key against Devin Desktop endpoints"
  print -r -- "  (the Billing Write probe sends an intentionally-invalid request; it mutates nothing.)"
  print -r -- ""

  # Billing Read — GetTeamCreditBalance. 200 = scope present.
  code=$(_dve_http POST "${base}/api/v1/GetTeamCreditBalance" "$billing" "")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Billing Read   " "$code" "$verdict" || (( fails++ ))

  # Billing Write — UsageConfig with no scope/cap fields. Authz passes -> 400 (validation);
  # scope absent -> 401/403. So 200|400 both mean the write scope is present.
  code=$(_dve_http POST "${base}/api/v1/UsageConfig" "$billing" "")
  verdict=$(_dve_classify "$code" 200 400)
  _dve_line "Billing Write  " "$code" "$verdict" || (( fails++ ))

  # Analytics Read — consumption (minimal 1-day, page_size=1). Burns 1 of 10/hr unless skipped.
  if [[ -n "${DVE_DOCTOR_SKIP_ANALYTICS:-}" ]]; then
    print -r -- "  Analytics Read   [skip]  ⏭  skipped (would consume 1 of 10/hr consumption calls)"
  else
    code=$(_dve_http GET \
      "${base}/api/v2alpha/analytics/consumption?start_date=${today}&end_date=${today}&product=agent&page_size=1" \
      "" "Authorization: Bearer ${key}")
    verdict=$(_dve_classify "$code" 200)
    _dve_line "Analytics Read " "$code" "$verdict" || (( fails++ ))
  fi

  # Teams Read-only — UserPageAnalytics.
  code=$(_dve_http POST "${base}/api/v1/UserPageAnalytics" "$billing" "")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Teams Read-only" "$code" "$verdict" || (( fails++ ))

  print -r -- ""
  if (( fails == 0 )); then
    print -r -- "✅ All probed scopes present. dve is ready."
    return 0
  fi
  print -r -- "❌ ${fails} scope(s) missing or uncertain."
  print -r -- "   Recreate the key with all scopes at https://windsurf.com/team/settings"
  return 3
}
