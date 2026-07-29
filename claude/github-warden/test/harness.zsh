#!/usr/bin/env zsh
# Minimal assert helpers for ghw tests. Source me, then call report at the end.

typeset -g _ghw_pass=0 _ghw_fail=0

_fail() { print -ru2 -- "FAIL: $1"; (( _ghw_fail++ )) || true }
_ok()   { (( _ghw_pass++ )) || true }

assert_eq() {  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then _ok; else _fail "$1: expected [$2] got [$3]"; fi
}

assert_contains() {  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then _ok; else _fail "$1: [$3] not found in output"; fi
}

assert_not_contains() {  # assert_not_contains <label> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then _ok; else _fail "$1: [$3] unexpectedly found in output"; fi
}

assert_exit() {  # assert_exit <label> <expected-code> <actual-code>
  if (( $2 == $3 )); then _ok; else _fail "$1: expected exit $2 got $3"; fi
}

report() {
  print -r -- "pass=${_ghw_pass} fail=${_ghw_fail}"
  (( _ghw_fail == 0 ))
}
