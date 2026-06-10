#!/usr/bin/env zsh
# dve doctor — probe both API keys and report which capabilities they hold.
# Deterministic and local: no agent launch, no token cost. Mutates nothing.
#
# Required — Devin API v3 cog_ key (api.devin.ai): consumption, orgs, roster,
# metrics, plus a safe org-cap write probe (PATCH against a nonexistent org:
# 404/422 = permission present; 403 is INCONCLUSIVE because the API masks
# unknown orgs as 403 — verified 2026-06-10: a key whose idempotent PATCH on a
# real org returned 200 still got 403 here. Nothing is mutated either way.)
# Optional — Windsurf service key (server.codeium.com): per-model/IDE analytics
# and roster activity. Missing key or scope degrades dve but does not fail doctor.
#
# Requires lib/key-resolve.zsh to be sourced already.

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
    missing)     sym="❌ missing (key lacks this permission)" ;;
    ratelimited) sym="⚠️  rate-limited (429) — inconclusive, retry later" ;;
    unreachable) sym="⚠️  unreachable — network or endpoint error" ;;
    *)           sym="⚠️  ${verdict}" ;;
  esac
  print -r -- "  ${label}  [${code}]  ${sym}"
  [[ "$verdict" == ok ]]
}

dve_doctor() {
  local v3base="${DVE_API_BASE_V3:-https://api.devin.ai}"
  local wsbase="${DVE_API_BASE:-https://server.codeium.com}"
  local cog_key windsurf_key today code verdict
  integer fails=0 warns=0

  if ! cog_key=$(dve_resolve_cog_key); then
    print -ru2 -- "dve doctor: no Devin API v3 service-user key (cog_...) found (see 'dve help' for setup)."
    return 1
  fi

  today=$(date +%F)
  local cog_auth="Authorization: Bearer ${cog_key}"

  print -r -- "dve doctor — probing API keys"
  print -r -- "  (the org-cap write probe targets a nonexistent org; it mutates nothing.)"
  print -r -- ""
  print -r -- "Devin API v3 (api.devin.ai, cog_ key) — required:"

  # ManageBilling — consumption cycles.
  code=$(_dve_http GET "${v3base}/v3/enterprise/consumption/cycles" "" "$cog_auth")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Consumption Read " "$code" "$verdict" || (( fails++ ))

  # Org read — organizations list (caps visible per org).
  code=$(_dve_http GET "${v3base}/v3/enterprise/organizations" "" "$cog_auth")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Org Read         " "$code" "$verdict" || (( fails++ ))

  # Org-cap write — PATCH a nonexistent org: 404/422 = authz passed. 403 is
  # inconclusive (the API masks unknown orgs as 403), so it warns, not fails.
  code=$(_dve_http PATCH "${v3base}/v3/enterprise/organizations/org-dve-doctor-probe" "{}" "$cog_auth")
  verdict=$(_dve_classify "$code" 404 422)
  if [[ "$verdict" == missing ]]; then
    print -r -- "  Org-cap Write      [${code}]  ⚠️  inconclusive — API masks unknown orgs as 403; verified only at write time"
    (( warns++ ))
  else
    _dve_line "Org-cap Write    " "$code" "$verdict" || (( fails++ ))
  fi

  # Roster — enterprise members.
  code=$(_dve_http GET "${v3base}/v3/enterprise/members/users?limit=1" "" "$cog_auth")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Roster Read      " "$code" "$verdict" || (( fails++ ))

  # ViewAccountMetrics — usage metrics.
  code=$(_dve_http GET "${v3base}/v3/enterprise/metrics/usage" "" "$cog_auth")
  verdict=$(_dve_classify "$code" 200)
  _dve_line "Metrics Read     " "$code" "$verdict" || (( fails++ ))

  print -r -- ""
  print -r -- "Windsurf analytics (server.codeium.com, service key) — optional:"

  if ! windsurf_key=$(dve_resolve_service_key); then
    print -r -- "  (no Windsurf service key — per-model/IDE breakdown and roster activity unavailable)"
    (( warns++ ))
  else
    local billing
    billing=$(jq -n --arg k "$windsurf_key" '{service_key: $k}')

    # Teams Read-only — UserPageAnalytics (roster activity: activeDays, last-usage).
    code=$(_dve_http POST "${wsbase}/api/v1/UserPageAnalytics" "$billing" "")
    verdict=$(_dve_classify "$code" 200)
    _dve_line "Teams Read-only  " "$code" "$verdict" || (( warns++ ))

    # Analytics Read — consumption (per-model/IDE ACUs). Burns 1 of 10/hr unless skipped.
    if [[ -n "${DVE_DOCTOR_SKIP_ANALYTICS:-}" ]]; then
      print -r -- "  Analytics Read     [skip]  ⏭  skipped (would consume 1 of 10/hr consumption calls)"
    else
      code=$(_dve_http GET \
        "${wsbase}/api/v2alpha/analytics/consumption?start_date=${today}&end_date=${today}&product=agent&page_size=1" \
        "" "Authorization: Bearer ${windsurf_key}")
      verdict=$(_dve_classify "$code" 200)
      _dve_line "Analytics Read   " "$code" "$verdict" || (( warns++ ))
    fi
  fi

  print -r -- ""
  if (( fails == 0 && warns == 0 )); then
    print -r -- "✅ All capabilities present. dve is ready."
    return 0
  fi
  if (( fails == 0 )); then
    print -r -- "✅ Required Devin v3 capabilities present. dve is ready."
    print -r -- "⚠️  ${warns} non-blocking warning(s) above (inconclusive or optional-unavailable)."
    print -r -- "   Missing Windsurf capability degrades per-model/IDE breakdown; key setup:"
    print -r -- "   https://windsurf.com/team/settings (Analytics Read + Teams Read-only)."
    return 0
  fi
  print -r -- "❌ ${fails} required capability(ies) missing or uncertain."
  print -r -- "   Recreate the cog_ key at app.devin.ai > Settings > Service users (enterprise-scoped)"
  print -r -- "   with permissions: ManageBilling, ViewOrgSessions, ViewAccountMetrics, ManageOrganizations."
  return 3
}
