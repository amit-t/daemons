# Account model

`ghw` operates two GitHub identities on Amit's behalf. This document is the account model in depth — the profiles, what each administers, the air-gap rule and why it exists, how a target resolves to a profile, and how to safely extend the config. See [`../README.md`](../README.md) for the daemon's full command reference and error table, and [`RUNBOOK-org-import.md`](RUNBOOK-org-import.md) for the operational import workflow.

## The two identities

Defined in `config/accounts.json`, one entry under `profiles` per identity:

### `personal` — login `amit-t`

Amit's own GitHub identity. Administers his personal orgs plus his own user namespace (`amit-t`).

Orgs (`config/accounts.json` → `profiles.personal.orgs`):

```
AppIncubatorHQ, babble-club, bharat-innovation-olympiad, BrightBytesHub, eternals-tech,
EverPlanHQ, EverPlanHQ-Dep, FlyingPenguinsInd, Hiplogik, iamamittiwari, IntelliBuilds,
KommonSchool, MilkyWaayy, nagpurtechies, perspectiv91, Quiet-Realist, RefineryInc,
Swapaholic, untox-labs, Zippy-Tech
```

Per the most recent `ghw doctor --strict` capture, admin on 19 of these 20; `nagpurtechies` is member-only (informational, not a failure for plain `ghw doctor`).

### `inv` — login `amit-tiwari_vnt`

The Invenco VNT account. Administers every Invenco org, including the `INVENCO-GROUP` EMU (Enterprise Managed Users) org.

Orgs (`config/accounts.json` → `profiles.inv.orgs`):

```
INVENCO-GROUP, Invenco-Cloud-Systems-ICS, inv-cloud-platform, Invenco-Group-Limited,
Invenco-Platform-Software, Invenco-Test-Practice-ITP
```

Per the most recent `ghw doctor --strict` capture, admin on 3 of these 6; `inv-cloud-platform`, `Invenco-Platform-Software`, and `Invenco-Test-Practice-ITP` are member-only.

Both accounts are already `gh auth login`'d with `admin:org`, and SSH keys are configured for both for git operations (`ghw mirror` clone/push). The GitHub API always goes over the resolved token, never SSH — see [README § One-time setup](../README.md#one-time-setup).

## The air-gap rule — in Amit's words

> Personal orgs are administered by `amit-t`; all Invenco orgs go through the VNT account. They must never spill rights onto each other.

This is a first-class safety property, peer to the import engine's never-PUT-existing-member rule (see [README § Safety model](../README.md#safety-model)). The concrete risk it prevents: running a command meant for one identity — by habit, typo, or a stale `--account` left over from a previous command in the same shell session — against an org that belongs to the other identity, using the wrong credential and the wrong blast radius.

The rule is enforced structurally, not by convention: `ghw_resolve_profile` (`lib/auth.zsh`) checks target ownership **before any network call**, so a mismatched `--account` never even gets the chance to send the wrong token to GitHub.

## How resolution picks a profile

`ghw_resolve_profile` (`lib/auth.zsh`), called by every command before it touches the network:

1. **Config invariant check first.** `ghw_check_airgap` runs a jq pass over `config/accounts.json` confirming no org or `user_namespace` is listed under more than one profile (case-insensitively). A violation fails resolution immediately (`ACCOUNT_OVERLAP`, exit 2) — this runs even for commands with no target at all.
2. **Explicit `--account <profile>` given?**
   - If a target org/owner is also present, it must belong to that exact profile (or to no profile — see step 4) — otherwise `ACCOUNT_MISMATCH`, exit 2, naming the actual owning profile.
   - If there's no target (e.g. `ghw --account inv doctor`), the explicit profile is used as-is; no ownership check to perform.
3. **No `--account`, target present — auto-map.** The target is matched against every profile's `orgs[]` **or** its `user_namespace` (whichever contains it). Exactly one profile can match (the config invariant in step 1 guarantees this). Match found → that profile is used. GitHub org/user names are case-insensitive, so this match is case-folded internally; the target's original casing is preserved in every message and downstream API call.
4. **No match anywhere** → hard refusal (`ACCOUNT_MISMATCH` if `--account` was given and named a real profile but the target maps to neither it nor anything else; a similar "org not mapped to any profile" message otherwise), exit 2, naming `config/accounts.json` as the fix. `ghw` never guesses and never falls back to a default profile.
5. **Neither `--account` nor a target** → `ghw: cannot resolve account — pass --account or a target org`, exit 2.

### `user_namespace`

An optional per-profile field naming that profile's own GitHub user namespace (e.g. `personal`'s is `amit-t`, `inv`'s is `amit-tiwari_vnt`). It resolves exactly like an entry in `orgs[]` for target-matching purposes — so `ghw mirror amit-t/some-repo` auto-maps to `personal` — but it is **never probed as an org**. `ghw doctor` prints it as `user <login>: own namespace` instead of issuing a `GET /orgs/<namespace>/memberships/<login>` call that would just 404 (user namespaces aren't orgs). A missing `user_namespace` key is treated as absent, never as the literal string `"null"` — a config typo that stringifies `null` would otherwise silently create a phantom matchable target.

## What happens on a cross-account attempt

Captured verbatim from a live run against `INVENCO-GROUP` (owned by `inv`) with `--account personal`:

```
$ ghw --account personal status --org INVENCO-GROUP
ACCOUNT_MISMATCH: 'INVENCO-GROUP' belongs to profile 'inv', not 'personal'. ghw keeps accounts air-gapped — rerun with --account inv or omit --account.
```

And the reverse, against a personal org with `--account inv`:

```
$ ghw --account inv status --org BrightBytesHub
ACCOUNT_MISMATCH: 'BrightBytesHub' belongs to profile 'personal', not 'inv'. ghw keeps accounts air-gapped — rerun with --account personal or omit --account.
```

Both refusals happen **before any GitHub API call** — `ghw_resolve_profile` runs entirely against the local `config/accounts.json`. No token is ever resolved or sent for the wrong profile; `ghw_token_for` isn't even called until resolution succeeds. Exit code is 2 in every case, matching every other usage/config error this daemon emits (contrast with 5, reserved for precondition failures that do require an API call to determine).

## How to add a new org or a third account safely

### Adding an org to an existing profile

1. Confirm the org isn't already listed under the *other* profile — `ghw_check_airgap` will catch it if it is, but check first (`grep -i '"<org>"' config/accounts.json`).
2. Add it to the correct profile's `orgs[]` array in `config/accounts.json`.
3. Run `ghw doctor` — the new org appears in that profile's per-org role table on the next run, with no other changes needed. If the account isn't yet an org member/admin there, it shows up as `role=none` or the appropriate GitHub error, which is informative, not a crash.

### Adding a third account

1. Add a new entry under `profiles` in `config/accounts.json`: a unique `token_env` name, the account's `login`, an optional `user_namespace`, and its `orgs[]`.
2. **No org or `user_namespace` value may overlap with an existing profile's** — `ghw_check_airgap` enforces this on every single command from then on, not just at setup time. If you're splitting an org's administration onto a new identity, remove it from the old profile's `orgs[]` in the same edit.
3. `gh auth login --hostname github.com` as the new account so the `gh` keyring holds its token (or set up its `token_env` var as a fallback).
4. Run `ghw doctor` to confirm the new profile resolves cleanly and the air-gap invariant still holds across all three profiles.

### Member-only orgs

Both profiles' org lists include orgs where the account is a **member**, not an **admin** — `inv-cloud-platform`, `Invenco-Platform-Software`, and `Invenco-Test-Practice-ITP` for `inv`; `nagpurtechies` for `personal`. These are legitimate entries: `ghw doctor` (plain, non-strict) treats them as informational, and `ghw doctor --strict` correctly flags them as not-admin without treating that as a config error.

The important behavior to know: any **mutating** command (`ghw import`) targeting a member-only org will correctly refuse — not at the air-gap layer (the org *is* correctly mapped to the right profile), but at the precondition gate, specifically **P3 `NOT_ORG_ADMIN`** (`ghw_precheck` in `lib/auth.zsh`), exit 5. This is by design: being listed in a profile's `orgs[]` means "this profile's identity is scoped to this org for reads and reporting," not "this profile is authorized to write here." Read-only commands (`status`, `audit`, `stale`, `members`, `doctor`) work fine against member-only orgs; only a write attempt hits `NOT_ORG_ADMIN`.
