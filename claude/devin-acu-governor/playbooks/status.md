# Playbook: status

Read-only consumption report: where the enterprise stands against the monthly ACU pool and where it will land at cycle-end. No confirmation gates — nothing is written.

## Steps

1. **Cycle.** GET `/v3/enterprise/consumption/cycles` → current cycle epochs; convert to dates.
2. **Enterprise consumption.** GET `/v3/enterprise/consumption/daily` with the cycle's `time_after`/`time_before` → `total_acus` + per-day `acus_by_product`.
3. **Org split + hard caps.** GET `/v3/enterprise/organizations`; for orgs of interest (or all if few), GET `/v3/enterprise/consumption/daily/organizations/{org_id}` for the same window. Show each org's consumption vs its `max_cycle_acu_limit` (if set) and its `max_session_acu_limit`.
4. **Per-user + per-model detail** (Windsurf key only). One GET `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `group_by=user,model_uid`, `page_size=10000`; follow pagination. One query — 10/hour rate limit. No Windsurf key: skip; report product split only and note the gap.
5. **Compute** (with jq or a short shell pipeline — show your work):
   - total ACUs consumed (step 2 `total_acus`); remaining = pool − consumed
   - days elapsed and days left in the cycle (epoch arithmetic)
   - daily run-rate = consumed / days elapsed
   - projected cycle-end = consumed + run-rate × days left
   - verdict: **UNDER** or **OVER** the pool, and by how much
   - product split: ACUs by product (devin / cascade / terminal / review), share of total
   - if step 4 ran: top-10 consumers by ACU with share of total, and per-model burn sorted desc
6. **Report.** Compact tables: headline (consumed / remaining / projection / verdict), trajectory numbers, product split, org split vs hard caps, top-10 users, per-model burn. If the ledger exists and is fresh, also show `sum_caps` vs pool (allocation exposure) and any users over their soft cap. Flag anomalies you notice (e.g. one user > 3× median, a model or product dominating burn).
