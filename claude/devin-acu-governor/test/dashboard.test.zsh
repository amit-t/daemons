#!/usr/bin/env zsh
# dag dashboard — local read-only ACU burn dashboard.
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
# "\n<http_code>" exactly like curl -w '\n%{http_code}'.
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env zsh
url=""
for a in "$@"; do url="$a"; done
emit() {  # $1 body-file  $2 code  $3 body-override
  if [[ -n "${3:-}" ]]; then print -rn -- "$3"; else cat "$1"; fi
  print -rn -- $'\n'"$2"
}
case "$url" in
  *consumption/cycles*)
    emit "${FIXTURES}/cycles.json" "${FAKE_CYCLES_CODE:-200}" "${FAKE_CYCLES_BODY:-}" ;;
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

now_epoch=1781510400   # 2026-06-15T08:00:00Z — day 30 of the 31-day fixture cycle

run_dash() {
  PATH="${tmpdir}/bin:$PATH" FIXTURES="$fixdir" OPEN_LOG="${tmpdir}/open.log" \
  DEVIN_COG_KEY=test-cog-key-SECRET DAG_NOW_EPOCH=$now_epoch \
  DAG_STATE_DIR="${tmpdir}/state" \
  DAG_MONTHLY_ACU_POOL="${DAG_MONTHLY_ACU_POOL:-}" DAG_PRINT_PROMPT="${DAG_PRINT_PROMPT:-}" \
  FAKE_CYCLES_CODE="${FAKE_CYCLES_CODE:-200}" FAKE_CYCLES_BODY="${FAKE_CYCLES_BODY:-}" \
  FAKE_DAILY_CODE="${FAKE_DAILY_CODE:-200}" FAKE_DAILY_BODY="${FAKE_DAILY_BODY:-}" \
  FAKE_ORGS_CODE="${FAKE_ORGS_CODE:-200}" FAKE_ORGS_BODY="${FAKE_ORGS_BODY:-}" \
  FAKE_ORG_DAILY_CODE="${FAKE_ORG_DAILY_CODE:-200}" FAKE_ORG_DAILY_BODY="${FAKE_ORG_DAILY_BODY:-}" \
  zsh "$dag" dashboard "$@"
}

out_dir="${tmpdir}/dash1"

# 1. Happy path exits 0; prints paths + file:// URL.
out=$(run_dash --no-open --out "$out_dir" 2>&1); rc=$?
assert_exit "dash rc" 0 $rc
assert_contains "paths printed" "$out" "dashboard.html"
assert_contains "open url printed" "$out" "file://"

# 2. All artifacts written.
for f in dashboard.html dashboard-data.js dashboard.css dashboard.js data.json; do
  if [[ -f "${out_dir}/${f}" ]]; then _ok; else _fail "missing artifact ${f}"; fi
done

# 3. dashboard-data.js carries the injection marker; data.json is valid JSON.
assert_contains "data marker" "$(cat "${out_dir}/dashboard-data.js")" "window.DAG_DASHBOARD_DATA ="
if jq -e . "${out_dir}/data.json" >/dev/null 2>&1; then _ok; else _fail "data.json not valid JSON"; fi

# 4. Key never leaks into stdout or any generated file.
if [[ "$out" == *test-cog-key-SECRET* ]]; then _fail "key leaked to stdout"; else _ok; fi
if grep -R "test-cog-key-SECRET" "$out_dir" >/dev/null 2>&1; then _fail "key leaked into generated files"; else _ok; fi

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
assert_eq "warnings count" "3" "$(jqd '.warnings | length')"
assert_contains "warning forecast_over org" "$(jqd '.warnings | join("|")')" "ML"
assert_contains "warning over org" "$(jqd '.warnings | join("|")')" "Sandbox"
assert_contains "warning uncapped org" "$(jqd '.warnings | join("|")')" "Labs"

# 7. Failed required read: non-zero exit, exact response body quoted, no files.
out=$(FAKE_CYCLES_CODE=500 FAKE_CYCLES_BODY='{"detail":"cycles exploded"}' \
  run_dash --no-open --out "${tmpdir}/dash-err" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "API failure must exit non-zero"; fi
assert_contains "error body quoted" "$out" '{"detail":"cycles exploded"}'
if [[ -f "${tmpdir}/dash-err/dashboard.html" ]]; then _fail "wrote dashboard despite API failure"; else _ok; fi

# 8. dag help lists the dashboard command.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=k zsh "$dag" help 2>&1); rc=$?
assert_exit "help rc" 0 $rc
assert_contains "help lists dashboard" "$out" "dashboard"

# 9. DAG_PRINT_PROMPT=1 still runs the local path — no playbook prompt, no agent.
out=$(DAG_PRINT_PROMPT=1 run_dash --no-open --out "${tmpdir}/dash-pp" 2>&1); rc=$?
assert_exit "print-prompt rc" 0 $rc
if [[ "$out" == *"# Playbook"* ]]; then _fail "dashboard assembled a playbook prompt"; else _ok; fi
if [[ -f "${tmpdir}/dash-pp/dashboard.html" ]]; then _ok; else _fail "print-prompt run wrote no dashboard"; fi

# 10. --json-only writes only the data artifacts; never opens.
out=$(run_dash --json-only --out "${tmpdir}/dash-json" 2>&1); rc=$?
assert_exit "json-only rc" 0 $rc
if [[ -f "${tmpdir}/dash-json/data.json" && -f "${tmpdir}/dash-json/dashboard-data.js" ]]; then _ok; else _fail "json-only data artifacts missing"; fi
if [[ -f "${tmpdir}/dash-json/dashboard.html" ]]; then _fail "json-only wrote app files"; else _ok; fi

# 11. Default (no --no-open) invokes open on the html.
: > "${tmpdir}/open.log"
out=$(run_dash --out "${tmpdir}/dash-open" 2>&1); rc=$?
assert_exit "open rc" 0 $rc
assert_contains "open called with html" "$(cat "${tmpdir}/open.log" 2>/dev/null)" "dash-open/dashboard.html"

# 12. Pool smaller than projection flips verdict to OVER.
out=$(DAG_MONTHLY_ACU_POOL=1000 run_dash --no-open --out "${tmpdir}/dash-over" 2>&1); rc=$?
assert_exit "over rc" 0 $rc
assert_eq "verdict OVER" "OVER" "$(jq -r .enterprise.verdict "${tmpdir}/dash-over/data.json")"
assert_eq "over delta" "-550" "$(jq -r .enterprise.projected_over_under "${tmpdir}/dash-over/data.json")"

# 13. Unknown flag -> exit 2.
out=$(run_dash --bogus 2>&1); rc=$?
assert_exit "bogus flag rc" 2 $rc

# 14. No cog key -> exit 1 with setup hint.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DAG_STATE_DIR="${tmpdir}/state" \
  zsh "$dag" dashboard --no-open --out "${tmpdir}/dash-nokey" 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "devin-cog-key"

# 15. Default output dir is $DAG_STATE_DIR/dashboard/latest.
out=$(run_dash --no-open 2>&1); rc=$?
assert_exit "default out rc" 0 $rc
if [[ -f "${tmpdir}/state/dashboard/latest/dashboard.html" ]]; then _ok; else _fail "default out dir missing dashboard.html"; fi

report
