# Playbook: set-limits

Distribute the monthly ACU pool (`DAG_MONTHLY_ACU_POOL` in Run context) across all enterprise engineers as enforceable **per-user Local Agent limits**. The calculation prorates the remaining ACUs after current cycle burn, then PATCHes each user's `local_agent.cycle_acu_limit` through the Cognizant-provided V3 beta API.

## Steps

1. **Cycle dates.** GET `/v3/enterprise/consumption/cycles`. Current cycle = item with `after <= now < before`. Convert epochs to dates for display.
2. **Roster / user IDs.** GET `/v3/enterprise/members/users` (paginate via `end_cursor`). Build rows `{email, user_id, name}`. This user_id list is required for `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` PATCH targets. URL-encode every `user_id` in endpoint paths.
3. **Per-user consumption.**
   - Windsurf key available: one GET `consumption` with `start_date` = cycle start date, `end_date` = today, `product=agent`, `group_by=user`, `page_size=10000`; follow `next_page_cursor`. Sum `consumption.billed_acus` per `user_email`. One query — mind the 10/hour rate limit.
   - No Windsurf key: loop GET `/v3/enterprise/consumption/daily/users/{user_id}` (URL-encoded) over the roster with the cycle's `time_after`/`time_before`; take each `total_acus`. Batch with `xargs -P4` or similar; no documented rate limit.
   - Cross-check: Σ per-user ACUs should approximate `/v3/enterprise/consumption/daily` `total_acus` for the same window; flag a gap > 5% before any write.
4. **Confirm engineer set.** Present headcount N plus the email/user_id list (compact table). Ask the user to confirm engineers included or remove non-engineers. Do not PATCH users outside the confirmed set.
5. **Compute caps.** Build `{"pool": <DAG_MONTHLY_ACU_POOL>, "users": [{"user_id": ..., "email": ..., "consumed": ...}, ...]}` and run `jq -f <compute_caps_jq>` on it. The program returns per-user `cap` values. Mid-cycle formula: `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`, so the remaining ACO/ACU pool is prorated evenly among all confirmed engineers while preserving what each has already used. Surface every warning for exhausted/near-exhausted pools.
6. **Read current limits.** For every target user, GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`. Capture old `local_agent.cycle_acu_limit` (or `<unset>`) and `billing_org_id` if present. Remember: GET returns explicit override only, not inherited default.
7. **Preview and confirm.** Show a table: email, user_id, consumed, old override, new `local_agent.cycle_acu_limit`, delta, over/under (consumed vs new cap); plus `total_consumed`, `remaining`, `sum_caps` vs pool. Print UI instruction: `app.devin.ai > Enterprise Settings > Consumption` (usage view; limits are API-managed). Wait for explicit confirmation.
8. **PATCH per-user limits.** For each confirmed user, PATCH `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` with body `{"local_agent":{"cycle_acu_limit":<cap>}}`. Do not include `billing_org_id` unless the user explicitly asked to change attribution.
9. **Live verify.** GET each changed user limit after PATCH. Confirm `local_agent.cycle_acu_limit` equals the planned cap. Report applied/failed/verified lists. If any PATCH or verify fails, quote exact body, stop further writes when safe, and offer a resume command/plan for only the failed subset.
10. **Write ledger.** Write the ledger file (path in Run context) with cycle epochs, per-email `{user_id, cap, consumed}`, `sum_caps`, and the current timestamp. Create the parent directory if needed. The live API remains authoritative; ledger supports boost/borrow planning.
11. **Report violators / boost candidates.** List users whose current consumption is already close to or above their new cap, sorted by overage. Point to `dag boost <email> [acus]`, which can Boost one user by Borrowing from low consumers.
12. **Org guardrail reminder.** If the team wants one org-wide hard cap too, use the deterministic one-time command: `dag set limit global <acus> [org_id|org_name]`. Example: `dag set limit global 2400`. It PATCHes the org Local Agent cap and live-GET verifies it.
