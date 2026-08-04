#!/usr/bin/env zsh
# Plan engine: every action branch of the sync state machine.
set -u
source "${0:A:h}/harness.zsh"
hive_sandbox

# No snapshot yet → hard error.
out=$(hive_run plan 2>&1); rc=$?
assert_exit "plan without snapshot fails" 1 $rc
assert_contains "asks for snapshot first" "$out" "run 'hive snapshot' first"

# Only this host → NEED_OTHER_MACHINE.
hive_run snapshot >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "single host" "$out" "action=NEED_OTHER_MACHINE"

# Second host, identical content → IN_SYNC.
hive_snapshot_as mac-b >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "identical hosts" "$out" "action=IN_SYNC"

# Second host diverges, both fresh → RECONCILE.
print -r -- "# global claude rules B (drifted)" > "$HIVE_HOME/.claude/CLAUDE.md"
hive_snapshot_as mac-b >/dev/null 2>&1
print -r -- "# global claude rules A" > "$HIVE_HOME/.claude/CLAUDE.md"
hive_run snapshot >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "diverged fresh hosts" "$out" "action=RECONCILE"

# Other snapshot older than window (and diverged) → STALE_OTHER; HIVE_FORCE downgrades.
old=$(( $(date +%s) - 30*3600 ))
print -r -- "# stale drifted B" > "$HIVE_HOME/.claude/CLAUDE.md"
hive_snapshot_as mac-b "$old" >/dev/null 2>&1
print -r -- "# global claude rules A" > "$HIVE_HOME/.claude/CLAUDE.md"
out=$(hive_run plan)
assert_contains "stale other host" "$out" "action=STALE_OTHER"
assert_contains "names stale host" "$out" "stale_hosts=mac-b"
out=$(HIVE_FORCE=1 zsh "$HIVE_BIN" plan)
assert_contains "force reconciles anyway" "$out" "action=RECONCILE"

# Golden pending on this host → APPLY_GOLDEN beats staleness.
hive_run golden init --from mac-b >/dev/null 2>&1
hive_run golden finalize --hosts mac-a,mac-b >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "golden pending wins" "$out" "action=APPLY_GOLDEN"

hive_sandbox_teardown
report
