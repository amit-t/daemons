#!/usr/bin/env zsh
# Snapshot engine: manifest, git commit, secret guard, missing surfaces, dir-md scoping.
set -u
source "${0:A:h}/harness.zsh"
hive_sandbox

out=$(hive_run snapshot 2>&1); rc=$?
assert_exit "snapshot exits 0" 0 $rc
assert_contains "reports 4 files" "$out" "4 files"

snap="$HIVE_PROFILES_DIR/agent-sync/machines/mac-a"
assert_file "claude surface copied" "$snap/claude/CLAUDE.md"
assert_file "codex agents copied" "$snap/codex/AGENTS.md"
assert_file "codex memory copied" "$snap/codex/memories/zsh-preference.md"
assert_file "gemini copied" "$snap/gemini/GEMINI.md"
assert_file "manifest written" "$snap/manifest.json"

assert_eq "manifest host" "mac-a" "$(jq -r .host "$snap/manifest.json")"
assert_eq "manifest file count" "4" "$(jq -r '.files|length' "$snap/manifest.json")"
assert_eq "no missing surfaces" "0" "$(jq -r '.missing_surfaces|length' "$snap/manifest.json")"

msg=$(git -C "$HIVE_PROFILES_DIR" log -1 --format=%s)
assert_contains "ledger committed" "$msg" "hive: snapshot mac-a"

# dir-md: subdirectories and non-md files are ignored.
mkdir -p "$HIVE_HOME/.codex/memories/rollout_summaries"
print -r -- "noise" > "$HIVE_HOME/.codex/memories/rollout_summaries/x.md"
print -r -- "noise" > "$HIVE_HOME/.codex/memories/notes.txt"
hive_run snapshot >/dev/null 2>&1
assert_eq "subdir + txt ignored" "4" "$(jq -r '.files|length' "$snap/manifest.json")"

# Secret guard: credential-looking file skipped with warning, run still succeeds.
print -r -- "token ghp_ABCDEFGHIJKLMNOPQRSTUVWX1234567890" > "$HIVE_HOME/.codex/memories/leaky.md"
out=$(hive_run snapshot 2>&1); rc=$?
assert_exit "snapshot survives secret file" 0 $rc
assert_contains "secret skip warned" "$out" "SKIPPED (secret-like content)"
assert_no_file "secret not in ledger" "$snap/codex/memories/leaky.md"
rm "$HIVE_HOME/.codex/memories/leaky.md"

# Missing surface: recorded, not fatal.
rm "$HIVE_HOME/.gemini/GEMINI.md"
hive_run snapshot >/dev/null 2>&1
assert_eq "missing surface recorded" "gemini-global" "$(jq -r '.missing_surfaces[0]' "$snap/manifest.json")"
assert_no_file "stale gemini gone from snapshot" "$snap/gemini/GEMINI.md"

hive_sandbox_teardown
report
