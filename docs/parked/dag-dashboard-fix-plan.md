# PARKED: dag dashboard fix plan (2026-08-04)

Status: parked by Amit. Pick up on request. No changes applied.

## Context

Investigated "why is ICS 121% over / why is the cap not working" from `dag dashboard`. Verdict: **caps are working; the dashboard compares the wrong numbers.**

## Root cause (verified live against Devin API, 2026-08-03/04)

- Dashboard "CYCLE CAP" column = `max_cycle_acu_limit` from `GET /v3/enterprise/organizations`. Proven identical to v3beta1 `cloud_agent.cycle_acu_limit` across all 6 orgs — it is the **cloud-agent-only** cap.
- "CONSUMED" column = all-product org total. ICS cycle burn ~652 ACUs = 96% Local Agent (`terminal` 392.7 + `cascade` 234.9); cloud (`devin`) only 24.04.
- `claude/devin-acu-governor/lib/dashboard.jq` — `org_status($c; $o.max_cycle_acu_limit; $oproj)` divides all-product consumption by the cloud-only cap: 637 / 500 = false **127.5% OVER**.
- Real enforcement gates all under limit:
  - Cloud gate: 24.04 / 500 (4.8%). Session cap 250 is cloud-only, untouched.
  - Local Agent org gate: ICS `local_agent.cycle_acu_limit` = **3000** (not 500); 627.6 used (21%).
  - Per-user explicit caps: every heavy user under their own cap.
- Attribution hole: enterprise cycle total 8202.7 ACUs vs org-attributed sum 1115.3 (ICS 652 + Vontier 463, other 4 orgs = 0). **~86% of enterprise burn attributed to no org** — every user has `billing_org_id: null`, so org-level caps cannot see or gate that usage.

ICS org_id: `org-954dbe3818324908b0a50d3943576361`.

## Parked plan

1. **Dashboard fix**: `lib/dashboard.zsh` fetch `GET /v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits` per org; `lib/dashboard.jq` render two meters per org — Local Agent products (`cascade`+`terminal`) vs `local_agent.cycle_acu_limit`, and `devin` vs `cloud_agent.cycle_acu_limit`. Kills the false OVER.
   - Caveat: Invenco ai-daemons pins `claude/devin-acu-governor` by SHA-256 — any edit breaks inv.dag parity until a reviewed re-pin.
2. **If intent was "ICS total ≤ 500"**: lower ICS `local_agent.cycle_acu_limit` from 3000 via PATCH (write-gated; requires `CONFIRM DAG WRITE`). Audit who set 3000 (ICS) / 24000 (Vontier).
3. **Attribution**: set explicit `billing_org_id` per user (`PATCH /v3beta1/enterprise/users/{user_id}/consumption/acu-limits`) so org aggregates capture the missing 86%.
4. Note: caps enforce at new-message/new-session time; in-flight sessions finish, so small overshoot is inherent even with correct caps.
