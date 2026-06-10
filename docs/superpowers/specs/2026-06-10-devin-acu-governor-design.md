# devin-acu-governor (`dve`) — Design

**Date:** 2026-06-10
**Status:** Approved
**Location:** `claude/devin-acu-governor/`

## Problem

Devin Enterprise (Desktop) bills on a monthly ACU pool — 24,000 ACUs/month here. A mid-month consumption spike nearly caused overages; the stopgap (disabling costlier models team-wide) penalizes everyone. Need terminal tooling to: distribute the pool as per-user caps (prorated mid-month), selectively raise individual caps, report consumption trajectory, and govern model availability.

## Solution shape

Thin zsh launcher + Claude-agent playbooks. `dve <command>` resolves the Devin service key, then execs `clscb` (Claude CLI, full-stack mode) with a playbook prompt embedding the API contract, math scripts, and confirmation gates. The agent performs curls, runs deterministic math via jq, presents plans, and writes only after explicit user confirmation in the interactive session. Extensible: new command = new playbook file.

## API surface (Devin Desktop, researched 2026-06-10)

Base: `https://server.codeium.com`. Team uses **ACU billing strategy** (consumption rows carry `billed_acus`).

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/v1/UsageConfig` | POST | service key in body, Billing Write | Set (`set_add_on_credit_cap` int) or clear (`clear_add_on_credit_cap` bool) per-user cap. Scope: exactly one of `team_level: true` \| `group_id` \| `user_email`. `team_level` applies the cap individually to every member (not shared). 200 + empty body on success. |
| `/api/v1/GetUsageConfig` | POST | key in body, Billing Read | Read cap for team/group/user. Response `{"addOnCreditCap": int}` or `{}` if unset. |
| `/api/v1/GetTeamCreditBalance` | POST | key in body, Billing Read | `promptCreditsPerSeat`, `numSeats`, `addOnCreditsAvailable`, `addOnCreditsUsed`, `billingCycleStart/End` (ISO 8601). Current cycle only. |
| `/api/v2alpha/analytics/consumption` | GET | `Authorization: Bearer <key>`, Analytics Read | Query params: `start_date`/`end_date` (YYYY-MM-DD, ≤90 days), `product=agent` (required), `granularity=daily\|monthly`, `group_by=user,model_uid,ide`, `models`, `group_id`, `user_id`, `page_size` (≤10,000), `page_cursor`. Rows: `user_id`, `user_email`, `model_uid`, `consumption.billed_acus`, `consumption.message_count`. **Rate limit 10 req/hr/team** (pagination exempt); supports `If-None-Match` ETag → 304. |
| `/api/v1/UserPageAnalytics` | POST | key in body, Teams Read-only | Roster: `userTableStats[]` with `name`, `email`, `role`, `activeDays`, `teamStatus`, last-usage timestamps; plus `billingCycleStart/End`. |

**Model gating: no documented API.** Admin Portal UI only ("Models Configuration" — filter by model/provider; "Default Model Override"). Desktop API surface above is complete per docs index.

## Repo layout

```
claude/devin-acu-governor/
├── bin/dve                 # zsh entrypoint: dve <command> [args]
├── lib/
│   ├── key-resolve.zsh     # Keychain → $DEVIN_SERVICE_KEY env → error
│   └── compute-caps.jq     # proration + headroom math
├── playbooks/
│   ├── _common.md          # shared API contract, hard rules, gates
│   ├── set-limits.md
│   ├── boost.md
│   ├── status.md
│   └── models.md
├── environment.env         # DVE_MONTHLY_ACU_POOL=24000; env vars override file
├── test/
└── README.md
```

New top-level `claude/` directory: daemons whose runtime is a Claude agent, parallel to `codex/`. Also updated: root `README.md` (daemon listing), `AGENTS.md` (`claude/` convention), `aliases.zsh` (`dve` entrypoint).

## Runtime flow

```
dve set-limits
 └─ bin/dve: key-resolve (security find-generic-password -s devin-service-key -w
             → $DEVIN_SERVICE_KEY → exit 1 with setup instructions)
 └─ export DEVIN_SERVICE_KEY
 └─ exec clscb "<_common.md + <command>.md + CLI args>"
 └─ interactive Claude session: agent executes playbook, user confirms at gates
```

Hard rules in `_common.md`:
- No mental arithmetic — all cap math through `lib/compute-caps.jq`.
- No write call (`UsageConfig` set/clear) without presenting the full plan and receiving explicit user confirmation.
- Quote exact API error bodies; stop before writes on any read failure.
- Consumption API: reuse ETags, back off on 429, never burn the 10/hr budget on retries.
- Never echo the service key into output or logs.

## Commands

### `dve set-limits`
1. `GetTeamCreditBalance` → cycle start/end.
2. Consumption `group_by=user`, cycle start → today → per-user `billed_acus`.
3. `UserPageAnalytics` → roster (approved members). Present count N; user confirms or overrides.
4. `compute-caps.jq` — **remaining-pool split**: `cap_i = round(consumed_i + (POOL − total_consumed) / N)`. No user instantly blocked; remaining budget split evenly. Day-1 (total_consumed ≈ 0) degenerates to flat `POOL/N` → emit single `team_level: true` call instead of N per-user calls. `POOL` from `DVE_MONTHLY_ACU_POOL`.
5. Preview table (email, consumed, new cap, Σ caps vs POOL) → confirm → `UsageConfig` per `user_email` → spot-verify 5 random users (or all, if N ≤ 5) via `GetUsageConfig`.
6. Write ledger `~/.local/state/devin-acu-governor/allocations.json` (per-user caps, Σ, timestamp, cycle).

### `dve boost <email> <acus>`
Increment + reserve check. `GetUsageConfig(user)` → `new_cap = current + acus` → headroom = `POOL − Σ caps` from ledger (rebuild via per-user `GetUsageConfig` over roster if ledger missing or cycle-stale) → if boost pushes Σ past POOL: explicit overage warning, user confirms knowingly → set → verify → update ledger.

### `dve status`
Balance + consumption (`granularity=daily`) → report: ACUs consumed, remaining, days elapsed/left in cycle, daily run-rate, projected month-end total, **over/under verdict**, top-10 consumers, per-model burn. Read-only — no confirmation gates.

### `dve models <file|inline-list>`
Per-model ACU report (`group_by=model_uid`), diff desired allowlist vs models observed in use, print exact Admin Portal steps to apply. Playbook instructs agent to re-check the docs index for a model-config API each run; if one ships, the command upgrades without redesign.

## Secrets

None in repo. One-time setup (documented in README):
`security add-generic-password -s devin-service-key -a "$USER" -w '<key>'`.
Fallback: `export DEVIN_SERVICE_KEY=...`. Key permissions required: Billing Read + Write, Analytics Read, Teams Read-only.

## Error handling

- Missing key → setup instructions, exit 1 (before any agent launch).
- Unknown command / bad args → usage text, exit 2.
- Partial set-limits failure (call k of N fails) → agent reports applied/failed email lists and offers resume of the failed subset.
- Roster vs consumption mismatch (user with consumption absent from roster) → flagged in preview, included in math, excluded from cap writes unless confirmed.

## Testing

- `zsh -n` parse-check all `.zsh` and `bin/dve`.
- zsh tests (`test/*.zsh`, run via `zsh`): subcommand dispatch, bad-arg exits, key-resolution order (keychain hit, env fallback, both-missing error), playbook prompt assembly (command args present in final prompt; `_common.md` prepended).
- jq golden tests for `compute-caps.jq`: day-1 flat split; mid-month remaining-pool; rounding remainders (Σ caps ≤ POOL); single user; overconsumed pool (remaining ≤ 0 → caps = consumed_i, warn); boost headroom over/under.

## Out of scope

- Automated/scheduled enforcement (cron polling, auto-throttle) — manual runs only this round.
- Devin core API (`api.devin.ai` v2/v3) — different product surface; org-level ACU limits there don't map to per-user caps.
- Model enable/disable via API — does not exist; revisit when documented.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Billing unit | ACU strategy | Confirmed by user; consumption rows use `billed_acus`. |
| Agent vs code | Agent does the work; daemon = launcher + playbooks | User choice; flexibility, conversational gates. |
| Proration | Remaining-pool split | No one instantly blocked mid-month; day-1 degenerates to flat. |
| Boost semantics | Increment + reserve check | Tracks pool exposure; overage requires informed confirm. |
| Key storage | Keychain first, env fallback | User choice; encrypted at rest, simple override. |
| Headcount | Auto-fetch roster, confirm/override | Accurate as team changes; user keeps final say. |
| Command name | `dve` (devin enterprise) | User choice; verified no collision. |
| Placement | `claude/devin-acu-governor/` | User choice; signals Claude-powered runtime. |
