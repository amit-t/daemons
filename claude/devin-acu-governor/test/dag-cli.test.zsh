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
assert_contains "usage global command" "$out" "dag set limit global <acus>"
assert_contains "usage targeted set-limits command" "$out" "dag set-limits <email>"
assert_contains "usage all commands" "$out" "dag all commands [task...]"
assert_contains "usage group command" "$out" "dag usage --group"
assert_contains "status group command" "$out" "dag status --group"

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
assert_contains "boost no amount recommend" "$out" "derive the recommendation from the user's run-rate projection"
assert_contains "boost no amount planning only" "$out" "planning input only, not write authorization"

# 4a. Global user-memory instructions are included in every agent prompt.
memhome="${tmpdir}/memhome"
mkdir -p "${memhome}/.codex/memories"
cat > "${memhome}/.codex/memories/global-zsh-and-dag-instructions.md" <<'EOF'
# Global user preferences

- Prefer zsh for all new shell scripts.
- Never describe Borrow donor reductions as “negative ACUs.”
EOF
run_dag_with_home() { HOME="$memhome" PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=test-cog-key DEVIN_SERVICE_KEY=test-ws-key zsh "$dag" "$@" }
for agent_args in "" "--claude" "--codex" "--devin"; do
  if [[ -n "$agent_args" ]]; then
    out=$(run_dag_with_home ${(z)agent_args} status); rc=$?
  else
    out=$(run_dag_with_home status); rc=$?
  fi
  assert_exit "global memory prompt rc ${agent_args:-default}" 0 $rc
  assert_contains "global memory heading ${agent_args:-default}" "$out" "## Global user instructions"
  assert_contains "global memory path ${agent_args:-default}" "$out" "global-zsh-and-dag-instructions.md"
  assert_contains "global zsh preference ${agent_args:-default}" "$out" "Prefer zsh for all new shell scripts"
  assert_contains "global dag donor wording ${agent_args:-default}" "$out" "Never describe Borrow donor reductions as “negative ACUs.”"
done

# Missing global memory is non-fatal and does not add an empty section.
missinghome="${tmpdir}/missinghome"
mkdir -p "$missinghome"
out=$(HOME="$missinghome" PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=test-cog-key DEVIN_SERVICE_KEY=test-ws-key zsh "$dag" status); rc=$?
assert_exit "missing global memory rc" 0 $rc
if [[ "$out" == *"## Global user instructions"* ]]; then _fail "missing global memory added section"; else _ok; fi

# 5. set-limits prompt assembly: contains common contract, playbook, run context.
out=$(run_dag set-limits); rc=$?
assert_exit "setlimits rc" 0 $rc
assert_contains "v3 contract in prompt" "$out" "Devin API v3 (primary"
assert_contains "playbook in prompt" "$out" "# Playbook: set-limits"
assert_contains "pool in context" "$out" "DAG_MONTHLY_ACU_POOL: 24000"
assert_contains "jq path in context" "$out" "compute-caps.jq"
assert_contains "cog key note" "$out" "exported as DEVIN_COG_KEY"
assert_contains "ws key note" "$out" "exported as DEVIN_SERVICE_KEY"
assert_contains "local agent user api" "$out" "/v3beta1/enterprise/users/{user_id}/consumption/acu-limits"
assert_contains "set-limits live verify" "$out" "GET each changed user limit after PATCH"
assert_contains "set-limits ui instructions" "$out" "Enterprise Settings > Consumption"
assert_contains "set-limits active default" "$out" "Default eligible set = current roster members whose activity status is active"
assert_contains "set-limits inactive no reserve" "$out" "Do not reserve ACUs for users who are not current members or are inactive"
assert_contains "set-limits stale cleanup" "$out" "clear stale explicit overrides for excluded users"
assert_contains "set-limits write gate token" "$out" "CONFIRM DAG WRITE"
assert_contains "set-limits scope not write auth" "$out" "Scope confirmation does not authorize any PATCH"
assert_contains "set-limits deterministic fallback" "$out" "an unmentioned roster member remains included"
assert_contains "set-limits first-failure stop" "$out" "perform no further PATCH, DELETE, or ledger update"
assert_contains "set-limits headroom guidance" "$out" "250 ACUs of direct headroom by default"

# 5a. set-limits targeted user mode: cap exactly one uncapped user by Borrowing.
out=$(run_dag set-limits alice@corp.com); rc=$?
assert_exit "setlimits target rc" 0 $rc
assert_contains "setlimits target command" "$out" "requested shell command: dag set-limits alice@corp.com"
assert_contains "setlimits target email" "$out" "target email: alice@corp.com"
assert_contains "setlimits target scope" "$out" "scope: cap only this target user"
assert_contains "setlimits target borrow" "$out" "Borrow from active capped donors"
assert_contains "setlimits target only target" "$out" "do not cap any other uncapped users"
assert_contains "setlimits target already capped guard" "$out" "If the target already has an explicit cap, stop"
assert_contains "setlimits target jq" "$out" "borrow-caps.jq"
assert_contains "setlimits target headroom default" "$out" '"max_headroom": 250'
assert_contains "setlimits target write gate" "$out" "After the user sends \`CONFIRM DAG WRITE\`"

out=$(run_dag set-limits not-an-email 2>&1); rc=$?
assert_exit "setlimits target bad email" 2 $rc
assert_contains "setlimits target bad email msg" "$out" "dag set-limits: argument must be a user email"
out=$(run_dag set-limits alice@corp.com extra 2>&1); rc=$?
assert_exit "setlimits target extra args" 2 $rc
assert_contains "setlimits target extra args msg" "$out" "dag set-limits: takes at most one target email"

# 5b. set-limits-new prompt assembly: own playbook + borrow_caps.jq path in context.
out=$(run_dag set-limits-new); rc=$?
assert_exit "setlimitsnew rc" 0 $rc
assert_contains "set-limits-new playbook" "$out" "# Playbook: set-limits-new"
assert_contains "set-limits-new command" "$out" "command: set-limits-new"
assert_contains "set-limits-new borrow jq" "$out" "borrow-caps.jq"
assert_contains "set-limits-new borrow wording" "$out" "Borrowing"
assert_contains "set-limits-new user api" "$out" "/v3beta1/enterprise/users/{user_id}/consumption/acu-limits"
assert_contains "set-limits-new live verify" "$out" "GET each changed user limit after PATCH"
assert_contains "set-limits-new zero sum" "$out" "zero-sum"
assert_contains "set-limits-new active default" "$out" "Default eligible set = current roster members whose activity status is active"
assert_contains "set-limits-new inactive no reserve" "$out" "Do not seed caps for inactive or former users"
assert_contains "set-limits-new stale cleanup" "$out" "clear stale explicit overrides for excluded users"
assert_contains "set-limits-new execution contract" "$out" "## DAG execution contract"
assert_contains "set-limits-new write gate token" "$out" "CONFIRM DAG WRITE"
assert_contains "set-limits-new headroom contract" "$out" "250 default, 500 hard max, above 500 never"
assert_contains "set-limits-new headroom default input" "$out" '"max_headroom": 250'
assert_contains "set-limits-new partial keywords" "$out" "PARTIAL"
# Old home-memory donor-policy section must no longer reach the prompt.
if [[ "$out" == *"donor presentation + safety rule"* ]]; then
  _fail "stale home-memory donor policy section leaked into prompt"
else
  _ok
fi
# usage help lists the new mode.
out=$(run_dag 2>&1)
assert_contains "usage lists set-limits-new" "$out" "dag set-limits-new"

# 5c. new-cycle prompt assembly: own playbook + guard/ledger context; no args allowed.
out=$(run_dag new-cycle); rc=$?
assert_exit "newcycle rc" 0 $rc
assert_contains "new-cycle playbook" "$out" "# Playbook: new-cycle"
assert_contains "new-cycle command" "$out" "command: new-cycle"
assert_contains "new-cycle requested" "$out" "requested shell command: dag new-cycle"
assert_contains "new-cycle scope" "$out" "start-of-cycle full reset"
assert_contains "new-cycle guard" "$out" "confirm a NEW cycle is actually current"
assert_contains "new-cycle old-cycle warn" "$out" "warn loudly and require explicit confirmation"
assert_contains "new-cycle ledger fresh" "$out" "rewrite fresh with the new cycle epochs"
assert_contains "new-cycle compute jq" "$out" "compute-caps.jq"
assert_contains "new-cycle stale cleanup" "$out" '{"local_agent":null}'
assert_contains "new-cycle user api" "$out" "/v3beta1/enterprise/users/{user_id}/consumption/acu-limits"
assert_contains "new-cycle live verify" "$out" "GET each changed user limit after PATCH"
assert_contains "new-cycle ui instruction" "$out" "Enterprise Settings > Consumption"
assert_contains "new-cycle headroom hard rule" "$out" "Direct cap headroom ceiling"
assert_contains "new-cycle execution contract" "$out" "## DAG execution contract"
assert_contains "new-cycle write gate token" "$out" "CONFIRM DAG WRITE"
assert_contains "new-cycle headroom contract" "$out" "250 default, 500 hard max, above 500 never"
out=$(run_dag new-cycle extra 2>&1); rc=$?
assert_exit "new-cycle extra args" 2 $rc
assert_contains "new-cycle extra args msg" "$out" "dag new-cycle: takes no arguments"
# usage help lists new-cycle.
out=$(run_dag 2>&1)
assert_contains "usage lists new-cycle" "$out" "dag new-cycle"
# all-commands surfaces the new-cycle playbook too.
out=$(run_dag all-commands)
assert_contains "all-commands new-cycle available" "$out" "# Playbook: new-cycle"

# 6. boost prompt carries args.
out=$(run_dag boost alice@corp.com 50)
assert_contains "boost playbook" "$out" "# Playbook: boost"
assert_contains "boost email" "$out" "alice@corp.com"
assert_contains "boost amount" "$out" "requested increment: 50 ACUs"
assert_contains "boost amount planning only" "$out" "planning input only; it is not write authorization"
assert_contains "boost plan jq" "$out" "boost-plan.jq"
assert_contains "boost borrow wording" "$out" "Borrow"
assert_contains "boost user acu endpoint" "$out" "/v3beta1/enterprise/users/{user_id}/consumption/acu-limits"
assert_contains "boost live verify" "$out" "GET every changed user limit after PATCH"
assert_contains "boost headroom clamp default" "$out" '"max_headroom": 250'
assert_contains "boost headroom hard rule" "$out" "Direct cap headroom ceiling"
assert_contains "boost donor run rate" "$out" "run_rate"
assert_contains "boost write gate token" "$out" "CONFIRM DAG WRITE"
assert_contains "boost never lower thresholds" "$out" "Never lower donor safety thresholds"

# 6a. boost over: no email required, discovers the over set at run time.
out=$(run_dag boost over); rc=$?
assert_exit "boost over rc" 0 $rc
assert_contains "boost over playbook" "$out" "# Playbook: boost over"
assert_contains "boost over command" "$out" "command: over"
assert_contains "boost over scope" "$out" "scope: all users currently over budget"
assert_contains "boost over no target" "$out" "no explicit target — discover the over set live"
assert_contains "boost over plan jq" "$out" "boost-plan.jq"
assert_contains "boost over user acu endpoint" "$out" "/v3beta1/enterprise/users/{user_id}/consumption/acu-limits"
# Alias: dag over (without the boost prefix).
out=$(run_dag over); rc=$?
assert_exit "over alias rc" 0 $rc
assert_contains "over alias playbook" "$out" "# Playbook: boost over"
# boost over takes no positional args.
out=$(run_dag boost over alice@corp.com 2>&1); rc=$?; assert_exit "boost over extra arg" 2 $rc
# usage help lists boost over.
out=$(run_dag 2>&1)
assert_contains "usage lists boost over" "$out" "dag boost over"
# all-commands surfaces the over playbook too.
out=$(run_dag all-commands)
assert_contains "all-commands over available" "$out" "# Playbook: boost over"

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

# 7b. status --group prompts when no group is supplied, then seeds a scoped agent prompt.
out=$(print -r -- "Core Eng" | run_dag status --group 2>&1); rc=$?
assert_exit "status --group prompt rc" 0 $rc
assert_contains "status --group playbook" "$out" "# Playbook: status"
assert_contains "status --group command" "$out" "requested shell command: dag status --group"
assert_contains "status --group name" "$out" "idp group name: Core Eng"
assert_contains "status --group last3" "$out" "last 3 days"

out=$(run_dag status--group Core Eng); rc=$?
assert_exit "status--group alias rc" 0 $rc
assert_contains "status--group alias name" "$out" "idp group name: Core Eng"

# 8. all commands prompt seeds all-docs mode, existing DAG command context, and the spin-up contract.
out=$(run_dag all commands "design a weekly session spend audit"); rc=$?
assert_exit "all commands rc" 0 $rc
assert_contains "all commands playbook" "$out" "# Playbook: all-commands"
assert_contains "all commands docs index" "$out" "https://docs.devin.ai/llms.txt"
assert_contains "all commands acu docs" "$out" "https://docs.devin.ai/admin/billing/acu-limits"
assert_contains "all commands usage config docs" "$out" "https://docs.devin.ai/desktop/accounts/api-reference/usage-config#overview"
assert_contains "all commands task" "$out" "generic task: design a weekly session spend audit"
assert_contains "all commands spin up" "$out" "spin it up"
assert_contains "all commands set-limits available" "$out" "# Playbook: set-limits"
assert_contains "all commands boost available" "$out" "# Playbook: boost"

out=$(run_dag all-commands); rc=$?
assert_exit "all-commands alias rc" 0 $rc
assert_contains "all-commands no task" "$out" "generic task: not provided"

out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY="" DEVIN_SERVICE_KEY="" zsh "$dag" all commands 2>&1); rc=$?
assert_exit "all commands no key rc" 0 $rc
assert_contains "all commands no key note" "$out" "Devin v3 key: ABSENT"
assert_contains "all commands no key docs" "$out" "https://docs.devin.ai/llms.txt"

out=$(run_dag all 2>&1); rc=$?
assert_exit "all missing commands rc" 2 $rc
assert_contains "all missing commands message" "$out" "expected: dag all commands [task...]"

# 9. Missing cog key -> exit 1 with setup hint; agent never launched.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DEVIN_SERVICE_KEY=ws zsh "$dag" status 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "devin-cog-key"

# 10. Missing Windsurf key is non-fatal: prompt notes its absence.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=k DEVIN_SERVICE_KEY="" zsh "$dag" status 2>/dev/null); rc=$?
assert_exit "no ws key rc" 0 $rc
assert_contains "no ws key note" "$out" "Windsurf key: ABSENT"

# 11. Keys never appear in prompt.
out=$(run_dag set-limits)
if [[ "$out" == *test-cog-key* || "$out" == *test-ws-key* ]]; then _fail "key leaked into prompt"; else _ok; fi

# 12. Parent agent selection (--agent / shorthands) resolves the launcher.
run_dag_launcher() { PATH="${tmpdir}/bin:$PATH" DAG_PRINT_LAUNCHER=1 DEVIN_COG_KEY=test-cog-key DEVIN_SERVICE_KEY=test-ws-key zsh "$dag" "$@" }
out=$(run_dag_launcher status); rc=$?
assert_exit "default launcher rc" 0 $rc
assert_contains "default launcher claude" "$out" "clscb"
out=$(run_dag_launcher --agent codex status); rc=$?
assert_exit "agent codex rc" 0 $rc
assert_contains "agent codex launcher" "$out" "cxscb"
out=$(run_dag_launcher --agent=devin status); rc=$?
assert_exit "agent devin rc" 0 $rc
assert_contains "agent devin launcher" "$out" "devin --permission-mode dangerous --"
out=$(run_dag_launcher --claude status); rc=$?
assert_exit "shorthand claude rc" 0 $rc
assert_contains "shorthand claude launcher" "$out" "clscb"
out=$(run_dag_launcher --codex status); rc=$?
assert_exit "shorthand codex rc" 0 $rc
assert_contains "shorthand codex launcher" "$out" "cxscb"
out=$(run_dag_launcher --devin status); rc=$?
assert_exit "shorthand devin rc" 0 $rc
assert_contains "shorthand devin launcher" "$out" "devin --permission-mode dangerous --"

# 13. Env overrides per-agent launchers; legacy DAG_LAUNCHER only applies without --agent.
out=$(DAG_LAUNCHER_CODEX="my-codex" run_dag_launcher --codex status)
assert_contains "codex launcher override" "$out" "my-codex"
out=$(DAG_LAUNCHER="my-default" run_dag_launcher status)
assert_contains "legacy launcher override" "$out" "my-default"
out=$(DAG_LAUNCHER="my-default" run_dag_launcher --codex status)
assert_contains "agent flag beats legacy launcher" "$out" "cxscb"

# 14. Invalid agent -> exit 2; agent flags rejected after the command.
out=$(run_dag_launcher --agent gemini status 2>&1); rc=$?
assert_exit "bad agent rc" 2 $rc
assert_contains "bad agent message" "$out" "claude, codex, devin"
out=$(run_dag_launcher --agent 2>&1); rc=$?
assert_exit "missing agent rc" 2 $rc

# 15. Agent flag does not leak into the prompt or break command dispatch.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=k DEVIN_SERVICE_KEY=ws zsh "$dag" --agent codex set-limits); rc=$?
assert_exit "agent prompt rc" 0 $rc
assert_contains "agent prompt playbook" "$out" "# Playbook: set-limits"
if [[ "$out" == *--agent* ]]; then _fail "--agent leaked into prompt"; else _ok; fi
# Usage mentions agent selection.
out=$(run_dag help)
assert_contains "usage agent flag" "$out" "--agent claude|codex|devin"

report
