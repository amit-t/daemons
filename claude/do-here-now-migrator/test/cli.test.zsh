#!/usr/bin/env zsh
# End-to-end CLI behaviour: argument handling, phase ordering, and the guards
# that stop a destructive phase running by accident.
set -u
source "${0:A:h}/harness.zsh"

local dhm="$(dhm_test_daemon_dir)/bin/dhm"
local tmp; tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT

typeset -gx DHM_STATE_DIR="${tmp}/state"

run_dhm() { zsh "$dhm" "$@" 2>&1 }

# ---- help and unknown input --------------------------------------------------

local out rc

out=$(run_dhm help)
assert_contains "help names the tool" "$out" "DigitalOcean to here.now"
assert_contains "help lists run"      "$out" "dhm run"
assert_contains "help lists agents"   "$out" "--agent codex"
assert_contains "help documents co"    "$out" 'via `co`'
assert_contains "help documents cf"    "$out" 'via `cf`'
assert_contains "help documents cxscb" "$out" 'via `cxscb`'
assert_contains "help documents dey"   "$out" 'via `dey`'
assert_contains "help states the safety model" "$out" "Only apex and www"

# No arguments prints help rather than doing anything.
out=$(run_dhm)
assert_contains "bare invocation prints help" "$out" "Usage:"

out=$(run_dhm frobnicate 2>&1); rc=$?
assert_ne "unknown command fails" 0 "$rc"
assert_contains "unknown command explains" "$out" "unknown command"

out=$(run_dhm run --nonsense 2>&1); rc=$?
assert_ne "unknown option fails" 0 "$rc"
assert_contains "unknown option explains" "$out" "unknown option"

# ---- a repository is required ------------------------------------------------

out=$(run_dhm status --repo /definitely/not/here 2>&1); rc=$?
assert_ne "missing repo fails" 0 "$rc"
assert_contains "missing repo explains" "$out" "does not exist"

# ---- agent validation happens before any work --------------------------------

out=$(run_dhm run --repo "$tmp" --agent gpt5 2>&1); rc=$?
assert_ne "unknown agent fails" 0 "$rc"
assert_contains "unknown agent explains" "$out" "unknown agent"

# ---- domain validation -------------------------------------------------------

out=$(run_dhm run --repo "$tmp" --domain "not a domain" 2>&1); rc=$?
assert_ne "malformed domain fails" 0 "$rc"
assert_contains "malformed domain explains" "$out" "does not look like a domain"

out=$(run_dhm run --repo "$tmp" --domain "https://example.com" 2>&1); rc=$?
assert_ne "url as domain fails" 0 "$rc"

# ---- unknown --through phase -------------------------------------------------

out=$(run_dhm run --repo "$tmp" --domain example.com --through teleport 2>&1); rc=$?
assert_ne "unknown phase fails" 0 "$rc"
assert_contains "unknown phase explains" "$out" "unknown phase"

# ---- state is created and reported ------------------------------------------

out=$(run_dhm status --repo "$tmp" --domain example.com --site clitest 2>&1)
assert_contains "status lists phases"       "$out" "preflight"
assert_contains "status lists decommission" "$out" "decommission"
assert_contains "status shows pending"      "$out" "pending"
assert_contains "status shows the domain"   "$out" "https://example.com"
assert_eq "state file was created" "1" \
  "$([[ -s "${DHM_STATE_DIR}/clitest/state.json" ]] && print 1 || print 0)"

# ---- decommission refuses without a backup ----------------------------------
# The guard that matters most: no recorded backup means nothing may be
# destroyed, regardless of what else is true.

out=$(run_dhm decommission --repo "$tmp" --domain example.com --site clitest --yes 2>&1); rc=$?
assert_ne "decommission without backup fails" 0 "$rc"
assert_contains "decommission explains the missing backup" "$out" "no backup recorded"
assert_not_contains "nothing was destroyed" "$out" "destroyed app"

# ---- preflight halts the pipeline on any problem -----------------------------
# A bare directory is not a usable repository, so nothing downstream may run.

out=$(run_dhm run --repo "$tmp" --domain example.com --site haltest --dry-run 2>&1); rc=$?
assert_ne "run stops on preflight failure" 0 "$rc"
assert_contains "preflight failure is explained" "$out" "nothing has been changed"
assert_not_contains "no later phase ran" "$out" "phase: publish"

# ---- a plain `run` never reaches decommission -------------------------------
# `--through` defaults to `ci`, and decommission is skipped unless explicitly
# named. Seed the earlier phases so the pipeline reaches the gate.

dhm_test_lib common
local ph
run_dhm status --repo "$tmp" --domain example.com --site skiptest >/dev/null 2>&1
for ph in preflight inventory backup account transform build publish domain verify ci; do
  dhm_phase_mark skiptest "$ph" done
done

# With the default --through ci the pipeline stops before decommission is even
# considered.
out=$(run_dhm run --repo "$tmp" --domain example.com --site skiptest --dry-run 2>&1)
assert_not_contains "default run never reaches decommission" "$out" "phase: decommission"
assert_not_contains "no destruction was attempted" "$out" "WILL BE DESTROYED"

# Running all the way through `report` steps over decommission explicitly,
# rather than treating "run everything" as permission to destroy.
out=$(run_dhm run --repo "$tmp" --domain example.com --site skiptest \
        --through report --dry-run 2>&1)
assert_contains "through-report skips decommission" "$out" "skipping decommission"
assert_not_contains "through-report destroys nothing" "$out" "WILL BE DESTROYED"

# Naming decommission explicitly still hits the backup precondition first.
out=$(run_dhm run --repo "$tmp" --domain example.com --site skiptest \
        --through decommission --dry-run --yes 2>&1)
assert_contains "explicit decommission is gated on the backup" "$out" "no backup recorded"

# ---- doctor runs without a repository or state ------------------------------

out=$(run_dhm doctor 2>&1)
assert_contains "doctor checks core tools" "$out" "curl"
assert_contains "doctor checks launchers"  "$out" "cxscb"

report
