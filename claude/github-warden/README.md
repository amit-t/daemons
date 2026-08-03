# github-warden (`ghw`)

`ghw` is a GitHub org/repo management daemon for Amit's two air-gapped GitHub identities: **personal** (login `amit-t`, his own orgs plus his own user namespace) and **inv** (login `amit-tiwari_vnt`, the Invenco VNT account administering every Invenco org, including the `INVENCO-GROUP` EMU org). Runtime shape mirrors `dag` (devin-acu-governor): read-only commands (`doctor`, `status`, `audit`, `stale`, `members`) run as pure local zsh/curl/jq and never launch an agent; the two mutating flows (`mirror`, `import`) launch a `co` playbook (interactive-shell launcher, override with `GHW_LAUNCHER`) whose writes go only through deterministic `lib/` engine scripts, never through raw agent-issued API calls. Admin access is verified fresh on every run, before any write — the daemon never trusts a cached auth state.

Related docs: [`docs/ACCOUNTS.md`](docs/ACCOUNTS.md) (the two-identity account model in depth) and [`docs/RUNBOOK-org-import.md`](docs/RUNBOOK-org-import.md) (the operational runbook for `ghw import`).

## Safety model

This daemon exists to make privileged GitHub org operations boring. Three invariants carry that weight; every one of them is enforced in code, not in agent judgment.

### 1. Account air-gap

Amit's two identities must never spill rights onto each other. Every target org/owner belongs to exactly one profile, matched against that profile's `orgs[]` or its `user_namespace` in `config/accounts.json`. `--account` selects a **credential**, not a bypass: if the resolved target belongs to a different profile than the one named by `--account`, `ghw_resolve_profile` (`lib/auth.zsh`) refuses **locally, before any network call** — the wrong token never leaves the machine.

Captured verbatim:

```
$ ghw --account personal status --org INVENCO-GROUP
ACCOUNT_MISMATCH: 'INVENCO-GROUP' belongs to profile 'inv', not 'personal'. ghw keeps accounts air-gapped — rerun with --account inv or omit --account.
```

```
$ ghw --account inv status --org BrightBytesHub
ACCOUNT_MISMATCH: 'BrightBytesHub' belongs to profile 'personal', not 'inv'. ghw keeps accounts air-gapped — rerun with --account personal or omit --account.
```

A target mapped to **no** profile fails the same way, naming `config/accounts.json` as the fix. `--account` with no target (`ghw --account inv doctor`) is unaffected — the guard only engages when a target is present to check. GitHub org/user names are case-insensitive, so the comparison is case-folded internally, but every message and downstream API call keeps the caller's original casing.

A companion config invariant closes the other half of the gap: no org or `user_namespace` may appear under more than one profile (case-insensitively). `ghw_check_airgap` (`lib/auth.zsh`) runs this jq pass before every resolution — every command inherits it via `ghw_resolve_profile`, and `ghw doctor` surfaces it too:

```
ACCOUNT_OVERLAP: '<name>' is listed under profiles <a>, <b> — accounts must be air-gapped.
```

Enforced in: `_ghw_profile_owning`, `ghw_check_airgap`, `ghw_resolve_profile` — all in `lib/auth.zsh`.

### 2. Never a membership PUT for an existing member

Both the org-membership and team-membership endpoints (`PUT /orgs/{org}/memberships/{u}`, `PUT /orgs/{org}/teams/{team}/memberships/{u}`) are upserts. A blind `PUT` against an existing **Owner** silently demotes them to Member; against an existing team **maintainer** it demotes them to member. This is not a hypothetical — the origin spec for this daemon exists because a single manual probe call demoted `leo-pronzolino_vnt` from maintainer to member during a real import, and had to be restored by hand.

`lib/import-engine.zsh` reads live org and team membership first, computes a per-phase **set-difference** against the CSV logins, and only PUTs logins that are not already members. Existing members get a `skipped` report row instead. This is the entire safety mechanism — there is no separate role-change code path, so it cannot be bypassed by a caller.

Enforced in: the `add_org`/`add_team` set-difference loops in `lib/import-engine.zsh` (against `in_org`/`in_team` maps built from `GET /orgs/{org}/members` and `GET /orgs/{org}/teams/{team}/members`).

### 3. Preconditions gate every write

`ghw_precheck` (`lib/auth.zsh`) runs before any write, all-or-nothing: it verifies the token authenticates as the expected login, the scopes include `admin:org`, the org exists, the caller is an org admin, and (if targeted) the team exists. Any failure aborts with a named code and **zero writes issued** — see [Error and refusal reference](#error-and-refusal-reference).

Enforced in: `ghw_precheck` in `lib/auth.zsh`, called from `lib/import-engine.zsh` before any `PUT`.

## One-time setup

1. `config/accounts.json` ships with real `login`/`orgs` values for both profiles, captured from `gh api user` (and `gh api user/orgs`) while authenticated as each account. See [`docs/ACCOUNTS.md`](docs/ACCOUNTS.md) for the full org list per profile and how to add a new org or account.
2. Run `gh auth login --hostname github.com` once per account (personal, then inv) so the `gh` CLI keyring holds a token for each `login`. This is the **primary** credential source — `ghw_token_for` (`lib/auth.zsh`) runs `gh auth token --user <login>` per profile, so no PAT needs to be minted or exported day to day.
   - **Fallback (non-interactive/headless path):** exporting `GHW_TOKEN_PERSONAL` / `GHW_TOKEN_INV` still works if `gh` isn't on `PATH` or its keyring has no token for that login. This is the path for cron/CI-style unattended runs, where an interactive `gh` keyring isn't available. Tokens are never read from anywhere else — not committed, not logged, not echoed into reports.
   - SSH keys are configured for both accounts for git operations (clone/push, used by `ghw mirror`); the GitHub API always goes over the resolved token (`GH_TOKEN`/`GITHUB_TOKEN`), never SSH.
3. Run `ghw doctor` to verify: token present (and which source produced it), login matches profile, air-gap invariant, and org-admin role for every configured org, per profile.

Real captured output (`ghw doctor`, both accounts already `gh auth login`'d with `admin:org`):

```
profile inv: token=ok(gh:amit-tiwari_vnt) login=ok scopes=admin:org, gist, repo, workflow
  user amit-tiwari_vnt: own namespace
  org INVENCO-GROUP: role=admin
  org Invenco-Cloud-Systems-ICS: role=admin
  org inv-cloud-platform: role=member
  org Invenco-Group-Limited: role=admin
  org Invenco-Platform-Software: role=member
  org Invenco-Test-Practice-ITP: role=member
  summary: admin on 3/6 orgs (member-only: inv-cloud-platform, Invenco-Platform-Software, Invenco-Test-Practice-ITP)
profile personal: token=ok(gh:amit-t) login=ok scopes=admin:org, gist, repo, workflow
  user amit-t: own namespace
  org AppIncubatorHQ: role=admin
  org babble-club: role=admin
  org bharat-innovation-olympiad: role=admin
  org BrightBytesHub: role=admin
  org eternals-tech: role=admin
  org EverPlanHQ: role=admin
  org EverPlanHQ-Dep: role=admin
  org FlyingPenguinsInd: role=admin
  org Hiplogik: role=admin
  org iamamittiwari: role=admin
  org IntelliBuilds: role=admin
  org KommonSchool: role=admin
  org MilkyWaayy: role=admin
  org nagpurtechies: role=member
  org perspectiv91: role=admin
  org Quiet-Realist: role=admin
  org RefineryInc: role=admin
  org Swapaholic: role=admin
  org untox-labs: role=admin
  org Zippy-Tech: role=admin
  summary: admin on 19/20 orgs (member-only: nagpurtechies)
```

Plain `ghw doctor` exits 0 here — every profile's credential health is good and the air-gap invariant holds; member-only orgs (`inv-cloud-platform`, `Invenco-Platform-Software`, `Invenco-Test-Practice-ITP`, `nagpurtechies`) are informational, not failures. `ghw doctor --strict` would exit 1 against this exact output, since it additionally requires admin on every listed org.

## Command reference

| Command | Mutates | Runtime |
|---|---:|---|
| `ghw mirror [<repo\|url>] [flags...]` | Yes | Agent (`co` playbook) by default; `--script` runs `mirror-repo.zsh` directly |
| `ghw import [--org X] [--team y] [--csv f] [flags...]` | Yes | Agent (`co` playbook) by default; bare `ghw import` interviews for org/csv; `--script` runs `lib/import-engine.zsh` directly |
| `ghw doctor [--strict]` | No | Local zsh |
| `ghw status [--org X]` | No | Local zsh |
| `ghw audit --org X --ref owner/repo` | No | Local zsh |
| `ghw stale --org X [--months N]` | No | Local zsh |
| `ghw members --org X [--csv out] [--json]` | No | Local zsh |

`--account personal|inv` is a **global** flag: it precedes the command (`ghw --account inv status`), not follows it. Omitted, `ghw` infers the profile from the target org/owner via `config/accounts.json`.

`GHW_DRY_LAUNCH=1` (any non-empty value), set on `mirror`/`import`, prints the assembled agent prompt instead of exec'ing the launcher — useful for inspecting exactly what an agent session would be told.

---

## `mirror`

```
ghw [--account personal|inv] mirror [<repo|url>] [--script] [flag value ...]
```

Launches an agent that scaffolds a new GitHub repo mirroring a reference repo's settings, branch protection, security flags, access, and (optionally) its Pages docs, via the `gh-repo-mirror` skill (`playbooks/mirror.md`).

**Target resolution** (`ghw_normalize_repo_target` in `bin/ghw`):
- If a `<repo|url>` argument is given, it's normalized: `https://github.com/` and `git@github.com:` prefixes and a trailing `.git` are stripped, leaving plain `owner/repo`.
- If no argument is given, `ghw` must be run inside a git repo with an `origin` remote — the reference becomes that remote, normalized the same way.
- If neither applies: `ghw mirror: pass a repo/URL or run inside a git repo with an origin remote` (exit 2).

The owner half of the normalized target (text before the first `/`) is what account resolution runs against — same air-gap rules as every other command.

**Flags:**

| Flag | Meaning |
|---|---|
| `--script` | Bypass the agent: run `~/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh --ref-repo <target> <passthru...>` directly |
| any other `--flag value` | Passed through unmodified to the agent playbook (interactive mode) or `mirror-repo.zsh` (`--script` mode) |

Flag-pair parsing bounds itself to what's left on the command line — a trailing lone flag with no following value is still forwarded as a single-token pass-through rather than causing `shift 2` to error mid-loop.

**What it reads/writes:** reads nothing locally beyond the resolved profile/token; all repo creation and settings writes happen inside `mirror-repo.zsh` (owned by the `gh-repo-mirror` skill, outside this daemon's `lib/`). SSH remotes are used for clone/push; API calls go over the resolved token.

**Worked example:**

```zsh
# Inside a repo whose origin is git@github.com:BrightBytesHub/some-repo.git
ghw mirror
# → resolves owner BrightBytesHub -> profile personal, launches the mirror playbook

# Explicit target, non-interactive script path
ghw mirror amit-t/some-repo --script --new-repo-name my-new-repo --private
```

**Exit codes:** `2` — no target and no `origin` remote, or account/token resolution failed. `0` — `GHW_DRY_LAUNCH` prompt print, or `mirror-repo.zsh`/launcher exits clean. Otherwise whatever the launcher or `mirror-repo.zsh` returns (both are `exec`'d, replacing the `ghw` process).

**Gotcha:** `--script` mode still exports `GH_TOKEN`/`GITHUB_TOKEN` for the resolved profile before handing off — `mirror-repo.zsh` authenticates via those, not via SSH.

---

## `import`

```
ghw [--account personal|inv] import [--org <org>] [--team <slug>] [--csv <file>]
    [--column login] [--role member|maintainer] [--org-role member]
    [--dry-run] [--script]
```

Reconciles a CSV of logins into an org (and optionally one team). Add-only, idempotent, never demotes an existing member — see [Import engine semantics](#import-engine-semantics) and [`docs/RUNBOOK-org-import.md`](docs/RUNBOOK-org-import.md) for the operational walkthrough.

**Flags** (parsed in `bin/ghw`'s `import` case arm):

| Flag | Default | Meaning |
|---|---|---|
| `--org <org>` | interview | Target org (required with `--script`; otherwise the agent interviews for it) |
| `--team <slug>` | none | Target team slug (org-only import if omitted) |
| `--csv <file>` | interview | Plain-CSV source of logins (required with `--script`; otherwise the agent interviews for it) |
| `--column <name>` | `login` | Header of the column holding logins |
| `--role <member\|maintainer>` | `member` | Desired **team** role for new team members |
| `--org-role <member\|admin>` | `member` | Desired **org** role for new org members only |
| `--dry-run` | off | Run steps 1–5, report `would_add`, zero writes |
| `--script` | off | Bypass the agent: run `lib/import-engine.zsh` directly |

`--org` and `--csv` are required only with `--script`; missing either there exits 2 with `ghw import --script: --org and --csv are required`. In agent mode a missing org/csv launches the playbook in interview mode: the agent collects the values (plus optional flags), previews the CSV, and runs the engine through a `bin/ghw import ... --script` re-entry that resolves the account and token from the org. Any other unrecognized flag exits 2. A flag that needs a value with none left exits 2 (`ghw import: <flag> requires a value`).

**What it reads/writes:** reads the CSV, `GET /orgs/{org}/members`, `GET /orgs/{org}/teams/{team}/members`; writes via `PUT /orgs/{org}/memberships/{u}` and `PUT /orgs/{org}/teams/{team}/memberships/{u}`, and writes a report under `${GHW_STATE_DIR}/reports/<job_id>/` (see [Reports](#reports)) — every write goes through `lib/import-engine.zsh`, whether reached via the agent playbook or `--script`.

**Worked example:**

```zsh
# Dry run first, always
ghw import --org INVENCO-GROUP --team ai-workbench-ppna --csv export.csv --dry-run --script

# Real run
ghw import --org INVENCO-GROUP --team ai-workbench-ppna --csv export.csv --script
```

**Exit codes** (from `lib/import-engine.zsh`, the code that ultimately runs either way):

| Code | Meaning |
|---:|---|
| `0` | Success — all writes landed and verified (or a clean dry run) |
| `1` | `MEMBER_LIST_READ_FAILED` (pre-write), or `completed_with_errors` (post-write: any `not_found`/`failed`/verify-failed row) |
| `2` | Usage error, or `ghw_resolve_profile`/`ghw_token_for` failure |
| `5` | Precondition failure (`ghw_precheck`: P1/P2/P3/P4/P5) |
| `6` | `SOURCE_INVALID` (P6 — CSV problem) |

**Gotcha:** `--dry-run` and `--script` are independent flags — `ghw import ... --dry-run` without `--script` still launches the agent, which is instructed (`playbooks/import.md`) to run the engine command exactly as given, including `--dry-run`. Add `--script` too when you want the deterministic path with no agent involved at all.

---

## `doctor`

```
ghw doctor [--strict]
```

Checks every configured profile: token presence + source, login match, scope check via a live `GET /user`, air-gap invariant, and org-admin role per listed org.

**Exit semantics:** exits `0` once every profile's **credential** health is good (token resolved, login matches, scopes OK) and the air-gap invariant holds — org-admin role is informational (member-only on someone else's org isn't actionable and shouldn't turn a permanently-red `doctor && ...` gate red). `--strict` additionally requires admin on every listed org, exiting `1` otherwise. An air-gap/overlap violation always fails doctor, in both modes.

**What it reads:** `GET /user` per profile, `GET /orgs/{org}/memberships/{me}` per configured org per profile. Writes nothing.

**Worked example:** see the [One-time setup](#one-time-setup) section above for real captured output.

```zsh
ghw doctor           # credential + air-gap health only
ghw doctor --strict  # also requires admin on every listed org
```

**Exit codes:** `0` healthy, `1` unhealthy (broken credential, mismatched login, air-gap/overlap violation, or `--strict` finding a member-only org).

---

## `status`

```
ghw [--account personal|inv] status [--org <org>]
```

Read-only org overview: repo count, member count, team count, plan name.

**`--org` is optional** — if omitted, `ghw` uses the resolved profile's first configured org (`.profiles[$p].orgs[0]` in `config/accounts.json`). This only works with an explicit `--account`, because profile resolution with no org **and** no explicit account fails (`ghw: cannot resolve account — pass --account or a target org`, exit 2) before the default-org lookup is ever reached.

**What it reads:** `GET /orgs/{org}` (repo counts, plan), `GET /orgs/{org}/members` (paged, counted), `GET /orgs/{org}/teams` (paged, counted). Writes nothing.

**Worked example (real captured output):**

```
$ ghw status --org INVENCO-GROUP
org INVENCO-GROUP: repos=0 members=357 teams=20 plan=enterprise
```

```zsh
ghw --account inv status                    # defaults to inv's orgs[0]
ghw status --org Invenco-Cloud-Systems-ICS  # account inferred from the org
```

**Exit codes:** `0` success, `1` if `/orgs/{org}`, the org member-list read, or the org team-list read fails — each prints a specific `ghw status: /orgs/{org}[/members|/teams] read failed` (or, for the initial `/orgs/{org}` call, `→ HTTP {status}`) line naming which one; the command never prints its `org ...: repos=... members=... teams=...` summary line unless all three reads succeeded, `2` unknown flag or account/token resolution failure.

---

## `audit`

```
ghw [--account personal|inv] audit --org <org> --ref <owner/repo>
```

Diffs every repo in `--org` against a reference repo's settings, security-and-analysis flags, and default-branch protection state. Both flags are required — missing either exits 2 (`ghw audit: --org and --ref <owner/repo> required`).

**Fields compared** (`_GHW_AUDIT_FIELDS` / `_GHW_SEC_FIELDS` in `lib/audit.zsh`):
- General: `private`, `has_issues`, `has_projects`, `has_wiki`, `has_discussions`, `allow_squash_merge`, `allow_merge_commit`, `allow_rebase_merge`, `delete_branch_on_merge`, `allow_update_branch`, `web_commit_signoff_required`.
- Security-and-analysis: `advanced_security`, `secret_scanning`, `secret_scanning_push_protection`, `dependabot_security_updates` (compared via `.security_and_analysis[$f].status`, defaulting to `unset`).
- Branch protection: `protected` / `unprotected` / `unknown(HTTP …)` on the default branch, via `GET /repos/{owner/repo}/branches/{branch}/protection`.

The reference repo itself is skipped if it happens to live inside the audited org (`[[ "${org}/${repo}" == "$ref" ]] && continue`).

**What it reads:** `GET /repos/{ref}`, `GET /orgs/{org}/repos` (paged), `GET /repos/{org}/{repo}` per repo, plus a branch-protection check per repo and for the reference. Writes nothing — output is a tab-separated drift table to stdout.

**A repo whose own detail fetch fails is not silently counted as audited.** `(( repos++ ))` only happens *after* `GET /repos/{org}/{repo}` succeeds — a failed fetch used to be counted before the fetch even ran, which meant an unreadable repo contributed zero drift lines and looked exactly like a repo that matched the reference perfectly. Now a failure prints `ghw audit: /repos/{org}/{repo} read failed — skipped` to stderr, increments a separate `skipped` counter instead of `repos`, and auditing continues with the next repo — it does not abort the run (contrast with the org-level repo-*list* read failing, which does abort; see Exit codes below).

**Worked example:**

```zsh
ghw audit --org INVENCO-GROUP --ref INVENCO-GROUP/reference-repo
```

Output shape (tab-separated `repo, field, expected, got` per drift line, then a summary):

```
some-repo	private	true	false
some-repo	branch_protection	protected	unprotected
2 repos audited, 2 drift lines (reference: INVENCO-GROUP/reference-repo)
```

If any per-repo fetch failed, the summary gains a trailing clause — `N repos audited, M drift lines (reference: <ref>), K skipped (unreadable — see stderr)` — so an incomplete audit can never read as a clean one just because the drift count looks low or zero.

**Exit codes:** `0` success — this includes runs where one or more repos were `skipped` per the note above; drift and skip counts are the signal for those, not the exit code. `1` if the reference repo `GET /repos/{ref}` fails (`→ HTTP {status}`) or the **org-level** repo-list read fails (`ghw audit: /orgs/{org}/repos read failed`) — the latter aborts before the repo loop runs at all, so a failed listing never prints a "0 repos audited" summary as if the org genuinely had none. `2` missing `--org`/`--ref` or account/token resolution failure.

---

## `stale`

```
ghw [--account personal|inv] stale --org <org> [--months <n>]
```

Read-only archive-candidate report. `--org` is required (`ghw stale: --org required`, exit 2 if missing). `--months` defaults to `6`.

**Candidate criteria** (`lib/stale.zsh`):
- `size == 0` or `pushed_at == null` → reason `empty`.
- Last push older than the cutoff → reason `inactive >{months}mo (last push {date})`.
- A fork that also matches either rule above gets `, fork` appended to the reason.
- Cutoff is computed with BSD `date -v-Nm` and falls back to GNU `date -d "-N months"`.

**What it reads:** `GET /orgs/{org}/repos` (paged). Writes nothing — for each candidate it prints the repo name, last-push date, reason, and the exact `gh repo archive {org}/{name} --yes` command to run by hand. It never runs that command itself.

**Worked example:**

```zsh
ghw stale --org INVENCO-GROUP --months 12
```

```
old-poc	2024-11-02T10:03:00Z	inactive >12mo (last push 2024-11-02)
  gh repo archive INVENCO-GROUP/old-poc --yes
1 archive candidate(s) in INVENCO-GROUP (nothing archived — commands above are for you to run)
```

**Exit codes:** `0` success, `1` if `GET /orgs/{org}/repos` fails — prints `ghw stale: /orgs/{org}/repos read failed` and aborts before the candidate loop runs, rather than printing "0 archive candidate(s)" as if the org genuinely had none, `2` missing `--org` or account/token resolution failure.

---

## `members`

```
ghw [--account personal|inv] members --org <org> [--csv <out>] [--json]
```

Read-only membership report: org role, team membership, 2FA-disabled flag, outside-collaborator flag, per login. `--org` is required (exit 2 if missing).

**What it reads:** `GET /orgs/{org}/members`, `GET /orgs/{org}/members?role=admin`, `GET /orgs/{org}/members?filter=2fa_disabled`, `GET /orgs/{org}/outside_collaborators`, `GET /orgs/{org}/teams` and `GET /orgs/{org}/teams/{slug}/members` per team (all paged).

**Output modes** (mutually compatible in code, but pick one intent):
- `--csv <out>` — writes `login,org_role,teams,twofa_disabled,outside_collaborator` rows to the given path; prints `wrote <n> lines to <out>`.
- `--json` — the same rows as a JSON array on stdout.
- neither — a column-aligned table on stdout (`column -t -s,`).

Outside collaborators get empty `org_role`/`teams` and `outside_collaborator=true`; org members get `false` there. `teams` is a `;`-joined list of team slugs a login belongs to.

**Worked example:**

```zsh
ghw members --org INVENCO-GROUP --csv /tmp/invenco-members.csv
# wrote 358 lines to /tmp/invenco-members.csv   (357 members + outside collaborators + header)
```

The CSV this produces round-trips directly into `ghw import --csv ... --column login`.

Every read is guarded, and a failure names the exact endpoint and aborts the run before any output is produced — because this command's `--csv` output is documented to round-trip into `ghw import`, a silently-incomplete `teams` column here could otherwise drive a write from incomplete data. Two of these reads need calling out, because the obvious way to guard a paged fetch doesn't actually work for them:
- The **org-level teams-list** fetch and the **per-team** member fetch (inside the `for team in ...` loop) both used to be vulnerable to the same failure mode: piping `ghw_api_paged` straight into `jq` before checking the exit status. Plain zsh (no `pipefail` set anywhere in this codebase) reports a pipeline's `$?` from its **last** stage only, and `ghw_api_paged` prints nothing on any failure path — so `jq` would see empty input and exit `0`, silently masking the read failure. The per-team fetch additionally had no guard at all in its original form.
- Both are now fixed the same way `lib/import-engine.zsh`'s pre-write reads already were: fetch and parse are two separate statements, each with its own exit-status check. A failed org teams-list read prints `ghw members: /orgs/{org}/teams read failed`; a failed per-team read prints `ghw members: /orgs/{org}/teams/{slug}/members read failed` and aborts immediately — it does not continue to other teams with that one silently empty.
- The other four reads (org members, org admins, org 2FA-disabled, outside collaborators) never had the pipe-masking problem — no `| jq` before their check — but were silent in a plainer way: a bare `|| return 1` with zero stderr output on failure. Each now names its endpoint too: `ghw members: /orgs/{org}/members read failed`, `.../members?role=admin read failed`, `.../members?filter=2fa_disabled read failed`, `.../outside_collaborators read failed`.

**Exit codes:** `0` success, `1` if any of the org members/admins/2FA/outside-collaborators reads, the org teams-list read, or any per-team member read fails — each names the specific failing endpoint on stderr, and no CSV/JSON/table output (nor a `wrote <n> lines to <out>` line) is produced unless every read that contributed to it succeeded, `2` missing `--org` or account/token resolution failure.

---

## Import engine semantics

`lib/import-engine.zsh` is **the only code path in this daemon that writes memberships** — reached either via the agent playbook (`playbooks/import.md`, which is instructed to run it verbatim and never issue a raw membership `PUT` itself) or directly via `ghw import --script`.

### Algorithm, in order

1. **Parse + dedupe source.** `ghw_parse_source` (`lib/report.zsh`) reads the CSV, refuses quoted fields, extracts the named column, drops empty values, and dedupes exact-match duplicates with a stderr warning (not a hard failure).
2. **Precondition gate.** `ghw_precheck` (`lib/auth.zsh`) — see [Error and refusal reference](#error-and-refusal-reference). All-or-nothing; zero writes on any failure.
3. **Read current org members.** `GET /orgs/{org}/members`, paged. A cheap invariant then checks that the authenticated login itself (already confirmed an org admin by step 2) appears in this list — a silently truncated or empty read fails closed here (`MEMBER_LIST_READ_FAILED`) rather than making every CSV login look "new."
4. **Read current team members** (if `--team` given). Same read-failure guard.
5. **Set-difference, per phase, independently.** A login already in `in_org` is skipped for the org phase; a login already in `in_team` is skipped for the team phase. These are computed **independently**, not cross-excluded — an existing org member who isn't yet on the target team still gets a team `PUT`. This is deliberate: adding existing org members to a new team is the daemon's primary use case. (Cross-phase exclusion was tried during development and reverted because it broke exactly that case.)
6. **Org phase.** Serial `PUT /orgs/{org}/memberships/{u}` for every login in `add_org`, fully complete before team phase starts.
7. **Team phase.** Serial `PUT /orgs/{org}/teams/{team}/memberships/{u}` for every login in `add_team` that didn't already fail in the org phase.
8. **Live-state verification.** Both org and team member lists are re-read post-write, and every login not already excluded by an earlier failure is checked against that live state, not against the sequence of `2xx` responses from steps 6–7. A read failure here does **not** abort — the writes already landed — instead every affected login gets an explicit `verify failed` report row, and the run ends `completed_with_errors` (exit 1) rather than hiding a partially-successful import.

### Safety properties and why they exist

- **Read-then-diff-then-write, never blind-write.** The set-difference in step 5 is the entire mechanism preventing accidental demotion — see [Never a membership PUT for an existing member](#2-never-a-membership-put-for-an-existing-member) above. The origin spec for this daemon (`SPEC-org-import-daemon.md`) documents the real incident that motivated it: a manual probe call demoted `leo-pronzolino_vnt` from team maintainer to member with a single unguarded `PUT`.
- **Org phase completes before team phase begins** (step 6 before 7). A team `PUT` for a non-org-member either fails or lands `pending`; ordering avoids that entirely.
- **Case-insensitive login matching throughout.** GitHub logins are case-insensitive but zsh associative-array keys are not, so every membership map key/lookup is lowercased (`${(L)u}`) while `logins`/`add_org`/`add_team` (and every report row, every PUT URL) keep the CSV's original casing.
- **Serial writes, one in flight at a time.** No concurrency; simpler failure semantics and avoids tripping GitHub's secondary rate limiter, which is opaque and job-wide.

### EMU behavior

`INVENCO-GROUP` is an Enterprise Managed Users (EMU) org. Two behaviors the engine does not fight:
- Org adds return `state: "active"` immediately — there is no invitation flow to poll.
- EMU logins are enterprise-scoped; one that doesn't exist in the enterprise 404s on the membership `PUT` and is recorded `not_found`, same as any other nonexistent login.

On a non-EMU org the same code path may return `state: "pending"` instead — the engine records whichever state the API gives and never treats `pending` as a failure.

### Rate-limit handling (`lib/api.zsh`, `ghw_api`)

- **Primary limit** (`403` + `x-ratelimit-remaining: 0`): sleep until `x-ratelimit-reset`, then retry — no attempt cap on this branch.
- **Secondary limit** (`403` + a `retry-after` header): sleep for `retry-after`, retry up to 5 attempts, then fail with rc 1.
- **Plain `403`** (neither of the above): a real permission error, rc 3 — never retried.
- **`5xx` or transport failure (`000`):** exponential backoff (`2^(attempt-1)`, capped at 60s), up to 3 attempts, then rc 1.
- **`404`:** rc 4, never retried — this is what turns into a per-login `not_found` report row.

### What it will NOT do

Add-only. No role changes to existing members (promotion or demotion), no removals, no team creation, no org creation. This is enforced structurally — there is no code path in `lib/import-engine.zsh` that issues a `DELETE`, and the only `PUT`s issued are gated by the set-difference in step 5. `playbooks/_common.md` states the same rule as agent policy, as a second line of defense for anything routed through the agent.

### Acceptance tests (A1–A8, from the origin spec) mapped to coverage

| # | Scenario | Covered in |
|---|---|---|
| A1 | Re-run a completed job unchanged → 0 writes, all `skipped`, exit 0 | `test/import-engine.test.zsh` ("A1 re-run exit 0" / "A1 zero writes") |
| A2 | Existing org **Owner** in source → no org `PUT`, role still `admin` | `test/import-engine.test.zsh` ("A2 no org PUT for owner") |
| A3 | Existing team **maintainer** in source → no team `PUT`, role still `maintainer` | `test/import-engine.test.zsh` ("A3 no team PUT for maintainer") |
| A4 | Nonexistent login in source → row `not_found`, batch continues | `test/import-engine.test.zsh` ("A4 ghost not_found" / "A4 batch continued") |
| A5 | Token lacks `admin:org` → refuses at P2, zero writes | `test/precheck.test.zsh` ("scope missing refuses") |
| A6 | `--dry-run` → zero writes, `would_add` rows | `test/import-engine.test.zsh` ("A6 dry-run exit" / "A6 zero writes" / "A6 would_add row") |
| A7 | Team `PUT` never precedes org membership | `test/import-engine.test.zsh` ("A7: org PUT must precede team PUT") |
| A8 | Injected secondary rate limit mid-batch → backs off, resumes, completes | `test/api.test.zsh` ("rate-limited then success" — labeled `A8 core` only in a source comment, not the assert text) |

## Reports

Every `import` run — including `--dry-run` — writes to `${GHW_STATE_DIR}/reports/<job_id>/`, where `job_id` is `<UTC-ish local timestamp>-<org>[-<team>]` (e.g. `20260729T140512-INVENCO-GROUP-ai-workbench-ppna`).

| File | Content |
|---|---|
| `report.csv` | Header `login,phase,status,state,role,detail`, one row per login per phase touched |
| `report.json` | The same rows, converted from the CSV by `ghw_report_finish` |
| `summary.txt` | Before → after org (and team, if targeted) counts |

**`status` values and what each means for the operator:**

| `status` | Phase(s) it appears in | Meaning | Operator action |
|---|---|---|---|
| `added` | `org`, `team` | `PUT` succeeded | None |
| `skipped` | `org`, `team` | Already a member — the set-difference safety mechanism at work | None; this is success, not a no-op error |
| `not_found` | `org`, `team` | Login doesn't exist on GitHub (404 on the `PUT`) | Fix the source data (typo, deleted/deactivated account) |
| `failed` | `org`, `team`, `verify` | A write returned a non-2xx, non-404 status; or a post-write verify read failed or found the login missing from live state | Investigate the `detail` column (HTTP status + API message), re-run — the engine is idempotent |
| `would_add` | `org`, `team` | `--dry-run` only — this is what a real run would add | None; run for real when ready |

Illustrative excerpt (constructed from the code's row format — the header and field order are exact, and the `not_found` detail below is the literal string `lib/import-engine.zsh` emits for that case; the rest of the data is illustrative, adapted from a real import the origin spec documents, not a live capture):

```
login,phase,status,state,role,detail
Alexis-Freitez_vnt,org,added,active,member,
Frank-Cohee_vnt,team,added,active,maintainer,org owner auto-elevated
Kiran1-Kumar_vnt,org,not_found,,,account does not exist on github.com
leo-pronzolino_vnt,team,skipped,active,maintainer,already a member
```

`detail` carries a `"org owner auto-elevated"` note (not an error) when GitHub auto-promotes an existing org Owner added to a team — the verify pass asserts membership, not role equality, so this never surfaces as a failure. Note the unquoted `not_found` detail field above: `_ghw_csv_field` (`lib/report.zsh`) quotes a field only when it contains a comma or a double-quote, and this message has neither — a field with either would appear double-quoted, with embedded quotes doubled (`""`).

**Retention:** reports are never deleted. `lib/report.zsh` only ever creates and appends; nothing in this daemon prunes `${GHW_STATE_DIR}/reports/`.

## Error and refusal reference

| Code | Cause | Exit | Operator fix |
|---|---|---:|---|
| `AUTH_INVALID` | `GET /user` failed, or the authenticated login doesn't match the profile's configured `login` | 5 | Check the token/`$GHW_TOKEN_ENV_NAME`; re-run `gh auth login --hostname github.com --user <login>` for the right account |
| `SCOPE_MISSING` | Classic PAT's `x-oauth-scopes` header lacks `admin:org` | 5 | `gh auth refresh -h github.com -s admin:org --user <login>`, or re-issue a fine-grained PAT with **Organization Members: read & write** |
| `NOT_ORG_ADMIN` | Caller's role in the target org isn't `admin` | 5 | Get org-admin granted on that org, or use the account that already has it |
| `ORG_NOT_FOUND` | `GET /orgs/{org}` failed — org doesn't exist or isn't visible to the token | 5 | Check the org name/casing; confirm the resolved account actually has access |
| `TEAM_NOT_FOUND` | `GET /orgs/{org}/teams/{team}` failed — team slug doesn't exist | 5 | Verify the exact team slug (not display name) via the GitHub UI or `ghw members` |
| `SOURCE_INVALID` | CSV missing, contains quoted fields, missing the requested `--column`, or has zero non-empty logins | 6 | Fix the CSV (plain, no quotes), check `--column`, ensure at least one row |
| `MEMBER_LIST_READ_FAILED` | A pre-write org/team member-list read failed or didn't parse, or the authenticated login was absent from a just-read org member list (truncated-read guard) | 1 | Re-run — usually transient (network, 5xx, rate limit); if persistent, check the read scope |
| `ACCOUNT_MISMATCH` | Target org/owner belongs to a different profile than `--account`, or to no profile at all | 2 | Rerun with the named `--account`, omit `--account` to auto-resolve, or add the org to `config/accounts.json` |
| `ACCOUNT_OVERLAP` | The same org/`user_namespace` is listed under more than one profile in `config/accounts.json` (case-insensitive) | 2 (resolution) / 1 (`doctor`, both modes) | Remove the duplicate entry from `config/accounts.json` |

## Configuration reference

### `config/accounts.json` schema

```json
{
  "profiles": {
    "<profile-name>": {
      "token_env": "GHW_TOKEN_...",
      "login": "<github-login>",
      "user_namespace": "<github-login-or-omit>",
      "orgs": ["Org1", "Org2", "..."]
    }
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `token_env` | yes | Name of the env var checked as the credential fallback for this profile |
| `login` | yes | Expected GitHub login for this profile — every `GET /user` result is checked against this |
| `user_namespace` | no | This profile's own GitHub user namespace. Resolves like an entry in `orgs[]` for target matching (`ghw mirror amit-t/some-repo`), but `ghw doctor` prints it as `user <login>: own namespace` instead of probing it as an org (which would 404). A missing key is treated as absent, never as the literal string `"null"` |
| `orgs` | yes (may be `[]`) | Every org this profile administers or is a member of; used for both air-gap matching and `ghw doctor`'s per-org role table |

See [`docs/ACCOUNTS.md`](docs/ACCOUNTS.md) for the real values and rationale.

### Environment variables

| Var | Default | Purpose |
|---|---|---|
| `GHW_TOKEN_PERSONAL` / `GHW_TOKEN_INV` | unset | Credential fallback per profile's `token_env`; used when `gh` isn't available or its keyring has no token for that login. Read via the profile's `token_env` name in `config/accounts.json`, not hardcoded |
| `GHW_LAUNCHER` | `co` | Agent launcher for `mirror`/`import`, resolved inside `zsh -ic` so interactive functions/aliases work (unless `--script` or `GHW_DRY_LAUNCH`) |
| `GHW_STATE_DIR` | `~/.local/state/github-warden` | Root for `reports/<job_id>/` |
| `GHW_API_ROOT` | `https://api.github.com` | GitHub API base URL |
| `GHW_DRY_LAUNCH` | unset | If set (non-empty), `mirror`/`import` print the assembled agent prompt instead of launching it |
| `GHW_GH` *(test-only knob)* | `gh` | Override the `gh` binary/command used for token resolution; production use is rare (pinning a specific `gh` path), primary use is pointing tests at `test/fixtures/gh-stub.zsh` |
| `GHW_CURL` *(test-only knob)* | `curl` | Override the curl binary used by `ghw_api`; tests point this at `test/fixtures/curl-stub.zsh` |
| `GHW_SLEEP` *(test-only knob)* | `sleep` | Override the sleep command used in rate-limit backoff; tests stub this to avoid real waits |
| `GHW_ACCOUNTS_FILE` *(test-only knob)* | `${daemon_dir}/config/accounts.json` | Override the accounts file path; tests point this at fixture JSON to exercise air-gap/overlap scenarios without touching the real config |

## Testing

```zsh
zsh claude/github-warden/test/run.zsh
```

Current: **11 test files, 243 assertions, all passing.** Each file is independently runnable (`zsh claude/github-warden/test/<name>.test.zsh`); `run.zsh` runs all of them and fails if any file fails.

Two fetch-succeeded-but-parse-failed guards (`lib/status.zsh`'s two `jq 'length'` parses, `lib/members.zsh`'s teams-slug `jq -r '.[].slug'` parse) got a named stderr message but no dedicated fixture: `ghw_api_paged` already validates its own output is a well-formed JSON array before returning success (proven by `api.test.zsh`'s existing "malformed page body" case, which shows a non-array 200 body makes `ghw_api_paged` itself fail — the *read*-failure guard one line above the parse, not the parse guard). Reaching the parse-failure branch specifically would need `ghw_api_paged` to succeed with data no real GitHub response shape produces; constructing that through the stub was judged contrived rather than a genuine regression scenario.

**Stub architecture — hermetic by design, no live network in tests:**
- `test/fixtures/curl-stub.zsh` — a fake `curl` that understands the exact arg layout `ghw_api` emits (`-sS -X METHOD -H ... -D hdrfile -o bodyfile -w %{http_code}`), routes requests via `$GHW_STUB_ROUTES`, and logs every call to `$GHW_STUB_LOG` so tests can assert exactly what was (or wasn't) sent — including asserting the **absence** of a `PUT`, which is how A1/A2/A3/A6 are proven.
- `test/fixtures/gh-stub.zsh` — a fake `gh` that understands `auth token --user <login>`, returns `$GHW_GH_STUB_TOKEN` (empty by default, forcing the env-var fallback path most tests exercise), and logs invocations to `$GHW_GH_STUB_LOG`.
- Both are wired in via `GHW_GH`/`GHW_CURL` env overrides, so the real `gh` and `curl` binaries are never invoked during the suite.

**What each file covers:**

| File | Assertions | Covers |
|---|---:|---|
| `airgap.test.zsh` | 39 | Cross-account guard, `user_namespace` resolution, config-overlap invariant, case-insensitive target matching |
| `api.test.zsh` | 19 | `ghw_api`: happy path, plain 403, 404, secondary rate-limit retry (A8), a second consecutive secondary-limit retry proving the captured body stays uncorrupted, pagination, malformed-body failure |
| `audit-stale.test.zsh` | 25 | `audit` drift detection, `stale` candidate ranking, a loop-body-local regression guard on the stale report output, a masked-pipe regression guard on the org repo-list read (`audit`), a silent-failure regression guard on the org repo-list read (`stale`), a per-repo unreadable-skip regression guard proving a failed repo detail fetch is named, excluded from the audited count, and doesn't stop other repos' drift from being reported |
| `auth-resolve.test.zsh` | 24 | Profile resolution (explicit/org-map/unmapped/unknown), token source precedence (gh keyring → env fallback → failure) |
| `doctor.test.zsh` | 23 | Credential health reporting, `--strict` vs non-strict exit semantics, overlap always failing both modes, a loop-body-local regression guard across two profiles both carrying a `user_namespace` |
| `ghw-cli.test.zsh` | 8 | Top-level dispatch: help, missing command, unknown command, `--account` with no value |
| `import-engine.test.zsh` | 24 | A1–A7 acceptance behaviors, guarded pre-write reads, case-insensitive membership matching |
| `launch.test.zsh` | 24 | Dry-launch prompt assembly, target normalization (SSH/HTTPS forms), `--script` mode, trailing-flag hang guards |
| `precheck.test.zsh` | 10 | P1–P5 precondition gate, each failure mode |
| `report.test.zsh` | 15 | CSV column parsing, quoted-field refusal, dedup, missing-column/empty-source failures |
| `status-members.test.zsh` | 32 | `status` and `members` read paths, masked-pipe regression guards on the org members/teams reads (`status`) and the org teams / per-team members reads (`members`), plus silent-failure regression guards on the remaining four `members` reads (org members, org admins, org 2FA-disabled, outside collaborators) — every case proving no CSV is written on a failed fetch |

`api.test.zsh`'s malformed-body test prints a `jq: error (...) cannot be added` line to stderr during the run — that's expected noise from the test asserting the engine fails closed on a non-array API body, not a broken test.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| A command exits 2 immediately with `NOT_ORG_ADMIN` or `AUTH_INVALID` on an org you know you're a member of | You're a **member**, not an **admin**, of that org — `ghw doctor` shows this as `role=member` and lists it under `member-only`. Mutating commands correctly refuse there; read-only commands (`status`, `audit`, `stale`, `members`) still work |
| Import row shows `not_found` for a login that "should" exist in an EMU org | EMU logins are enterprise-scoped — a login not provisioned in that specific enterprise 404s on the membership `PUT` even if the underlying GitHub account is real. Fix the source data or provision the account in the enterprise first |
| `SCOPE_MISSING` on a token you just minted | Classic PATs need `admin:org` explicitly; fine-grained PATs need **Organization Members: read & write** and send no `x-oauth-scopes` header, so `NOT_ORG_ADMIN` (P3, the real authority for fine-grained PATs) is what actually surfaces instead |
| `ghw: no credential available for profile '<profile>'` | Neither the `gh` keyring nor the env-var fallback produced a token. Run `gh auth login --hostname github.com` as that profile's login, or export the profile's `token_env` var |
| Running from cron/CI with no interactive `gh` session | Use the env-var fallback: export `GHW_TOKEN_PERSONAL`/`GHW_TOKEN_INV` in the job's environment. `ghw_token_for` falls back to it automatically whenever `gh` is missing or its keyring has nothing for that login |
| `ghw status` (no flags at all) exits 2 with "cannot resolve account" | `status`'s org-optional default only engages with an explicit `--account`; bare `ghw status` has neither an org nor an account to resolve from. Use `ghw --account <profile> status` or pass `--org` |

## Backlog (not built in v1)

`offboard` (remove a user from all orgs/teams/repos, confirm-gated), `team-sync` (declarative team membership), webhook/deploy-key audit, secret-scanning alert report, Actions-permissions audit, topics/license normalization, label sync, CODEOWNERS audit, invite cleanup, repo transfer helper.
