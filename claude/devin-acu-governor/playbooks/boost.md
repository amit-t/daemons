# Playbook: boost (zero-sum reallocation)

Raise a heavy user's cap **by taking ACUs from the lowest consumers**, keeping total allocation (Σ caps) unchanged so the team never tips into overage. Target email is in Run context (`boost target`). An optional `explicit increment` is also in Run context — if `none`, recommend the amount from the user's run-rate projection.

## Steps

1. **Cycle + recipient consumption.** POST `GetTeamCreditBalance` for cycle dates. GET `consumption` (`group_by=user`, cycle start → today) for per-user `billed_acus`. Derive the recipient's `consumed`, daily `run_rate` (consumed / days elapsed), and `days_left` in the cycle.
2. **Recipient current cap.** POST `GetUsageConfig` for the target `user_email`. If `{}`, treat current cap as 0 (tell the user).
3. **Donor candidates.** From the per-user consumption + roster (`UserPageAnalytics`, approved members), rank the **lowest consumers** (exclude the recipient). Fetch each candidate's current cap from the ledger, or `GetUsageConfig` if the ledger is missing/stale. Take the bottom ~10 (or all if the team is small) as the donor pool — more than enough; the math only draws what it needs.
4. **Plan.** Build the `boost_plan_jq` input:
   ```json
   {"pool": <DVE_MONTHLY_ACU_POOL>, "share": <pool / N>,
    "recipient_buffer": 0.15, "donor_buffer": 0.10,
    "recipient": {"email": ..., "cap": ..., "consumed": ..., "run_rate": ..., "days_left": ...},
    "donors": [{"email": ..., "cap": ..., "consumed": ...}, ...]}
   ```
   If Run context has an explicit increment, add `"delta_override": <amount>` to `recipient`. Run `jq -f <boost_plan_jq>`. The program returns the recommended cap (`ceil(projected_month_end × 1.15)`), the funded delta, the per-donor takes (each cut no lower than `consumed + 10% of share`), any `shortfall`, and `sum_before`/`sum_after` (must be equal).
5. **Preview.** Show a before/after table: the recipient (cap_before → cap_after) and every donor drawn from (cap_before → cap_after, given), plus `projected_month_end`, `delta`, `funded`, and `sum_before == sum_after` to prove it's zero-sum. Surface every warning. If `shortfall > 0`, explain the recipient can't reach the full recommendation from donors alone — offer to (a) accept the partial raise, (b) add more donors, or (c) cover the shortfall from pool headroom (run `boost_check_jq` to confirm headroom; note this is real overage spend) — user decides.
6. **Confirm.** Wait for explicit confirmation of the full reallocation.
7. **Apply atomically.** Write every cap with `UsageConfig` (`set_add_on_credit_cap` per `user_email`): the recipient and each donor. If any call fails, stop, report applied/failed emails, and offer to roll back the applied subset (re-set them to their `cap_before`) or resume the failed ones.
8. **Verify.** `GetUsageConfig` for the recipient and each donor; confirm caps match the plan. Quote mismatches verbatim.
9. **Ledger.** Update every changed user's cap; `sum_caps` is unchanged when `shortfall == 0`. Refresh `updated`, write the file.
