#!/usr/bin/env zsh
# CLI surface: help, unknown commands, launcher selection, sync prompt assembly, status/diff/doctor smoke.
set -u
source "${0:A:h}/harness.zsh"
hive_sandbox

out=$(hive_run help); rc=$?
assert_exit "help exits 0" 0 $rc
assert_contains "help lists sync" "$out" "hive [sync]"

out=$(hive_run bogus 2>&1); rc=$?
assert_exit "unknown command exits 2" 2 $rc

# Launcher selection.
assert_eq "default launcher" "cf" "$(HIVE_PRINT_LAUNCHER=1 hive_run sync)"
assert_eq "--agent codex" "cxscb" "$(HIVE_PRINT_LAUNCHER=1 hive_run --agent codex sync)"
assert_eq "--devin shorthand" "deo" "$(HIVE_PRINT_LAUNCHER=1 hive_run --devin sync)"
assert_eq "--co shorthand" "co" "$(HIVE_PRINT_LAUNCHER=1 hive_run --co sync)"
out=$(hive_run --agent nope sync 2>&1); rc=$?
assert_exit "bad --agent exits 2" 2 $rc

# Sync prompt: playbooks + run context, cd-into-profiles rule present.
out=$(HIVE_DRY_LAUNCH=1 hive_run sync)
assert_contains "common policy included" "$out" "hivemind common policy"
assert_contains "sync playbook included" "$out" "action=NEED_OTHER_MACHINE"
assert_contains "profiles dir in context" "$out" "profiles dir (ALWAYS work from here): $HIVE_PROFILES_DIR"
assert_contains "host in context" "$out" "this machine: mac-a"

# Status/diff/doctor smoke.
hive_run snapshot >/dev/null 2>&1
hive_snapshot_as mac-b >/dev/null 2>&1
out=$(hive_run status)
assert_contains "status lists host" "$out" "mac-a"
assert_contains "status verdict" "$out" "machines: IN SYNC"
out=$(hive_run diff 2>&1); rc=$?
assert_exit "diff identical exits 0" 0 $rc
print -r -- "# drift" > "$HIVE_HOME/.claude/CLAUDE.md"
hive_snapshot_as mac-b >/dev/null 2>&1
out=$(hive_run status)
assert_contains "status diverged" "$out" "machines: DIVERGED"
out=$(hive_run diff 2>&1); rc=$?
assert_exit "diff diverged exits 1" 1 $rc
assert_contains "diff shows drift" "$out" "# drift"
out=$(hive_run doctor 2>&1); rc=$?
assert_exit "doctor healthy" 0 $rc
assert_contains "doctor checks repo" "$out" "Profiles git repo"

hive_sandbox_teardown
report
