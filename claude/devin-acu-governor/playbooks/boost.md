# Playbook: boost (zero-sum reallocation)

Raise a heavy user's soft cap **by taking ACUs from the lowest consumers**, keeping total allocation (Σ caps) unchanged so the team never tips into overage. Caps are ledger soft allocations (no per-user cap API on this SKU) — all writes land in the ledger. Target email is in Run context (`boost target`). An optional `explicit increment` is also in Run context — if `none`, recommend the amount from the user's run-rate projection.

## Steps

1. **Ledger required.** Read the ledger (path in Run context). If missing or stale (its `cycle_start` ≠ the live current cycle's `after` from `/v3/enterprise/consumption/cycles`), stop and tell the user to run `dve set-limits` first — boost reallocates an existing allocation.
2. **Cycle + per-user consumption.** Current cycle from `/v3/enterprise/consumption/cycles`. Per-user `billed_acus` for the cycle: one Windsurf `consumption` call (`group_by=user`, cycle start → today) if the key is available, else loop `/v3/enterprise/consumption/daily/users/{user_id}` over the ledger's emails (resolve `user_id` via `/v3/enterprise/members/users`). Derive the recipient's `consumed`, daily `run_rate` (consumed / days elapsed), and `days_left` in the cycle.
3. **Recipient current cap.** From the ledger `caps`. If the recipient is absent, treat current cap as 0 (tell the user).
4. **Donor candidates.** Rank the **lowest consumers** (exclude the recipient) from step 2; caps from the ledger. Take the bottom ~10 (or all if the team is small) as the donor pool — more than enough; the math only draws what it needs.
5. **Plan.** Build the `boost_plan_jq` input:
   ```json
   {"pool": <DVE_MONTHLY_ACU_POOL>, "share": <pool / N>,
    "recipient_buffer": 0.15, "donor_buffer": 0.10,
    "recipient": {"email": ..., "cap": ..., "consumed": ..., "run_rate": ..., "days_left": ...},
    "donors": [{"email": ..., "cap": ..., "consumed": ...}, ...]}
   ```
   If Run context has an explicit increment, add `"delta_override": <amount>` to `recipient`. Run `jq -f <boost_plan_jq>`. The program returns the recommended cap (`ceil(projected_month_end × 1.15)`), the funded delta, the per-donor takes (each cut no lower than `consumed + 10% of share`), any `shortfall`, and `sum_before`/`sum_after` (must be equal).
6. **Preview.** Show a before/after table: the recipient (cap_before → cap_after) and every donor drawn from (cap_before → cap_after, given), plus `projected_month_end`, `delta`, `funded`, and `sum_before == sum_after` to prove it's zero-sum. Surface every warning. If `shortfall > 0`, explain the recipient can't reach the full recommendation from donors alone — offer to (a) accept the partial raise, (b) add more donors, or (c) cover the shortfall from pool headroom (run `boost_check_jq` to confirm headroom; note this is real overage spend) — user decides.
7. **Confirm.** Wait for explicit confirmation of the full reallocation.
8. **Apply.** Update every changed cap in the ledger with jq (recipient and each donor), refresh `updated`; `sum_caps` is unchanged when `shortfall == 0`. Re-read the file and show the changed entries to verify.
9. **Remind.** Soft caps are advisory — the platform does not enforce them per user. If the recipient sits in an org with a `max_cycle_acu_limit`, note their headroom against that hard cap (`/v3/enterprise/organizations` + the org's cycle consumption).
