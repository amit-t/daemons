# github-warden (`ghw`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `claude/github-warden/` — a dag-style GitHub org/repo management daemon (`ghw`) with deterministic zsh+curl+jq core, agent playbooks for `mirror`/`import`, and read-only `doctor`/`status`/`audit`/`stale`/`members` commands.

**Architecture:** Thin zsh CLI (`bin/ghw`) dispatches: read-only commands run pure zsh/jq locally; `mirror`/`import` launch a `clscb` playbook session whose writes go only through deterministic engine scripts. Every mutating path is gated by precondition checks P1–P6 from the import spec. All GitHub API traffic goes through one curl wrapper with rate-limit backoff, making everything testable via a curl stub.

**Tech Stack:** zsh, curl, jq, `clscb` (Claude agent launcher), existing `~/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh`.

**Spec:** `docs/superpowers/specs/2026-07-28-github-warden-design.md`. Import semantics: `/Users/amittiwari/Projects/Invenco/DoE/github-org-mgmt/SPEC-org-import-daemon.md`.

## Global Constraints

- All shell files are zsh: `#!/usr/bin/env zsh`, `set -u`, validated with `zsh -n` (never shellcheck).
- Inside zsh functions `$0` is the function name — capture `script_path=${0:A}` at file top before defining functions.
- Tokens come only from env vars named in `config/accounts.json` (`GHW_TOKEN_PERSONAL`, `GHW_TOKEN_INV`); never the `gh` keyring, never committed, never logged, never echoed into reports or prompts.
- **Never issue a membership `PUT` for a principal that is already a member** (import spec §4.2). Set-difference is the safety mechanism, implemented in code.
- Org-membership phase completes fully before team-membership phase begins (import spec §4.1).
- Writes are serial — one in-flight API request.
- No removals, no role changes for existing members, no team/org creation (import spec §10).
- State/reports: `~/.local/state/github-warden/` (override `GHW_STATE_DIR`); reports never deleted.
- Repo rule: commit after each task; final task pushes. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Base dir for all paths below: `/Users/amittiwari/Projects/Tools-Utilities/daemons`.

---

### Task 1: Scaffold + CLI dispatch + aliases wrapper

**Files:**
- Create: `claude/github-warden/bin/ghw`
- Create: `claude/github-warden/test/harness.zsh`
- Create: `claude/github-warden/test/run.zsh`
- Create: `claude/github-warden/test/ghw-cli.test.zsh`
- Modify: `aliases.zsh` (append `ghw` wrapper after the `cas` selectors block)

**Interfaces:**
- Produces: `bin/ghw` dispatch — `ghw [--account <name>] <command> [args...]`; global var `daemon_dir`; `ghw_usage`. Later tasks add `case` arms that `source "${daemon_dir}/lib/<cmd>.zsh"` and call `ghw_<cmd> "$@"`.
- Produces: test harness functions `assert_eq`, `assert_contains`, `assert_exit`, `report` (identical contract to dag's harness).

- [ ] **Step 1: Write harness + runner (copied dag pattern, ghw counters)**

`claude/github-warden/test/harness.zsh`:
```zsh
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
```

`claude/github-warden/test/run.zsh`:
```zsh
#!/usr/bin/env zsh
# Run all github-warden tests. Exit non-zero if any file fails.
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
```

- [ ] **Step 2: Write failing CLI test**

`claude/github-warden/test/ghw-cli.test.zsh`:
```zsh
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `zsh claude/github-warden/test/ghw-cli.test.zsh`
Expected: FAIL (bin/ghw missing → non-zero, or asserts fail)

- [ ] **Step 4: Write `bin/ghw`**

```zsh
#!/usr/bin/env zsh
# ghw — github-warden: GitHub org/repo management daemon.
# Thin launcher: resolves the account profile + token, runs deterministic
# read-only commands locally, and hands mutating flows (mirror, import) to a
# clscb playbook session whose writes go only through lib/ engine scripts.
set -u
script_path=${0:A}
daemon_dir=${script_path:h:h}

ghw_usage() {
  cat <<'EOF'
ghw — github-warden: GitHub org/repo management daemon

Usage:
  ghw [--account personal|inv] <command ...>
                              --account picks the credential profile; omitted, ghw
                              infers it from the target org/owner via config/accounts.json.
  ghw mirror [<repo|url>] [flags...]
                              Launch an agent that scaffolds a new repo mirroring a
                              reference repo (gh-repo-mirror skill). Bare inside a git
                              repo: reference = origin. --script runs
                              mirror-repo.zsh directly (pass its flags through).
  ghw import --org <org> [--team <slug>] --csv <file> [--column login]
             [--role member|maintainer] [--org-role member] [--dry-run] [--script]
                              Reconcile logins into an org/team. Add-only, idempotent,
                              never demotes an existing member. --script skips the agent
                              and runs the deterministic engine directly.
  ghw doctor                  Check every profile: token, login, scopes, org admin role.
  ghw status [--org <org>]    Org overview: repos, members, teams (read-only).
  ghw audit --org <org> [--ref <owner/repo>]
                              Settings/security/branch-protection drift vs reference repo.
  ghw stale --org <org> [--months <n>]
                              Archive candidates: inactive/empty repos (read-only).
  ghw members --org <org> [--csv <out>] [--json]
                              Membership report: roles, teams, 2FA, outside collaborators.
  ghw help                    Show this help.

Config (env):
  GHW_TOKEN_PERSONAL / GHW_TOKEN_INV   tokens per profile (see config/accounts.json)
  GHW_LAUNCHER                         agent launcher for mirror/import (default clscb)
  GHW_STATE_DIR                        reports/state dir (default ~/.local/state/github-warden)
EOF
}

main() {
  : ${GHW_STATE_DIR:=${HOME}/.local/state/github-warden}
  typeset -gx GHW_STATE_DIR
  local account=""
  while (( $# )); do
    case "${1:-}" in
      --account=*) account="${1#--account=}"; shift ;;
      --account)
        account="${2:-}"
        if [[ -z "$account" ]]; then
          print -ru2 -- "ghw: --account expects a profile name"
          exit 2
        fi
        shift 2
        ;;
      *) break ;;
    esac
  done

  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    ghw_usage >&2
    exit 2
  fi
  shift

  case "$cmd" in
    help|-h|--help)
      ghw_usage
      exit 0
      ;;
    *)
      print -ru2 -- "ghw: unknown command: ${cmd}"
      ghw_usage >&2
      exit 2
      ;;
  esac
}

main "$@"
```

(Command arms land in later tasks; `help`/errors are the full Task-1 surface.)

- [ ] **Step 5: Run tests to verify pass; parse-check**

Run: `zsh -n claude/github-warden/bin/ghw && zsh claude/github-warden/test/run.zsh`
Expected: `all test files passed`

- [ ] **Step 6: Append wrapper to `aliases.zsh`** (after the `cas--def` line)

```zsh
# ghw — github-warden: GitHub org/repo management daemon.
ghw() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/github-warden/bin/ghw"
  if [[ ! -x "$daemon_entry" && ! -f "$daemon_entry" ]]; then
    print -ru2 -- "ghw: missing daemon entrypoint at $daemon_entry"
    return 1
  fi
  zsh "$daemon_entry" "$@"
}
```

Run: `zsh -n aliases.zsh`
Expected: silent, exit 0

- [ ] **Step 7: Commit**

```bash
git add claude/github-warden aliases.zsh
git commit -m "feat(ghw): scaffold github-warden CLI dispatch, test harness, alias

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Account profiles + resolution (`config/accounts.json`, `lib/auth.zsh` part 1)

**Files:**
- Create: `claude/github-warden/config/accounts.json`
- Create: `claude/github-warden/lib/auth.zsh`
- Create: `claude/github-warden/test/auth-resolve.test.zsh`

**Interfaces:**
- Produces: `ghw_resolve_profile <explicit-account> <org-or-owner>` — prints profile name, exit 2 with message on failure. `ghw_token_for <profile>` — exports `GHW_TOKEN` + `GHW_TOKEN_ENV_NAME`, exit 2 if env var empty. `ghw_profile_login <profile>` — prints expected login. Env override `GHW_ACCOUNTS_FILE` (tests point it at a fixture).
- Consumes: nothing from earlier tasks (sourced standalone).

- [ ] **Step 1: Write `config/accounts.json`** (real values Amit fills at setup; committed file is secret-free)

```json
{
  "profiles": {
    "personal": {
      "token_env": "GHW_TOKEN_PERSONAL",
      "login": "amit-t",
      "orgs": ["amit-t"]
    },
    "inv": {
      "token_env": "GHW_TOKEN_INV",
      "login": "FILL_AT_SETUP",
      "orgs": ["INVENCO-GROUP", "Invenco-Cloud-Systems-ICS"]
    }
  }
}
```

- [ ] **Step 2: Write failing resolution test**

`claude/github-warden/test/auth-resolve.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/auth.zsh"

fixture=$(mktemp)
cat > "$fixture" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["amit-t"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP","Invenco-Cloud-Systems-ICS"]}}}
JSON
export GHW_ACCOUNTS_FILE="$fixture"

out=$(ghw_resolve_profile "inv" ""); rc=$?
assert_exit "explicit account ok" 0 $rc
assert_eq "explicit account wins" "inv" "$out"

out=$(ghw_resolve_profile "" "INVENCO-GROUP"); rc=$?
assert_exit "org map ok" 0 $rc
assert_eq "org maps to inv" "inv" "$out"

out=$(ghw_resolve_profile "" "amit-t"); rc=$?
assert_eq "owner maps to personal" "personal" "$out"

out=$(ghw_resolve_profile "" "unknown-org" 2>&1); rc=$?
assert_exit "unmapped org fails" 2 $rc
assert_contains "unmapped names orgs" "$out" "INVENCO-GROUP"

out=$(ghw_resolve_profile "nope" "" 2>&1); rc=$?
assert_exit "unknown profile fails" 2 $rc

export T_I="tok123"
unset GHW_TOKEN GHW_TOKEN_ENV_NAME 2>/dev/null
ghw_token_for "inv"; rc=$?
assert_exit "token resolves" 0 $rc
assert_eq "token exported" "tok123" "${GHW_TOKEN:-}"
assert_eq "token env name recorded" "T_I" "${GHW_TOKEN_ENV_NAME:-}"

unset T_P
out=$(ghw_token_for "personal" 2>&1); rc=$?
assert_exit "missing token fails" 2 $rc
assert_contains "missing token names env var" "$out" "T_P"

out=$(ghw_profile_login "inv")
assert_eq "login lookup" "amit_vnt" "$out"

rm -f "$fixture"
report
```

- [ ] **Step 3: Run to verify it fails** — `zsh claude/github-warden/test/auth-resolve.test.zsh` → FAIL (no lib/auth.zsh)

- [ ] **Step 4: Write `lib/auth.zsh` (resolution half)**

```zsh
#!/usr/bin/env zsh
# ghw auth — profile resolution + token loading. Precondition gate added in a
# later section of this file. Requires jq. Sourced by bin/ghw and engines.

ghw_accounts_file() {
  print -r -- "${GHW_ACCOUNTS_FILE:-${daemon_dir}/config/accounts.json}"
}

ghw_resolve_profile() {  # $1 explicit account or "", $2 target org/owner or ""
  local explicit="$1" org="$2" file
  file=$(ghw_accounts_file)
  if [[ ! -f "$file" ]]; then
    print -ru2 -- "ghw: accounts file not found: $file"
    return 2
  fi
  if [[ -n "$explicit" ]]; then
    if jq -e --arg p "$explicit" '.profiles[$p]' "$file" >/dev/null; then
      print -r -- "$explicit"
      return 0
    fi
    print -ru2 -- "ghw: unknown account profile: $explicit ($(jq -r '.profiles | keys | join(", ")' "$file"))"
    return 2
  fi
  if [[ -n "$org" ]]; then
    local match
    match=$(jq -r --arg o "$org" '.profiles | to_entries[] | select(.value.orgs | index($o)) | .key' "$file" | head -1)
    if [[ -n "$match" ]]; then
      print -r -- "$match"
      return 0
    fi
    print -ru2 -- "ghw: org '$org' not mapped to any profile. Known orgs: $(jq -r '[.profiles[].orgs[]] | join(", ")' "$file"). Use --account or add it to config/accounts.json."
    return 2
  fi
  print -ru2 -- "ghw: cannot resolve account — pass --account or a target org"
  return 2
}

ghw_profile_field() {  # $1 profile, $2 field
  jq -r --arg p "$1" --arg f "$2" '.profiles[$p][$f]' "$(ghw_accounts_file)"
}

ghw_profile_login() { ghw_profile_field "$1" login }

ghw_token_for() {  # $1 profile — exports GHW_TOKEN, GHW_TOKEN_ENV_NAME
  local env_name
  env_name=$(ghw_profile_field "$1" token_env)
  if [[ -z "${(P)env_name:-}" ]]; then
    print -ru2 -- "ghw: token env var ${env_name} is empty — export it for profile '$1'"
    return 2
  fi
  typeset -gx GHW_TOKEN="${(P)env_name}" GHW_TOKEN_ENV_NAME="$env_name"
}
```

- [ ] **Step 5: Run tests, parse-check** — `zsh -n claude/github-warden/lib/auth.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 6: Commit**

```bash
git add claude/github-warden/config/accounts.json claude/github-warden/lib/auth.zsh claude/github-warden/test/auth-resolve.test.zsh
git commit -m "feat(ghw): account profiles + resolution with org auto-map

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: API wrapper with rate-limit backoff (`lib/api.zsh`) + curl stub

**Files:**
- Create: `claude/github-warden/lib/api.zsh`
- Create: `claude/github-warden/test/fixtures/curl-stub.zsh`
- Create: `claude/github-warden/test/api.test.zsh`

**Interfaces:**
- Produces: `ghw_api <METHOD> <path> [json-body]` — prints response body; return 0 (2xx), 3 (plain 403), 4 (404), 1 (other, after retries); sets `GHW_LAST_STATUS`, `GHW_LAST_HEADERS`. `ghw_api_paged <path>` — prints one merged JSON array across pages (per_page=100). Env: `GHW_TOKEN` (required), `GHW_API_ROOT` (default `https://api.github.com`), `GHW_CURL` (default `curl`, tests point at stub), `GHW_SLEEP` (default `sleep`, tests point at a logger).
- Produces: curl stub protocol — stub reads `GHW_STUB_ROUTES` (zsh file defining `stub_route <method> <url> <body>` that sets `RESP_STATUS`, `RESP_BODY`, `RESP_HEADERS`) and appends `"<METHOD> <url> <body>"` lines to `GHW_STUB_LOG`. Every later API test consumes this exact protocol.

- [ ] **Step 1: Write the curl stub**

`claude/github-warden/test/fixtures/curl-stub.zsh`:
```zsh
#!/usr/bin/env zsh
# Fake curl for ghw tests. Understands the exact arg layout ghw_api emits:
#   -sS -X METHOD -H ... -D hdrfile -o bodyfile -w %{http_code} [-H ct -d body] URL
# Looks up the response via stub_route from $GHW_STUB_ROUTES, logs the request
# to $GHW_STUB_LOG, writes headers/body files, prints the status code.
set -u
method=GET body="" hdr=/dev/null out=/dev/null url=""
while (( $# )); do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -D) hdr=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -d) body=$2; shift 2 ;;
    -H|-w) shift 2 ;;
    -sS) shift ;;
    *) url=$1; shift ;;
  esac
done
print -r -- "${method} ${url} ${body}" >> "$GHW_STUB_LOG"
RESP_STATUS=200 RESP_BODY="{}" RESP_HEADERS=""
source "$GHW_STUB_ROUTES"
stub_route "$method" "$url" "$body"
print -r -- "$RESP_HEADERS" > "$hdr"
print -rn -- "$RESP_BODY" > "$out"
print -rn -- "$RESP_STATUS"
```

- [ ] **Step 2: Write failing API tests** (happy path, plain-403 no-retry, 404, secondary rate limit honors retry-after — this is acceptance test A8's engine half, pagination)

`claude/github-warden/test/api.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/api.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_TOKEN="testtoken"
export GHW_API_ROOT="https://api.github.example"
sleep_log="${work}/sleeps"
cat > "${work}/fake-sleep" <<EOF
#!/usr/bin/env zsh
print -r -- "\$1" >> "${sleep_log}"
EOF
chmod +x "${work}/fake-sleep"
export GHW_SLEEP="${work}/fake-sleep"

# happy path
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' }
EOF
: > "$GHW_STUB_LOG"
out=$(ghw_api GET /user); rc=$?
assert_exit "200 rc" 0 $rc
assert_contains "body passthrough" "$out" '"login":"amit-t"'
assert_contains "headers captured" "$GHW_LAST_HEADERS" "admin:org"

# plain 403 — no retry, rc 3
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=403; RESP_BODY='{"message":"Must be an admin"}'; RESP_HEADERS='x-ratelimit-remaining: 42' }
EOF
: > "$GHW_STUB_LOG"
out=$(ghw_api PUT /orgs/o/memberships/u '{"role":"member"}'); rc=$?
assert_exit "plain 403 rc" 3 $rc
calls=$(wc -l < "$GHW_STUB_LOG")
assert_eq "plain 403 not retried" 1 "${calls// /}"

# 404 rc 4
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS='' }
EOF
out=$(ghw_api GET /users/ghost); rc=$?
assert_exit "404 rc" 4 $rc

# secondary rate limit: 403+retry-after once, then 200 (A8 core)
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  local n_file="${work}/n"; local n=0
  [[ -f "\$n_file" ]] && n=\$(<"\$n_file")
  (( n++ )); print -rn -- \$n > "\$n_file"
  if (( n == 1 )); then
    RESP_STATUS=403; RESP_BODY='{"message":"secondary rate limit"}'; RESP_HEADERS='retry-after: 7'
  else
    RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS=''
  fi
}
EOF
: > "$GHW_STUB_LOG"; : > "$sleep_log"; rm -f "${work}/n"
out=$(ghw_api PUT /orgs/o/memberships/u '{"role":"member"}'); rc=$?
assert_exit "rate-limited then success" 0 $rc
assert_contains "slept retry-after" "$(<$sleep_log)" "7"
calls=$(wc -l < "$GHW_STUB_LOG")
assert_eq "retried once" 2 "${calls// /}"

# pagination: 100-item page then 1-item page
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    *page=1*) RESP_STATUS=200; RESP_BODY=$(jq -nc '[range(100) | {login: ("u\(.)")}]'); RESP_HEADERS='' ;;
    *page=2*) RESP_STATUS=200; RESP_BODY='[{"login":"last"}]'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='[]'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(ghw_api_paged /orgs/o/members); rc=$?
assert_exit "paged rc" 0 $rc
assert_eq "paged length" 101 "$(print -r -- "$out" | jq 'length')"

rm -rf "$work"
report
```

- [ ] **Step 3: Run to verify it fails** — `zsh claude/github-warden/test/api.test.zsh` → FAIL (no lib/api.zsh)

- [ ] **Step 4: Write `lib/api.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw api — single curl wrapper for all GitHub API traffic.
# Serial by construction: one request per call, callers loop.
# Return codes: 0 = 2xx, 3 = plain 403 (permission), 4 = 404, 1 = exhausted retries.

: ${GHW_API_ROOT:=https://api.github.com}

_ghw_hdr() {  # $1 header-name (lowercase), $2 header-file — prints value or ""
  awk -v h="$1:" 'tolower($1)==h { v=$2; gsub("\r","",v); print v; exit }' "$2"
}

ghw_api() {  # $1 METHOD, $2 path, $3 optional JSON body
  local method="$1" path="$2" body="${3:-}"
  local url="${GHW_API_ROOT}${path}"
  local hdr_file body_file status
  local -i attempt=0 rl_attempt=0
  hdr_file=$(mktemp); body_file=$(mktemp)
  while true; do
    (( attempt++ ))
    local -a args
    args=(-sS -X "$method" -H "Authorization: Bearer ${GHW_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -D "$hdr_file" -o "$body_file" -w '%{http_code}')
    if [[ -n "$body" ]]; then
      args+=(-H "Content-Type: application/json" -d "$body")
    fi
    status=$(${=GHW_CURL:-curl} "${args[@]}" "$url" 2>/dev/null) || status=000
    typeset -g GHW_LAST_STATUS="$status"
    typeset -g GHW_LAST_HEADERS="$(<"$hdr_file")"
    case "$status" in
      2*)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 0 ;;
      403)
        local remaining retry_after reset now wait
        remaining=$(_ghw_hdr x-ratelimit-remaining "$hdr_file")
        retry_after=$(_ghw_hdr retry-after "$hdr_file")
        if [[ "$remaining" == 0 ]]; then            # primary limit: sleep to reset
          reset=$(_ghw_hdr x-ratelimit-reset "$hdr_file")
          now=$(date +%s); wait=$(( reset - now )); (( wait < 1 )) && wait=1
          ${=GHW_SLEEP:-sleep} "$wait"; continue
        elif [[ -n "$retry_after" ]]; then          # secondary limit: honor header
          ${=GHW_SLEEP:-sleep} "$retry_after"
          if (( ++rl_attempt < 5 )); then continue; fi
          cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1
        else                                        # real permission error
          cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 3
        fi ;;
      404)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 4 ;;
      5*|000)
        if (( attempt <= 3 )); then
          local backoff=$(( 2 ** (attempt - 1) )); (( backoff > 60 )) && backoff=60
          ${=GHW_SLEEP:-sleep} "$backoff"; continue
        fi
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1 ;;
      *)
        cat "$body_file"; rm -f "$hdr_file" "$body_file"; return 1 ;;
    esac
  done
}

ghw_api_paged() {  # $1 path — GETs all pages, prints one merged JSON array
  local path="$1" sep="?" out="[]" chunk len
  local -i page=1
  [[ "$path" == *\?* ]] && sep="&"
  while true; do
    chunk=$(ghw_api GET "${path}${sep}per_page=100&page=${page}") || return $?
    out=$(print -r -- "$out" | jq --argjson c "$chunk" '. + $c')
    len=$(print -r -- "$chunk" | jq 'length')
    (( len < 100 )) && break
    (( page++ ))
  done
  print -r -- "$out"
}
```

- [ ] **Step 5: Run tests, parse-check** — `zsh -n claude/github-warden/lib/api.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 6: Commit**

```bash
git add claude/github-warden/lib/api.zsh claude/github-warden/test/fixtures/curl-stub.zsh claude/github-warden/test/api.test.zsh
git commit -m "feat(ghw): API wrapper with rate-limit backoff + curl stub harness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Precondition gate P1–P5 (`lib/auth.zsh` part 2)

**Files:**
- Modify: `claude/github-warden/lib/auth.zsh` (append)
- Create: `claude/github-warden/test/precheck.test.zsh`

**Interfaces:**
- Consumes: `ghw_api` (Task 3), `ghw_profile_login` (Task 2).
- Produces: `ghw_precheck <profile> <org> [team-slug]` — return 0 all pass; on failure prints one named code line to stderr (`AUTH_INVALID` | `SCOPE_MISSING` | `NOT_ORG_ADMIN` | `ORG_NOT_FOUND` | `TEAM_NOT_FOUND`) plus remediation, returns 5. P6 (`SOURCE_INVALID`) lives in the import engine's parser (Task 5's `ghw_parse_source`). Scope rule: classic PAT → `x-oauth-scopes` must contain `admin:org`; header absent (fine-grained PAT) → P3's admin check is the authority.

- [ ] **Step 1: Write failing precheck tests** (pass case; A5 scope-missing case asserting **zero writes**; wrong-login; non-admin; missing org/team)

`claude/github-warden/test/precheck.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/api.zsh"
source "${daemon_dir}/lib/auth.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_TOKEN="testtoken" GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
fixture="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$fixture"
export GHW_ACCOUNTS_FILE="$fixture"

all_good_routes() {
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' ;;
    */orgs/INVENCO-GROUP/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin","state":"active"}'; RESP_HEADERS='' ;;
    */orgs/INVENCO-GROUP/teams/ai-workbench-ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ai-workbench-ppna"}'; RESP_HEADERS='' ;;
    */orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
}

all_good_routes
out=$(ghw_precheck inv INVENCO-GROUP ai-workbench-ppna 2>&1); rc=$?
assert_exit "all preconditions pass" 0 $rc

# A5: classic PAT without admin:org — refuse, zero writes
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: repo, read:org' ;;
    *) RESP_STATUS=200; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "scope missing refuses" 5 $rc
assert_contains "scope failure named" "$out" "SCOPE_MISSING"
assert_not_contains "zero writes on refusal" "$(<$GHW_STUB_LOG)" "PUT "

# wrong login
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{"login":"someone-else"}'; RESP_HEADERS='x-oauth-scopes: admin:org' }
EOF
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "login mismatch refuses" 5 $rc
assert_contains "auth failure named" "$out" "AUTH_INVALID"

# not org admin (fine-grained: no scopes header → P3 is authority)
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='' ;;
    */memberships/*) RESP_STATUS=200; RESP_BODY='{"role":"member","state":"active"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "non-admin refuses" 5 $rc
assert_contains "admin failure named" "$out" "NOT_ORG_ADMIN"

# missing team
all_good_routes
cat >> "$GHW_STUB_ROUTES" <<'EOF'
old_stub_route=$functions[stub_route]
stub_route() {
  if [[ "$2" == */teams/ghost-team ]]; then RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS=''
  else eval "$old_stub_route"; fi
}
EOF
out=$(ghw_precheck inv INVENCO-GROUP ghost-team 2>&1); rc=$?
assert_exit "missing team refuses" 5 $rc
assert_contains "team failure named" "$out" "TEAM_NOT_FOUND"

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — `zsh claude/github-warden/test/precheck.test.zsh` → FAIL (`ghw_precheck` undefined)

- [ ] **Step 3: Append precheck to `lib/auth.zsh`**

```zsh
# ---- precondition gate (import spec §3) ------------------------------------
# All-or-nothing, runs before any write. Named failures, return 5.

ghw_precheck() {  # $1 profile, $2 org, $3 optional team slug
  local profile="$1" org="$2" team="${3:-}"
  local me expected scopes body rc

  # P1 token authenticates + login matches profile
  body=$(ghw_api GET /user); rc=$?
  if (( rc != 0 )); then
    print -ru2 -- "AUTH_INVALID: GET /user failed (HTTP ${GHW_LAST_STATUS}). Check \$${GHW_TOKEN_ENV_NAME:-GHW_TOKEN}."
    return 5
  fi
  me=$(print -r -- "$body" | jq -r .login)
  expected=$(ghw_profile_login "$profile")
  if [[ "$me" != "$expected" ]]; then
    print -ru2 -- "AUTH_INVALID: token authenticates as '${me}', profile '${profile}' expects '${expected}'."
    return 5
  fi

  # P2 scopes — classic PAT lists them in x-oauth-scopes; fine-grained PATs
  # send no header, in which case P3 (org admin) is the real authority.
  scopes=$(print -r -- "$GHW_LAST_HEADERS" | awk 'tolower($1)=="x-oauth-scopes:" { $1=""; gsub("\r",""); print; exit }')
  if [[ -n "${scopes// /}" && ",${scopes// /}," != *,admin:org,* ]]; then
    print -ru2 -- "SCOPE_MISSING: token scopes (${scopes## }) lack admin:org. Re-issue the PAT with admin:org (or a fine-grained PAT with Organization Members: read & write). ghw never self-elevates."
    return 5
  fi

  # P4 org exists
  ghw_api GET "/orgs/${org}" >/dev/null; rc=$?
  if (( rc != 0 )); then
    print -ru2 -- "ORG_NOT_FOUND: /orgs/${org} → HTTP ${GHW_LAST_STATUS}."
    return 5
  fi

  # P3 caller is org admin
  body=$(ghw_api GET "/orgs/${org}/memberships/${me}"); rc=$?
  if (( rc != 0 )) || [[ "$(print -r -- "$body" | jq -r .role)" != "admin" ]]; then
    print -ru2 -- "NOT_ORG_ADMIN: ${me} role in ${org} is '$(print -r -- "$body" | jq -r .role 2>/dev/null)' (need admin)."
    return 5
  fi

  # P5 team exists (when targeted)
  if [[ -n "$team" ]]; then
    ghw_api GET "/orgs/${org}/teams/${team}" >/dev/null; rc=$?
    if (( rc != 0 )); then
      print -ru2 -- "TEAM_NOT_FOUND: /orgs/${org}/teams/${team} → HTTP ${GHW_LAST_STATUS}."
      return 5
    fi
  fi
  return 0
}
```

- [ ] **Step 4: Run tests, parse-check** — `zsh -n claude/github-warden/lib/auth.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 5: Commit**

```bash
git add claude/github-warden/lib/auth.zsh claude/github-warden/test/precheck.test.zsh
git commit -m "feat(ghw): precondition gate P1-P5 with named failures

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Report module + source parser (`lib/report.zsh`)

**Files:**
- Create: `claude/github-warden/lib/report.zsh`
- Create: `claude/github-warden/test/report.test.zsh`

**Interfaces:**
- Produces: `ghw_report_init <job-id>` (creates `${GHW_STATE_DIR}/reports/<job-id>/`, sets `GHW_REPORT_DIR`, writes CSV header `login,phase,status,state,role,detail`); `ghw_report_row <login> <phase> <status> <state> <role> <detail>` (appends CSV-escaped row); `ghw_report_finish <summary-text>` (writes `summary.txt`, derives `report.json` from the CSV, prints report dir path). `ghw_parse_source <csv-path> <column>` — prints deduped logins one per line (order preserved, duplicates deduped with a stderr warning), return 6 + `SOURCE_INVALID` on missing file/column/empty (P6).
- Consumes: nothing API-side (pure zsh/jq/awk).

- [ ] **Step 1: Write failing tests** (init+row+finish round-trip incl. comma-in-detail escaping; parser happy path; parser dedupes with warning; missing column → `SOURCE_INVALID` rc 6; empty csv → rc 6)

`claude/github-warden/test/report.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/report.zsh"

work=$(mktemp -d)
export GHW_STATE_DIR="$work"

ghw_report_init "20260728-test-job"
assert_eq "report dir" "${work}/reports/20260728-test-job" "$GHW_REPORT_DIR"
ghw_report_row "alice_vnt" org added active member ""
ghw_report_row "bob_vnt" org not_found "" "" "account does not exist, stale row"
out=$(ghw_report_finish "org: 2 -> 3 (+1)")
assert_contains "finish prints dir" "$out" "$GHW_REPORT_DIR"
csv=$(<"${GHW_REPORT_DIR}/report.csv")
assert_contains "csv header" "$csv" "login,phase,status,state,role,detail"
assert_contains "csv row" "$csv" "alice_vnt,org,added,active,member,"
assert_contains "csv quoted detail" "$csv" '"account does not exist, stale row"'
assert_eq "json rows" 2 "$(jq 'length' "${GHW_REPORT_DIR}/report.json")"
assert_eq "json field" "not_found" "$(jq -r '.[1].status' "${GHW_REPORT_DIR}/report.json")"
assert_contains "summary persisted" "$(<${GHW_REPORT_DIR}/summary.txt)" "+1"

csvfile="${work}/src.csv"
print -rl -- "name,login,email" "A,alice_vnt,a@x" "B,bob_vnt,b@x" "A2,alice_vnt,a@x" > "$csvfile"
out=$(ghw_parse_source "$csvfile" login 2>"${work}/err")
assert_eq "parsed logins" $'alice_vnt\nbob_vnt' "$out"
assert_contains "dup warned" "$(<${work}/err)" "duplicate"

out=$(ghw_parse_source "$csvfile" nope 2>&1); rc=$?
assert_exit "missing column rc" 6 $rc
assert_contains "missing column named" "$out" "SOURCE_INVALID"

print -r -- "login" > "$csvfile"
out=$(ghw_parse_source "$csvfile" login 2>&1); rc=$?
assert_exit "empty source rc" 6 $rc

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — `zsh claude/github-warden/test/report.test.zsh` → FAIL

- [ ] **Step 3: Write `lib/report.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw report — per-login CSV/JSON reports (import spec §8) + source parsing (P6).
# Reports persist under ${GHW_STATE_DIR}/reports/<job_id>/ and are never deleted.

ghw_report_init() {  # $1 job id
  typeset -g GHW_REPORT_DIR="${GHW_STATE_DIR}/reports/$1"
  mkdir -p "$GHW_REPORT_DIR"
  print -r -- "login,phase,status,state,role,detail" > "${GHW_REPORT_DIR}/report.csv"
}

_ghw_csv_field() {  # quote a field iff it contains comma/quote
  local f="$1"
  if [[ "$f" == *[,\"]* ]]; then
    print -rn -- "\"${f//\"/\"\"}\""
  else
    print -rn -- "$f"
  fi
}

ghw_report_row() {  # login phase status state role detail
  local -a fields=("$1" "$2" "$3" "$4" "$5" "$6")
  local out="" f
  for f in "${fields[@]}"; do
    out+="$(_ghw_csv_field "$f"),"
  done
  print -r -- "${out%,}" >> "${GHW_REPORT_DIR}/report.csv"
}

ghw_report_finish() {  # $1 summary text — writes summary + JSON, prints dir
  print -r -- "$1" > "${GHW_REPORT_DIR}/summary.txt"
  jq -R -s '
    split("\n") | map(select(length > 0)) | .[1:] |
    map(
      # naive-safe CSV split: report fields never contain embedded newlines
      [scan("(?:^|,)(\"(?:[^\"]|\"\")*\"|[^,]*)")] | flatten |
      map(if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end) |
      {login: .[0], phase: .[1], status: .[2], state: .[3], role: .[4], detail: .[5]}
    )' "${GHW_REPORT_DIR}/report.csv" > "${GHW_REPORT_DIR}/report.json"
  print -r -- "$GHW_REPORT_DIR"
}

ghw_parse_source() {  # $1 csv path, $2 column name — prints deduped logins
  local csv="$1" column="$2"
  if [[ ! -f "$csv" ]]; then
    print -ru2 -- "SOURCE_INVALID: file not found: $csv"
    return 6
  fi
  local raw
  raw=$(awk -F',' -v col="$column" '
    NR==1 { for (i=1;i<=NF;i++) { h=$i; gsub(/^[" \r]+|[" \r]+$/,"",h); if (h==col) c=i }
            if (!c) exit 2; next }
    { v=$c; gsub(/^[" \r]+|[" \r]+$/,"",v); if (v!="") print v }
  ' "$csv")
  if (( $? == 2 )); then
    print -ru2 -- "SOURCE_INVALID: column '${column}' not found in ${csv}"
    return 6
  fi
  local -a logins out
  local u
  typeset -A seen
  logins=("${(@f)raw}")
  out=()
  for u in "${logins[@]}"; do
    [[ -z "$u" ]] && continue
    if [[ -n "${seen[$u]:-}" ]]; then
      print -ru2 -- "ghw: duplicate login in source deduped: ${u}"
      continue
    fi
    seen[$u]=1
    out+=("$u")
  done
  if (( ${#out} == 0 )); then
    print -ru2 -- "SOURCE_INVALID: no logins parsed from ${csv} column '${column}'"
    return 6
  fi
  print -rl -- "${out[@]}"
}
```

- [ ] **Step 4: Run tests, parse-check** — `zsh -n claude/github-warden/lib/report.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 5: Commit**

```bash
git add claude/github-warden/lib/report.zsh claude/github-warden/test/report.test.zsh
git commit -m "feat(ghw): report module + source parser with P6 validation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Import engine (`lib/import-engine.zsh`) — acceptance tests A1–A4, A6, A7

**Files:**
- Create: `claude/github-warden/lib/import-engine.zsh` (executable standalone script)
- Create: `claude/github-warden/test/import-engine.test.zsh`

**Interfaces:**
- Consumes: `ghw_resolve_profile`, `ghw_token_for`, `ghw_precheck` (auth.zsh); `ghw_api`, `ghw_api_paged` (api.zsh); `ghw_report_init/row/finish`, `ghw_parse_source` (report.zsh).
- Produces: runnable script — `zsh lib/import-engine.zsh --org <org> [--team <slug>] --csv <file> [--column login] [--role member|maintainer] [--org-role member|admin] [--account <profile>] [--dry-run]`. Exit 0 = clean, 1 = `completed_with_errors` (any `not_found`/`failed` row), 2 = bad flags, 5 = precondition refusal, 6 = source invalid. Prints per-phase progress lines + final `report: <dir>` + `org: A -> B (+N)` / `team: A -> B (+N)` summary. Job id format: `$(date +%Y%m%dT%H%M%S)-<org>[-<team>]`.

- [ ] **Step 1: Write failing engine tests**

`claude/github-warden/test/import-engine.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
engine="${daemon_dir}/lib/import-engine.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_STATE_DIR="${work}/state"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export T_I="tok"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$GHW_ACCOUNTS_FILE"

csv="${work}/src.csv"

# Routes: org has owner1+existing1; team has maint1. PUTs echo membership JSON.
# ghost_vnt 404s on org PUT. Org/team member lists re-read includes adds
# (stub keeps it simple: after any PUT for login X, member lists include X via state file).
base_routes() {
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  local added="${work}/added"
  case "\$1 \$2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/orgs/INVENCO-GROUP/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna/members*)
      local extra=""
      [[ -f "\$added" ]] && extra=\$(awk '/^team /{printf ",{\"login\":\"%s\"}", \$2}' "\$added")
      RESP_STATUS=200; RESP_BODY="[{\"login\":\"maint1_vnt\"}\${extra}]"; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*)
      local extra=""
      [[ -f "\$added" ]] && extra=\$(awk '/^org /{printf ",{\"login\":\"%s\"}", \$2}' "\$added")
      RESP_STATUS=200; RESP_BODY="[{\"login\":\"owner1_vnt\"},{\"login\":\"existing1_vnt\"}\${extra}]"; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/memberships/ghost_vnt) RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/memberships/*)
      print -r -- "org \${2##*/}" >> "\$added"
      RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/teams/ppna/memberships/*)
      print -r -- "team \${2##*/}" >> "\$added"
      RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
}

# A6 dry-run: zero writes, would_add rows
base_routes; : > "$GHW_STUB_LOG"; rm -f "${work}/added"
print -rl -- "login" "newuser_vnt" "owner1_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" --dry-run 2>&1); rc=$?
assert_exit "A6 dry-run exit" 0 $rc
assert_not_contains "A6 zero writes" "$(<$GHW_STUB_LOG)" "PUT "
rdir=$(print -r -- "$out" | awk '/^report: /{print $2}')
assert_contains "A6 would_add row" "$(<${rdir}/report.csv)" "newuser_vnt,org,would_add"

# A2+A3+A7+A4: live run — owner/maintainer untouched, phases ordered, 404 continues
base_routes; : > "$GHW_STUB_LOG"; rm -f "${work}/added"
print -rl -- "login" "newuser_vnt" "owner1_vnt" "maint1_vnt" "ghost_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "live run completed_with_errors (ghost)" 1 $rc
log=$(<$GHW_STUB_LOG)
assert_not_contains "A2 no org PUT for owner" "$log" "memberships/owner1_vnt"
assert_not_contains "A3 no team PUT for maintainer" "$log" "teams/ppna/memberships/maint1_vnt"
assert_contains "new user org PUT" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/memberships/newuser_vnt"
assert_contains "new user team PUT" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/teams/ppna/memberships/newuser_vnt"
org_line=$(grep -n "PUT .*memberships/newuser_vnt" <<< "$log" | grep -v teams | cut -d: -f1 | head -1)
team_line=$(grep -n "PUT .*teams/ppna/memberships/newuser_vnt" <<< "$log" | cut -d: -f1 | head -1)
if (( org_line < team_line )); then _ok; else _fail "A7: org PUT must precede team PUT"; fi
rdir=$(print -r -- "$out" | awk '/^report: /{print $2}')
rcsv=$(<${rdir}/report.csv)
assert_contains "A4 ghost not_found" "$rcsv" "ghost_vnt,org,not_found"
assert_contains "A4 batch continued" "$rcsv" "newuser_vnt,org,added"
assert_contains "owner skipped row" "$rcsv" "owner1_vnt,org,skipped"
assert_contains "summary counts" "$out" "org: 2 -> 3 (+1)"

# A1 idempotent re-run: everyone already present → zero PUTs, all skipped, exit 0
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$1 $2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/teams/ppna/members*) RESP_STATUS=200; RESP_BODY='[{"login":"newuser_vnt"},{"login":"maint1_vnt"}]'; RESP_HEADERS='' ;;
    "GET "*/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*) RESP_STATUS=200; RESP_BODY='[{"login":"newuser_vnt"},{"login":"maint1_vnt"}]'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
print -rl -- "login" "newuser_vnt" "maint1_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "A1 re-run exit 0" 0 $rc
assert_not_contains "A1 zero writes" "$(<$GHW_STUB_LOG)" "PUT "

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — `zsh claude/github-warden/test/import-engine.test.zsh` → FAIL

- [ ] **Step 3: Write `lib/import-engine.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw import engine — deterministic org/team membership reconciliation.
# Implements SPEC-org-import-daemon §3–§8. THE ONLY CODE PATH THAT WRITES
# MEMBERSHIPS. Read-then-diff-then-write; never PUTs an existing member (§4.2);
# org phase completes before team phase (§4.1); verifies against live state.
set -u
script_path=${0:A}
daemon_dir=${script_path:h:h}

source "${daemon_dir}/lib/api.zsh"
source "${daemon_dir}/lib/auth.zsh"
source "${daemon_dir}/lib/report.zsh"

usage() {
  print -ru2 -- "usage: import-engine.zsh --org <org> [--team <slug>] --csv <file> [--column login] [--role member|maintainer] [--org-role member|admin] [--account <profile>] [--dry-run]"
  exit 2
}

org="" team="" csv="" column="login" role="member" org_role="member" account="" dry_run=0
while (( $# )); do
  case "$1" in
    --org) org="${2:?}"; shift 2 ;;
    --team) team="${2:?}"; shift 2 ;;
    --csv) csv="${2:?}"; shift 2 ;;
    --column) column="${2:?}"; shift 2 ;;
    --role) role="${2:?}"; shift 2 ;;
    --org-role) org_role="${2:?}"; shift 2 ;;
    --account) account="${2:?}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done
[[ -z "$org" || -z "$csv" ]] && usage
[[ "$role" != (member|maintainer) ]] && usage
[[ "$org_role" != (member|admin) ]] && usage

: ${GHW_STATE_DIR:=${HOME}/.local/state/github-warden}

profile=$(ghw_resolve_profile "$account" "$org") || exit 2
ghw_token_for "$profile" || exit 2

# P6 first (cheap, local), then API preconditions P1–P5.
logins_raw=$(ghw_parse_source "$csv" "$column") || exit 6
local -a logins; logins=("${(@f)logins_raw}")
ghw_precheck "$profile" "$org" "$team" || exit 5

job_id="$(date +%Y%m%dT%H%M%S)-${org}${team:+-${team}}"
ghw_report_init "$job_id"

fetch_org_members() { ghw_api_paged "/orgs/${org}/members" | jq -r '.[].login' }
fetch_team_members() { ghw_api_paged "/orgs/${org}/teams/${team}/members" | jq -r '.[].login' }

typeset -A in_org in_team
local u
for u in ${(f)"$(fetch_org_members)"}; do in_org[$u]=1; done
org_before=${#in_org}
team_before=0
if [[ -n "$team" ]]; then
  for u in ${(f)"$(fetch_team_members)"}; do in_team[$u]=1; done
  team_before=${#in_team}
fi

# §4 steps 4–5: set difference IS the safety mechanism (§4.2).
local -a add_org add_team
add_org=(); add_team=()
for u in "${logins[@]}"; do
  if [[ -n "${in_org[$u]:-}" ]]; then
    ghw_report_row "$u" org skipped active "" "already a member"
  else
    add_org+=("$u")
  fi
done
if [[ -n "$team" ]]; then
  for u in "${logins[@]}"; do
    if [[ -n "${in_team[$u]:-}" ]]; then
      ghw_report_row "$u" team skipped active "" "already a member"
    else
      add_team+=("$u")
    fi
  done
fi

if (( dry_run )); then
  for u in "${add_org[@]}"; do ghw_report_row "$u" org would_add "" "$org_role" ""; done
  for u in "${add_team[@]}"; do ghw_report_row "$u" team would_add "" "$role" ""; done
  rdir=$(ghw_report_finish "dry_run: org +${#add_org}, team +${#add_team}, zero writes")
  print -r -- "dry-run: would add ${#add_org} to org, ${#add_team} to team ${team:-'(none)'}"
  print -r -- "report: $rdir"
  exit 0
fi

typeset -A org_failed   # logins that failed/404'd in phase 1 — excluded from phase 2
errors=0

# Phase 1: org membership (fully completes before team phase — §4.1). Serial.
for u in "${add_org[@]}"; do
  body=$(ghw_api PUT "/orgs/${org}/memberships/${u}" "{\"role\":\"${org_role}\"}"); rc=$?
  case $rc in
    0)
      state=$(print -r -- "$body" | jq -r '.state // ""')
      got_role=$(print -r -- "$body" | jq -r '.role // ""')
      ghw_report_row "$u" org added "$state" "$got_role" ""
      print -r -- "org + ${u} (${state})"
      ;;
    4)
      ghw_report_row "$u" org not_found "" "" "account does not exist on github.com"
      org_failed[$u]=1; (( errors++ )) || true
      ;;
    *)
      ghw_report_row "$u" org failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
      org_failed[$u]=1; (( errors++ )) || true
      ;;
  esac
done

# Phase 2: team membership.
if [[ -n "$team" ]]; then
  for u in "${add_team[@]}"; do
    [[ -n "${org_failed[$u]:-}" ]] && continue
    body=$(ghw_api PUT "/orgs/${org}/teams/${team}/memberships/${u}" "{\"role\":\"${role}\"}"); rc=$?
    case $rc in
      0)
        state=$(print -r -- "$body" | jq -r '.state // ""')
        got_role=$(print -r -- "$body" | jq -r '.role // ""')
        note=""
        [[ "$got_role" == maintainer && "$role" == member ]] && note="org owner auto-elevated"
        ghw_report_row "$u" team added "$state" "$got_role" "$note"
        print -r -- "team + ${u} (${state})"
        ;;
      4)
        ghw_report_row "$u" team not_found "" "" "account does not exist on github.com"
        (( errors++ )) || true
        ;;
      *)
        ghw_report_row "$u" team failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
        (( errors++ )) || true
        ;;
    esac
  done
fi

# §4 step 8: verify against LIVE state, membership not role equality (§7).
typeset -A org_after_map team_after_map
for u in ${(f)"$(fetch_org_members)"}; do org_after_map[$u]=1; done
org_after=${#org_after_map}
team_after=0
if [[ -n "$team" ]]; then
  for u in ${(f)"$(fetch_team_members)"}; do team_after_map[$u]=1; done
  team_after=${#team_after_map}
fi
for u in "${logins[@]}"; do
  [[ -n "${org_failed[$u]:-}" ]] && continue
  if [[ -z "${org_after_map[$u]:-}" ]]; then
    ghw_report_row "$u" verify failed "" "" "not in live org member list after import"
    (( errors++ )) || true
  fi
  if [[ -n "$team" && -z "${team_after_map[$u]:-}" ]]; then
    ghw_report_row "$u" verify failed "" "" "not in live team member list after import"
    (( errors++ )) || true
  fi
done

summary="org: ${org_before} -> ${org_after} (+$(( org_after - org_before )))"
[[ -n "$team" ]] && summary+=$'\n'"team: ${team_before} -> ${team_after} (+$(( team_after - team_before )))"
rdir=$(ghw_report_finish "$summary")
print -r -- "$summary"
print -r -- "report: $rdir"
(( errors > 0 )) && exit 1
exit 0
```

- [ ] **Step 4: Run tests, parse-check** — `zsh -n claude/github-warden/lib/import-engine.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 5: Commit**

```bash
git add claude/github-warden/lib/import-engine.zsh claude/github-warden/test/import-engine.test.zsh
git commit -m "feat(ghw): deterministic import engine — A1-A4, A6, A7 acceptance tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Playbooks + `import`/`mirror` command wiring in `bin/ghw`

**Files:**
- Create: `claude/github-warden/playbooks/_common.md`
- Create: `claude/github-warden/playbooks/import.md`
- Create: `claude/github-warden/playbooks/mirror.md`
- Modify: `claude/github-warden/bin/ghw` (add `import`/`mirror` case arms + `ghw_build_prompt` + `ghw_launch`)
- Create: `claude/github-warden/test/launch.test.zsh`

**Interfaces:**
- Consumes: `ghw_resolve_profile`, `ghw_token_for` (auth.zsh); `lib/import-engine.zsh` (Task 6); `~/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh` (existing, external).
- Produces: `ghw import ... [--script]` — default assembles `_common.md + import.md + run context` prompt, exports `GH_TOKEN`/`GITHUB_TOKEN`, execs `${GHW_LAUNCHER:-clscb} "$prompt"`; `--script` execs the engine directly. `ghw mirror [target] [flags...] [--script]` — same launch shape with `mirror.md`; `--script` execs `mirror-repo.zsh` with remaining flags passed through. `GHW_DRY_LAUNCH=1` prints the assembled prompt instead of launching (tests + inspection).

- [ ] **Step 1: Write `playbooks/_common.md`**

```markdown
# github-warden common policy

You are a github-warden (`ghw`) agent session operating on Amit's GitHub accounts.

Non-negotiable rules:
1. The credential for this run is already exported as `GH_TOKEN`/`GITHUB_TOKEN`. Never print, echo, or log it, and never write it into any file or report.
2. Membership writes happen ONLY through `lib/import-engine.zsh`. Never issue a raw org/team membership `PUT` yourself — both endpoints are upserts that silently demote existing Owners/maintainers.
3. Add-only: never remove members, never change an existing member's role, never create teams or orgs.
4. Admin access is verified by the engine's precondition gate before any write. If it refuses (named codes AUTH_INVALID, SCOPE_MISSING, NOT_ORG_ADMIN, ORG_NOT_FOUND, TEAM_NOT_FOUND, SOURCE_INVALID), report the code and its remediation to Amit and stop — never work around it.
5. Reports persist under the state dir; quote the report path in your summary. Never delete reports.
6. Use zsh for any shell work. Ask Amit only when genuinely blocked.
```

- [ ] **Step 2: Write `playbooks/import.md`**

```markdown
# ghw import playbook

Objective: reconcile the source logins into the target org (and team, if given), then explain the outcome.

Steps:
1. Run the deterministic engine exactly as provided in Run context (`engine command` line). Do not re-implement any part of it.
2. If it exits 5 (precondition) or 6 (source), relay the named failure + remediation and stop.
3. On completion read `report.csv` in the printed report dir. Summarize: added / skipped / not_found / failed counts per phase, the before→after org and team counts, and every `not_found` or `failed` row verbatim — those need Amit's action (fix source data or investigate).
4. `note` rows like "org owner auto-elevated" are GitHub semantics, not errors — mention, don't alarm.
5. If any row failed verification (`phase: verify`), flag it as the top item: live state diverged from expected.
```

- [ ] **Step 3: Write `playbooks/mirror.md`**

```markdown
# ghw mirror playbook

Objective: scaffold a new GitHub repo mirroring a reference repo's settings, protection, security flags, access, and (optionally) Pages docs.

Steps:
1. Read the gh-repo-mirror skill at `~/.claude/skills/gh-repo-mirror/SKILL.md` and follow its workflow. The helper script is `~/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh`.
2. Run context gives you the reference target (repo arg or "origin of the launch directory") and any pass-through flags. Interview Amit only for required values the flags don't cover (new repo name, description, Pages choices).
3. Auth: `GH_TOKEN` is already exported for the right account profile — verify `gh api user --jq .login` matches the expected login from Run context before creating anything.
4. Prefer `--dry-run` first when the flag set is ambiguous; show Amit the plan, then run for real.
5. Report: new repo URL, which settings/protection/access mirrored, any warnings (unresolvable teams, dropped flags), and Pages/DNS follow-ups.
```

- [ ] **Step 4: Write failing launch test**

`claude/github-warden/test/launch.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$GHW_ACCOUNTS_FILE"
export T_I="tok" GHW_DRY_LAUNCH=1

csv="${work}/s.csv"; print -rl -- "login" "a_vnt" > "$csv"
out=$(zsh "$ghw_bin" import --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "import dry launch ok" 0 $rc
assert_contains "common policy included" "$out" "github-warden common policy"
assert_contains "import playbook included" "$out" "ghw import playbook"
assert_contains "engine command in context" "$out" "import-engine.zsh --org INVENCO-GROUP --team ppna"
assert_not_contains "token never in prompt" "$out" "tok"

out=$(zsh "$ghw_bin" mirror INVENCO-GROUP/some-repo 2>&1); rc=$?
assert_exit "mirror dry launch ok" 0 $rc
assert_contains "mirror playbook included" "$out" "ghw mirror playbook"
assert_contains "target in context" "$out" "INVENCO-GROUP/some-repo"

out=$(zsh "$ghw_bin" import --org INVENCO-GROUP 2>&1); rc=$?
assert_exit "import without csv exits 2" 2 $rc

rm -rf "$work"
report
```

- [ ] **Step 5: Run to verify it fails** — `zsh claude/github-warden/test/launch.test.zsh` → FAIL (unknown command)

- [ ] **Step 6: Wire `bin/ghw`** — add above `main`:

```zsh
ghw_build_prompt() {  # $1 playbook name, rest = run-context lines
  local playbook="$1"; shift
  cat "${daemon_dir}/playbooks/_common.md" "${daemon_dir}/playbooks/${playbook}.md"
  print -r -- ""
  print -r -- "## Run context"
  print -r -- "- today: $(date +%F)"
  print -r -- "- daemon dir: ${daemon_dir}"
  print -r -- "- state dir: ${GHW_STATE_DIR}"
  local line
  for line in "$@"; do print -r -- "- ${line}"; done
}

ghw_launch() {  # $1 prompt — exports token for gh CLI, hands off to launcher
  local prompt="$1"
  typeset -gx GH_TOKEN="$GHW_TOKEN" GITHUB_TOKEN="$GHW_TOKEN"
  if [[ -n "${GHW_DRY_LAUNCH:-}" ]]; then
    print -r -- "$prompt"
    return 0
  fi
  exec ${=GHW_LAUNCHER:-clscb} "$prompt"
}
```

and add case arms in `main` (before the `*)` arm), with `source "${daemon_dir}/lib/auth.zsh"` added once near the top of `main`:

```zsh
    import)
      local org="" team="" script_mode=0
      local -a engine_args
      engine_args=()
      while (( $# )); do
        case "$1" in
          --script) script_mode=1; shift ;;
          --org) org="${2:-}"; engine_args+=(--org "${2:-}"); shift 2 ;;
          --team) team="${2:-}"; engine_args+=(--team "${2:-}"); shift 2 ;;
          --csv|--column|--role|--org-role) engine_args+=("$1" "${2:-}"); shift 2 ;;
          --dry-run) engine_args+=(--dry-run); shift ;;
          *) print -ru2 -- "ghw import: unknown flag: $1"; exit 2 ;;
        esac
      done
      if [[ -z "$org" || " ${engine_args[*]} " != *" --csv "* ]]; then
        print -ru2 -- "ghw import: --org and --csv are required"
        exit 2
      fi
      local profile
      profile=$(ghw_resolve_profile "$account" "$org") || exit 2
      ghw_token_for "$profile" || exit 2
      engine_args+=(--account "$profile")
      if (( script_mode )); then
        exec zsh "${daemon_dir}/lib/import-engine.zsh" "${engine_args[@]}"
      fi
      local prompt
      prompt=$(ghw_build_prompt import \
        "account profile: ${profile} (expected login: $(ghw_profile_login "$profile"))" \
        "engine command: zsh ${daemon_dir}/lib/import-engine.zsh ${engine_args[*]}" \
        "token: exported as GH_TOKEN/GITHUB_TOKEN in this shell. Never print it.")
      ghw_launch "$prompt"
      ;;
    mirror)
      local target="" script_mode=0
      local -a passthru
      passthru=()
      while (( $# )); do
        case "$1" in
          --script) script_mode=1; shift ;;
          --*) passthru+=("$1" "${2:-}"); shift 2 ;;
          *) target="$1"; shift ;;
        esac
      done
      local owner=""
      if [[ -n "$target" ]]; then
        owner="${${target#https://github.com/}%%/*}"
      elif git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        target=$(git -C "$PWD" remote get-url origin 2>/dev/null)
        owner="${${${target#https://github.com/}#git@github.com:}%%/*}"
      fi
      if [[ -z "$target" ]]; then
        print -ru2 -- "ghw mirror: pass a repo/URL or run inside a git repo with an origin remote"
        exit 2
      fi
      local profile
      profile=$(ghw_resolve_profile "$account" "$owner") || exit 2
      ghw_token_for "$profile" || exit 2
      if (( script_mode )); then
        exec zsh "${HOME}/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh" --ref-repo "$target" "${passthru[@]}"
      fi
      local prompt
      prompt=$(ghw_build_prompt mirror \
        "account profile: ${profile} (expected login: $(ghw_profile_login "$profile"))" \
        "reference target: ${target}" \
        "pass-through flags: ${passthru[*]:-'(none — interview Amit)'}" \
        "token: exported as GH_TOKEN/GITHUB_TOKEN in this shell. Never print it.")
      ghw_launch "$prompt"
      ;;
```

- [ ] **Step 7: Run tests, parse-check** — `zsh -n claude/github-warden/bin/ghw && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 8: Commit**

```bash
git add claude/github-warden/playbooks claude/github-warden/bin/ghw claude/github-warden/test/launch.test.zsh
git commit -m "feat(ghw): mirror/import agent launch with playbooks and --script paths

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `ghw doctor` (`lib/doctor.zsh`)

**Files:**
- Create: `claude/github-warden/lib/doctor.zsh`
- Modify: `claude/github-warden/bin/ghw` (add `doctor` case arm)
- Create: `claude/github-warden/test/doctor.test.zsh`

**Interfaces:**
- Consumes: `ghw_api` , accounts file helpers.
- Produces: `ghw_doctor` — iterates every profile in accounts.json; per profile prints `profile <name>: token=<ok|MISSING> login=<got|MISMATCH(got)> scopes=<list|fine-grained>`, then per org `  org <name>: role=<admin|member|none|error>`. Exit 0 if every profile has token+login ok and admin on all its orgs; exit 1 otherwise. Read-only — GETs only.

- [ ] **Step 1: Write failing test** — two profiles in fixture; one healthy (admin everywhere), one with missing token env. Assert healthy lines, `token=MISSING`, exit 1. Routes: `/user` returns the right login with `x-oauth-scopes: admin:org`; `/orgs/<org>/memberships/<login>` returns `admin`.

`claude/github-warden/test/doctor.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["amit-t"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}
JSON
export T_P="tokp"; unset T_I 2>/dev/null
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' ;;
    */orgs/amit-t/memberships/amit-t) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=404; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "doctor exit 1 when a profile is broken" 1 $rc
assert_contains "healthy token" "$out" "profile personal: token=ok"
assert_contains "healthy role" "$out" "org amit-t: role=admin"
assert_contains "missing token flagged" "$out" "profile inv: token=MISSING"
assert_not_contains "no writes" "$(<$GHW_STUB_LOG)" "PUT "

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — unknown command `doctor` → exit 2, asserts FAIL

- [ ] **Step 3: Write `lib/doctor.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw doctor — per-profile credential/role health. Read-only.

ghw_doctor() {
  local file profile env_name expected me scopes org role body rc
  local -i broken=0
  file=$(ghw_accounts_file)
  for profile in ${(f)"$(jq -r '.profiles | keys[]' "$file")"}; do
    env_name=$(ghw_profile_field "$profile" token_env)
    if [[ -z "${(P)env_name:-}" ]]; then
      print -r -- "profile ${profile}: token=MISSING (export ${env_name})"
      (( broken++ )); continue
    fi
    typeset -gx GHW_TOKEN="${(P)env_name}"
    expected=$(ghw_profile_login "$profile")
    body=$(ghw_api GET /user); rc=$?
    if (( rc != 0 )); then
      print -r -- "profile ${profile}: token=INVALID (HTTP ${GHW_LAST_STATUS})"
      (( broken++ )); continue
    fi
    me=$(print -r -- "$body" | jq -r .login)
    scopes=$(print -r -- "$GHW_LAST_HEADERS" | awk 'tolower($1)=="x-oauth-scopes:" { $1=""; gsub("\r",""); sub(/^ /,""); print; exit }')
    local login_disp="ok"
    if [[ "$me" != "$expected" ]]; then login_disp="MISMATCH(${me})"; (( broken++ )); fi
    print -r -- "profile ${profile}: token=ok login=${login_disp} scopes=${scopes:-fine-grained}"
    for org in ${(f)"$(jq -r --arg p "$profile" '.profiles[$p].orgs[]' "$file")"}; do
      body=$(ghw_api GET "/orgs/${org}/memberships/${me}"); rc=$?
      if (( rc == 0 )); then
        role=$(print -r -- "$body" | jq -r .role)
      elif (( rc == 4 )); then
        role="none"
      else
        role="error(HTTP ${GHW_LAST_STATUS})"
      fi
      print -r -- "  org ${org}: role=${role}"
      [[ "$role" != admin ]] && (( broken++ ))
    done
  done
  (( broken == 0 ))
}
```

- [ ] **Step 4: Add case arm in `bin/ghw` main**

```zsh
    doctor)
      source "${daemon_dir}/lib/api.zsh"
      source "${daemon_dir}/lib/doctor.zsh"
      ghw_doctor "$@"
      exit $?
      ;;
```
(Ensure `lib/auth.zsh` is sourced in `main` before the case; it provides `ghw_accounts_file`/`ghw_profile_field`.)

- [ ] **Step 5: Run tests, parse-check** — `zsh -n claude/github-warden/lib/doctor.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 6: Commit**

```bash
git add claude/github-warden/lib/doctor.zsh claude/github-warden/bin/ghw claude/github-warden/test/doctor.test.zsh
git commit -m "feat(ghw): doctor — per-profile token/login/scope/admin health

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: `ghw status` + `ghw members` (`lib/status.zsh`, `lib/members.zsh`)

**Files:**
- Create: `claude/github-warden/lib/status.zsh`
- Create: `claude/github-warden/lib/members.zsh`
- Modify: `claude/github-warden/bin/ghw` (two case arms)
- Create: `claude/github-warden/test/status-members.test.zsh`

**Interfaces:**
- Consumes: `ghw_resolve_profile`, `ghw_token_for`, `ghw_api`, `ghw_api_paged`.
- Produces: `ghw_status <account> [--org <org>]` — for the org (required via `--org` or sole org of resolved profile): prints `org <name>: repos=<public+private> members=<n> teams=<n> plan=<name>`. `ghw_members <account> --org <org> [--csv <out>] [--json]` — table (or CSV/JSON) with columns `login,org_role,teams,twofa_disabled,outside_collaborator`; org_role from `?role=admin` sublist; teams as `;`-joined slugs from per-team member sweep; 2FA from `?filter=2fa_disabled`; outside collaborators appended as rows with `outside_collaborator=true`. CSV output's `login` column round-trips into `ghw import --csv`.

- [ ] **Step 1: Write failing tests** — stub routes for `/orgs/o` (`{"public_repos":3,"total_private_repos":5,"plan":{"name":"free"}}`), `/orgs/o/members` (2 members), `/orgs/o/members?role=admin` (1), `/orgs/o/members?filter=2fa_disabled` (1), `/orgs/o/teams` (1 team `t1`), `/orgs/o/teams/t1/members` (1), `/orgs/o/outside_collaborators` (1). Assert: status line `repos=8 members=2 teams=1`; members CSV contains `alice,admin,t1,false,false` shape rows and outside collaborator row; `--csv` file written; zero PUTs in log.

`claude/github-warden/test/status-members.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["ORG1"]}}}' > "$GHW_ACCOUNTS_FILE"
export T_I="tok"
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */orgs/ORG1/members\?*role=admin*|*/orgs/ORG1/members\?*filter=2fa_disabled*) : ;;
  esac
  case "$2" in
    */orgs/ORG1/teams/t1/members*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/teams*) RESP_STATUS=200; RESP_BODY='[{"slug":"t1"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*role=admin*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*2fa_disabled*) RESP_STATUS=200; RESP_BODY='[{"login":"bob"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"},{"login":"bob"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/outside_collaborators*) RESP_STATUS=200; RESP_BODY='[{"login":"contractor1"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1) RESP_STATUS=200; RESP_BODY='{"login":"ORG1","public_repos":3,"total_private_repos":5,"plan":{"name":"free"}}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF

out=$(zsh "$ghw_bin" status --org ORG1 2>&1); rc=$?
assert_exit "status ok" 0 $rc
assert_contains "status line" "$out" "org ORG1: repos=8 members=2 teams=1 plan=free"

csv_out="${work}/members.csv"
out=$(zsh "$ghw_bin" members --org ORG1 --csv "$csv_out" 2>&1); rc=$?
assert_exit "members ok" 0 $rc
body=$(<"$csv_out")
assert_contains "members header" "$body" "login,org_role,teams,twofa_disabled,outside_collaborator"
assert_contains "admin row with team" "$body" "alice,admin,t1,false,false"
assert_contains "2fa flag" "$body" "bob,member,,true,false"
assert_contains "outside collab" "$body" "contractor1,,,false,true"
assert_not_contains "read-only" "$(<$GHW_STUB_LOG)" "PUT "

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — unknown commands → FAIL

- [ ] **Step 3: Write `lib/status.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw status — read-only org overview.

ghw_status() {  # $1 account (may be ""), remaining flags
  local account="$1"; shift
  local org=""
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw status: unknown flag: $1"; return 2 ;;
    esac
  done
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  if [[ -z "$org" ]]; then
    org=$(jq -r --arg p "$profile" '.profiles[$p].orgs[0]' "$(ghw_accounts_file)")
  fi
  ghw_token_for "$profile" || return 2
  local body repos members teams plan
  body=$(ghw_api GET "/orgs/${org}") || { print -ru2 -- "ghw status: /orgs/${org} → HTTP ${GHW_LAST_STATUS}"; return 1 }
  repos=$(print -r -- "$body" | jq '(.public_repos // 0) + (.total_private_repos // 0)')
  plan=$(print -r -- "$body" | jq -r '.plan.name // "?"')
  members=$(ghw_api_paged "/orgs/${org}/members" | jq 'length') || return 1
  teams=$(ghw_api_paged "/orgs/${org}/teams" | jq 'length') || return 1
  print -r -- "org ${org}: repos=${repos} members=${members} teams=${teams} plan=${plan}"
}
```

- [ ] **Step 4: Write `lib/members.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw members — read-only membership report. CSV round-trips into ghw import.

ghw_members() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" csv_out="" json_mode=0
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --csv) csv_out="${2:?}"; shift 2 ;;
      --json) json_mode=1; shift ;;
      *) print -ru2 -- "ghw members: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" ]] && { print -ru2 -- "ghw members: --org required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  local members admins twofa teams team outside u
  members=$(ghw_api_paged "/orgs/${org}/members") || return 1
  admins=$(ghw_api_paged "/orgs/${org}/members?role=admin") || return 1
  twofa=$(ghw_api_paged "/orgs/${org}/members?filter=2fa_disabled") || return 1
  outside=$(ghw_api_paged "/orgs/${org}/outside_collaborators") || return 1
  teams=$(ghw_api_paged "/orgs/${org}/teams" | jq -r '.[].slug') || return 1

  typeset -A team_of is_admin no2fa
  for u in ${(f)"$(print -r -- "$admins" | jq -r '.[].login')"}; do is_admin[$u]=1; done
  for u in ${(f)"$(print -r -- "$twofa" | jq -r '.[].login')"}; do no2fa[$u]=1; done
  for team in ${(f)teams}; do
    for u in ${(f)"$(ghw_api_paged "/orgs/${org}/teams/${team}/members" | jq -r '.[].login')"}; do
      team_of[$u]="${team_of[$u]:+${team_of[$u]};}${team}"
    done
  done

  local -a rows
  local role_disp twofa_disp
  rows=("login,org_role,teams,twofa_disabled,outside_collaborator")
  for u in ${(f)"$(print -r -- "$members" | jq -r '.[].login')"}; do
    role_disp=member; [[ -n "${is_admin[$u]:-}" ]] && role_disp=admin
    twofa_disp=false; [[ -n "${no2fa[$u]:-}" ]] && twofa_disp=true
    rows+=("${u},${role_disp},${team_of[$u]:-},${twofa_disp},false")
  done
  for u in ${(f)"$(print -r -- "$outside" | jq -r '.[].login')"}; do
    rows+=("${u},,,false,true")
  done

  if [[ -n "$csv_out" ]]; then
    print -rl -- "${rows[@]}" > "$csv_out"
    print -r -- "wrote ${#rows[@]} lines to ${csv_out}"
  elif (( json_mode )); then
    print -rl -- "${rows[@]}" | jq -R -s 'split("\n") | map(select(length>0)) | .[1:] | map(split(",") | {login: .[0], org_role: .[1], teams: .[2], twofa_disabled: .[3], outside_collaborator: .[4]})'
  else
    print -rl -- "${rows[@]}" | column -t -s,
  fi
}
```


- [ ] **Step 5: Add case arms in `bin/ghw` main**

```zsh
    status)
      source "${daemon_dir}/lib/api.zsh"
      source "${daemon_dir}/lib/status.zsh"
      ghw_status "$account" "$@"
      exit $?
      ;;
    members)
      source "${daemon_dir}/lib/api.zsh"
      source "${daemon_dir}/lib/members.zsh"
      ghw_members "$account" "$@"
      exit $?
      ;;
```

- [ ] **Step 6: Run tests, parse-check** — `zsh -n claude/github-warden/lib/status.zsh claude/github-warden/lib/members.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 7: Commit**

```bash
git add claude/github-warden/lib/status.zsh claude/github-warden/lib/members.zsh claude/github-warden/bin/ghw claude/github-warden/test/status-members.test.zsh
git commit -m "feat(ghw): status + members read-only reports

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: `ghw audit` + `ghw stale` (`lib/audit.zsh`, `lib/stale.zsh`)

**Files:**
- Create: `claude/github-warden/lib/audit.zsh`
- Create: `claude/github-warden/lib/stale.zsh`
- Modify: `claude/github-warden/bin/ghw` (two case arms)
- Create: `claude/github-warden/test/audit-stale.test.zsh`

**Interfaces:**
- Consumes: `ghw_resolve_profile`, `ghw_token_for`, `ghw_api`, `ghw_api_paged`.
- Produces: `ghw_audit <account> --org <org> --ref <owner/repo>` — drift lines `repo<TAB>field<TAB>expected<TAB>actual`, summary `N repos audited, M drift lines`, exit 0 always (drift is information, not failure). Compared fields: `private, has_issues, has_projects, has_wiki, has_discussions, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, allow_update_branch, web_commit_signoff_required` + `security_and_analysis.{advanced_security,secret_scanning,secret_scanning_push_protection,dependabot_security_updates}.status` + branch protection presence on default branch (`protected` vs `unprotected`). `ghw_stale <account> --org <org> [--months <n>]` (default 6) — lines `repo<TAB>pushed_at<TAB>reason` (reasons: `inactive >Nmo`, `empty`, `fork`), each followed by a printed (never executed) `gh repo archive <org>/<repo> --yes` command.

- [ ] **Step 1: Write failing tests** — audit: ref repo with `has_wiki=true`, secret_scanning enabled, protection 200; org with 2 repos — one identical+protected (no drift), one `has_wiki=false`, secret_scanning disabled, protection 404 (3 drift lines). stale: 3 repos — one pushed recently (excluded), one `pushed_at` 2020 (inactive), one `size=0` (empty); assert reasons + printed archive commands + zero PUT/DELETE in stub log.

`claude/github-warden/test/audit-stale.test.zsh`:
```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["ORG1"]}}}' > "$GHW_ACCOUNTS_FILE"
export T_I="tok"

repo_json() {  # $1 name, $2 has_wiki, $3 secret_scanning status
  jq -nc --arg n "$1" --argjson w "$2" --arg ss "$3" '{
    name: $n, private: true, has_issues: true, has_projects: false, has_wiki: $w,
    has_discussions: false, allow_squash_merge: true, allow_merge_commit: false,
    allow_rebase_merge: true, delete_branch_on_merge: true, allow_update_branch: true,
    web_commit_signoff_required: false, default_branch: "main",
    security_and_analysis: {secret_scanning: {status: $ss}}}'
}
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  case "\$2" in
    */repos/ORG1/ref-repo/branches/main/protection|*/repos/ORG1/good/branches/main/protection)
      RESP_STATUS=200; RESP_BODY='{"required_pull_request_reviews":{}}'; RESP_HEADERS='' ;;
    */repos/ORG1/drifty/branches/main/protection)
      RESP_STATUS=404; RESP_BODY='{"message":"Branch not protected"}'; RESP_HEADERS='' ;;
    */repos/ORG1/ref-repo) RESP_STATUS=200; RESP_BODY='$(repo_json ref-repo true enabled)'; RESP_HEADERS='' ;;
    */repos/ORG1/good) RESP_STATUS=200; RESP_BODY='$(repo_json good true enabled)'; RESP_HEADERS='' ;;
    */repos/ORG1/drifty) RESP_STATUS=200; RESP_BODY='$(repo_json drifty false disabled)'; RESP_HEADERS='' ;;
    */orgs/ORG1/repos*)
      RESP_STATUS=200; RESP_BODY='[{"name":"good","pushed_at":"2026-07-01T00:00:00Z","size":10,"fork":false},{"name":"drifty","pushed_at":"2020-01-01T00:00:00Z","size":10,"fork":false},{"name":"emptyrepo","pushed_at":null,"size":0,"fork":false}]'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF

out=$(zsh "$ghw_bin" audit --org ORG1 --ref ORG1/ref-repo 2>&1); rc=$?
assert_exit "audit ok" 0 $rc
assert_contains "wiki drift" "$out" $'drifty\thas_wiki\ttrue\tfalse'
assert_contains "secret scanning drift" "$out" $'drifty\tsecret_scanning\tenabled\tdisabled'
assert_contains "protection drift" "$out" $'drifty\tbranch_protection\tprotected\tunprotected'
assert_not_contains "good repo clean" "$out" $'good\thas_wiki'

out=$(zsh "$ghw_bin" stale --org ORG1 --months 6 2>&1); rc=$?
assert_exit "stale ok" 0 $rc
assert_contains "inactive flagged" "$out" "drifty"
assert_contains "empty flagged" "$out" "emptyrepo"
assert_not_contains "active excluded" "$out" $'good\t'
assert_contains "archive command printed" "$out" "gh repo archive ORG1/drifty --yes"
assert_not_contains "read-only" "$(<$GHW_STUB_LOG)" "PUT "
assert_not_contains "no deletes" "$(<$GHW_STUB_LOG)" "DELETE "

rm -rf "$work"
report
```

- [ ] **Step 2: Run to verify it fails** — unknown commands → FAIL

- [ ] **Step 3: Write `lib/audit.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw audit — read-only settings/protection drift vs a reference repo.

typeset -ga _GHW_AUDIT_FIELDS
_GHW_AUDIT_FIELDS=(private has_issues has_projects has_wiki has_discussions
  allow_squash_merge allow_merge_commit allow_rebase_merge delete_branch_on_merge
  allow_update_branch web_commit_signoff_required)
typeset -ga _GHW_SEC_FIELDS
_GHW_SEC_FIELDS=(advanced_security secret_scanning secret_scanning_push_protection dependabot_security_updates)

_ghw_protection_state() {  # $1 owner/repo, $2 branch — prints protected|unprotected|unknown
  ghw_api GET "/repos/$1/branches/$2/protection" >/dev/null
  case $? in
    0) print -r -- protected ;;
    4) print -r -- unprotected ;;
    *) print -r -- "unknown(HTTP ${GHW_LAST_STATUS})" ;;
  esac
}

ghw_audit() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" ref=""
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --ref) ref="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw audit: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" || -z "$ref" ]] && { print -ru2 -- "ghw audit: --org and --ref <owner/repo> required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  local ref_json ref_branch ref_prot repo repo_json branch prot f exp got
  local -i repos=0 drift=0
  ref_json=$(ghw_api GET "/repos/${ref}") || { print -ru2 -- "ghw audit: reference /repos/${ref} → HTTP ${GHW_LAST_STATUS}"; return 1 }
  ref_branch=$(print -r -- "$ref_json" | jq -r .default_branch)
  ref_prot=$(_ghw_protection_state "$ref" "$ref_branch")

  for repo in ${(f)"$(ghw_api_paged "/orgs/${org}/repos" | jq -r '.[].name')"}; do
    [[ "ORG_SLASH_REPO" == "$ref" ]] && :  # ref may live outside org; compare it too if listed
    [[ "${org}/${repo}" == "$ref" ]] && continue
    (( repos++ ))
    repo_json=$(ghw_api GET "/repos/${org}/${repo}") || continue
    for f in "${_GHW_AUDIT_FIELDS[@]}"; do
      exp=$(print -r -- "$ref_json" | jq -r --arg f "$f" '.[$f]')
      got=$(print -r -- "$repo_json" | jq -r --arg f "$f" '.[$f]')
      if [[ "$exp" != "$got" ]]; then
        print -r -- "${repo}\t${f}\t${exp}\t${got}"
        (( drift++ ))
      fi
    done
    for f in "${_GHW_SEC_FIELDS[@]}"; do
      exp=$(print -r -- "$ref_json" | jq -r --arg f "$f" '.security_and_analysis[$f].status // "unset"')
      got=$(print -r -- "$repo_json" | jq -r --arg f "$f" '.security_and_analysis[$f].status // "unset"')
      if [[ "$exp" != "$got" ]]; then
        print -r -- "${repo}\t${f}\t${exp}\t${got}"
        (( drift++ ))
      fi
    done
    branch=$(print -r -- "$repo_json" | jq -r .default_branch)
    prot=$(_ghw_protection_state "${org}/${repo}" "$branch")
    if [[ "$prot" != "$ref_prot" ]]; then
      print -r -- "${repo}\tbranch_protection\t${ref_prot}\t${prot}"
      (( drift++ ))
    fi
  done
  print -r -- "${repos} repos audited, ${drift} drift lines (reference: ${ref})"
}
```
(Use literal tab characters in the `print` format strings — `$'\t'` — when implementing; shown as `\t` here for readability. Delete the placeholder `[[ "ORG_SLASH_REPO" ... ]]` line — it documents the skip-ref intent already covered by the next line.)

- [ ] **Step 4: Write `lib/stale.zsh`**

```zsh
#!/usr/bin/env zsh
# ghw stale — read-only archive-candidate report. Prints commands, never runs them.

ghw_stale() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" months=6
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --months) months="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw stale: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" ]] && { print -ru2 -- "ghw stale: --org required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  local cutoff repos line name pushed size is_fork reason
  cutoff=$(date -v-"${months}"m +%s 2>/dev/null || date -d "-${months} months" +%s)
  repos=$(ghw_api_paged "/orgs/${org}/repos") || return 1
  local -i count=0
  while IFS=$'\t' read -r name pushed size is_fork; do
    reason=""
    if [[ "$size" == 0 || "$pushed" == null ]]; then
      reason="empty"
    else
      local pushed_epoch
      pushed_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed" +%s 2>/dev/null || date -d "$pushed" +%s)
      if (( pushed_epoch < cutoff )); then
        reason="inactive >${months}mo (last push ${pushed%T*})"
      fi
    fi
    [[ "$is_fork" == true && -n "$reason" ]] && reason+=", fork"
    if [[ -n "$reason" ]]; then
      (( count++ ))
      print -r -- "${name}"$'\t'"${pushed}"$'\t'"${reason}"
      print -r -- "  gh repo archive ${org}/${name} --yes"
    fi
  done < <(print -r -- "$repos" | jq -r '.[] | [.name, (.pushed_at // "null"), .size, .fork] | @tsv')
  print -r -- "${count} archive candidate(s) in ${org} (nothing archived — commands above are for you to run)"
}
```

- [ ] **Step 5: Add case arms in `bin/ghw` main**

```zsh
    audit)
      source "${daemon_dir}/lib/api.zsh"
      source "${daemon_dir}/lib/audit.zsh"
      ghw_audit "$account" "$@"
      exit $?
      ;;
    stale)
      source "${daemon_dir}/lib/api.zsh"
      source "${daemon_dir}/lib/stale.zsh"
      ghw_stale "$account" "$@"
      exit $?
      ;;
```

- [ ] **Step 6: Run tests, parse-check** — `zsh -n claude/github-warden/lib/audit.zsh claude/github-warden/lib/stale.zsh && zsh claude/github-warden/test/run.zsh` → `all test files passed`

- [ ] **Step 7: Commit**

```bash
git add claude/github-warden/lib/audit.zsh claude/github-warden/lib/stale.zsh claude/github-warden/bin/ghw claude/github-warden/test/audit-stale.test.zsh
git commit -m "feat(ghw): audit drift report + stale archive candidates

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Docs + final verification + push

**Files:**
- Create: `claude/github-warden/README.md`
- Modify: `README.md` (root — add github-warden row/section alongside dag/cas)

**Interfaces:**
- Consumes: everything above (documents it).

- [ ] **Step 1: Write `claude/github-warden/README.md`** covering, in this order: purpose paragraph (dag-style GitHub org/repo daemon, two account profiles personal/inv, admin verified every run); one-time setup (fill `config/accounts.json` real `login`/`orgs` from `gh api user`, export `GHW_TOKEN_PERSONAL`/`GHW_TOKEN_INV`, recommended fine-grained PAT with Organization Members read&write per import spec §9, run `ghw doctor` to verify); command table (the 7 commands with Mutates/Runtime columns copied from the design spec `docs/superpowers/specs/2026-07-28-github-warden-design.md`); safety section (§4.2 never-PUT-existing-member, add-only, phase ordering, precondition codes table P1–P6); reports location `~/.local/state/github-warden/reports/<job_id>/` (csv/json/summary, never deleted); env vars (`GHW_LAUNCHER`, `GHW_STATE_DIR`, `GHW_API_ROOT`); verification (`zsh claude/github-warden/test/run.zsh`); backlog list (offboard confirm-gated, team-sync, webhook/deploy-key audit, secret-scanning alert report, Actions-permissions audit, topics/license normalization, label sync, CODEOWNERS audit, invite cleanup, repo transfer helper).

- [ ] **Step 2: Add root `README.md` entry** — follow the existing dag/cas row format in that file (read it first, mirror its structure): name `github-warden (ghw)`, path `claude/github-warden/`, one-line purpose "GitHub org/repo management: mirror, org/team import, audit, stale, members across personal/inv accounts", exposure via `aliases.zsh` `ghw` wrapper.

- [ ] **Step 3: Full verification**

Run:
```bash
for f in claude/github-warden/bin/ghw claude/github-warden/lib/*.zsh claude/github-warden/test/*.zsh claude/github-warden/test/fixtures/*.zsh; do zsh -n "$f" || echo "PARSE FAIL: $f"; done
zsh claude/github-warden/test/run.zsh
zsh -n aliases.zsh
```
Expected: no `PARSE FAIL`, `all test files passed`, silent aliases check.

- [ ] **Step 4: Live smoke (only if a token is exported in the shell; skip cleanly otherwise)**

Run: `zsh claude/github-warden/bin/ghw doctor`
Expected with no tokens: every profile prints `token=MISSING`, exit 1 — that IS the correct offline behavior; note it in the completion report, don't fake success.

- [ ] **Step 5: Commit + push**

```bash
git add claude/github-warden/README.md README.md
git commit -m "docs(ghw): github-warden README + root repo entry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin HEAD
```

---

## Self-Review Notes (resolved inline)

- Spec coverage: mirror (T7), import engine + A1–A8 (T3 covers A8's backoff mechanics at the api layer; T6 covers A1–A4, A6, A7; T4 covers A5), doctor (T8), status/members (T9), audit/stale (T10), playbooks/_common policy (T7), reports retention (T5), aliases + docs rule (T1, T11).
- P6 duplicate-login handling: spec §3 marks duplicates `SOURCE_INVALID`, §4 says "deduped, order preserved". Resolution (matches design spec): dedupe with a stderr warning; empty/missing column stays `SOURCE_INVALID`.
- The admin/member and 2FA displays in `lib/members.zsh` use explicit `if` branches (a `${var:+a}${var:-b}` ternary would print the sentinel value when set); the test rows assert both branches.
- `date -v` (BSD/macOS) used with GNU `date -d` fallback in `stale` — platform is darwin, fallback keeps tests honest on Linux CI if ever run there.
