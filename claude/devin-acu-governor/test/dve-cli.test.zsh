#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dve="${script_dir}/../bin/dve"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Fake security: always miss, so DEVIN_SERVICE_KEY env drives key resolution.
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

run_dve() { PATH="${tmpdir}/bin:$PATH" DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=test-key zsh "$dve" "$@" }

# 1. No args -> usage, exit 2.
out=$(run_dve 2>&1); rc=$?
assert_exit "noargs rc" 2 $rc
assert_contains "noargs usage" "$out" "Usage:"

# 2. help -> exit 0.
out=$(run_dve help 2>&1); rc=$?
assert_exit "help rc" 0 $rc

# 3. Unknown command -> exit 2.
out=$(run_dve frobnicate 2>&1); rc=$?
assert_exit "unknown rc" 2 $rc

# 4. boost arg validation.
out=$(run_dve boost 2>&1); rc=$?; assert_exit "boost noargs" 2 $rc
out=$(run_dve boost not-an-email 50 2>&1); rc=$?; assert_exit "boost bad email" 2 $rc
out=$(run_dve boost a@b.co xx 2>&1); rc=$?; assert_exit "boost bad amount" 2 $rc

# 5. set-limits prompt assembly: contains common contract, playbook, run context.
out=$(run_dve set-limits); rc=$?
assert_exit "setlimits rc" 0 $rc
assert_contains "common in prompt" "$out" "Devin Desktop API contract"
assert_contains "playbook in prompt" "$out" "# Playbook: set-limits"
assert_contains "pool in context" "$out" "DVE_MONTHLY_ACU_POOL: 24000"
assert_contains "jq path in context" "$out" "compute-caps.jq"

# 6. boost prompt carries args.
out=$(run_dve boost alice@corp.com 50)
assert_contains "boost playbook" "$out" "# Playbook: boost"
assert_contains "boost email" "$out" "alice@corp.com"
assert_contains "boost amount" "$out" "increment: 50"

# 7. Env override: pool from environment wins over environment.env.
out=$(PATH="${tmpdir}/bin:$PATH" DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=k DVE_MONTHLY_ACU_POOL=9999 zsh "$dve" status)
assert_contains "env override" "$out" "DVE_MONTHLY_ACU_POOL: 9999"

# 8. Missing key -> exit 1 with setup hint; agent never launched.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_SERVICE_KEY="" zsh "$dve" status 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "add-generic-password"

# 9. Key never appears in prompt.
out=$(run_dve set-limits)
if [[ "$out" == *test-key* ]]; then _fail "key leaked into prompt"; else _ok; fi

report
