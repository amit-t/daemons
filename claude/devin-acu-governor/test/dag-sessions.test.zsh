#!/usr/bin/env zsh
# dag sessions — CLI dispatch, alias coverage, window math, flag validation,
# and prompt assembly (playbook + output-file contract + executive summary).
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Fake `security`: always miss so env vars alone drive key resolution.
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

# Pinned "now" = 2026-07-25T17:20:00Z, so every window epoch below is exact.
NOW=1785000000
STATE="${tmpdir}/state"

run_dag() {
  PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DAG_SESSIONS_NOW=$NOW \
    DAG_STATE_DIR="$STATE" DEVIN_COG_KEY=test-cog-key DEVIN_SERVICE_KEY=test-ws-key \
    zsh "$dag" "$@"
}

# ---------------------------------------------------------------------------
# 1. Default window is 24 hours and the canonical command resolves to sessions.
# ---------------------------------------------------------------------------
out=$(run_dag sessions); rc=$?
assert_exit "sessions rc" 0 $rc
assert_contains "sessions playbook" "$out" "# Playbook: sessions (session logs + prompt traces)"
assert_contains "sessions command" "$out" "command: sessions"
assert_contains "sessions requested" "$out" "requested shell command: dag sessions"
assert_contains "sessions default 24h" "$out" "window hours: 24 (source: default 24h)"
assert_contains "sessions window end epoch" "$out" "window end epoch: 1785000000"
assert_contains "sessions window start epoch" "$out" "window start epoch: 1784913600"
assert_contains "sessions window end utc" "$out" "window end utc: 2026-07-25T17:20:00Z"
assert_contains "sessions window start utc" "$out" "window start utc: 2026-07-24T17:20:00Z"
assert_contains "sessions read-only scope" "$out" "GET only, no PATCH/POST/DELETE"
assert_contains "sessions execution contract" "$out" "## DAG execution contract"

# Run context carries the whole artifact layout, rooted at DAG_STATE_DIR.
run_dir="${STATE}/sessions/20260725T172000Z"
assert_contains "sessions run id" "$out" "run id: 20260725T172000Z"
assert_contains "sessions out dir" "$out" "output directory: ${run_dir}"
assert_contains "sessions overview path" "$out" "overview file: ${run_dir}/OVERVIEW.md"
assert_contains "sessions manifest path" "$out" "manifest file: ${run_dir}/manifest.json"
assert_contains "sessions raw path" "$out" "sessions raw file: ${run_dir}/sessions.json"
assert_contains "sessions ndjson path" "$out" "sessions ndjson file: ${run_dir}/sessions.ndjson"
assert_contains "sessions traces dir" "$out" "traces directory: ${run_dir}/traces"
assert_contains "sessions users path" "$out" "users file: ${run_dir}/users.json"
assert_contains "sessions orgs path" "$out" "organizations file: ${run_dir}/organizations.json"
assert_contains "sessions errors path" "$out" "errors log: ${run_dir}/errors.log"

# Defaults for the optional switches.
assert_contains "sessions traces default on" "$out" "prompt traces: ENABLED"
assert_contains "sessions insights default off" "$out" "session insights: DISABLED"
assert_contains "sessions org filter none" "$out" "org filter: none"
assert_contains "sessions user filter none" "$out" "user filter: none"
assert_contains "sessions origin filter none" "$out" "origin filter: none"
assert_contains "sessions max unlimited" "$out" "max sessions: unlimited"

# ---------------------------------------------------------------------------
# 2. Endpoints, permission, and file contract reach the prompt.
# ---------------------------------------------------------------------------
assert_contains "sessions list endpoint" "$out" "GET /v3/enterprise/sessions"
assert_contains "sessions messages endpoint" "$out" "/v3/organizations/{org_id}/sessions/{session_id}/messages"
assert_contains "sessions insights endpoint" "$out" "/v3/enterprise/sessions/insights"
assert_contains "sessions permission" "$out" "ViewOrgSessions"
assert_contains "sessions membership permission" "$out" "ViewAccountMembership"
assert_contains "sessions members map" "$out" "/v3/enterprise/members/users"
assert_contains "sessions orgs map" "$out" "/v3/enterprise/organizations"
assert_contains "sessions created filter" "$out" "created_after=1784913600"
assert_contains "sessions created before" "$out" "created_before=1785000000"
assert_contains "sessions cursor pagination" "$out" "has_next_page"

# Live-verified API semantics that a naive implementation would get wrong.
assert_contains "sessions half-open window" "$out" "[created_after, created_before)"
assert_contains "sessions time_after banned" "$out" "Do NOT pass time_after/time_before"
assert_contains "sessions time_after silently ignored" "$out" "silently ignored"
assert_contains "sessions created_at basis" "$out" "window membership rule: created_at only"
assert_contains "sessions no devin prefix" "$out" "no \`devin-\` prefix"
assert_contains "sessions detail redundant" "$out" "Verified live — and redundant"
assert_contains "sessions messages total null" "$out" "\`total\` is always \`null\`"
assert_contains "sessions messages oldest first" "$out" "oldest-first"
assert_contains "sessions list newest first" "$out" "newest-first"
assert_contains "sessions client-side filters" "$out" "apply org/user/origin filters CLIENT-SIDE"

# The trace-depth limitation must be stated honestly, not glossed over.
assert_contains "sessions trace scope limit" "$out" "prompt trace scope: visible conversation only"
assert_contains "sessions no tool traces" "$out" "no tool calls, shell commands, command output, code edits"
assert_contains "sessions events 404" "$out" "/events\` and \`/logs\` subresources both return \`404\`"
assert_contains "sessions not execution log" "$out" "full execution log"
assert_contains "sessions attachment inline" "$out" "ATTACHMENT:"
assert_contains "sessions unmapped user" "$out" "(unmapped)"

# Output-file contract.
assert_contains "contract manifest" "$out" '`manifest.json`'
assert_contains "contract sessions json" "$out" '`sessions.json`'
assert_contains "contract ndjson" "$out" '`sessions.ndjson`'
assert_contains "contract trace json" "$out" '`traces/<session_id>.json`'
assert_contains "contract trace md" "$out" '`traces/<session_id>.md`'
assert_contains "contract errors log" "$out" '`errors.log`'
assert_contains "contract overview" "$out" '`OVERVIEW.md`'
assert_contains "contract manifest schema" "$out" '"items_after_filter"'
assert_contains "contract window basis" "$out" '"window_basis"'
assert_contains "contract trace status" "$out" '"trace_status"'
assert_contains "contract verbatim rule" "$out" "verbatim"
# Per-session raw file is self-contained: metadata + transcript together.
assert_contains "contract trace self-contained" "$out" '{"session_id", "org_id", "session": {...}, "messages": [...]}'

# Executive summary template.
assert_contains "overview template heading" "$out" "## Executive summary template"
assert_contains "overview exec summary" "$out" "## Executive summary"
assert_contains "overview at a glance" "$out" "## At a glance"
assert_contains "overview who did what" "$out" "## Who did what"
assert_contains "overview by org" "$out" "## By organization"
assert_contains "overview worked on" "$out" "## What was worked on"
assert_contains "overview notable" "$out" "## Notable sessions"
assert_contains "overview prompt obs" "$out" "## Prompt-trace observations"
assert_contains "overview risks" "$out" "## Risks and anomalies"
assert_contains "overview actions" "$out" "## Recommended actions"
assert_contains "overview coverage" "$out" "## Coverage and caveats"

# Command-specific hard requirements.
assert_contains "sessions no api writes" "$out" "No PATCH, POST, PUT, or DELETE to any Devin endpoint"
assert_contains "sessions no insights generate" "$out" "insights/generate"
assert_contains "sessions no silent truncation" "$out" "No silent truncation"
assert_contains "sessions secret handling" "$out" "never reproduce the secret"
assert_contains "sessions dir sensitive" "$out" "chmod 700"
assert_contains "sessions window discipline" "$out" "do not silently widen it yourself"

# Artifact carve-out must be present in the shared execution contract, else the
# agent would refuse to write its own report files.
assert_contains "common artifact carve-out" "$out" "report/artifact files written under a Run-context output directory"

# ---------------------------------------------------------------------------
# 3. Aliases: hyphenated and two-word spellings all reach the sessions playbook.
# ---------------------------------------------------------------------------
for alias_args in "session-logs" "prompt-traces" "session logs" "prompt traces"; do
  out=$(run_dag ${=alias_args}); rc=$?
  assert_exit "alias rc ${alias_args}" 0 $rc
  assert_contains "alias playbook ${alias_args}" "$out" "# Playbook: sessions"
  assert_contains "alias command ${alias_args}" "$out" "command: sessions"
  assert_contains "alias requested ${alias_args}" "$out" "requested shell command: dag ${alias_args}"
  assert_contains "alias default window ${alias_args}" "$out" "window hours: 24"
done

# Two-word spellings only accept their own second word.
out=$(run_dag session traces 2>&1); rc=$?
assert_exit "session traces rc" 2 $rc
assert_contains "session traces msg" "$out" "unknown command 'session traces'"
out=$(run_dag prompt logs 2>&1); rc=$?
assert_exit "prompt logs rc" 2 $rc
assert_contains "prompt logs msg" "$out" "unknown command 'prompt logs'"
out=$(run_dag session 2>&1); rc=$?
assert_exit "bare session rc" 2 $rc

# ---------------------------------------------------------------------------
# 4. Window selectors.
# ---------------------------------------------------------------------------
out=$(run_dag sessions --hours 72); rc=$?
assert_exit "hours 72 rc" 0 $rc
assert_contains "hours 72 label" "$out" "window hours: 72 (source: --hours 72)"
assert_contains "hours 72 start" "$out" "window start epoch: 1784740800"
assert_contains "hours 72 start utc" "$out" "window start utc: 2026-07-22T17:20:00Z"
assert_contains "hours 72 requested" "$out" "requested shell command: dag sessions --hours 72"

out=$(run_dag sessions --hours=72)
assert_contains "hours equals form" "$out" "window hours: 72"

out=$(run_dag sessions --days 7); rc=$?
assert_exit "days 7 rc" 0 $rc
assert_contains "days 7 label" "$out" "window hours: 168 (source: --days 7 (168h))"
assert_contains "days 7 start" "$out" "window start epoch: 1784395200"

# Explicit epochs: exact, no local-timezone dependence.
out=$(run_dag sessions --since 1784000000 --until 1784500000); rc=$?
assert_exit "epoch window rc" 0 $rc
assert_contains "epoch window start" "$out" "window start epoch: 1784000000"
assert_contains "epoch window end" "$out" "window end epoch: 1784500000"
assert_contains "epoch window source" "$out" "source: explicit --since/--until"
assert_contains "epoch window span" "$out" "window hours: 139"

# --since without --until runs up to "now".
out=$(run_dag sessions --since 1784000000)
assert_contains "since only end is now" "$out" "window end epoch: 1785000000"

# A bare --since date spans whole local days. Because the API window is
# half-open on created_at, --until resolves to the FOLLOWING local midnight, so
# 07-01..07-07 is exactly seven whole days (168h) with the 7th included.
out=$(run_dag sessions --since 2026-07-01 --until 2026-07-07); rc=$?
assert_exit "date window rc" 0 $rc
assert_contains "date window span" "$out" "window hours: 168"
out=$(run_dag sessions --since 2026-07-01 --until 2026-07-01)
assert_contains "single day window span" "$out" "window hours: 24"

# Hours are also the boundary values.
out=$(run_dag sessions --hours 1); rc=$?; assert_exit "hours min rc" 0 $rc
assert_contains "hours min" "$out" "window hours: 1"
out=$(run_dag sessions --hours 8760); rc=$?; assert_exit "hours max rc" 0 $rc
out=$(run_dag sessions --days 365); rc=$?; assert_exit "days max rc" 0 $rc

# ---------------------------------------------------------------------------
# 5. Window validation.
# ---------------------------------------------------------------------------
out=$(run_dag sessions --hours 2>&1); rc=$?
assert_exit "hours missing value rc" 2 $rc
assert_contains "hours missing value msg" "$out" "--hours expects a value"
out=$(run_dag sessions --hours abc 2>&1); rc=$?
assert_exit "hours nonint rc" 2 $rc
assert_contains "hours nonint msg" "$out" "--hours expects a positive integer"
out=$(run_dag sessions --hours 0 2>&1); rc=$?
assert_exit "hours zero rc" 2 $rc
assert_contains "hours zero msg" "$out" "--hours must be between 1 and 8760"
out=$(run_dag sessions --hours 8761 2>&1); rc=$?
assert_exit "hours over rc" 2 $rc
out=$(run_dag sessions --days 0 2>&1); rc=$?
assert_exit "days zero rc" 2 $rc
assert_contains "days zero msg" "$out" "--days must be between 1 and 365"
out=$(run_dag sessions --days 366 2>&1); rc=$?
assert_exit "days over rc" 2 $rc
out=$(run_dag sessions --hours 5 --days 2 2>&1); rc=$?
assert_exit "hours+days rc" 2 $rc
assert_contains "hours+days msg" "$out" "mutually exclusive"
out=$(run_dag sessions --hours 5 --since 2026-07-01 2>&1); rc=$?
assert_exit "hours+since rc" 2 $rc
assert_contains "hours+since msg" "$out" "mutually exclusive"
out=$(run_dag sessions --until 2026-07-07 2>&1); rc=$?
assert_exit "until alone rc" 2 $rc
assert_contains "until alone msg" "$out" "--until requires --since"
out=$(run_dag sessions --since notadate 2>&1); rc=$?
assert_exit "since garbage rc" 2 $rc
assert_contains "since garbage msg" "$out" "--since expects YYYY-MM-DD or a Unix epoch"
out=$(run_dag sessions --since 2026-13-45 2>&1); rc=$?
assert_exit "since impossible date rc" 2 $rc
assert_contains "since impossible date msg" "$out" "not a real calendar date"
out=$(run_dag sessions --since 1784500000 --until 1784000000 2>&1); rc=$?
assert_exit "inverted window rc" 2 $rc
assert_contains "inverted window msg" "$out" "must be after window start"

# ---------------------------------------------------------------------------
# 6. Filter and option flags.
# ---------------------------------------------------------------------------
out=$(run_dag sessions --no-traces); rc=$?
assert_exit "no-traces rc" 0 $rc
assert_contains "no-traces context" "$out" "prompt traces: DISABLED (--no-traces)"
assert_contains "no-traces disclosure" "$out" "say so in OVERVIEW.md"

out=$(run_dag sessions --insights); rc=$?
assert_exit "insights rc" 0 $rc
assert_contains "insights context" "$out" "session insights: ENABLED (--insights)"
assert_contains "insights fields" "$out" "session_size"
out=$(run_dag sessions --include-insights)
assert_contains "include-insights long form" "$out" "session insights: ENABLED"

out=$(run_dag sessions --org "Platform Eng"); rc=$?
assert_exit "org filter rc" 0 $rc
assert_contains "org filter context" "$out" "org filter: Platform Eng"
assert_contains "org filter resolution" "$out" "match session org_id, resolving the name"

out=$(run_dag sessions --user alice@corp.com); rc=$?
assert_exit "user filter rc" 0 $rc
assert_contains "user filter context" "$out" "user filter: alice@corp.com"
assert_contains "user filter resolution" "$out" "resolve the email to a user_id"
out=$(run_dag sessions --user bob 2>&1); rc=$?
assert_exit "user filter bad email rc" 2 $rc
assert_contains "user filter bad email msg" "$out" "--user expects a user email"

out=$(run_dag sessions --origin cli); rc=$?
assert_exit "origin filter rc" 0 $rc
assert_contains "origin filter context" "$out" "origin filter: cli"
out=$(run_dag sessions --origin nope 2>&1); rc=$?
assert_exit "origin bad rc" 2 $rc
assert_contains "origin bad msg" "$out" "--origin must be one of"

out=$(run_dag sessions --max-sessions 50); rc=$?
assert_exit "max sessions rc" 0 $rc
assert_contains "max sessions context" "$out" "max sessions: 50"
assert_contains "max sessions disclosure" "$out" "never truncate silently"
out=$(run_dag sessions --max-sessions -3 2>&1); rc=$?
assert_exit "max sessions negative rc" 2 $rc
out=$(run_dag sessions --max-sessions xx 2>&1); rc=$?
assert_exit "max sessions nonint rc" 2 $rc

out=$(run_dag sessions --out "${tmpdir}/audit"); rc=$?
assert_exit "out dir rc" 0 $rc
assert_contains "out dir context" "$out" "output directory: ${tmpdir:A}/audit"
assert_contains "out dir overview" "$out" "overview file: ${tmpdir:A}/audit/OVERVIEW.md"

# Everything combined still parses, in any order.
out=$(run_dag prompt traces --insights --hours 6 --org Research --user bob@corp.com --origin api --max-sessions 10 --no-traces --out "${tmpdir}/combo"); rc=$?
assert_exit "combined flags rc" 0 $rc
assert_contains "combined window" "$out" "window hours: 6"
assert_contains "combined traces off" "$out" "prompt traces: DISABLED"
assert_contains "combined insights on" "$out" "session insights: ENABLED"
assert_contains "combined org" "$out" "org filter: Research"
assert_contains "combined user" "$out" "user filter: bob@corp.com"
assert_contains "combined origin" "$out" "origin filter: api"
assert_contains "combined max" "$out" "max sessions: 10"
assert_contains "combined out" "$out" "output directory: ${tmpdir:A}/combo"
assert_contains "combined requested" "$out" "requested shell command: dag prompt traces --insights --hours 6"

# ---------------------------------------------------------------------------
# 7. Unknown flags and stray positionals are rejected, not passed through.
# ---------------------------------------------------------------------------
out=$(run_dag sessions --bogus 2>&1); rc=$?
assert_exit "unknown flag rc" 2 $rc
assert_contains "unknown flag msg" "$out" "unknown flag '--bogus'"
out=$(run_dag sessions yesterday 2>&1); rc=$?
assert_exit "stray positional rc" 2 $rc
assert_contains "stray positional msg" "$out" "unexpected argument 'yesterday'"

# ---------------------------------------------------------------------------
# 8. Launcher selection, key handling, and discoverability.
# ---------------------------------------------------------------------------
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_LAUNCHER=1 DAG_SESSIONS_NOW=$NOW DAG_STATE_DIR="$STATE" \
  DEVIN_COG_KEY=k zsh "$dag" --codex sessions); rc=$?
assert_exit "sessions launcher rc" 0 $rc
assert_contains "sessions launcher codex" "$out" "cxscb"
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_LAUNCHER=1 DAG_SESSIONS_NOW=$NOW DAG_STATE_DIR="$STATE" \
  DEVIN_COG_KEY=k zsh "$dag" --def prompt traces); rc=$?
assert_exit "sessions devin launcher rc" 0 $rc
assert_eq "sessions devin launcher dashdash" "def --" "$out"

# Agent selector must not leak into the prompt.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DAG_SESSIONS_NOW=$NOW DAG_STATE_DIR="$STATE" \
  DEVIN_COG_KEY=k zsh "$dag" --agent codex sessions --hours 12); rc=$?
assert_exit "sessions agent prompt rc" 0 $rc
assert_contains "sessions agent playbook" "$out" "# Playbook: sessions"
assert_contains "sessions agent window" "$out" "window hours: 12"
if [[ "$out" == *--agent* ]]; then _fail "--agent leaked into sessions prompt"; else _ok; fi

# Missing cog key is fatal for a live-data command.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_SESSIONS_NOW=$NOW DAG_STATE_DIR="$STATE" \
  DEVIN_COG_KEY="" DEVIN_SERVICE_KEY="" zsh "$dag" sessions 2>&1); rc=$?
assert_exit "sessions nokey rc" 1 $rc
assert_contains "sessions nokey hint" "$out" "devin-cog-key"

# Keys never reach the prompt.
out=$(run_dag sessions --hours 48)
if [[ "$out" == *test-cog-key* || "$out" == *test-ws-key* ]]; then _fail "key leaked into sessions prompt"; else _ok; fi

# Help lists the command and every alias.
out=$(run_dag help)
assert_contains "help lists sessions" "$out" "dag sessions ["
assert_contains "help lists session logs" "$out" "dag session logs"
assert_contains "help lists session-logs" "$out" "dag session-logs"
assert_contains "help lists prompt traces" "$out" "dag prompt traces"
assert_contains "help lists prompt-traces" "$out" "dag prompt-traces"
assert_contains "help sessions default window" "$out" "last 24 hours (default)"
assert_contains "help sessions now env" "$out" "DAG_SESSIONS_NOW"

# all-commands seeds the sessions playbook and routes to it.
out=$(run_dag all-commands)
assert_contains "all-commands sessions playbook" "$out" "# Playbook: sessions"
assert_contains "all-commands sessions routing" "$out" "Use \`dag sessions\`"

report
