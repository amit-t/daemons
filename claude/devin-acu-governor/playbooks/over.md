# Playbook: boost over (Boost everyone currently over budget)

Find every engineer whose current-cycle consumption has reached or passed their enforceable Local Agent cap (state `OVER`: `consumed >= effective cap`), then run the same Boost + Borrow flow as `boost` for each one — no email is given, the recipient set is discovered live at run time. Fund each Boost zero-sum by Borrowing from the lowest consumers, keeping total allocation (Σ caps) unchanged unless the user explicitly accepts pool-headroom overage risk. There is no `boost target` in Run context; the targets are whoever is over right now.

`OVER` definition (matches `dag usage`): a user's effective cap is their explicit per-user Local Agent override if set, else the org default user limit. A user is over when `consumed >= effective_cap` and the cap is a finite number (unlimited/None caps are never "over"). A `cap == 0` blocked user with `consumed > 0` is also over.

## Steps

1. **Cycle + roster + consumption.** GET `/v3/enterprise/consumption/cycles` for the current cycle. GET `/v3/enterprise/members/users` for the roster and build an email ↔ user_id map. Get current-cycle per-user ACUs: one Windsurf `consumption` call (`group_by=user`, cycle start → today) if the key is available, else loop `/v3/enterprise/consumption/daily/users/{user_id}`. URL-encode every `user_id` path segment.
2. **Read live current limits.** GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for the whole roster. Prefer live `local_agent.cycle_acu_limit`; fall back to the org default user limit; treat unset/None as unlimited.
3. **Select the over set.** Compute each user's `effective_cap` and `ratio = consumed / effective_cap`. Keep every user with a finite cap and `consumed >= effective_cap` (plus `cap == 0` with `consumed > 0`). This is the recipient set. If it is empty, report "no users are currently over budget" and stop — nothing to boost.
4. **Report the over set first.** Print a table of every over user: email, consumed, effective_cap, ratio (%), and over-by amount (`consumed - cap`), sorted most-over first. State the count: "N users over budget". This is the answer to "who is over right now".
5. **Shared donor pool.** Rank the **lowest consumers** across the roster (excluding the over set) as Borrow candidates, ordered ascending by consumed. This single donor pool funds all Boosts in this run; track each donor's remaining headroom as it is spent so no donor is double-counted or cut below its own consumption.
6. **Plan each recipient (sequential).** For each over user, most-over first, build the `boost_plan_jq` input exactly as `boost` does:
   ```json
   {"pool": <DAG_MONTHLY_ACU_POOL>, "share": <pool / N>,
    "recipient_buffer": 0.15, "donor_buffer": 0.10,
    "recipient": {"email": ..., "cap": ..., "consumed": ..., "run_rate": ..., "days_left": ...},
    "donors": [{"email": ..., "cap": ..., "consumed": ...}, ...]}
   ```
   Use the *current remaining* donor headroom (caps already reduced by earlier recipients in this run) so the zero-sum invariant holds across the whole batch. No `delta_override` — each recommendation comes from that user's own run-rate projection (`ceil(projected_month_end × 1.15)`). Run `jq -f <boost_plan_jq>`. Carry the resulting donor `cap_after` values forward as the donors' new baselines for the next recipient.
7. **Batch preview.** Show one combined before/after table: every recipient Boost (cap_before → cap_after) and every donor Borrow (cap_before → cap_after, total given across the batch), plus per-recipient `projected_month_end`, `delta`, `funded`, and the batch `Σ caps before == Σ caps after` (zero-sum across the whole run). Surface every warning. If any recipient has `shortfall > 0`, explain the choices per recipient: (a) accept partial Boost, (b) add more Borrow donors, or (c) cover the shortfall from pool headroom (run `boost_check_jq`; raises total exposure/overage risk). The user decides.
8. **Confirm.** Wait for one explicit confirmation covering every changed user limit in the batch. List exactly which users will be PATCHed and to what value.
9. **PATCH changed users.** PATCH `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for every recipient and every donor with body `{"local_agent":{"cycle_acu_limit":<new_cap>}}`. A user override replaces the default. Apply recipients and donors together so the allocation stays balanced.
10. **Live verify.** GET every changed user limit after PATCH. Confirm `local_agent.cycle_acu_limit` equals the planned value for each recipient and donor. Report applied/failed/verified lists; quote exact bodies for failures.
11. **Update ledger.** Refresh changed entries in the ledger with `{user_id, cap, consumed}` and an updated timestamp. Re-read the file and show changed entries. With no shortfall covered from headroom, batch `sum_caps` is unchanged.
12. **UI instruction.** Print: `app.devin.ai > Enterprise Settings > Consumption` to see current-cycle Local Agent usage by product/user. Note that configured Local Agent limits are API-managed and this run's GET verification is the proof.
