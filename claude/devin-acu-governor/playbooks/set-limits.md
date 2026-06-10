# Playbook: set-limits

Distribute the monthly ACU pool (`DAG_MONTHLY_ACU_POOL` in Run context) across all enterprise members as per-user **soft caps**, prorated by what has already been consumed this billing cycle. Soft caps live in the ledger — no per-user cap API exists on this SKU. Optionally guard the pool with org-level hard caps.

## Steps

1. **Cycle dates.** GET `/v3/enterprise/consumption/cycles`. Current cycle = item with `after <= now < before`. Convert epochs to dates for display.
2. **Roster.** GET `/v3/enterprise/members/users` (paginate via `end_cursor`). Build the email ↔ `user_id` map. N = member count.
3. **Per-user consumption.**
   - Windsurf key available: one GET `consumption` with `start_date` = cycle start date, `end_date` = today, `product=agent`, `group_by=user`, `page_size=10000`; follow `next_page_cursor`. Sum `consumption.billed_acus` per `user_email`. One query — mind the 10/hour rate limit.
   - No Windsurf key: loop GET `/v3/enterprise/consumption/daily/users/{user_id}` (URL-encoded) over the roster with the cycle's `time_after`/`time_before`; take each `total_acus`. Batch with `xargs -P4` or similar; no documented rate limit.
   - Cross-check: Σ per-user ACUs should approximate `/v3/enterprise/consumption/daily` `total_acus` for the same window; flag a gap > 5%.
4. **Confirm headcount.** Present the roster count N and ask the user: use N, or override with another number? An override replaces N in the math only; caps are still recorded for the actual roster emails.
5. **Compute caps.** Build `{"pool": <DAG_MONTHLY_ACU_POOL>, "users": [{"email": ..., "consumed": ...}, ...]}` and run `jq -f <compute_caps_jq>` on it. The program returns either `mode: "team_level"` (day-1 case — nothing consumed: one flat cap for everyone) or `mode: "per_user"` (remaining-pool split: `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`), plus `warnings` for exhausted/near-exhausted pools. Surface every warning.
6. **Preview and confirm.** Show a table: email, consumed, new soft cap, over/under (consumed vs cap); plus `total_consumed`, `remaining`, `sum_caps` vs pool, and the mode. State plainly: these are advisory allocations recorded locally — the platform does not enforce them per user. Wait for explicit confirmation.
7. **Write the ledger.** Write the ledger file (path in Run context, schema in the contract) with cycle epochs, per-email caps, `sum_caps`, and the current timestamp. Create the parent directory if needed.
8. **Report violators.** List users whose `consumed` already exceeds their new cap, sorted by overage. These are the `dag boost` / follow-up-conversation candidates.
9. **Optional org guardrail.** GET `/v3/enterprise/organizations` and show each org's `max_cycle_acu_limit` / `max_session_acu_limit`. If the user wants hard protection, offer to PATCH per-org `max_cycle_acu_limit` so Σ org caps = pool (or a split they choose). This is the only hard enforcement available — gate it behind its own explicit confirmation per Hard rule 2.
