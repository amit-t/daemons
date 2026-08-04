#!/usr/bin/env zsh
# Assert helpers + fixture builders for hivemind tests. Source me, call report at end.

typeset -g _hive_pass=0 _hive_fail=0
typeset -g HIVE_TEST_ROOT=""
typeset -g HIVE_BIN=${0:A:h:h}/bin/hive

_fail() { print -ru2 -- "FAIL: $1"; (( _hive_fail++ )) || true }
_ok()   { (( _hive_pass++ )) || true }

assert_eq()           { if [[ "$2" == "$3" ]]; then _ok; else _fail "$1: expected [$2] got [$3]"; fi }
assert_contains()     { if [[ "$2" == *"$3"* ]]; then _ok; else _fail "$1: [$3] not found in output"; fi }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then _ok; else _fail "$1: [$3] unexpectedly found"; fi }
assert_exit()         { if (( $2 == $3 )); then _ok; else _fail "$1: expected exit $2 got $3"; fi }
assert_file()         { if [[ -f "$2" ]]; then _ok; else _fail "$1: missing file $2"; fi }
assert_no_file()      { if [[ ! -f "$2" ]]; then _ok; else _fail "$1: file should not exist: $2"; fi }

report() {
  print -r -- "pass=${_hive_pass} fail=${_hive_fail}"
  (( _hive_fail == 0 ))
}

# --- fixtures --------------------------------------------------------------

# Fresh sandbox: fake HOME with live surfaces + a local-only Profiles git repo.
# Exports every HIVE_* env the engines honor. Call once per test file.
hive_sandbox() {
  HIVE_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hivemind-test.XXXXXX")
  export HIVE_HOME="${HIVE_TEST_ROOT}/home"
  export HIVE_PROFILES_DIR="${HIVE_TEST_ROOT}/profiles"
  export HIVE_STATE_DIR="${HIVE_TEST_ROOT}/state"
  export HIVE_HOST="mac-a"
  export HIVE_MAX_AGE_HOURS=24
  unset HIVE_NOW HIVE_FORCE 2>/dev/null || true

  mkdir -p "$HIVE_HOME/.claude" "$HIVE_HOME/.codex/memories" "$HIVE_HOME/.gemini"
  print -r -- "# global claude rules A" > "$HIVE_HOME/.claude/CLAUDE.md"
  print -r -- "# codex agents A"        > "$HIVE_HOME/.codex/AGENTS.md"
  print -r -- "prefer zsh"              > "$HIVE_HOME/.codex/memories/zsh-preference.md"
  print -r -- "# gemini A"              > "$HIVE_HOME/.gemini/GEMINI.md"

  git init --quiet "$HIVE_PROFILES_DIR"
  git -C "$HIVE_PROFILES_DIR" config user.email test@example.com
  git -C "$HIVE_PROFILES_DIR" config user.name "hive test"
  print -r -- "# profiles" > "$HIVE_PROFILES_DIR/README.md"
  git -C "$HIVE_PROFILES_DIR" add -A
  git -C "$HIVE_PROFILES_DIR" commit --quiet -m init
}

hive_sandbox_teardown() {
  [[ -n "$HIVE_TEST_ROOT" && -d "$HIVE_TEST_ROOT" ]] && rm -rf "$HIVE_TEST_ROOT"
}

hive_run() { zsh "$HIVE_BIN" "$@" }

# Simulate the other machine: snapshot the same sandbox HOME as a second host,
# optionally after mutating surfaces, optionally with a faked capture time.
hive_snapshot_as() {  # $1 host, $2 optional epoch override
  HIVE_HOST="$1" HIVE_NOW="${2:-}" zsh "$HIVE_BIN" snapshot
}
