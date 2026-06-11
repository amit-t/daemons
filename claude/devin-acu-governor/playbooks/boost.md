# Playbook: boost (Boost + Borrow)

Boost one engineer's enforceable Local Agent user limit by Borrowing ACUs from the lowest consumers, keeping total allocation (Σ caps) unchanged unless the user explicitly accepts pool-headroom overage risk. Target email is in Run context (`boost target`). An optional `explicit increment` is also in Run context — if `none`, recommend the amount from the user's run-rate projection.

## Steps

1. **Cycle + roster.** GET `/v3/enterprise/consumption/cycles` for current cycle. GET `/v3/enterprise/members/users` and resolve the target email to `user_id`; build email ↔ user_id map for donor candidates. URL-encode all `user_id` path segments.
2. **Per-user consumption.** Get current-cycle per-user ACUs: one Windsurf `consumption` call (`group_by=user`, cycle start → today) if the key is available, else loop `/v3/enterprise/consumption/daily/users/{user_id}` over the roster. Derive recipient `consumed`, daily `run_rate` (consumed / days elapsed), and `days_left` in the cycle.
3. **Read live current limits.** GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for the recipient and donor pool. Prefer live `local_agent.cycle_acu_limit`; if unset but a fresh ledger has a cap, show both and ask whether to seed missing live limits from the ledger first. The API is authoritative.
4. **Donor candidates.** Rank the **lowest consumers** (exclude recipient) as Borrow candidates. Use users with enough headroom above `consumed + 10% of even share`; do not cut anyone below current consumption.
5. **Plan.** Build the `boost_plan_jq` input:
   ```json
   {"pool": <DAG_MONTHLY_ACU_POOL>, "share": <pool / N>,
    "recipient_buffer": 0.15, "donor_buffer": 0.10,
    "recipient": {"email": ..., "cap": ..., "consumed": ..., "run_rate": ..., "days_left": ...},
    "donors": [{"email": ..., "cap": ..., "consumed": ...}, ...]}
   ```
   If Run context has an explicit increment, add `"delta_override": <amount>` to `recipient`. Run `jq -f <boost_plan_jq>`. The program returns the recommended cap (`ceil(projected_month_end × 1.15)`), funded delta, Borrow takes, shortfall, and `sum_before`/`sum_after` (must be equal for zero-sum Borrow).
6. **Preview.** Show a before/after table: recipient Boost (cap_before → cap_after) and every donor Borrow (cap_before → cap_after, given), plus `projected_month_end`, `delta`, `funded`, and `sum_before == sum_after`. Surface every warning. If `shortfall > 0`, explain choices: (a) accept partial Boost, (b) add more Borrow donors, or (c) cover shortfall from pool headroom (run `boost_check_jq`; this increases total exposure/overage risk). User decides.
7. **Confirm.** Wait for explicit confirmation of every changed user limit.
8. **PATCH changed users.** PATCH `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for the recipient and each donor with body `{"local_agent":{"cycle_acu_limit":<new_cap>}}`. This writes real user-level Local Agent overrides; a user override replaces the default.
9. **Live verify.** GET every changed user limit after PATCH. Confirm `local_agent.cycle_acu_limit` equals the planned value for recipient and donors. Report applied/failed/verified lists; quote exact bodies for failures.
10. **Update ledger.** Refresh changed entries in the ledger with `{user_id, cap, consumed}` and updated timestamp. Re-read the file and show changed entries. If `shortfall == 0`, `sum_caps` should remain unchanged.
11. **UI instruction.** Print: `app.devin.ai > Enterprise Settings > Consumption` to see current-cycle Local Agent usage by product/user. Note that configured Local Agent limits are API-managed and this run's GET verification is the proof.
