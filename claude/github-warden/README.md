# github-warden (`ghw`)

GitHub org/repo management daemon for Amit's two **air-gapped** accounts: **personal** (login `amit-t`, owns his personal orgs plus his own user namespace `amit-t`) and **inv** (login `amit-tiwari_vnt`, the Invenco VNT account, administers all Invenco orgs — `INVENCO-GROUP`, `Invenco-Cloud-Systems-ICS`, etc.). These two identities never share credentials or targets; see "Safety (account air-gap)" below. Runtime shape mirrors `dag` (devin-acu-governor): read-only commands run as pure zsh/curl/jq with no agent involved; mutating flows (`mirror`, `import`) launch a `clscb` playbook whose writes go only through deterministic `lib/` engine scripts. Admin access is verified fresh on every run, before any write — the daemon never trusts a cached auth state.

## One-time setup

1. `config/accounts.json` ships with real `login`/`orgs` values for both profiles, captured from `gh api user` (and `gh api user/orgs`) while authenticated as each account.
2. Run `gh auth login --hostname github.com` once per account (personal, then inv) so the `gh` CLI keyring holds a token for each `login`. This is the **primary** credential source — `ghw_token_for` runs `gh auth token --user <login>` per profile, so no PAT needs to be minted or exported day to day.
   - Fallback: exporting `GHW_TOKEN_PERSONAL` / `GHW_TOKEN_INV` still works if `gh` isn't on `PATH` or its keyring has no token for that login. Tokens are never read from anywhere else: not committed, not logged, not echoed into reports.
   - SSH keys are configured for both accounts for git operations (clone/push); the GitHub API always goes over the resolved token (`GH_TOKEN`/`GITHUB_TOKEN`), never SSH.
3. Run `ghw doctor` to verify: token present (and which source produced it), login matches profile, air-gap invariant (no org/user_namespace shared across profiles), and org-admin role for every configured org, per profile. Plain `doctor` exits 0 once credentials + air-gap are healthy (member-only orgs are informational); `ghw doctor --strict` additionally requires admin on every listed org and exits 1 otherwise.
4. `personal`'s current `gh` token lacks the `admin:org` scope, so mutating org commands (`import`) against personal orgs need a re-login with that scope first: `gh auth refresh -h github.com -s admin:org --user amit-t`. Read-only commands (`status`, `audit`, `stale`, `members`, `doctor`) work as-is.

## Safety (account air-gap)

Amit's two GitHub identities must never spill rights onto each other. This is a first-class safety property, peer to the import engine's never-PUT-existing-member rule:

- Every target org/owner belongs to exactly one profile, matched against that profile's `orgs[]` or its `user_namespace` (§ below). `--account` selects a **credential**, not a bypass: if the resolved target belongs to a different profile than the one named by `--account`, `ghw_resolve_profile` (`lib/auth.zsh`) refuses **locally, before any network call** — the wrong token never leaves the machine. `ghw --account personal status --org INVENCO-GROUP` fails with `ACCOUNT_MISMATCH` and exit 2, naming the owning profile and the exact `--account` to rerun with.
- A target mapped to no profile at all also fails with `ACCOUNT_MISMATCH`, naming `config/accounts.json` as the fix.
- `--account` with no target (e.g. `ghw --account inv doctor`) is unaffected — the guard only engages when a target is present to check.
- `user_namespace`: an optional per-profile field in `config/accounts.json` naming a profile's own GitHub user namespace (e.g. personal's `amit-t`, inv's `amit-tiwari_vnt`). It resolves like an entry in `orgs[]` (for `ghw mirror amit-t/some-repo`, for instance) but is never probed as an org — `ghw doctor` prints it as `user <login>: own namespace` instead of issuing a bogus `GET /orgs/<namespace>/memberships/<login>` that 404s. A missing `user_namespace` key is treated as absent, never as the literal string `"null"`.
- Config invariant: no org or user_namespace may appear under more than one profile. `ghw_check_airgap` (`lib/auth.zsh`) enforces this with a cheap jq pass before any resolution — every command inherits the check via `ghw_resolve_profile`, and `ghw doctor` surfaces it too. A violation prints `ACCOUNT_OVERLAP: '<name>' is listed under profiles <a> and <b> — accounts must be air-gapped.` and fails (exit 2 from resolution, doctor always fails in both `--strict` and non-strict modes).

## Commands

| Command | Mutates | Runtime |
|---|---:|---|
| `ghw mirror <repo\|url>` (or bare inside a repo — infers ref from `origin`) | ✅ | clscb playbook seeded with gh-repo-mirror skill, resolved profile, target arg; agent interviews and drives `mirror-repo.zsh`. `--script` bypasses the agent: `mirror-repo.zsh` direct with config-preset defaults, fails on missing input |
| `ghw import --org X [--team y] --csv f [--column login] [--role member\|maintainer] [--org-role member] [--dry-run]` | ✅ | clscb playbook narrates, judges edge rows, and reports; **every write goes through `lib/import-engine.zsh`** — algorithm in code, not prompt |
| `ghw doctor [--strict]` | ❌ | local zsh — every profile: token auth, scopes, air-gap invariant, admin role per listed org; named pass/fail table. Exits 0 once credentials + air-gap are healthy (org-admin role is informational). `--strict` additionally requires admin on every listed org and exits 1 otherwise. An air-gap/overlap violation always fails, in both modes |
| `ghw status [--org X]` (`--account` is a global selector that precedes the command: `ghw --account a status`) | ❌ | local zsh — org overview: repo counts, member/team counts, visibility split, plan/seat basics |
| `ghw audit --org X --ref owner/repo` | ❌ | local zsh — every repo vs reference: general settings, security-and-analysis flags, classic branch protection on default branch; drift table, read-only |
| `ghw stale --org X [--months N]` (default 6) | ❌ | local zsh — repos with no push/PR/issue activity in N months, empty repos, fork clutter; ranked report, prints archive commands, executes nothing |
| `ghw members --org X [--csv out] [--json]` | ❌ | local zsh — members, org roles, team matrix, 2FA-disabled flags, outside collaborators; CSV output round-trips into `ghw import` |

`--script` on `mirror`/`import` bypasses the agent entirely: `import --script` runs `lib/import-engine.zsh` directly; `mirror --script` runs `mirror-repo.zsh` with `GH_TOKEN`/`GITHUB_TOKEN` exported. `GHW_DRY_LAUNCH=1` prints the assembled agent prompt instead of launching it.

## Safety (import engine)

`lib/import-engine.zsh` is the only code path that writes memberships. It implements the org-import spec verbatim:

- Read-then-diff-then-write: parse+dedupe source → page current org members → page current team members → per-phase **set-difference** → serial PUTs → re-read live state and assert `logins ⊆ members`. Reports assert server state, not 2xx responses.
- **Never PUTs a membership for an existing member** — both membership endpoints are upserts that would silently demote an existing Owner or maintainer. The set-difference is the safety mechanism; promotion/demotion is out of scope.
- Add-only: no removals, no role changes, no team/org creation.
- Phase ordering: org-membership adds complete fully before team adds begin.
- Login matching is case-insensitive throughout.
- Writes are serial (one in flight at a time).
- If the pre-write member-list read fails or can't be parsed, the engine aborts with `MEMBER_LIST_READ_FAILED` rather than writing against a possibly-truncated read.

### Precondition codes

The precheck gate (`lib/auth.zsh`) runs before any mutating command, all-or-nothing:

| Code | Meaning |
|---|---|
| P1 `AUTH_INVALID` | `GET /user` fails, or authenticated login ≠ profile's configured `login` |
| P2 `SCOPE_MISSING` | classic PAT missing `admin:org` in `x-oauth-scopes`; fine-grained PATs are checked via a targeted probe call instead |
| P3 `NOT_ORG_ADMIN` | caller's role in the target org is not `admin` |
| P4 `ORG_NOT_FOUND` | target org doesn't exist / isn't visible to the token |
| P5 `TEAM_NOT_FOUND` | target team slug doesn't exist in the org |
| P6 `SOURCE_INVALID` | import CSV missing, missing the requested column, or a row has an empty login (duplicate logins are deduped with a stderr warning, not rejected) |

`ghw` never attempts to self-elevate scope or auth — every precondition failure prints remediation for a human and exits without writing.

## Reports

Every `import` run (including `--dry-run`) writes to `~/.local/state/github-warden/reports/<job_id>/`:

- `report.csv` — per-login rows: `login,phase,status,state,role,detail`
- `report.json` — the same rows as JSON
- `summary.txt` — before/after org and team counts

Reports are never deleted.

## Environment

| Var | Purpose |
|---|---|
| `GHW_TOKEN_PERSONAL` / `GHW_TOKEN_INV` | credentials per `config/accounts.json` profile (optional fallback — primary source is `gh auth token --user <login>`) |
| `GHW_LAUNCHER` | agent launcher for `mirror`/`import` (default `clscb`) |
| `GHW_STATE_DIR` | reports/state dir (default `~/.local/state/github-warden`) |
| `GHW_API_ROOT` | GitHub API base URL (default `https://api.github.com`) |
| `GHW_DRY_LAUNCH` | if set, prints the assembled agent prompt instead of launching it |

## Verification

```zsh
zsh claude/github-warden/test/run.zsh
```

## Backlog (not built in v1)

`offboard` (remove a user from all orgs/teams/repos, confirm-gated), `team-sync` (declarative team membership), webhook/deploy-key audit, secret-scanning alert report, Actions-permissions audit, topics/license normalization, label sync, CODEOWNERS audit, invite cleanup, repo transfer helper.
