#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dve="${script_dir}/../bin/dve"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

# Fake security: always miss, so env vars drive key resolution.
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

# Fake curl: echo an HTTP code chosen by the endpoint URL (last arg).
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env zsh
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  *consumption/cycles*)        print -rn -- "${FAKE_CYCLES:-200}" ;;
  *organizations/org-dve-doctor-probe*) print -rn -- "${FAKE_ORG_WRITE:-404}" ;;
  *enterprise/organizations*)  print -rn -- "${FAKE_ORGS:-200}" ;;
  *members/users*)             print -rn -- "${FAKE_ROSTER:-200}" ;;
  *metrics/usage*)             print -rn -- "${FAKE_METRICS:-200}" ;;
  *UserPageAnalytics*)         print -rn -- "${FAKE_TEAMS:-200}" ;;
  *analytics/consumption*)     print -rn -- "${FAKE_ANALYTICS:-200}" ;;
  *)                           print -rn -- "000" ;;
esac
EOF
chmod +x "${tmpdir}/bin/curl"

run_doctor() {  # env overrides via FAKE_* assignments prefixed to the call
  PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY=wsk \
  FAKE_CYCLES="${FAKE_CYCLES:-200}" FAKE_ORG_WRITE="${FAKE_ORG_WRITE:-404}" \
  FAKE_ORGS="${FAKE_ORGS:-200}" FAKE_ROSTER="${FAKE_ROSTER:-200}" \
  FAKE_METRICS="${FAKE_METRICS:-200}" FAKE_TEAMS="${FAKE_TEAMS:-200}" \
  FAKE_ANALYTICS="${FAKE_ANALYTICS:-200}" \
  zsh "$dve" doctor 2>&1
}

# 1. Everything present.
out=$(run_doctor); rc=$?
assert_exit "all rc" 0 $rc
assert_contains "all summary" "$out" "All capabilities present"
assert_contains "consumption line" "$out" "Consumption Read"
assert_contains "org write line" "$out" "Org-cap Write"
assert_contains "write noop note" "$out" "mutates nothing"

# 2. Required v3 capability missing (consumption 403) -> exit 3.
out=$(FAKE_CYCLES=403 run_doctor); rc=$?
assert_exit "v3 missing rc" 3 $rc
assert_contains "v3 missing word" "$out" "missing"
assert_contains "v3 missing hint" "$out" "app.devin.ai"

# 3. Org-cap write probe: 403 = inconclusive (API masks unknown orgs) -> warn, exit 0.
out=$(FAKE_ORG_WRITE=403 run_doctor); rc=$?
assert_exit "org write inconclusive rc" 0 $rc
assert_contains "org write inconclusive word" "$out" "inconclusive"

# 4. Windsurf capability missing -> exit 0 with degradation warning.
out=$(FAKE_TEAMS=403 run_doctor); rc=$?
assert_exit "ws missing rc" 0 $rc
assert_contains "ws degraded" "$out" "degrades per-model/IDE breakdown"

# 5. Analytics rate-limited (429) -> optional, still exit 0 but flagged.
out=$(FAKE_ANALYTICS=429 run_doctor); rc=$?
assert_exit "an 429 rc" 0 $rc
assert_contains "an 429 word" "$out" "rate-limited"

# 6. Skip analytics probe (avoid burning the 10/hr budget).
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY=wsk DVE_DOCTOR_SKIP_ANALYTICS=1 \
  zsh "$dve" doctor 2>&1); rc=$?
assert_exit "skip rc" 0 $rc
assert_contains "skip word" "$out" "skipped"

# 7. No Windsurf key at all -> exit 0, notes unavailability.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY="" zsh "$dve" doctor 2>&1); rc=$?
assert_exit "no ws key rc" 0 $rc
assert_contains "no ws key word" "$out" "no Windsurf service key"

# 8. No cog key -> exit 1.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DEVIN_SERVICE_KEY=wsk zsh "$dve" doctor 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey word" "$out" "no Devin API v3 service-user key"

# 9. Keys never leak into doctor output.
out=$(run_doctor)
if [[ "$out" == *"Bearer cogk"* || "$out" == *"Bearer wsk"* || "$out" == *"key=cogk"* ]]; then
  _fail "key leaked into doctor output"
else
  _ok
fi

report
