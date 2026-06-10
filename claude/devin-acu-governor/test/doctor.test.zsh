#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dve="${script_dir}/../bin/dve"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

# Fake security: always miss, so DEVIN_SERVICE_KEY env drives key resolution.
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
  *GetTeamCreditBalance*) print -rn -- "${FAKE_BILLING_READ:-200}" ;;
  *UsageConfig*)          print -rn -- "${FAKE_BILLING_WRITE:-400}" ;;
  *consumption*)          print -rn -- "${FAKE_ANALYTICS:-200}" ;;
  *UserPageAnalytics*)    print -rn -- "${FAKE_TEAMS:-200}" ;;
  *)                      print -rn -- "000" ;;
esac
EOF
chmod +x "${tmpdir}/bin/curl"

run_doctor() {  # br bw an tm  (HTTP codes per endpoint)
  PATH="${tmpdir}/bin:$PATH" DEVIN_SERVICE_KEY=k \
  FAKE_BILLING_READ=$1 FAKE_BILLING_WRITE=$2 FAKE_ANALYTICS=$3 FAKE_TEAMS=$4 \
  zsh "$dve" doctor 2>&1
}

# 1. All scopes present (write probe returns 400 = authz ok, validation rejected).
out=$(run_doctor 200 400 200 200); rc=$?
assert_exit "all rc" 0 $rc
assert_contains "all summary" "$out" "All probed scopes present"
assert_contains "br present" "$out" "Billing Read"
assert_contains "bw present" "$out" "Billing Write"
assert_contains "write noop note" "$out" "mutates nothing"

# 2. Billing Write missing (403).
out=$(run_doctor 200 403 200 200); rc=$?
assert_exit "bw missing rc" 3 $rc
assert_contains "bw missing line" "$out" "Billing Write"
assert_contains "bw missing word" "$out" "missing"

# 3. Analytics rate-limited (429) -> inconclusive, non-zero exit.
out=$(run_doctor 200 400 429 200); rc=$?
assert_exit "an 429 rc" 3 $rc
assert_contains "an 429 word" "$out" "rate-limited"

# 4. Teams unreachable (000).
out=$(run_doctor 200 400 200 000); rc=$?
assert_exit "tm unreachable rc" 3 $rc
assert_contains "tm unreachable word" "$out" "unreachable"

# 5. Billing Read missing (401).
out=$(run_doctor 401 400 200 200); rc=$?
assert_exit "br missing rc" 3 $rc
assert_contains "br missing word" "$out" "missing"

# 6. Skip analytics probe (avoid burning the 10/hr budget); rest present -> exit 0.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_SERVICE_KEY=k DVE_DOCTOR_SKIP_ANALYTICS=1 \
  FAKE_BILLING_READ=200 FAKE_BILLING_WRITE=400 FAKE_TEAMS=200 zsh "$dve" doctor 2>&1); rc=$?
assert_exit "skip rc" 0 $rc
assert_contains "skip word" "$out" "skipped"

# 7. No key -> exit 1.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_SERVICE_KEY="" zsh "$dve" doctor 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey word" "$out" "no Devin service key"

# 8. Key never leaks into doctor output.
out=$(run_doctor 200 400 200 200)
if [[ "$out" == *"key=k"* || "$out" == *"Bearer k"* ]]; then _fail "key leaked into doctor output"; else _ok; fi

report
