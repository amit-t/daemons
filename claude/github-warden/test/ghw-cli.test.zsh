#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

out=$(zsh "$ghw_bin" help 2>&1); rc=$?
assert_exit "help exits 0" 0 $rc
assert_contains "help lists mirror" "$out" "ghw mirror"
assert_contains "help lists import" "$out" "ghw import"
assert_contains "help lists doctor" "$out" "ghw doctor"

out=$(zsh "$ghw_bin" 2>&1); rc=$?
assert_exit "no command exits 2" 2 $rc

out=$(zsh "$ghw_bin" bogus-cmd 2>&1); rc=$?
assert_exit "unknown command exits 2" 2 $rc
assert_contains "unknown command named" "$out" "unknown command: bogus-cmd"

out=$(zsh "$ghw_bin" --account 2>&1); rc=$?
assert_exit "--account without value exits 2" 2 $rc

report
