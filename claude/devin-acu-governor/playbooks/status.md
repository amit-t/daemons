# Playbook: status

Read-only consumption report: where the team stands against the monthly ACU pool and where it will land at month-end. No confirmation gates — nothing is written.

## Steps

1. **Cycle.** POST `GetTeamCreditBalance` for `billingCycleStart`/`billingCycleEnd`, `numSeats`, add-on credit figures.
2. **Consumption.** GET `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `granularity=daily`, `group_by=user,model_uid`, `page_size=10000`; follow pagination. One query — 10/hour rate limit.
3. **Compute** (with jq or a short shell pipeline — show your work):
   - total ACUs consumed = Σ `billed_acus`; remaining = pool − consumed
   - days elapsed and days left in the cycle (from cycle dates and today)
   - daily run-rate = consumed / days elapsed
   - projected month-end = consumed + run-rate × days left
   - verdict: **UNDER** or **OVER** the pool, and by how much
   - top-10 consumers by ACU with their share of total
   - per-model burn: ACUs by `model_uid`, sorted desc
4. **Report.** Compact tables: headline (consumed / remaining / projection / verdict), trajectory numbers, top-10 users, per-model burn. If the ledger exists, also show `sum_caps` vs pool (allocation exposure). Flag anomalies you notice (e.g. one user > 3× median, a model dominating burn).
