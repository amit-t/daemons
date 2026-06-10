# devin-acu-governor (`dve`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terminal tool `dve` that governs Devin Enterprise (Desktop) ACU spend by launching Claude-agent sessions (`clscb`) armed with playbooks for set-limits, boost, status, and models.

**Architecture:** Thin zsh launcher (`bin/dve`) resolves the service key (Keychain → env), assembles a prompt from `playbooks/_common.md` + `playbooks/<cmd>.md` + a run-context block, and execs the Claude launcher. All cap math lives in deterministic jq programs the agent must run. New top-level `claude/` directory for Claude-powered daemons.

**Tech Stack:** zsh, jq, macOS `security` CLI, `clscb` (Claude CLI wrapper). Spec: `docs/superpowers/specs/2026-06-10-devin-acu-governor-design.md`.

---

## File structure

```
claude/devin-acu-governor/
├── bin/dve                       # entrypoint: dispatch, env load, prompt assembly, launch
├── lib/key-resolve.zsh           # dve_resolve_service_key()
├── lib/compute-caps.jq           # remaining-pool split math
├── lib/boost-check.jq            # boost headroom math
├── playbooks/_common.md          # API contract + hard rules (prepended to every command)
├── playbooks/set-limits.md
├── playbooks/boost.md
├── playbooks/status.md
├── playbooks/models.md
├── environment.env               # DVE_MONTHLY_ACU_POOL etc.; shell env overrides
├── test/harness.zsh              # assert helpers
├── test/key-resolve.test.zsh
├── test/compute-caps.test.zsh
├── test/boost-check.test.zsh
├── test/dve-cli.test.zsh
├── test/run.zsh                  # runs all *.test.zsh
└── README.md
```

Modified: `aliases.zsh` (add `dve`), `README.md:9,22-25` (claude/ convention + daemon entry), `AGENTS.md:9` (claude/ convention).

---

### Task 1: Scaffold + key resolution

**Files:**
- Create: `claude/devin-acu-governor/environment.env`
- Create: `claude/devin-acu-governor/lib/key-resolve.zsh`
- Create: `claude/devin-acu-governor/test/harness.zsh`
- Test: `claude/devin-acu-governor/test/key-resolve.test.zsh`

- [x] **Step 1: Write test harness**

`test/harness.zsh`:

```zsh
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
```

- [x] **Step 2: Write failing key-resolve test**

`test/key-resolve.test.zsh`:

```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
source "${script_dir}/../lib/key-resolve.zsh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Fake `security` that succeeds.
cat > "${tmpdir}/security-hit/security" <<'EOF' 2>/dev/null || { mkdir -p "${tmpdir}/security-hit"; cat > "${tmpdir}/security-hit/security" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == *"find-generic-password"* ]] && { print -r -- "key-from-keychain"; exit 0 }
exit 1
EOF
}
EOF
chmod +x "${tmpdir}/security-hit/security"

# Fake `security` that fails (item not found).
mkdir -p "${tmpdir}/security-miss"
cat > "${tmpdir}/security-miss/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/security-miss/security"

# 1. Keychain hit wins even when env var is set.
out=$(PATH="${tmpdir}/security-hit:$PATH" DEVIN_SERVICE_KEY="key-from-env" dve_resolve_service_key)
assert_eq "keychain wins" "key-from-keychain" "$out"

# 2. Keychain miss falls back to env var.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="key-from-env" dve_resolve_service_key)
assert_eq "env fallback" "key-from-env" "$out"

# 3. Both missing -> non-zero return, empty output.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="" dve_resolve_service_key); rc=$?
assert_exit "both missing rc" 1 $rc
assert_eq "both missing out" "" "$out"

report
```

Note: the first heredoc above is mangled — when implementing, write it as a plain `mkdir -p` + `cat > file <<'EOF'` pair like the miss case. Final form:

```zsh
mkdir -p "${tmpdir}/security-hit"
cat > "${tmpdir}/security-hit/security" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == *"find-generic-password"* ]]; then
  print -r -- "key-from-keychain"
  exit 0
fi
exit 1
EOF
chmod +x "${tmpdir}/security-hit/security"
```

- [x] **Step 3: Run test, verify it fails**

Run: `zsh claude/devin-acu-governor/test/key-resolve.test.zsh`
Expected: FAIL — `lib/key-resolve.zsh` does not exist (source error).

- [x] **Step 4: Implement key-resolve + environment.env**

`lib/key-resolve.zsh`:

```zsh
#!/usr/bin/env zsh
# Resolve the Devin service key.
# Order: macOS Keychain item (DVE_KEYCHAIN_SERVICE, default devin-service-key),
# then $DEVIN_SERVICE_KEY. Prints the key on stdout; returns 1 if neither is set.

dve_resolve_service_key() {
  local service="${DVE_KEYCHAIN_SERVICE:-devin-service-key}"
  local key
  if key=$(security find-generic-password -s "$service" -w 2>/dev/null) && [[ -n "$key" ]]; then
    print -r -- "$key"
    return 0
  fi
  if [[ -n "${DEVIN_SERVICE_KEY:-}" ]]; then
    print -r -- "$DEVIN_SERVICE_KEY"
    return 0
  fi
  return 1
}
```

`environment.env`:

```
# devin-acu-governor configuration. Shell environment variables override these.
DVE_MONTHLY_ACU_POOL=24000
DVE_LAUNCHER=clscb
DVE_KEYCHAIN_SERVICE=devin-service-key
```

- [x] **Step 5: Run test, verify pass; parse-check**

Run: `zsh claude/devin-acu-governor/test/key-resolve.test.zsh`
Expected: `pass=4 fail=0`, exit 0.
Run: `zsh -n claude/devin-acu-governor/lib/key-resolve.zsh`

- [x] **Step 6: Commit**

```bash
git add claude/devin-acu-governor
git commit -m "feat(devin-acu-governor): scaffold with keychain-first key resolution"
```

### Task 2: compute-caps.jq

**Files:**
- Create: `claude/devin-acu-governor/lib/compute-caps.jq`
- Test: `claude/devin-acu-governor/test/compute-caps.test.zsh`

- [x] **Step 1: Write failing golden tests**

`test/compute-caps.test.zsh`:

```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/compute-caps.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# 1. Day-1: nothing consumed -> team_level flat split, floor(24000/104)=230.
out=$(run_jq '{"pool":24000,"users":[{"email":"a@x","consumed":0},{"email":"b@x","consumed":0}]}')
assert_contains "day1 mode" "$out" '"mode":"team_level"'
assert_contains "day1 flat" "$out" '"flat_cap":12000'

# 2. Mid-month remaining-pool split: pool 1000, consumed 100+300=400, remaining 600,
#    share floor(600/2)=300 -> caps 400 and 600. sum_caps=1000 <= pool.
out=$(run_jq '{"pool":1000,"users":[{"email":"a@x","consumed":100},{"email":"b@x","consumed":300}]}')
assert_contains "mid mode" "$out" '"mode":"per_user"'
assert_contains "mid capA" "$out" '{"email":"a@x","consumed":100,"cap":400}'
assert_contains "mid capB" "$out" '{"email":"b@x","consumed":300,"cap":600}'
assert_contains "mid sum" "$out" '"sum_caps":1000'

# 3. Fractional consumption rounds: floor(consumed)+share keeps sum<=pool.
#    pool 1000, consumed 100.7+300.9=401.6, remaining 598.4, share=floor(299.2)=299
#    caps: floor(100.7)+299=399, floor(300.9)+299=599 -> sum 998 <= 1000.
out=$(run_jq '{"pool":1000,"users":[{"email":"a@x","consumed":100.7},{"email":"b@x","consumed":300.9}]}')
assert_contains "frac capA" "$out" '"cap":399'
assert_contains "frac capB" "$out" '"cap":599'
assert_contains "frac sum" "$out" '"sum_caps":998'

# 4. Single user gets whole remainder.
out=$(run_jq '{"pool":500,"users":[{"email":"a@x","consumed":100}]}')
assert_contains "single cap" "$out" '"cap":500'

# 5. Overconsumed pool: remaining <= 0 -> freeze at ceil(consumed), warn.
out=$(run_jq '{"pool":300,"users":[{"email":"a@x","consumed":150.2},{"email":"b@x","consumed":200}]}')
assert_contains "over warn" "$out" 'pool exhausted'
assert_contains "over capA" "$out" '"cap":151'
assert_contains "over capB" "$out" '"cap":200'

# 6. share == 0 (remaining < N): freeze + warn.
out=$(run_jq '{"pool":401,"users":[{"email":"a@x","consumed":200},{"email":"b@x","consumed":200}]}')
assert_contains "tiny warn" "$out" 'smaller than team size'

# 7. Empty roster -> error object.
out=$(run_jq '{"pool":1000,"users":[]}')
assert_contains "empty" "$out" '"error"'

report
```

- [x] **Step 2: Run, verify fails** (jq file missing)

Run: `zsh claude/devin-acu-governor/test/compute-caps.test.zsh`

- [x] **Step 3: Implement**

`lib/compute-caps.jq`:

```jq
# Remaining-pool split for dve set-limits.
# Input:  {"pool": <int>, "users": [{"email": <str>, "consumed": <number>}, ...]}
# Output: {mode, total_consumed, remaining, share?, flat_cap?, caps: [{email, consumed, cap}],
#          sum_caps, warnings: [..]}  or  {"error": ..} on empty roster.
#
# Invariant: when share >= 1, cap_i = floor(consumed_i) + share, so
# sum(caps) <= total_consumed + remaining = pool.
# Degenerate cases freeze caps at ceil(consumed) and warn.

(.users | length) as $n
| .pool as $pool
| if $n == 0 then {error: "no users in roster"}
  else
    ([.users[].consumed] | add) as $total
    | ($pool - $total) as $remaining
    | (if $total == 0 then
        (($pool / $n) | floor) as $flat
        | {mode: "team_level", flat_cap: $flat, total_consumed: 0, remaining: $pool,
           caps: [.users[] | {email, consumed, cap: $flat}], warnings: []}
      elif $remaining <= 0 then
        {mode: "per_user", total_consumed: $total, remaining: $remaining,
         caps: [.users[] | {email, consumed, cap: (.consumed | ceil)}],
         warnings: ["pool exhausted: remaining \($remaining); caps frozen at current consumption"]}
      else
        (($remaining / $n) | floor) as $share
        | if $share == 0 then
            {mode: "per_user", total_consumed: $total, remaining: $remaining,
             caps: [.users[] | {email, consumed, cap: (.consumed | ceil)}],
             warnings: ["remaining pool (\($remaining)) smaller than team size (\($n)); caps frozen at current consumption"]}
          else
            {mode: "per_user", total_consumed: $total, remaining: $remaining, share: $share,
             caps: [.users[] | {email, consumed, cap: ((.consumed | floor) + $share)}],
             warnings: []}
          end
      end)
    | . + {sum_caps: ([.caps[].cap] | add)}
  end
```

- [x] **Step 4: Run, verify pass**

Run: `zsh claude/devin-acu-governor/test/compute-caps.test.zsh`
Expected: `pass=15 fail=0`.

- [x] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/compute-caps.jq claude/devin-acu-governor/test/compute-caps.test.zsh
git commit -m "feat(devin-acu-governor): remaining-pool cap math in jq with golden tests"
```

### Task 3: boost-check.jq

**Files:**
- Create: `claude/devin-acu-governor/lib/boost-check.jq`
- Test: `claude/devin-acu-governor/test/boost-check.test.zsh`

- [x] **Step 1: Write failing tests**

`test/boost-check.test.zsh`:

```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/boost-check.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# 1. Within pool.
out=$(run_jq '{"pool":24000,"current_cap":230,"increment":50,"sum_caps":23000}')
assert_contains "ok newcap" "$out" '"new_cap":280'
assert_contains "ok newsum" "$out" '"new_sum":23050'
assert_contains "ok headroom" "$out" '"headroom_after":950'
assert_contains "ok flag" "$out" '"over_pool":false'

# 2. Pushes past pool.
out=$(run_jq '{"pool":24000,"current_cap":230,"increment":50,"sum_caps":23980}')
assert_contains "over flag" "$out" '"over_pool":true'
assert_contains "over headroom" "$out" '"headroom_after":-30'

report
```

- [x] **Step 2: Run, verify fails**
- [x] **Step 3: Implement**

`lib/boost-check.jq`:

```jq
# Boost headroom check for dve boost.
# Input:  {"pool": <int>, "current_cap": <int>, "increment": <int>, "sum_caps": <int>}
# Output: {new_cap, new_sum, headroom_after, over_pool}
(.current_cap + .increment) as $new_cap
| (.sum_caps + .increment) as $new_sum
| {new_cap: $new_cap, new_sum: $new_sum,
   headroom_after: (.pool - $new_sum), over_pool: ($new_sum > .pool)}
```

- [x] **Step 4: Run, verify pass** (`pass=6 fail=0`)
- [x] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/boost-check.jq claude/devin-acu-governor/test/boost-check.test.zsh
git commit -m "feat(devin-acu-governor): boost headroom math in jq"
```

### Task 4: Playbooks

**Files:**
- Create: `claude/devin-acu-governor/playbooks/_common.md`, `set-limits.md`, `boost.md`, `status.md`, `models.md`

No unit tests of their own (prose); content asserted by CLI tests in Task 5. Full text for each file is specified in the spec §Commands and §API surface — implement as complete markdown playbooks containing:

- [x] **Step 1: Write `_common.md`** — role statement; full API contract table (5 endpoints, exact URLs/methods/auth/fields from spec); hard rules: (1) all cap math via the jq programs given in run context — never mental arithmetic, (2) no write call without presenting the plan and getting explicit user confirmation, (3) quote exact API error bodies and stop before writes on read failure, (4) consumption API ≤10 req/hr — reuse ETags, back off on 429, (5) never print `$DEVIN_SERVICE_KEY`, (6) ledger lives at the path in run context; read/write it with jq.
- [x] **Step 2: Write `set-limits.md`** — the 6-step flow from spec §`dve set-limits` (balance → consumption group_by=user → roster → confirm N → compute-caps.jq → preview table → confirm → write caps (team_level on day-1 path) → spot-verify 5 → write ledger).
- [x] **Step 3: Write `boost.md`** — flow from spec §`dve boost` (GetUsageConfig → boost-check.jq with ledger sum_caps, rebuild ledger from roster if missing/stale → overage warning gate → write → verify → update ledger).
- [x] **Step 4: Write `status.md`** — read-only report from spec §`dve status` (consumed, remaining, days elapsed/left, run-rate, projection, verdict, top-10, per-model burn).
- [x] **Step 5: Write `models.md`** — per-model report, allowlist diff, Admin Portal walkthrough, re-check docs for a model API each run (spec §`dve models`).
- [x] **Step 6: Commit**

```bash
git add claude/devin-acu-governor/playbooks
git commit -m "feat(devin-acu-governor): agent playbooks for set-limits, boost, status, models"
```

### Task 5: bin/dve CLI

**Files:**
- Create: `claude/devin-acu-governor/bin/dve`
- Test: `claude/devin-acu-governor/test/dve-cli.test.zsh`

- [x] **Step 1: Write failing CLI tests**

`test/dve-cli.test.zsh`:

```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dve="${script_dir}/../bin/dve"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Fake security: always miss, so DEVIN_SERVICE_KEY env drives key resolution.
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

run_dve() { PATH="${tmpdir}/bin:$PATH" DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=test-key zsh "$dve" "$@" }

# 1. No args -> usage, exit 2.
out=$(run_dve 2>&1); rc=$?
assert_exit "noargs rc" 2 $rc
assert_contains "noargs usage" "$out" "Usage:"

# 2. help -> exit 0.
out=$(run_dve help 2>&1); rc=$?
assert_exit "help rc" 0 $rc

# 3. Unknown command -> exit 2.
out=$(run_dve frobnicate 2>&1); rc=$?
assert_exit "unknown rc" 2 $rc

# 4. boost arg validation.
out=$(run_dve boost 2>&1); rc=$?; assert_exit "boost noargs" 2 $rc
out=$(run_dve boost not-an-email 50 2>&1); rc=$?; assert_exit "boost bad email" 2 $rc
out=$(run_dve boost a@b.co xx 2>&1); rc=$?; assert_exit "boost bad amount" 2 $rc

# 5. set-limits prompt assembly: contains common contract, playbook, run context.
out=$(run_dve set-limits); rc=$?
assert_exit "setlimits rc" 0 $rc
assert_contains "common in prompt" "$out" "Devin Desktop API contract"
assert_contains "playbook in prompt" "$out" "# Playbook: set-limits"
assert_contains "pool in context" "$out" "DVE_MONTHLY_ACU_POOL: 24000"
assert_contains "jq path in context" "$out" "compute-caps.jq"

# 6. boost prompt carries args.
out=$(run_dve boost alice@corp.com 50)
assert_contains "boost playbook" "$out" "# Playbook: boost"
assert_contains "boost email" "$out" "alice@corp.com"
assert_contains "boost amount" "$out" "increment: 50"

# 7. Env override: pool from environment wins over environment.env.
out=$(PATH="${tmpdir}/bin:$PATH" DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=k DVE_MONTHLY_ACU_POOL=9999 zsh "$dve" status)
assert_contains "env override" "$out" "DVE_MONTHLY_ACU_POOL: 9999"

# 8. Missing key -> exit 1 with setup hint; agent never launched.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_SERVICE_KEY="" zsh "$dve" status 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey hint" "$out" "add-generic-password"

# 9. Key never appears in prompt.
out=$(run_dve set-limits)
if [[ "$out" == *test-key* ]]; then _fail "key leaked into prompt"; else _ok; fi

report
```

- [x] **Step 2: Run, verify fails** (bin/dve missing)
- [x] **Step 3: Implement `bin/dve`**

```zsh
#!/usr/bin/env zsh
# dve — Devin Enterprise ACU governor.
# Thin launcher: resolves the Devin service key, assembles a playbook prompt,
# and hands the job to a Claude agent session (DVE_LAUNCHER, default clscb).
set -u
script_path=${0:A}
daemon_dir=${script_path:h:h}

source "${daemon_dir}/lib/key-resolve.zsh"

dve_load_env() {
  local env_file="${daemon_dir}/environment.env" line key value
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == \#* || "$line" != *=* ]] && continue
    key=${line%%=*}
    value=${line#*=}
    if [[ -z "${(P)key:-}" ]]; then
      typeset -gx "$key"="$value"
    fi
  done < "$env_file"
}

dve_usage() {
  cat <<'EOF'
dve — Devin Enterprise ACU governor

Usage:
  dve set-limits              Distribute the monthly ACU pool as per-user caps (prorated)
  dve boost <email> <acus>    Raise one user's cap by <acus> with a pool headroom check
  dve status                  Consumption, remaining ACUs, month-end projection
  dve models [file|names...]  Per-model burn report + Admin Portal allowlist walkthrough
  dve help                    Show this help

Config (environment.env; shell env vars override):
  DVE_MONTHLY_ACU_POOL   monthly ACU pool (default 24000)
  DVE_LAUNCHER           agent launcher command (default clscb)
  DVE_KEYCHAIN_SERVICE   keychain item holding the service key (default devin-service-key)
  DVE_STATE_DIR          ledger directory (default ~/.local/state/devin-acu-governor)

Service key (Billing Read+Write, Analytics Read, Teams Read-only), one-time setup:
  security add-generic-password -s devin-service-key -a "$USER" -w '<key>'
Fallback: export DEVIN_SERVICE_KEY=<key>
EOF
}

dve_build_prompt() {  # $1 = command, rest = extra context lines
  local cmd="$1"; shift
  cat "${daemon_dir}/playbooks/_common.md" "${daemon_dir}/playbooks/${cmd}.md"
  print -r -- ""
  print -r -- "## Run context"
  print -r -- "- command: ${cmd}"
  print -r -- "- today: $(date +%F)"
  print -r -- "- DVE_MONTHLY_ACU_POOL: ${DVE_MONTHLY_ACU_POOL}"
  print -r -- "- compute_caps_jq: ${daemon_dir}/lib/compute-caps.jq"
  print -r -- "- boost_check_jq: ${daemon_dir}/lib/boost-check.jq"
  print -r -- "- ledger: ${DVE_STATE_DIR}/allocations.json"
  print -r -- "- service key: exported as DEVIN_SERVICE_KEY in this shell. Never print it."
  local line
  for line in "$@"; do print -r -- "- ${line}"; done
}

main() {
  dve_load_env
  : ${DVE_MONTHLY_ACU_POOL:=24000}
  : ${DVE_LAUNCHER:=clscb}
  : ${DVE_STATE_DIR:=${HOME}/.local/state/devin-acu-governor}

  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { dve_usage >&2; exit 2 }
  shift

  local -a context_lines
  case "$cmd" in
    help|-h|--help) dve_usage; exit 0 ;;
    set-limits|status) ;;
    boost)
      local email="${1:-}" amount="${2:-}"
      if [[ "$email" != *@*.* ]]; then
        print -ru2 -- "dve boost: first argument must be a user email (got: ${email:-<missing>})"
        exit 2
      fi
      if [[ "$amount" != <1-> ]]; then
        print -ru2 -- "dve boost: second argument must be a positive integer ACU amount (got: ${amount:-<missing>})"
        exit 2
      fi
      context_lines=("boost target: ${email}" "increment: ${amount}")
      ;;
    models)
      if [[ -n "${1:-}" && -f "$1" ]]; then
        context_lines=("desired model allowlist (from file $1):" "$(cat "$1")")
      elif (( $# > 0 )); then
        context_lines=("desired model allowlist: $*")
      else
        context_lines=("desired model allowlist: not provided — report current usage only")
      fi
      ;;
    *)
      print -ru2 -- "dve: unknown command '${cmd}'"
      dve_usage >&2
      exit 2
      ;;
  esac

  local key
  if ! key=$(dve_resolve_service_key); then
    print -ru2 -- "dve: no Devin service key found."
    print -ru2 -- "  Keychain: security add-generic-password -s ${DVE_KEYCHAIN_SERVICE:-devin-service-key} -a \"\$USER\" -w '<key>'"
    print -ru2 -- "  Or: export DEVIN_SERVICE_KEY=<key>"
    exit 1
  fi

  mkdir -p "${DVE_STATE_DIR}"
  local prompt
  prompt=$(dve_build_prompt "$cmd" "${context_lines[@]}")

  if [[ -n "${DVE_PRINT_PROMPT:-}" ]]; then
    print -r -- "$prompt"
    exit 0
  fi

  export DEVIN_SERVICE_KEY="$key"
  exec zsh -ic "${DVE_LAUNCHER} $(printf '%q' "$prompt")"
}

main "$@"
```

Note: `"${context_lines[@]}"` with an empty array needs `set -u` care in zsh — zsh handles empty `"$@"`-style expansion of empty arrays fine (expands to nothing). Verify in tests.

- [x] **Step 4: Run CLI tests + full suite + parse checks**

Run: `zsh claude/devin-acu-governor/test/dve-cli.test.zsh` → expected `pass=19 fail=0`.
Run: `zsh -n claude/devin-acu-governor/bin/dve`

- [x] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/bin/dve claude/devin-acu-governor/test/dve-cli.test.zsh
git commit -m "feat(devin-acu-governor): dve CLI dispatch, prompt assembly, agent launch"
```

### Task 6: Test runner + repo wiring + docs

**Files:**
- Create: `claude/devin-acu-governor/test/run.zsh`
- Create: `claude/devin-acu-governor/README.md`
- Modify: `aliases.zsh` (append `dve` function)
- Modify: `README.md:9` (claude/ convention), `README.md:22-25` (daemon entry)
- Modify: `AGENTS.md:9` (claude/ convention)

- [x] **Step 1: Write `test/run.zsh`**

```zsh
#!/usr/bin/env zsh
# Run all devin-acu-governor tests. Exit non-zero if any file fails.
set -u
script_dir=${0:A:h}
typeset -i failures=0
local f
for f in "${script_dir}"/*.test.zsh; do
  print -r -- "== ${f:t}"
  zsh "$f" || (( failures++ ))
done
(( failures == 0 )) || { print -ru2 -- "${failures} test file(s) failed"; exit 1 }
print -r -- "all test files passed"
```

- [x] **Step 2: Append to `aliases.zsh`**

```zsh
dve() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/devin-acu-governor/bin/dve"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "dve: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}
```

- [x] **Step 3: Update root `README.md`** — add to Repository contract: `- Claude-powered daemons (runtime is a Claude agent session) live under `claude/<daemon-name>/`.`; add to Current daemons: `- [`claude/devin-acu-governor`](./claude/devin-acu-governor) — `dve`, a Devin Enterprise ACU governor that launches Claude-agent playbook sessions (via `clscb`) to distribute the monthly ACU pool as prorated per-user caps (`set-limits`), raise individual caps with pool-headroom checks (`boost`), report consumption trajectory and month-end projection (`status`), and audit per-model burn with an Admin Portal allowlist walkthrough (`models`).`

- [x] **Step 4: Update `AGENTS.md`** — after the codex line: `- Claude-powered daemons live under `claude/<daemon-name>/`; their runtime is a Claude agent session launched from a thin zsh wrapper.`

- [x] **Step 5: Write daemon `README.md`** — purpose, commands table, one-time key setup, config table, how a run works, file map, verification (`zsh test/run.zsh`, `zsh -n`), API gap note for models.

- [x] **Step 6: Full verification**

Run: `zsh claude/devin-acu-governor/test/run.zsh` → all pass.
Run: `for f in claude/devin-acu-governor/bin/dve claude/devin-acu-governor/lib/key-resolve.zsh claude/devin-acu-governor/test/*.zsh aliases.zsh; do zsh -n "$f" || echo "PARSE FAIL: $f"; done` → no failures.

- [x] **Step 7: Commit**

```bash
git add claude/devin-acu-governor aliases.zsh README.md AGENTS.md
git commit -m "feat(devin-acu-governor): wire dve into repo, add docs and test runner"
```

---

## Self-review notes

- Spec coverage: set-limits (T2 math, T4 playbook, T5 CLI), boost (T3, T4, T5), status (T4, T5), models (T4, T5), key storage (T1), ledger path (T5 run context), repo wiring + docs (T6), testing (T1-T6). Out-of-scope items untouched. ✓
- Types consistent: `compute-caps.jq` I/O matches set-limits playbook contract; `boost-check.jq` matches boost playbook; run-context keys match playbook references. ✓
- Step 2 of Task 1 contains an intentionally-flagged mangled heredoc with the corrected form directly below it; implementer uses the corrected form. ✓
