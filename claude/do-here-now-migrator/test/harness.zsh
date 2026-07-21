#!/usr/bin/env zsh
# Minimal assert helpers for do-here-now-migrator tests.
# Source me, then call `report` at the end.

typeset -g _dhm_pass=0 _dhm_fail=0

# Inside a zsh function $0 is the function name, not the script path, so the
# locations are captured here at source time and never re-derived.
typeset -g DHM_TEST_DIR=${0:A:h}
typeset -g DHM_TEST_DAEMON_DIR=${DHM_TEST_DIR:h}

_fail() { print -ru2 -- "FAIL: $1"; (( _dhm_fail++ )) || true }
_ok()   { (( _dhm_pass++ )) || true }

assert_eq() {  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then _ok; else _fail "$1: expected [$2] got [$3]"; fi
}

assert_ne() {  # assert_ne <label> <unexpected> <actual>
  if [[ "$2" != "$3" ]]; then _ok; else _fail "$1: did not expect [$2]"; fi
}

assert_contains() {  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then _ok; else _fail "$1: [$3] not found in output"; fi
}

assert_not_contains() {  # assert_not_contains <label> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then _ok; else _fail "$1: [$3] should not appear"; fi
}

assert_ok() {  # assert_ok <label> <command ...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then _ok; else _fail "$label: expected success from: $*"; fi
}

assert_fails() {  # assert_fails <label> <command ...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then _fail "$label: expected failure from: $*"; else _ok; fi
}

assert_exit() {  # assert_exit <label> <expected-code> <actual-code>
  if (( $2 == $3 )); then _ok; else _fail "$1: expected exit $2 got $3"; fi
}

# Load the daemon's libraries into the current test shell.
dhm_test_lib() {  # dhm_test_lib <name ...>
  local name
  for name in "$@"; do
    source "${DHM_TEST_DAEMON_DIR}/lib/${name}.zsh" || {
      _fail "could not source lib/${name}.zsh"
      return 1
    }
  done
}

dhm_test_daemon_dir() { print -r -- "$DHM_TEST_DAEMON_DIR" }
dhm_test_fixture()    { print -r -- "${DHM_TEST_DIR}/fixtures/${1}" }

# A disposable state directory, so tests never touch the real one.
#
# This must NOT be called through $(...): a command substitution runs in a
# subshell, so the export would be discarded and the test would silently write
# to the operator's real state directory. It therefore sets DHM_TEST_SANDBOX
# in the caller's shell instead of printing the path.
dhm_test_state_sandbox() {
  typeset -g DHM_TEST_SANDBOX
  DHM_TEST_SANDBOX=$(mktemp -d) || return 1
  typeset -gx DHM_STATE_DIR="$DHM_TEST_SANDBOX"
}

report() {
  print -r -- "pass=${_dhm_pass} fail=${_dhm_fail}"
  (( _dhm_fail == 0 ))
}
