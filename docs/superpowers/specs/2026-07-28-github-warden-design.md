# github-warden (`ghw`) — Design Spec

Date: 2026-07-28
Status: approved (brainstorm 2026-07-28)
Derives from: `/Users/amittiwari/Projects/Invenco/DoE/github-org-mgmt/SPEC-org-import-daemon.md` (org-import spec, referenced below as "import spec"), `dag` (devin-acu-governor) runtime pattern, `~/.claude/skills/gh-repo-mirror`.

## Purpose

GitHub org/repo management daemon for Amit's two accounts — **personal** and **inv** (Invenco; includes EMU org `INVENCO-GROUP` and `Invenco-Cloud-Systems-ICS`). Deterministic zsh + GitHub API core, Claude-agent playbooks for agent-shaped work, admin access verified on every run before any write.

Runtime shape mirrors `dag`: zsh CLI entrypoint, local read-only commands run pure zsh/curl/jq with no agent; mutating flows launch `clscb` playbooks whose writes go through deterministic engine scripts with explicit gates.

## Layout

```
claude/github-warden/
├── bin/ghw                    # zsh entrypoint, subcommand dispatch
├── lib/
│   ├── auth.zsh               # profile resolution + precondition gate (P1–P6)
│   ├── api.zsh                # curl wrapper: pagination, rate-limit backoff, serial writes
│   ├── import-engine.zsh      # import spec §4 algorithm — the only code path that writes memberships
│   ├── report.zsh             # CSV/JSON report emit + retention
│   ├── audit.zsh              # settings/protection drift diff
│   └── (status/stale/members helpers)
├── playbooks/
│   ├── _common.md             # policy injected into every ghw agent session
│   ├── mirror.md              # drives gh-repo-mirror skill/script
│   └── import.md              # narrates/judges; delegates writes to import-engine.zsh
├── config/
│   └── accounts.json          # committed, secret-free profile map (see Auth)
├── test/                      # dag-style harness, *.test.zsh, fixtures/ (stubbed curl)
└── README.md
```

Global exposure: `ghw` wrapper added to repo `aliases.zsh`; root `README.md` gains a github-warden row. All shell is zsh (`#!/usr/bin/env zsh`, `zsh -n` validated, no shellcheck).

## Auth

Profiles in `config/accounts.json`:

```json
{
  "profiles": {
    "personal": { "token_env": "GHW_TOKEN_PERSONAL", "login": "amit-t",         "user_namespace": "amit-t",         "orgs": ["..."] },
    "inv":      { "token_env": "GHW_TOKEN_INV",      "login": "amit-tiwari_vnt", "user_namespace": "amit-tiwari_vnt", "orgs": ["INVENCO-GROUP", "Invenco-Cloud-Systems-ICS"] }
  }
}
```

Amit's actual split: `personal` (login `amit-t`) owns his personal orgs plus his own user namespace `amit-t`; `inv` (login `amit-tiwari_vnt`, the Invenco VNT account) administers all Invenco orgs (`INVENCO-GROUP`, EMU, etc.). (`orgs` values above are illustrative; real values captured from `GET /user` and `GET /user/orgs` during first `ghw doctor` setup, per profile.)

- `user_namespace` (optional, per profile): a profile's own GitHub user namespace. Resolves like an entry in `orgs[]` (e.g. `ghw mirror amit-t/some-repo`), but is never probed as an org by `ghw doctor` — it prints `user <login>: own namespace` instead of a `GET /orgs/<namespace>/memberships/<login>` probe that 404s. A missing `user_namespace` key is absent, never the literal string `"null"`.
- Resolution order: explicit `--account personal|inv` → target org/owner matched against `orgs[]` **or** `user_namespace` → hard fail with the org list printed. Never guesses.
- **Account air-gap (safety property, peer to the import engine's never-PUT-existing-member rule):** Amit's two identities never share credentials or targets. `--account` selects a credential, not a bypass — it cannot override org ownership. When both an explicit `--account` and a target are given, `ghw_resolve_profile` verifies the target belongs to that profile *before any network call*:
  - Owned by a different profile → `ACCOUNT_MISMATCH: '<target>' belongs to profile '<owner>', not '<explicit>'. ghw keeps accounts air-gapped — rerun with --account <owner> or omit --account.` (exit 2).
  - Owned by no profile → `ACCOUNT_MISMATCH: '<target>' is not mapped to profile '<explicit>' (or any profile). Add it to config/accounts.json.` (exit 2).
  - `--account` with no target is unaffected.
  - Config invariant: no org or `user_namespace` may appear under more than one profile. `ghw_check_airgap` (`lib/auth.zsh`) enforces this with a cheap jq pass, called from `ghw_resolve_profile` before any matching so every command inherits it, and surfaced by `ghw doctor`. Violation: `ACCOUNT_OVERLAP: '<name>' is listed under profiles <a> and <b> — accounts must be air-gapped.` (exit 2).
- Token source order (`ghw_token_for` in `lib/auth.zsh`), per resolved profile:
  1. `gh` keyring, primary: if `gh` is on `PATH`, `gh auth token --user <profile login>`. One-time setup is `gh auth login --hostname github.com` per account — no PAT to mint or rotate by hand.
  2. Env var fallback: the profile's `token_env` (`GHW_TOKEN_PERSONAL` / `GHW_TOKEN_INV`), used when `gh` is absent or its keyring has no token for that login.
  3. Neither present → hard fail naming both remediations (`gh auth login --hostname github.com` and `export <VARNAME>=<token>`); ghw never self-elevates or guesses.
  The token is never printed or logged; `ghw doctor` reports which source each profile resolved from (`gh:<login>` or `env:<VAR>`), never the token value.
  SSH keys are configured for both accounts for git clone/push; the GitHub API always uses the resolved token, never SSH.
- Precondition gate (`lib/auth.zsh`) runs before any mutating command, all-or-nothing, each failure named:
  - P1 `AUTH_INVALID` — `GET /user` fails or login ≠ profile `login`.
  - P2 `SCOPE_MISSING` — classic PAT: `x-oauth-scopes` lacks required scope; fine-grained PAT (no header): targeted probe call. Daemon never attempts to acquire scope; prints remediation for a human.
  - P3 `NOT_ORG_ADMIN` — `GET /orgs/{org}/memberships/{me}` role ≠ `admin`.
  - P4 `ORG_NOT_FOUND`, P5 `TEAM_NOT_FOUND`, P6 `SOURCE_INVALID` — per import spec §3.
- `ghw doctor` exit semantics: exits 0 once every profile's credential health is good (token resolved, login matches, scopes OK) and the air-gap invariant holds — org-admin role is informational (member-only on someone else's org isn't actionable and shouldn't turn a permanently-red `doctor && ...` gate). `ghw doctor --strict` additionally requires admin on every listed org, exiting 1 otherwise. An air-gap/overlap violation always fails doctor, in both modes.

## Commands (v1)

| Command | Mutates | Runtime |
|---|---:|---|
| `ghw mirror <repo\|url>` (or bare inside a repo — infers ref from `origin`) | ✅ | clscb playbook seeded with gh-repo-mirror skill, resolved profile, target arg; agent interviews and drives `mirror-repo.zsh`. `--script` bypasses the agent: `mirror-repo.zsh` direct with config-preset defaults, fails on missing input |
| `ghw import --org X [--team y] --csv f [--column login] [--role member\|maintainer] [--org-role member] [--dry-run]` | ✅ | clscb playbook narrates, judges edge rows, and reports; **every write goes through `lib/import-engine.zsh`** — algorithm in code, not prompt |
| `ghw doctor [--strict]` | ❌ | local zsh — every profile: token auth, scopes, air-gap invariant, admin role per listed org; named pass/fail table. Exits 0 on healthy credentials + air-gap; `--strict` additionally requires admin on every org |
| `ghw status [--org X]` (`--account` is a global selector that precedes the command: `ghw --account a status`) | ❌ | local zsh — org overview: repo counts, member/team counts, visibility split, plan/seat basics |
| `ghw audit --org X --ref owner/repo` | ❌ | local zsh — every repo vs reference: general settings, security-and-analysis flags, classic branch protection on default branch; drift table, read-only |
| `ghw stale --org X [--months N]` (default 6) | ❌ | local zsh — repos with no push/PR/issue activity in N months, empty repos, fork clutter; ranked report, prints archive commands, executes nothing |
| `ghw members --org X [--csv out] [--json]` | ❌ | local zsh — members, org roles, team matrix, 2FA-disabled flags, outside collaborators; CSV output round-trips into `ghw import` |

## Import engine

Implements the import spec verbatim; deltas from that spec here are interface-level only (CLI flags instead of HTTP jobs — the `POST /jobs` surface is dropped, job semantics kept).

- Read-then-diff-then-write (§4): parse+dedupe source → page current org members → page current team members → set-difference → serial PUTs → **re-read live state and assert `logins ⊆ members`** — report asserts server state, not 2xx responses.
- Phase order (§4.1): org adds complete fully before team adds begin.
- Safety rule (§4.2), non-negotiable: **never PUT a membership for an existing member** — both endpoints are upserts that silently demote Owners/maintainers. Set-difference is the safety mechanism. Promotion is out of scope.
- EMU (§5): org adds may return `state:"active"` immediately (no invite flow); `pending` on non-EMU orgs is recorded, not failed. Nonexistent enterprise logins 404.
- Errors (§6): per-login 404 → `not_found`, continue. Primary rate limit → sleep to `x-ratelimit-reset`. Secondary 403 → honor `retry-after`, else backoff 1s→60s, 5 attempts. 5xx/network → 3 retries then `failed`, continue. Writes serial, one in flight.
- Auto-elevation (§7): org owners land as team `maintainer` regardless of requested role — reported as `note`, verify pass asserts membership, not role equality.
- Report (§8): per-login CSV/JSON (`added|skipped|not_found|failed|would_add`) + before/after org and team counts. Persisted under `~/.local/state/github-warden/reports/<job_id>/`, never deleted.
- `--dry-run`: steps 1–5 only, `would_add` report, zero writes.
- Non-goals (§10): no removals, no role changes, no team/org creation, no source-data repair.

## Testing

- dag-pattern zsh harness with stubbed `curl` fixtures; no live API in tests.
- Import spec acceptance tests A1–A8 as the regression suite: idempotent re-run (0 writes), existing Owner untouched, existing maintainer untouched, 404 login continues batch, missing scope refuses with zero writes, dry-run zero writes, phase ordering, secondary-rate-limit backoff/resume.
- `zsh -n` on every `.zsh` file; auth-resolution and audit-diff unit tests.

## Backlog (documented in README, not built in v1)

`offboard` (remove a user from all orgs/teams/repos, confirm-gated — the deliberate counterpart to add-only import), `team-sync` (declarative team membership), webhook + deploy-key audit, secret-scanning alert report, Actions-permissions audit, topics/license normalization, label sync, CODEOWNERS audit, pending-invite cleanup, repo transfer helper.

## Out of scope (v1)

HTTP job surface from the import spec; any member removal or role mutation; auto-archiving from `stale`.
