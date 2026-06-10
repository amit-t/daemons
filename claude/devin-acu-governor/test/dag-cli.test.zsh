#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Fake security: always miss, so env vars drive key resolution.
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

run_dag() { PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=test-cog-key DEVIN_SERVICE_KEY=test-ws-key zsh "$dag" "$@" }

# 1. No args -> usage, exit 2.
out=$(run_dag 2>&1); rc=$?
assert_exit "noargs rc" 2 $rc
assert_contains "noargs usage" "$out" "Usage:"

# 2. help -> exit 0.
out=$(run_dag help 2>&1); rc=$?
assert_exit "help rc" 0 $rc

# 3. Unknown command -> exit 2.
out=$(run_dag frobnicate 2>&1); rc=$?
assert_exit "unknown rc" 2 $rc

# 4. boost arg validation (amount now optional).
out=$(run_dag boost 2>&1); rc=$?; assert_exit "boost noargs" 2 $rc
out=$(run_dag boost not-an-email 50 2>&1); rc=$?; assert_exit "boost bad email" 2 $rc
out=$(run_dag boost a@b.co xx 2>&1); rc=$?; assert_exit "boost bad amount" 2 $rc
out=$(run_dag boost a@b.co 2>&1); rc=$?; assert_exit "boost no amount ok" 0 $rc
assert_contains "boost no amount recommend" "$out" "recommend from the user's run-rate projection"

# 5. set-limits prompt assembly: contains common contract, playbook, run context.
out=$(run_dag set-limits); rc=$?
assert_exit "setlimits rc" 0 $rc
assert_contains "v3 contract in prompt" "$out" "Devin API v3 (primary"
assert_contains "playbook in prompt" "$out" "# Playbook: set-limits"
assert_contains "pool in context" "$out" "DAG_MONTHLY_ACU_POOL: 24000"
assert_contains "jq path in context" "$out" "compute-caps.jq"
assert_contains "cog key note" "$out" "exported as DEVIN_COG_KEY"
assert_contains "ws key note" "$out" "exported as DEVIN_SERVICE_KEY"

# 6. boost prompt carries args.
out=$(run_dag boost alice@corp.com 50)
assert_contains "boost playbook" "$out" "# Playbook: boost"
assert_contains "boost email" "$out" "alice@corp.com"
assert_contains "boost amount" "$out" "explicit increment: 50"
assert_contains "boost plan jq" "$out" "boost-plan.jq"

# 6b. user command dispatch + validation.
out=$(run_dag user 2>&1); rc=$?; assert_exit "user noargs" 2 $rc
out=$(run_dag user not-an-email 2>&1); rc=$?; assert_exit "user bad email" 2 $rc
out=$(run_dag user bob@corp.com); rc=$?
assert_exit "user rc" 0 $rc
assert_contains "user playbook" "$out" "# Playbook: user"
assert_contains "user email" "$out" "user: bob@corp.com"

# 7. Env override: pool from environment wins over environment.env.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=k DAG_MONTHLY_ACU_POOL=9999 zsh "$dag" status 2>/dev/null)
assert_contains "env override" "$out" "DAG_MONTHLY_ACU_POOL: 9999"

# 8. Missing cog key -> exit 1 with setup hint; agent never launched.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DEVIN_SERVICE_KEY=ws zsh "$dag" status 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "devin-cog-key"

# 9. Missing Windsurf key is non-fatal: prompt notes its absence.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=k DEVIN_SERVICE_KEY="" zsh "$dag" status 2>/dev/null); rc=$?
assert_exit "no ws key rc" 0 $rc
assert_contains "no ws key note" "$out" "Windsurf key: ABSENT"

# 10. Keys never appear in prompt.
out=$(run_dag set-limits)
if [[ "$out" == *test-cog-key* || "$out" == *test-ws-key* ]]; then _fail "key leaked into prompt"; else _ok; fi

report
