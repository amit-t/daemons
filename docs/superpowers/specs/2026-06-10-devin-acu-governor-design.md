# devin-acu-governor (`dag`) — Design

**Date:** 2026-06-10  
**Updated:** 2026-06-11 for Cognizant Local Agent ACU-limit API  
**Status:** Approved, implemented in `claude/devin-acu-governor/`

## Problem

Devin Enterprise Local Agent usage can burn through a monthly ACU pool. The team needs terminal tooling that discovers engineer user IDs, prorates remaining ACUs across engineers, sets enforceable Local Agent per-user limits, supports Boost/Borrow reallocations, and provides a one-time org-level Local Agent cap command with live verification.

## Authoritative API contract

Base URL: `https://api.devin.ai`. Service user token required.

| Endpoint | Method | Purpose |
|---|---|---|
| `/v3/enterprise/members/users` | GET | Discover user IDs/emails. |
| `/v3/enterprise/organizations` | GET | Discover org IDs/names. |
| `/v3/enterprise/consumption/cycles` | GET | Current monthly cycle. |
| `/v3/enterprise/consumption/daily[/users/{user_id}]` | GET | Current-cycle ACU burn. |
| `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` | GET/PATCH/DELETE | Individual Local Agent limit override + billing org attribution. |
| `/v3beta1/enterprise/users/consumption/acu-limits` | GET/PATCH/DELETE | Default per-user Local Agent limit. |
| `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits` | GET/PATCH/DELETE | Org aggregate Local Agent limit and cloud-agent org limit. |

Limit semantics:
- Local Agent = Devin Desktop, Windsurf JetBrains, Devin CLI.
- Per-user and org gates are independent; both must pass.
- User override replaces default, not additive.
- All limits reset monthly.
- `cycle_acu_limit: 0` blocks; `local_agent: null` clears.
- UI can view current-cycle Local Agent usage at `app.devin.ai > Enterprise Settings > Consumption`; configured limits are API-managed and verified by GET output.

Permissions:
- Read limits: `ViewAccountConsumption`.
- Update/delete limits: `ManageBilling`.

## Architecture

Thin zsh launcher plus command-specific playbooks. Agent commands (`set-limits`, `boost`, `user`, `status`, `models`) launch `clscb` with `_common.md` + command playbook + run context. Local deterministic commands (`doctor`, `dashboard`, `set limit global`) run in zsh without agent launch.

All allocation math lives in jq:
- `compute-caps.jq`: remaining-pool proration, preserving `user_id` for PATCH targets.
- `boost-plan.jq`: zero-sum Boost + Borrow donor plan.
- `boost-check.jq`: overage-headroom check when donor funding is insufficient.

## Commands

### `dag set-limits`

1. Get current cycle.
2. Get roster/user IDs.
3. Get per-user current-cycle consumption.
4. Confirm engineer set.
5. Run `compute-caps.jq`: `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`.
6. GET current user ACU settings.
7. Preview old → new user limits and UI instruction.
8. On confirmation, PATCH every user's `local_agent.cycle_acu_limit`.
9. GET each changed user limit after PATCH and verify exact values.
10. Write ledger for audit/resume; API is authoritative.

### `dag boost <email> [acus]`

Boost recipient's user limit by borrowing from lowest consumers. PATCH recipient and donors; GET every changed user limit after PATCH. Keep Σ caps unchanged unless user explicitly accepts pool-headroom overage risk.

### `dag set limit global <acus> [org_id|org_name]`

Local one-time command. GET orgs, resolve org, PATCH `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits`, then GET same resource and confirm `local_agent.cycle_acu_limit` equals requested value. Prints UI instruction every time.

## Safety rules

- No agent-driven API write without explicit confirmation.
- Reads gate writes; quote exact API error bodies.
- Live GET verification after every PATCH.
- Never print API keys.
- Show UI instruction after every limit preview/result.
- Dashboard remains read-only; tests assert no curl write verbs.

## Verification

`zsh claude/devin-acu-governor/test/run.zsh` covers 228 assertions across CLI validation, key resolution, cap math, Boost/Borrow math, v3beta1 global limit write+verify, doctor probes, and dashboard robustness.
