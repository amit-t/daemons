#!/usr/bin/env zsh
# dag dashboard — local read-only ACU burn dashboard (React app + local server).
# Fixture cycle: 2026-05-16 → 2026-06-16 (31 days), DAG_NOW_EPOCH pinned at day 30.
# Enterprise: 1500 ACUs consumed → run rate 50/day, projected 1550, pool 24000 → UNDER.
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"
fixdir="${script_dir}/fixtures/dashboard"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

# Fake security: always miss, so env vars drive key resolution.
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

# Fake curl: serve a fixture chosen by the URL (last arg), then append
# "\n<http_code>" exactly like curl -w '\n%{http_code}'. Records any write
# verb (-X/--request/--data/-d/--form) to WRITE_LOG — dashboard is read-only.
# FAKE_CURL_RC simulates a transport failure (e.g. 18 partial body) after a 200.
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env zsh
url=""
for a in "$@"; do
  url="$a"
  case "$a" in
    -X*|--request|--data*|-d|-F|--form) print -r -- "$a" >> "${WRITE_LOG}" ;;
  esac
done
print -r -- "$url" >> "${CURL_URL_LOG}"
emit() {  # $1 body-file  $2 code  $3 body-override
  if [[ -n "${3:-}" ]]; then print -rn -- "$3"; else cat "$1"; fi
  print -rn -- $'\n'"$2"
  exit "${FAKE_CURL_RC:-0}"
}
# Transient injection: emit FAKE_TRANSIENT_CODE (HTML body, like a real gateway)
# for the first FAKE_TRANSIENT_TIMES requests whose URL contains FAKE_TRANSIENT_URL.
# -1 = always fail. TRANSIENT_COUNTER persists the attempt count across the
# separate curl subprocesses the dashboard spawns.
if [[ -n "${FAKE_TRANSIENT_URL:-}" && "$url" == *"${FAKE_TRANSIENT_URL}"* ]]; then
  n=$(<"${TRANSIENT_COUNTER}" 2>/dev/null); n=${n:-0}
  if [[ "${FAKE_TRANSIENT_TIMES:-0}" == "-1" ]] || (( n < ${FAKE_TRANSIENT_TIMES:-0} )); then
    print -r -- $(( n + 1 )) > "${TRANSIENT_COUNTER}"
    print -rn -- "<html><head><title>504 Gateway Time-out</title></head><body><center><h1>504 Gateway Time-out</h1></center></body></html>"
    print -rn -- $'\n'"${FAKE_TRANSIENT_CODE:-504}"
    exit 0
  fi
fi
case "$url" in
  *consumption/cycles*)
    emit "${FIXTURES}/cycles.json" "${FAKE_CYCLES_CODE:-200}" "${FAKE_CYCLES_BODY:-}" ;;
  *v3/enterprise/sessions*)
    emit "${FIXTURES}/sessions.json" "${FAKE_SESSIONS_CODE:-200}" "${FAKE_SESSIONS_BODY:-}" ;;
  *api/v2alpha/analytics/consumption*)
    emit "${FIXTURES}/windsurf-consumption.json" "${FAKE_WINDSURF_CODE:-200}" "${FAKE_WINDSURF_BODY:-}" ;;
  *enterprise/members/users*)
    emit "${FIXTURES}/members-users.json" "${FAKE_USERS_CODE:-200}" "${FAKE_USERS_BODY:-}" ;;
  *v3beta1/enterprise/users/consumption/acu-limits*)
    emit "${FIXTURES}/user-default-limit.json" "${FAKE_DEFAULT_USER_LIMIT_CODE:-200}" "${FAKE_DEFAULT_USER_LIMIT_BODY:-}" ;;
  *v3beta1/enterprise/users/email%7Calice/consumption/acu-limits*)
    emit "${FIXTURES}/user-email-alice-limit.json" "${FAKE_USER_LIMIT_CODE:-200}" "${FAKE_USER_LIMIT_BODY:-}" ;;
  *v3beta1/enterprise/users/email%7Cbob/consumption/acu-limits*)
    emit "${FIXTURES}/user-email-bob-limit.json" "${FAKE_USER_LIMIT_CODE:-200}" "${FAKE_USER_LIMIT_BODY:-}" ;;
  *v3beta1/enterprise/users/email%7Czero/consumption/acu-limits*)
    emit "${FIXTURES}/user-email-zero-limit.json" "${FAKE_USER_LIMIT_CODE:-200}" "${FAKE_USER_LIMIT_BODY:-}" ;;
  *v3beta1/enterprise/users/okta%7CTeam%7Cchandra/consumption/acu-limits*)
    emit "${FIXTURES}/user-okta-team-chandra-limit.json" "${FAKE_USER_LIMIT_CODE:-200}" "${FAKE_USER_LIMIT_BODY:-}" ;;
  *consumption/daily/users/email%7Calice*)
    emit "${FIXTURES}/user-email-alice-daily.json" "${FAKE_USER_DAILY_CODE:-200}" "${FAKE_USER_DAILY_BODY:-}" ;;
  *consumption/daily/users/email%7Cbob*)
    emit "${FIXTURES}/user-email-bob-daily.json" "${FAKE_USER_DAILY_CODE:-200}" "${FAKE_USER_DAILY_BODY:-}" ;;
  *consumption/daily/users/email%7Czero*)
    emit "${FIXTURES}/user-email-zero-daily.json" "${FAKE_USER_DAILY_CODE:-200}" "${FAKE_USER_DAILY_BODY:-}" ;;
  *consumption/daily/users/okta%7CTeam%7Cchandra*)
    emit "${FIXTURES}/user-okta-team-chandra-daily.json" "${FAKE_USER_DAILY_CODE:-200}" "${FAKE_USER_DAILY_BODY:-}" ;;
  *consumption/daily/organizations/*)
    org="${url##*/organizations/}"; org="${org%%\?*}"
    emit "${FIXTURES}/org-${org}-daily.json" "${FAKE_ORG_DAILY_CODE:-200}" "${FAKE_ORG_DAILY_BODY:-}" ;;
  *consumption/daily*)
    emit "${FIXTURES}/enterprise-daily.json" "${FAKE_DAILY_CODE:-200}" "${FAKE_DAILY_BODY:-}" ;;
  *enterprise/organizations*)
    emit "${FIXTURES}/organizations.json" "${FAKE_ORGS_CODE:-200}" "${FAKE_ORGS_BODY:-}" ;;
  *) print -rn -- $'\n000' ;;
esac
EOF
chmod +x "${tmpdir}/bin/curl"

# Fake open: record invocations instead of launching a browser.
cat > "${tmpdir}/bin/open" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$@" >> "${OPEN_LOG}"
EOF
chmod +x "${tmpdir}/bin/open"

# Fake python3: deterministic stand-in for the port check (-c with a port arg →
# always free), the free-port pick (-c without args → 8999), and the static
# server (-m http.server → log argv, then idle until killed).
cat > "${tmpdir}/bin/python3" <<'EOF'
#!/usr/bin/env zsh
if [[ "${1:-}" == "-c" ]]; then
  if (( $# >= 3 )); then exit 0; else print -r -- 8999; exit 0; fi
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "http.server" ]]; then
  print -r -- "$@" >> "${SERVE_LOG}"
  while true; do sleep 1; done
fi
exit 0
EOF
chmod +x "${tmpdir}/bin/python3"

# Fake python3 whose http.server dies instantly (server-start failure path).
mkdir -p "${tmpdir}/deadpy"
cat > "${tmpdir}/deadpy/python3" <<'EOF'
#!/usr/bin/env zsh
if [[ "${1:-}" == "-c" ]]; then exit 0; fi
exit 1
EOF
chmod +x "${tmpdir}/deadpy/python3"

# Fixture React app: package.json + a prebuilt dist, so no npm is needed.
appdir="${tmpdir}/app"
mkdir -p "${appdir}/dist/assets"
print -r -- '{"name":"fixture-app"}' > "${appdir}/package.json"
cat > "${appdir}/dist/index.html" <<'EOF'
<!doctype html><html><head><script type="module" src="./assets/app.js"></script></head><body><div id="root"></div></body></html>
EOF
print -r -- 'fetch("./data.json")' > "${appdir}/dist/assets/app.js"

# Fake npm: logs each invocation; "run build" materializes a dist.
cat > "${tmpdir}/bin/npm" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$@" >> "${NPM_LOG}"
prefix=""
for ((i = 1; i <= $#; i++)); do
  [[ "${argv[i]}" == "--prefix" ]] && prefix="${argv[i+1]}"
done
if [[ "$*" == *"run build"* && -n "$prefix" ]]; then
  mkdir -p "${prefix}/dist/assets"
  print -r -- "<!doctype html><html></html>" > "${prefix}/dist/index.html"
  print -r -- "built" > "${prefix}/dist/assets/app.js"
fi
exit 0
EOF
chmod +x "${tmpdir}/bin/npm"

now_epoch=1781510400   # 2026-06-15T08:00:00Z — day 30 of the 31-day fixture cycle

run_dash() {
  PATH="${tmpdir}/bin:$PATH" FIXTURES="$fixdir" OPEN_LOG="${tmpdir}/open.log" \
  WRITE_LOG="${tmpdir}/write.log" CURL_URL_LOG="${tmpdir}/curl-urls.log" \
  SERVE_LOG="${SERVE_LOG:-${tmpdir}/serve.log}" NPM_LOG="${NPM_LOG:-${tmpdir}/npm.log}" \
  DEVIN_COG_KEY=test-cog-key-SECRET DAG_NOW_EPOCH=$now_epoch \
  DEVIN_SERVICE_KEY="${TEST_WINDSURF_KEY-test-windsurf-key-SECRET}" \
  DAG_MODEL_ANALYTICS_TTL_MINUTES="${DAG_MODEL_ANALYTICS_TTL_MINUTES:-}" \
  DAG_STATE_DIR="${tmpdir}/state" \
  DAG_DASHBOARD_APP_DIR="${DAG_DASHBOARD_APP_DIR:-$appdir}" \
  DAG_DASHBOARD_PYTHON="${DAG_DASHBOARD_PYTHON:-python3}" \
  DAG_DASHBOARD_NPM="${DAG_DASHBOARD_NPM:-npm}" \
  DAG_DASHBOARD_SERVE_ONCE="${DAG_DASHBOARD_SERVE_ONCE:-1}" \
  DAG_DASHBOARD_SERVE_GRACE=0.25 \
  DAG_DASHBOARD_REFRESH_ONCE="${DAG_DASHBOARD_REFRESH_ONCE:-}" \
  DAG_MONTHLY_ACU_POOL="${DAG_MONTHLY_ACU_POOL:-24000}" DAG_PRINT_PROMPT="${DAG_PRINT_PROMPT:-}" \
  FAKE_CURL_RC="${FAKE_CURL_RC:-0}" \
  FAKE_CYCLES_CODE="${FAKE_CYCLES_CODE:-200}" FAKE_CYCLES_BODY="${FAKE_CYCLES_BODY:-}" \
  FAKE_DAILY_CODE="${FAKE_DAILY_CODE:-200}" FAKE_DAILY_BODY="${FAKE_DAILY_BODY:-}" \
  FAKE_ORGS_CODE="${FAKE_ORGS_CODE:-200}" FAKE_ORGS_BODY="${FAKE_ORGS_BODY:-}" \
  FAKE_ORG_DAILY_CODE="${FAKE_ORG_DAILY_CODE:-200}" FAKE_ORG_DAILY_BODY="${FAKE_ORG_DAILY_BODY:-}" \
  FAKE_USERS_CODE="${FAKE_USERS_CODE:-200}" FAKE_USERS_BODY="${FAKE_USERS_BODY:-}" \
  FAKE_USER_DAILY_CODE="${FAKE_USER_DAILY_CODE:-200}" FAKE_USER_DAILY_BODY="${FAKE_USER_DAILY_BODY:-}" \
  FAKE_DEFAULT_USER_LIMIT_CODE="${FAKE_DEFAULT_USER_LIMIT_CODE:-200}" FAKE_DEFAULT_USER_LIMIT_BODY="${FAKE_DEFAULT_USER_LIMIT_BODY:-}" \
  FAKE_USER_LIMIT_CODE="${FAKE_USER_LIMIT_CODE:-200}" FAKE_USER_LIMIT_BODY="${FAKE_USER_LIMIT_BODY:-}" \
  FAKE_SESSIONS_CODE="${FAKE_SESSIONS_CODE:-200}" FAKE_SESSIONS_BODY="${FAKE_SESSIONS_BODY:-}" \
  FAKE_WINDSURF_CODE="${FAKE_WINDSURF_CODE:-200}" FAKE_WINDSURF_BODY="${FAKE_WINDSURF_BODY:-}" \
  FAKE_TRANSIENT_URL="${FAKE_TRANSIENT_URL:-}" FAKE_TRANSIENT_TIMES="${FAKE_TRANSIENT_TIMES:-0}" \
  FAKE_TRANSIENT_CODE="${FAKE_TRANSIENT_CODE:-504}" TRANSIENT_COUNTER="${TRANSIENT_COUNTER:-${tmpdir}/transient.cnt}" \
  DAG_FETCH_RETRIES="${DAG_FETCH_RETRIES:-3}" DAG_FETCH_RETRY_SLEEP="${DAG_FETCH_RETRY_SLEEP:-0}" \
  zsh "$dag" dashboard "$@"
}

out_dir="${tmpdir}/dash1"

# 1. Happy path exits 0; prints the local server URL + data path.
out=$(run_dash --no-open --out "$out_dir" 2>&1); rc=$?
assert_exit "dash rc" 0 $rc
assert_contains "serving printed" "$out" "Dashboard serving:"
assert_contains "local url printed" "$out" "http://127.0.0.1:8642/"
assert_contains "data path printed" "$out" "${out_dir}/data.json"

# 2. All artifacts staged: data + the built React app.
for f in data.json index.html assets/app.js; do
  if [[ -f "${out_dir}/${f}" ]]; then _ok; else _fail "missing artifact ${f}"; fi
done
if jq -e . "${out_dir}/data.json" >/dev/null 2>&1; then _ok; else _fail "data.json not valid JSON"; fi

# 3. Server invoked local-only: bound to 127.0.0.1 and the staged out_dir.
serve_line=$(tail -1 "${tmpdir}/serve.log" 2>/dev/null)
assert_contains "server module" "$serve_line" "http.server"
assert_contains "server port" "$serve_line" "8642"
assert_contains "server local bind" "$serve_line" "--bind 127.0.0.1"
assert_contains "server directory" "$serve_line" "--directory ${out_dir:A}"

# 4. Keys never leak into stdout or any generated file (cog_ and Windsurf).
if [[ "$out" == *test-cog-key-SECRET* ]]; then _fail "cog key leaked to stdout"; else _ok; fi
if [[ "$out" == *test-windsurf-key-SECRET* ]]; then _fail "windsurf key leaked to stdout"; else _ok; fi
if grep -R "test-cog-key-SECRET" "$out_dir" >/dev/null 2>&1; then _fail "cog key leaked into generated files"; else _ok; fi
if grep -R "test-windsurf-key-SECRET" "$out_dir" >/dev/null 2>&1; then _fail "windsurf key leaked into generated files"; else _ok; fi

# 5. Forecast math deterministic under DAG_NOW_EPOCH.
jqd() { jq -r "$1" "${out_dir}/data.json" }
assert_eq "generated_at" "2026-06-15T08:00:00Z" "$(jqd .generated_at)"
assert_eq "cycle after" "1778918400" "$(jqd .cycle.after)"
assert_eq "cycle before" "1781596800" "$(jqd .cycle.before)"
assert_eq "start_date" "2026-05-16" "$(jqd .cycle.start_date)"
assert_eq "end_date" "2026-06-16" "$(jqd .cycle.end_date)"
assert_eq "cycle_days" "31" "$(jqd .cycle.cycle_days)"
assert_eq "elapsed_days" "30" "$(jqd .cycle.elapsed_days)"
assert_eq "left_days" "1" "$(jqd .cycle.left_days)"
assert_eq "pool" "24000" "$(jqd .pool)"
assert_eq "consumed" "1500" "$(jqd .enterprise.consumed)"
assert_eq "remaining" "22500" "$(jqd .enterprise.remaining)"
assert_eq "daily_run_rate" "50" "$(jqd .enterprise.daily_run_rate)"
assert_eq "projected_cycle_total" "1550" "$(jqd .enterprise.projected_cycle_total)"
assert_eq "projected_over_under" "22450" "$(jqd .enterprise.projected_over_under)"
assert_eq "verdict" "UNDER" "$(jqd .enterprise.verdict)"
assert_eq "capped user total" "550" "$(jqd '.cap_totals.effective_user_cycle_acu_limit')"
assert_eq "capped user count" "4" "$(jqd '.cap_totals.capped_users')"
assert_eq "uncapped user count" "0" "$(jqd '.cap_totals.uncapped_users')"
assert_eq "zero user cap count" "1" "$(jqd '.cap_totals.zero_cap_users')"
assert_eq "split devin" "300" "$(jqd '.product_split[] | select(.product=="devin").acus')"
assert_eq "split cascade" "900" "$(jqd '.product_split[] | select(.product=="cascade").acus')"
assert_eq "split terminal" "240" "$(jqd '.product_split[] | select(.product=="terminal").acus')"
assert_eq "split review" "60" "$(jqd '.product_split[] | select(.product=="review").acus')"
assert_eq "daily count" "3" "$(jqd '.daily | length')"
assert_eq "daily[0] acus" "500" "$(jqd '.daily[0].acus')"
assert_eq "daily[0] cascade" "300" "$(jqd '.daily[0].cascade')"
# Real API serves .date as a Unix epoch (PST midnight); output must carry both forms.
assert_eq "daily[0] epoch" "1778918400" "$(jqd '.daily[0].epoch')"
assert_eq "daily[0] date" "2026-05-16" "$(jqd '.daily[0].date')"
assert_eq "daily[2] date" "2026-06-14" "$(jqd '.daily[2].date')"

# 6. Org status classification covers every branch.
org_field() { jq -r --arg id "$1" ".orgs[] | select(.org_id==\$id)$2" "${out_dir}/data.json" }
assert_eq "org ok" "ok" "$(org_field platform .status)"
assert_eq "org warning" "warning" "$(org_field research .status)"
assert_eq "org critical" "critical" "$(org_field growth .status)"
assert_eq "org forecast_over" "forecast_over" "$(org_field ml .status)"
assert_eq "org over" "over" "$(org_field sandbox .status)"
assert_eq "org uncapped" "uncapped" "$(org_field labs .status)"
assert_eq "org pct_limit" "0.95" "$(org_field growth .pct_limit)"
assert_eq "org projected" "1007.5" "$(org_field ml .projected)"
assert_eq "org run rate" "29" "$(org_field research .daily_run_rate)"
assert_eq "org session cap" "100" "$(org_field platform .max_session_acu_limit)"
assert_eq "org warning boundary (== 0.85)" "warning" "$(org_field edge-warn .status)"
assert_eq "org over boundary (consumed == limit)" "over" "$(org_field edge-over .status)"
assert_eq "org zero cap unused blocked" "blocked" "$(org_field blocked .status)"
assert_eq "warnings count" "5" "$(jqd '.warnings | length')"
assert_contains "warning forecast_over org" "$(jqd '.warnings | join("|")')" "ML"
assert_contains "warning over org" "$(jqd '.warnings | join("|")')" "Sandbox"
assert_contains "warning uncapped org" "$(jqd '.warnings | join("|")')" "Labs"
if [[ "$(jqd '.warnings | join("|")')" == *Blocked* ]]; then
  _fail "zero-usage blocked org should not be over-warning"
else
  _ok
fi

# 7. User section includes each user's consumed ACUs and effective cap.
assert_eq "user count" "4" "$(jqd '.users | length')"
user_field() { jq -r --arg email "$1" ".users[] | select(.email==\$email)$2" "${out_dir}/data.json" }
assert_eq "alice user id preserved" "email|alice" "$(user_field alice@example.com .user_id)"
assert_eq "alice consumed" "120.25" "$(user_field alice@example.com .consumed)"
assert_eq "alice explicit cap" "200" "$(user_field alice@example.com .effective_cycle_acu_limit)"
assert_eq "alice cap source" "explicit" "$(user_field alice@example.com .cap_source)"
assert_eq "alice billing org" "platform" "$(user_field alice@example.com .billing_org_id)"
assert_eq "bob consumed" "80" "$(user_field bob@example.com .consumed)"
assert_eq "bob default cap" "100" "$(user_field bob@example.com .effective_cycle_acu_limit)"
assert_eq "bob cap source" "default" "$(user_field bob@example.com .cap_source)"
assert_eq "chandra status over" "over" "$(user_field chandra@example.com .status)"
assert_eq "chandra headroom" "-10" "$(user_field chandra@example.com .headroom)"
assert_contains "user warning over" "$(jqd '.warnings | join("|")')" "chandra@example.com"
assert_eq "zero explicit cap" "0" "$(user_field zero@example.com .effective_cycle_acu_limit)"
assert_eq "zero cap source" "explicit" "$(user_field zero@example.com .cap_source)"
assert_eq "zero consumed" "0" "$(user_field zero@example.com .consumed)"
assert_eq "zero status blocked" "blocked" "$(user_field zero@example.com .status)"
if [[ "$(jqd '.warnings | join("|")')" == *zero@example.com* ]]; then
  _fail "zero-usage blocked user should not be over-warning"
else
  _ok
fi

# 7e. Per-user detail data: daily series with both date forms + product split.
assert_eq "alice daily count" "2" "$(user_field alice@example.com '.daily | length')"
assert_eq "alice daily[0] epoch" "1778918400" "$(user_field alice@example.com '.daily[0].epoch')"
assert_eq "alice daily[0] date" "2026-05-16" "$(user_field alice@example.com '.daily[0].date')"
assert_eq "alice daily[0] acus" "40" "$(user_field alice@example.com '.daily[0].acus')"
assert_eq "alice daily[1] acus" "80.25" "$(user_field alice@example.com '.daily[1].acus')"
assert_eq "alice daily[1] cascade" "50.25" "$(user_field alice@example.com '.daily[1].cascade')"
assert_eq "alice product cascade total" "75.25" "$(user_field alice@example.com '.product_totals.cascade')"
assert_eq "alice product devin total" "30" "$(user_field alice@example.com '.product_totals.devin')"
assert_eq "bob daily string date kept" "2026-06-10" "$(user_field bob@example.com '.daily[0].date')"
assert_eq "zero daily empty" "0" "$(user_field zero@example.com '.daily | length')"

# 7f. Devin Cloud session stats grouped per user; service-user sessions excluded
#     from user rows but counted in the enterprise total.
assert_eq "sessions available" "true" "$(jqd '.sessions_info.available')"
assert_eq "sessions total count" "5" "$(jqd '.sessions_info.count')"
assert_eq "sessions total acus" "21.5" "$(jqd '.sessions_info.acus')"
assert_eq "alice session count" "2" "$(user_field alice@example.com '.sessions.count')"
assert_eq "alice session acus" "12.5" "$(user_field alice@example.com '.sessions.acus')"
assert_eq "bob session count" "1" "$(user_field bob@example.com '.sessions.count')"
assert_eq "zero session count" "0" "$(user_field zero@example.com '.sessions.count')"
if grep -E "v3/enterprise/sessions\?first=200&created_after=1778918400&created_before=1781596800" "${tmpdir}/curl-urls.log" >/dev/null; then
  _ok
else
  _fail "sessions request missing cycle window"
fi

# 7g. Windsurf model/IDE analytics joined per user, aggregated + sorted by ACUs.
assert_eq "model analytics available" "true" "$(jqd '.model_analytics.available')"
assert_eq "model analytics stale" "false" "$(jqd '.model_analytics.stale')"
assert_eq "model analytics start" "2026-05-16" "$(jqd '.model_analytics.start_date')"
assert_eq "model analytics end" "2026-06-15" "$(jqd '.model_analytics.end_date')"
assert_eq "alice model count" "2" "$(user_field alice@example.com '.models | length')"
assert_eq "alice top model" "claude-sonnet-4-6" "$(user_field alice@example.com '.models[0].model')"
assert_eq "alice top model acus" "40" "$(user_field alice@example.com '.models[0].acus')"
assert_eq "alice top model messages" "153" "$(user_field alice@example.com '.models[0].messages')"
assert_eq "alice chisel ide acus" "30.5" "$(user_field alice@example.com '.ides[] | select(.ide=="chisel").acus')"
assert_eq "alice ide count" "2" "$(user_field alice@example.com '.ides | length')"
assert_eq "bob model" "gpt-6" "$(user_field bob@example.com '.models[0].model')"
assert_eq "zero models empty" "0" "$(user_field zero@example.com '.models | length')"
if grep -E "api/v2alpha/analytics/consumption\?start_date=2026-05-16&end_date=2026-06-15&product=agent&group_by=user,model_uid,ide" "${tmpdir}/curl-urls.log" >/dev/null; then
  _ok
else
  _fail "windsurf analytics request missing cycle dates or grouping"
fi

# 7a. User IDs with reserved characters are URL-encoded in read endpoints.
curl_log="${tmpdir}/curl-urls.log"
if grep -F "email%7Calice" "$curl_log" >/dev/null 2>&1; then _ok; else _fail "encoded alice user_id not requested"; fi
if grep -F "okta%7CTeam%7Cchandra" "$curl_log" >/dev/null 2>&1; then _ok; else _fail "encoded okta user_id not requested"; fi

# 7b. User table keeps Billing org as the last visible column, with Status shifted left.
user_table_src="${script_dir}/../web/dashboard-app/src/components/UserTable.tsx"
status_line=$(grep -n "label: 'Status'" "$user_table_src" | cut -d: -f1)
source_line=$(grep -n "label: 'Cap source'" "$user_table_src" | cut -d: -f1)
org_line=$(grep -n "label: 'Billing org'" "$user_table_src" | cut -d: -f1)
if (( status_line < source_line && source_line < org_line )); then
  _ok
else
  _fail "user table column order should be Status, Cap source, Billing org at the right edge"
fi
app_src=$(<"${script_dir}/../web/dashboard-app/src/App.tsx")
assert_contains "top card labels capped user total" "$app_src" "Capped user total"
assert_contains "top card renders capped total field" "$app_src" "cap_totals.effective_user_cycle_acu_limit"
assert_contains "app wires refresh controls" "$app_src" "RefreshControls"
assert_contains "app passes manual refresh handler" "$app_src" "refreshNow"
assert_contains "app passes refresh status" "$app_src" "status={status}"
controls_src=$(<"${script_dir}/../web/dashboard-app/src/components/RefreshControls.tsx")
assert_contains "controls refresh button" "$controls_src" "Refresh now"
assert_contains "controls refreshing percentage" "$controls_src" "Refreshing "
assert_contains "controls countdown label" "$controls_src" "next refresh in"
assert_contains "controls countdown source" "$controls_src" "next_refresh_epoch"
assert_contains "controls progress bar" "$controls_src" "refresh-progress"
hook_src=$(<"${script_dir}/../web/dashboard-app/src/useDashboardData.ts")
assert_contains "hook exposes manual refresh" "$hook_src" "refreshNow"
assert_contains "hook polls status channel" "$hook_src" "status.json"
assert_contains "hook exposes refresh status" "$hook_src" "status:"
assert_contains "hook refetches on new snapshot" "$hook_src" "generated_at !== generatedAt.current"

# 7h. Per-user detail view wired into the app: explicit Details buttons open
#     the drawer; email copy has its own button and does not select rows.
detail_src=$(<"${script_dir}/../web/dashboard-app/src/components/UserDetail.tsx")
assert_contains "detail daily chart" "$detail_src" "Daily ACU usage"
assert_contains "detail models panel" "$detail_src" "Models"
assert_contains "detail surfaces panel" "$detail_src" "Surfaces"
assert_contains "detail cloud sessions card" "$detail_src" "Devin Cloud sessions"
assert_contains "detail session acus card" "$detail_src" "Cloud session ACUs"
assert_contains "detail devin desktop label" "$detail_src" "Devin Desktop"
assert_contains "detail esc to close" "$detail_src" "Escape"
sortable_src=$(<"${script_dir}/../web/dashboard-app/src/components/SortableTable.tsx")
assert_contains "table supports optional row click" "$sortable_src" "onRowClick"
assert_contains "app renders user detail" "$app_src" "UserDetail"
assert_contains "app tracks selected user" "$app_src" "selectedUserId"
user_table_src_body=$(<"$user_table_src")
assert_contains "user table copy button label" "$user_table_src_body" 'aria-label={`Copy ${user.email}`}'
assert_contains "user table copy uses clipboard" "$user_table_src_body" "copyToClipboard(user.email)"
assert_contains "user table details button label" "$user_table_src_body" 'aria-label={`Open details for ${user.email || user.name || user.user_id}`}'
assert_contains "user table details selects user" "$user_table_src_body" "onSelect(user)"
if [[ "$user_table_src_body" == *"onRowClick={onSelect}"* ]]; then
  _fail "user table does not forward row click: unexpected onRowClick={onSelect}"
else
  _ok
fi

# 7c. --refresh records backend cadence metadata; loop honors REFRESH_ONCE.
out=$(DAG_DASHBOARD_SERVE_ONCE="" DAG_DASHBOARD_REFRESH_ONCE=1 \
  run_dash --refresh 30 --no-open --out "${tmpdir}/dash-refresh" 2>&1); rc=$?
assert_exit "refresh rc" 0 $rc
assert_contains "refresh stdout" "$out" "data refetched every 30 minute(s) in the background"
assert_eq "refresh enabled" "true" "$(jq -r '.refresh.enabled' "${tmpdir}/dash-refresh/data.json")"
assert_eq "refresh minutes" "30" "$(jq -r '.refresh.interval_minutes' "${tmpdir}/dash-refresh/data.json")"
assert_eq "refresh ms" "1800000" "$(jq -r '.refresh.interval_ms' "${tmpdir}/dash-refresh/data.json")"
# status.json refresh channel: a one-shot refresh settles on the static state,
# carrying the snapshot timestamp the browser uses to detect a fresh data.json.
if [[ -f "${tmpdir}/dash-refresh/status.json" ]]; then _ok; else _fail "refresh run wrote no status.json"; fi
assert_eq "refresh status state" "static" "$(jq -r '.state' "${tmpdir}/dash-refresh/status.json")"
assert_eq "refresh status gen matches data" \
  "$(jq -r '.generated_at' "${tmpdir}/dash-refresh/data.json")" \
  "$(jq -r '.generated_at' "${tmpdir}/dash-refresh/status.json")"

# 7d. --refresh only accepts the supported 5/10/15/30 minute intervals.
out=$(run_dash --refresh 7 --no-open --out "${tmpdir}/dash-refresh-bad" 2>&1); rc=$?
assert_exit "bad refresh rc" 2 $rc
assert_contains "bad refresh hint" "$out" "5, 10, 15, or 30"

# 8. Failed required read: non-zero exit, exact response body quoted, no app staged.
out=$(FAKE_CYCLES_CODE=500 FAKE_CYCLES_BODY='{"detail":"cycles exploded"}' \
  run_dash --no-open --out "${tmpdir}/dash-err" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "API failure must exit non-zero"; fi
assert_contains "error body quoted" "$out" '{"detail":"cycles exploded"}'
if [[ -f "${tmpdir}/dash-err/index.html" || -f "${tmpdir}/dash-err/data.json" ]]; then _fail "wrote dashboard despite API failure"; else _ok; fi

# 8b. Every other required read failure path also quotes the exact body.
out=$(FAKE_DAILY_CODE=500 FAKE_DAILY_BODY='{"detail":"daily down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err2" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "daily failure must exit non-zero"; fi
assert_contains "daily error body" "$out" '{"detail":"daily down"}'
out=$(FAKE_ORGS_CODE=502 FAKE_ORGS_BODY='{"detail":"orgs down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err3" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "orgs failure must exit non-zero"; fi
assert_contains "orgs error body" "$out" '{"detail":"orgs down"}'
out=$(FAKE_ORG_DAILY_CODE=503 FAKE_ORG_DAILY_BODY='{"detail":"org daily down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err4" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "org-daily failure must exit non-zero"; fi
assert_contains "org-daily error body" "$out" '{"detail":"org daily down"}'
out=$(FAKE_USERS_CODE=500 FAKE_USERS_BODY='{"detail":"users down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err-users" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "users failure must exit non-zero"; fi
assert_contains "users error body" "$out" '{"detail":"users down"}'
out=$(FAKE_USER_DAILY_CODE=500 FAKE_USER_DAILY_BODY='{"detail":"user daily down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err-user-daily" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "user daily failure must exit non-zero"; fi
assert_contains "user daily error body" "$out" '{"detail":"user daily down"}'
out=$(FAKE_USER_LIMIT_CODE=500 FAKE_USER_LIMIT_BODY='{"detail":"user limit down"}' \
  run_dash --no-open --out "${tmpdir}/dash-err-user-limit" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "user limit failure must exit non-zero"; fi
assert_contains "user limit error body" "$out" '{"detail":"user limit down"}'

# 8c. Invalid JSON in a 200 body fails loudly — must never zero an org silently.
out=$(FAKE_ORG_DAILY_BODY='not json' run_dash --no-open --out "${tmpdir}/dash-err5" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "invalid 200 body must exit non-zero"; fi
assert_contains "invalid body quoted" "$out" "not json"

# 8d. curl transport failure (rc != 0) despite an HTTP 200 fails loudly.
out=$(FAKE_CURL_RC=18 run_dash --no-open --out "${tmpdir}/dash-err6" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "curl transport failure must exit non-zero"; fi
assert_contains "curl rc reported" "$out" "curl exit 18"

# 8e. Transient 504 on a per-user ACU-limit endpoint recovers on retry:
#     dashboard exits 0 and that user's EXPLICIT cap survives (not degraded).
cnt="${tmpdir}/t-recover.cnt"; rm -f "$cnt"
out=$(FAKE_TRANSIENT_URL="email%7Calice/consumption/acu-limits" FAKE_TRANSIENT_TIMES=2 \
  FAKE_TRANSIENT_CODE=504 TRANSIENT_COUNTER="$cnt" DAG_FETCH_RETRIES=3 DAG_FETCH_RETRY_SLEEP=0 \
  run_dash --no-open --out "${tmpdir}/dash-504-recover" 2>&1); rc=$?
assert_exit "504 recover rc" 0 $rc
assert_contains "504 retry logged" "$out" "transient; retry"
assert_eq "504 recover attempts" "2" "$(<"$cnt")"
ufr() { jq -r --arg e "$1" ".users[] | select(.email==\$e)$2" "${tmpdir}/dash-504-recover/data.json" }
assert_eq "504 recover alice cap" "200" "$(ufr alice@example.com .effective_cycle_acu_limit)"
assert_eq "504 recover alice source" "explicit" "$(ufr alice@example.com .cap_source)"

# 8f. Persistent 504 on a per-user ACU-limit endpoint degrades gracefully:
#     dashboard still exits 0; that user falls back to the default cap.
cnt="${tmpdir}/t-degrade.cnt"; rm -f "$cnt"
out=$(FAKE_TRANSIENT_URL="email%7Calice/consumption/acu-limits" FAKE_TRANSIENT_TIMES=-1 \
  FAKE_TRANSIENT_CODE=504 TRANSIENT_COUNTER="$cnt" DAG_FETCH_RETRIES=2 DAG_FETCH_RETRY_SLEEP=0 \
  run_dash --no-open --out "${tmpdir}/dash-504-degrade" 2>&1); rc=$?
assert_exit "504 degrade rc" 0 $rc
assert_contains "504 degrade warned" "$out" "using default cap"
udg() { jq -r --arg e "$1" ".users[] | select(.email==\$e)$2" "${tmpdir}/dash-504-degrade/data.json" }
assert_eq "504 degrade alice cap" "100" "$(udg alice@example.com .effective_cycle_acu_limit)"
assert_eq "504 degrade alice source" "default" "$(udg alice@example.com .cap_source)"
if [[ -f "${tmpdir}/dash-504-degrade/index.html" ]]; then _ok; else _fail "degraded run staged no app"; fi

# 8g. Persistent 504 on the default ACU-limit endpoint degrades: users without an
#     explicit cap show uncapped; the dashboard still renders.
cnt="${tmpdir}/t-defdeg.cnt"; rm -f "$cnt"
out=$(FAKE_TRANSIENT_URL="users/consumption/acu-limits" FAKE_TRANSIENT_TIMES=-1 \
  FAKE_TRANSIENT_CODE=504 TRANSIENT_COUNTER="$cnt" DAG_FETCH_RETRIES=2 DAG_FETCH_RETRY_SLEEP=0 \
  run_dash --no-open --out "${tmpdir}/dash-504-defdeg" 2>&1); rc=$?
assert_exit "504 default-limit degrade rc" 0 $rc
assert_contains "504 default-limit warned" "$out" "default ACU-limit endpoint unavailable"
udd() { jq -r --arg e "$1" ".users[] | select(.email==\$e)$2" "${tmpdir}/dash-504-defdeg/data.json" }
assert_eq "504 default-limit bob uncapped" "uncapped" "$(udd bob@example.com .status)"
assert_eq "504 default-limit alice explicit kept" "explicit" "$(udd alice@example.com .cap_source)"

# 8h. A hard 500 (not a gateway-timeout class) on a per-user limit stays FATAL —
#     retry/degrade applies only to transient 429/502/503/504, not real errors.
out=$(FAKE_USER_LIMIT_CODE=500 FAKE_USER_LIMIT_BODY='{"detail":"hard 500"}' \
  run_dash --no-open --out "${tmpdir}/dash-hard500" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "hard 500 on user limit must stay fatal"; fi
if [[ "$out" == *"transient; retry"* ]]; then _fail "500 was retried as transient"; else _ok; fi

# 8i. Sessions endpoint failure (e.g. missing ViewOrgSessions) degrades:
#     dashboard renders, user session stats null, enterprise section flagged off.
out=$(FAKE_SESSIONS_CODE=500 FAKE_SESSIONS_BODY='{"detail":"sessions denied"}' \
  run_dash --no-open --out "${tmpdir}/dash-nosess" 2>&1); rc=$?
assert_exit "sessions degrade rc" 0 $rc
assert_contains "sessions degrade warned" "$out" "Devin Cloud session stats"
nsf() { jq -r "$1" "${tmpdir}/dash-nosess/data.json" }
assert_eq "sessions degrade available" "false" "$(nsf '.sessions_info.available')"
assert_eq "sessions degrade user null" "null" "$(nsf '.users[] | select(.email=="alice@example.com").sessions')"
if [[ -f "${tmpdir}/dash-nosess/index.html" ]]; then _ok; else _fail "sessions-degraded run staged no app"; fi

# 8j. No Windsurf service key: model analytics marked unavailable with reason;
#     user model/IDE lists empty; dashboard renders.
: > "${tmpdir}/curl-urls.log"
out=$(TEST_WINDSURF_KEY="" run_dash --no-open --out "${tmpdir}/dash-nowskey" 2>&1); rc=$?
assert_exit "no windsurf key rc" 0 $rc
nwk() { jq -r "$1" "${tmpdir}/dash-nowskey/data.json" }
assert_eq "no windsurf key available" "false" "$(nwk '.model_analytics.available')"
assert_eq "no windsurf key reason" "no_windsurf_key" "$(nwk '.model_analytics.reason')"
assert_eq "no windsurf key models empty" "0" "$(nwk '.users[] | select(.email=="alice@example.com") | .models | length')"
if grep -F "api/v2alpha/analytics/consumption" "${tmpdir}/curl-urls.log" >/dev/null 2>&1; then
  _fail "windsurf API called without a key"
else
  _ok
fi

# 8k. Windsurf refusal (429 rate limit) with no previous snapshot: unavailable
#     with reason fetch_failed; dashboard still renders.
out=$(FAKE_WINDSURF_CODE=429 run_dash --no-open --out "${tmpdir}/dash-ws429" 2>&1); rc=$?
assert_exit "windsurf 429 rc" 0 $rc
assert_contains "windsurf 429 warned" "$out" "model analytics unavailable"
assert_eq "windsurf 429 available" "false" "$(jq -r '.model_analytics.available' "${tmpdir}/dash-ws429/data.json")"
assert_eq "windsurf 429 reason" "fetch_failed" "$(jq -r '.model_analytics.reason' "${tmpdir}/dash-ws429/data.json")"

# 8l. Windsurf refusal WITH a previous good snapshot in the out dir: the prior
#     model/IDE section is carried forward and flagged stale; per-user model
#     splits survive. (TTL forced to 0 so the refetch is attempted.)
wsdir="${tmpdir}/dash-ws-carry"
out=$(run_dash --no-open --out "$wsdir" 2>&1); rc=$?
assert_exit "carry-forward seed rc" 0 $rc
out=$(FAKE_WINDSURF_CODE=429 DAG_MODEL_ANALYTICS_TTL_MINUTES=0 \
  run_dash --no-open --out "$wsdir" 2>&1); rc=$?
assert_exit "carry-forward rc" 0 $rc
assert_contains "carry-forward warned" "$out" "carrying previous snapshot forward"
cff() { jq -r "$1" "${wsdir}/data.json" }
assert_eq "carry-forward available" "true" "$(cff '.model_analytics.available')"
assert_eq "carry-forward stale" "true" "$(cff '.model_analytics.stale')"
assert_eq "carry-forward alice top model" "claude-sonnet-4-6" "$(cff '.users[] | select(.email=="alice@example.com").models[0].model')"

# 8m. Within the TTL the previous section is reused without any Windsurf request
#     (the API allows 10 req/hr/team) — even though the endpoint would fail.
: > "${tmpdir}/curl-urls.log"
out=$(FAKE_WINDSURF_CODE=500 run_dash --no-open --out "$wsdir" 2>&1); rc=$?
assert_exit "ttl reuse rc" 0 $rc
assert_eq "ttl reuse available" "true" "$(cff '.model_analytics.available')"
if grep -F "api/v2alpha/analytics/consumption" "${tmpdir}/curl-urls.log" >/dev/null 2>&1; then
  _fail "windsurf API refetched inside the TTL"
else
  _ok
fi

# 9. dag help lists the dashboard command and its flags.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=k zsh "$dag" help 2>&1); rc=$?
assert_exit "help rc" 0 $rc
assert_contains "help lists dashboard" "$out" "dashboard"
assert_contains "help lists refresh" "$out" "--refresh"
assert_contains "help lists port" "$out" "--port"

# 10. DAG_PRINT_PROMPT=1 still runs the local path — no playbook prompt, no agent.
out=$(DAG_PRINT_PROMPT=1 run_dash --no-open --out "${tmpdir}/dash-pp" 2>&1); rc=$?
assert_exit "print-prompt rc" 0 $rc
if [[ "$out" == *"# Playbook"* ]]; then _fail "dashboard assembled a playbook prompt"; else _ok; fi
if [[ -f "${tmpdir}/dash-pp/index.html" ]]; then _ok; else _fail "print-prompt run staged no app"; fi

# 11. --json-only writes only data.json; never opens, never serves, never builds.
: > "${tmpdir}/open.log"; : > "${tmpdir}/serve.log"
out=$(run_dash --json-only --out "${tmpdir}/dash-json" 2>&1); rc=$?
assert_exit "json-only rc" 0 $rc
if [[ -f "${tmpdir}/dash-json/data.json" ]]; then _ok; else _fail "json-only data.json missing"; fi
if [[ -f "${tmpdir}/dash-json/index.html" ]]; then _fail "json-only staged app files"; else _ok; fi
if [[ -s "${tmpdir}/open.log" ]]; then _fail "json-only invoked open"; else _ok; fi
if [[ -s "${tmpdir}/serve.log" ]]; then _fail "json-only started a server"; else _ok; fi

# 12. Default (no --no-open) opens the local server URL, not a file://.
: > "${tmpdir}/open.log"
out=$(run_dash --out "${tmpdir}/dash-open" 2>&1); rc=$?
assert_exit "open rc" 0 $rc
assert_contains "open called with url" "$(cat "${tmpdir}/open.log" 2>/dev/null)" "http://127.0.0.1:8642/"

# 12b. --port pins the server port; the opened URL follows.
: > "${tmpdir}/open.log"; : > "${tmpdir}/serve.log"
out=$(run_dash --port 9001 --out "${tmpdir}/dash-port" 2>&1); rc=$?
assert_exit "port rc" 0 $rc
assert_contains "port url opened" "$(cat "${tmpdir}/open.log" 2>/dev/null)" "http://127.0.0.1:9001/"
assert_contains "server got port" "$(tail -1 "${tmpdir}/serve.log")" "9001"

# 12c. Server that dies on startup fails loudly.
out=$(DAG_DASHBOARD_PYTHON="${tmpdir}/deadpy/python3" \
  run_dash --no-open --out "${tmpdir}/dash-deadsrv" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "dead server must exit non-zero"; fi
assert_contains "dead server message" "$out" "failed to start"

# 13. Pool smaller than projection flips verdict to OVER.
out=$(DAG_MONTHLY_ACU_POOL=1000 run_dash --no-open --out "${tmpdir}/dash-over" 2>&1); rc=$?
assert_exit "over rc" 0 $rc
assert_eq "verdict OVER" "OVER" "$(jq -r .enterprise.verdict "${tmpdir}/dash-over/data.json")"
assert_eq "over delta" "-550" "$(jq -r .enterprise.projected_over_under "${tmpdir}/dash-over/data.json")"

# 14. Unknown flag -> exit 2; --out followed by a flag -> exit 2; bad --port -> exit 2.
out=$(run_dash --bogus 2>&1); rc=$?
assert_exit "bogus flag rc" 2 $rc
out=$(run_dash --out --no-open 2>&1); rc=$?
assert_exit "out-eats-flag rc" 2 $rc
out=$(run_dash --port nope 2>&1); rc=$?
assert_exit "bad port rc" 2 $rc

# 15. No cog key -> exit 1 with setup hint.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DAG_STATE_DIR="${tmpdir}/state" \
  zsh "$dag" dashboard --no-open --out "${tmpdir}/dash-nokey" 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "devin-cog-key"

# 16. Default output dir is $DAG_STATE_DIR/dashboard/latest.
out=$(run_dash --no-open 2>&1); rc=$?
assert_exit "default out rc" 0 $rc
if [[ -f "${tmpdir}/state/dashboard/latest/index.html" ]]; then _ok; else _fail "default out dir missing index.html"; fi

# 17. First run with no dist builds the app once (npm install + build); the
#     second run reuses the dist without invoking npm again.
freshapp="${tmpdir}/freshapp"
mkdir -p "$freshapp"
print -r -- '{"name":"fresh"}' > "${freshapp}/package.json"
NPM_LOG="${tmpdir}/npm-fresh.log"; : > "$NPM_LOG"
out=$(DAG_DASHBOARD_APP_DIR="$freshapp" NPM_LOG="$NPM_LOG" \
  run_dash --no-open --out "${tmpdir}/dash-build" 2>&1); rc=$?
assert_exit "build rc" 0 $rc
assert_contains "build announced" "$out" "Building dashboard app (one-time)"
assert_contains "npm install ran" "$(cat "$NPM_LOG")" "install"
assert_contains "npm build ran" "$(cat "$NPM_LOG")" "run build"
if [[ -f "${freshapp}/dist/index.html" ]]; then _ok; else _fail "build produced no dist"; fi
: > "$NPM_LOG"
out=$(DAG_DASHBOARD_APP_DIR="$freshapp" NPM_LOG="$NPM_LOG" \
  run_dash --no-open --out "${tmpdir}/dash-build2" 2>&1); rc=$?
assert_exit "rebuild-skip rc" 0 $rc
if [[ -s "$NPM_LOG" ]]; then _fail "second run re-invoked npm"; else _ok; fi
unset NPM_LOG

# 17b. Missing npm with no dist fails with a Node.js hint.
nodist="${tmpdir}/nodist-app"
mkdir -p "$nodist"
print -r -- '{"name":"nodist"}' > "${nodist}/package.json"
out=$(DAG_DASHBOARD_APP_DIR="$nodist" DAG_DASHBOARD_NPM="/nonexistent-npm" \
  run_dash --no-open --out "${tmpdir}/dash-nonpm" 2>&1); rc=$?
assert_exit "no-npm rc" 1 $rc
assert_contains "no-npm hint" "$out" "install Node.js"

# 17c. Missing app source fails loudly.
out=$(DAG_DASHBOARD_APP_DIR="${tmpdir}/no-such-app" \
  run_dash --no-open --out "${tmpdir}/dash-noapp" 2>&1); rc=$?
assert_exit "no-app rc" 1 $rc
assert_contains "no-app message" "$out" "app source missing"

# 18. String "YYYY-MM-DD" dates (docs shape) handled alongside live epoch dates.
out=$(FAKE_DAILY_BODY='{"total_acus":100,"consumption_by_date":[{"date":"2026-05-20","acus":100,"acus_by_product":{"devin":100,"cascade":0,"terminal":0,"review":0}}]}' \
  run_dash --no-open --out "${tmpdir}/dash-str" 2>&1); rc=$?
assert_exit "string date rc" 0 $rc
assert_eq "string date kept" "2026-05-20" "$(jq -r '.daily[0].date' "${tmpdir}/dash-str/data.json")"
assert_eq "string date epoch" "1779235200" "$(jq -r '.daily[0].epoch' "${tmpdir}/dash-str/data.json")"

# 19. Read-only contract: no run ever sent a curl write verb (-X/--data/...).
if [[ -s "${tmpdir}/write.log" ]]; then
  _fail "curl write verb used: $(cat "${tmpdir}/write.log" | tr '\n' ' ')"
else
  _ok
fi

# 20. Refresh-status channel helpers (unit): status.json schema + state machine
#     and the human-friendly duration the terminal countdown / browser share.
daemon_dir="${script_dir:A}/.."
source "${daemon_dir}/lib/dashboard.zsh"
sdir=$(mktemp -d)
print -r -- '{"generated_at":"2026-06-15T08:00:00Z"}' > "${sdir}/data.json"

_dag_dash_status_write "$sdir" refreshing 42 "user dailies" "3/40" 0 0 "2026-06-15T08:00:00Z"
if jq -e . "${sdir}/status.json" >/dev/null 2>&1; then _ok; else _fail "status.json not valid JSON"; fi
assert_eq "status state refreshing" "refreshing" "$(jq -r '.state' "${sdir}/status.json")"
assert_eq "status pct" "42" "$(jq -r '.pct' "${sdir}/status.json")"
assert_eq "status phase" "user dailies" "$(jq -r '.phase' "${sdir}/status.json")"
assert_eq "status detail" "3/40" "$(jq -r '.detail' "${sdir}/status.json")"
assert_eq "status generated_at carried" "2026-06-15T08:00:00Z" "$(jq -r '.generated_at' "${sdir}/status.json")"
assert_eq "status no countdown while refreshing" "null" "$(jq -r '.next_refresh_epoch' "${sdir}/status.json")"

_dag_dash_status_write "$sdir" counting_down 0 "" "" 300 1781510700 "2026-06-15T08:00:00Z"
assert_eq "status counting_down state" "counting_down" "$(jq -r '.state' "${sdir}/status.json")"
assert_eq "status next refresh epoch" "1781510700" "$(jq -r '.next_refresh_epoch' "${sdir}/status.json")"
assert_eq "status interval seconds" "300" "$(jq -r '.interval_seconds' "${sdir}/status.json")"

_dag_dash_status_static "$sdir"
assert_eq "status static state" "static" "$(jq -r '.state' "${sdir}/status.json")"
assert_eq "status static reads generated_at from data" "2026-06-15T08:00:00Z" "$(jq -r '.generated_at' "${sdir}/status.json")"

# Missing out_dir is a no-op (never errors mid-refresh on an unwritten dir).
_dag_dash_status_write "${sdir}/nope" refreshing 10 "x" "" 0 0 ""
if [[ -f "${sdir}/nope/status.json" ]]; then _fail "status written into nonexistent dir"; else _ok; fi

assert_eq "fmt_dur seconds" "45s" "$(_dag_dash_fmt_dur 45)"
assert_eq "fmt_dur minutes" "4m 32s" "$(_dag_dash_fmt_dur 272)"
assert_eq "fmt_dur hours" "1h 5m" "$(_dag_dash_fmt_dur 3900)"
assert_eq "fmt_dur clamps negative" "0s" "$(_dag_dash_fmt_dur -3)"
rm -rf "$sdir"

report
