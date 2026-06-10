# Playbook: set-limits

Distribute the monthly ACU pool (`DVE_MONTHLY_ACU_POOL` in Run context) across all approved team members as per-user caps, prorated by what has already been consumed this billing cycle.

## Steps

1. **Cycle dates.** POST `GetTeamCreditBalance`. Record `billingCycleStart` and `billingCycleEnd`. Show `numSeats` for reference.
2. **Per-user consumption.** GET `consumption` with `start_date` = cycle start date, `end_date` = today, `product=agent`, `group_by=user`, `page_size=10000`. Follow `next_page_cursor` until exhausted. Sum `consumption.billed_acus` per `user_email`. One query — mind the 10/hour rate limit.
3. **Roster.** POST `UserPageAnalytics`. Keep members with `teamStatus == "USER_TEAM_STATUS_APPROVED"`. Merge with step 2: every roster member appears (consumed = 0 if absent from consumption); flag any consumption email missing from the roster — include it in the math but exclude it from cap writes unless the user confirms otherwise.
4. **Confirm headcount.** Present the merged roster count N and ask the user: use N, or override with another number? An override replaces N in the math only; caps are still written for the actual roster emails.
5. **Compute caps.** Build `{"pool": <DVE_MONTHLY_ACU_POOL>, "users": [{"email": ..., "consumed": ...}, ...]}` and run `jq -f <compute_caps_jq>` on it. The program returns either `mode: "team_level"` (day-1 case — nothing consumed: one flat cap for everyone) or `mode: "per_user"` (remaining-pool split: `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`), plus `warnings` for exhausted/near-exhausted pools. Surface every warning.
6. **Preview and confirm.** Show a table: email, consumed, new cap; plus `total_consumed`, `remaining`, `sum_caps` vs pool, and the mode. Wait for explicit confirmation.
7. **Write caps.**
   - `team_level` mode: one `UsageConfig` call with `"team_level": true, "set_add_on_credit_cap": <flat_cap>`.
   - `per_user` mode: one `UsageConfig` call per email with `"user_email"` and that user's cap. On any failure, stop, report applied/failed email lists, offer to resume the failed subset.
8. **Verify.** Pick 5 random users (or all, if N ≤ 5) and POST `GetUsageConfig` for each; confirm `addOnCreditCap` matches the plan. Report mismatches verbatim.
9. **Ledger.** Write the ledger file (path in Run context, schema in the contract) with cycle dates, per-email caps, `sum_caps`, and the current timestamp. Create the parent directory if needed.
