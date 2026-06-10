#!/usr/bin/env zsh
# Minimal assert helpers for dve tests. Source me, then call report at the end.

typeset -g _dve_pass=0 _dve_fail=0

_fail() { print -ru2 -- "FAIL: $1"; (( _dve_fail++ )) || true }
_ok()   { (( _dve_pass++ )) || true }

assert_eq() {  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then _ok; else _fail "$1: expected [$2] got [$3]"; fi
}

assert_contains() {  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then _ok; else _fail "$1: [$3] not found in output"; fi
}

assert_exit() {  # assert_exit <label> <expected-code> <actual-code>
  if (( $2 == $3 )); then _ok; else _fail "$1: expected exit $2 got $3"; fi
}

report() {
  print -r -- "pass=${_dve_pass} fail=${_dve_fail}"
  (( _dve_fail == 0 ))
}
