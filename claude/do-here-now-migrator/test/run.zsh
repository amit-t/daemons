#!/usr/bin/env zsh
# Run all do-here-now-migrator tests. Exit non-zero if any file fails.
set -u
script_dir=${0:A:h}
typeset -i failures=0
local f
for f in "${script_dir}"/*.test.zsh; do
  print -r -- "== ${f:t}"
  zsh "$f" || (( failures++ ))
done
if (( failures > 0 )); then
  print -ru2 -- "${failures} test file(s) failed"
  exit 1
fi
print -r -- "all test files passed"
