#!/usr/bin/env zsh
# Golden build + apply: seed, edit, finalize, converge live surfaces, backups, drift.
set -u
source "${0:A:h}/harness.zsh"
hive_sandbox

# Machine A snapshot, then machine B with drifted claude rules + an extra memory.
hive_run snapshot >/dev/null 2>&1
print -r -- "# global claude rules B (better)" > "$HIVE_HOME/.claude/CLAUDE.md"
print -r -- "new lesson from B" > "$HIVE_HOME/.codex/memories/lesson-b.md"
hive_snapshot_as mac-b >/dev/null 2>&1
# restore A's live state
print -r -- "# global claude rules A" > "$HIVE_HOME/.claude/CLAUDE.md"
rm "$HIVE_HOME/.codex/memories/lesson-b.md"
hive_run snapshot >/dev/null 2>&1

# finalize without init refuses
out=$(hive_run golden finalize --hosts mac-a,mac-b 2>&1); rc=$?
assert_exit "finalize needs init" 1 $rc

# Seed golden from B (the better side), reconcile by hand: drop the old zsh dupe.
out=$(hive_run golden init --from mac-b 2>&1)
assert_exit "golden init ok" 0 $?
golden="$HIVE_PROFILES_DIR/agent-sync/golden"
assert_file "seeded from B: claude rules" "$golden/claude/CLAUDE.md"
assert_file "seeded from B: lesson" "$golden/codex/memories/lesson-b.md"
rm "$golden/codex/memories/zsh-preference.md"   # reconciler decision: dropped everywhere

out=$(hive_run golden finalize --hosts mac-a,mac-b 2>&1); rc=$?
assert_exit "finalize ok" 0 $rc
assert_file "golden manifest" "$golden/manifest.json"
assert_eq "golden surface attribution" "claude-global" \
  "$(jq -r '.files[] | select(.path=="claude/CLAUDE.md") | .surface' "$golden/manifest.json")"
msg=$(git -C "$HIVE_PROFILES_DIR" log -1 --format=%s)
assert_contains "golden committed" "$msg" "hive: golden set"

# Secret guard on finalize.
print -r -- "xoxb-123456789012-fake" > "$golden/codex/memories/oops.md"
out=$(hive_run golden finalize --hosts mac-a,mac-b 2>&1); rc=$?
assert_exit "finalize refuses secrets" 1 $rc
rm "$golden/codex/memories/oops.md"
hive_run golden finalize --hosts mac-a,mac-b >/dev/null 2>&1

# Apply on A: overwrite claude rules, add lesson-b, remove dropped memory, back all up.
out=$(hive_run apply 2>&1); rc=$?
assert_exit "apply ok" 0 $rc
assert_eq "live claude converged" "# global claude rules B (better)" "$(cat "$HIVE_HOME/.claude/CLAUDE.md")"
assert_file "live gained lesson-b" "$HIVE_HOME/.codex/memories/lesson-b.md"
assert_no_file "live dropped zsh dupe" "$HIVE_HOME/.codex/memories/zsh-preference.md"
assert_contains "backup path reported" "$out" "$HIVE_STATE_DIR/backups/"
backup=$(print -r -- "$out" | grep -o "${HIVE_STATE_DIR}/backups/[^ ]*" | head -1)
assert_file "old claude rules backed up" "$backup/claude/CLAUDE.md"
assert_file "removed memory backed up" "$backup/codex/memories/zsh-preference.md"

# State + convergence: plan now IN_SYNC once B also applies (simulate B apply).
assert_eq "applied marker set" \
  "$(jq -r '.golden.created_at' "$HIVE_PROFILES_DIR/agent-sync/state.json")" \
  "$(jq -r '.applied["mac-a"].golden_created_at' "$HIVE_PROFILES_DIR/agent-sync/state.json")"
HIVE_HOST=mac-b zsh "$HIVE_BIN" apply >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "both applied → in sync" "$out" "action=IN_SYNC"

# Idempotent second apply: nothing to overwrite or remove.
out=$(hive_run apply 2>&1)
assert_contains "idempotent overwrites" "$out" "overwritten: 0"
assert_contains "idempotent removals" "$out" "removed:     0"

# Drift after apply → RECONCILE on next plan.
print -r -- "post-golden local edit" >> "$HIVE_HOME/.claude/CLAUDE.md"
hive_run snapshot >/dev/null 2>&1
out=$(hive_run plan)
assert_contains "post-apply drift reconciles" "$out" "action=RECONCILE"

hive_sandbox_teardown
report
