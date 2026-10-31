#!/usr/bin/env zsh
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
aliases_file="${script_dir}/../../../aliases.zsh"
zsh -n "$aliases_file" 2>/dev/null
assert_exit "aliases parse cleanly" 0 $?
out=$(zsh -fc "source '$aliases_file'; type dag.flat-cap.defu" 2>&1); rc=$?
assert_exit "pinned flat-cap wrapper loads" 0 $rc
assert_contains "pinned flat-cap wrapper exists" "$out" "dag.flat-cap.defu"
report
