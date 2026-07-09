# Playbook: status

Read-only consumption report: where the enterprise stands against the monthly ACU pool and where it will land at cycle-end. No confirmation gates — nothing is written.

If Run context includes `idp group name`, scope the report to that exact IDP group:
- GET `/v3/enterprise/members/idp-users` with pagination and keep only users whose `idp_role_assignments[].idp_group_name` exactly matches.
- Report only those users in user tables and anomaly callouts.
- Include current-cycle consumed/cap status plus a detailed last-3-days usage pattern by user and product.
- Keep the report GET-only.

## Steps

1. **Cycle.** GET `/v3/enterprise/consumption/cycles` → current cycle epochs; convert to dates.
2. **Enterprise consumption.** GET `/v3/enterprise/consumption/daily` with the cycle's `time_after`/`time_before` → `total_acus` + per-day `acus_by_product`.
3. **Org split + Local Agent org limits.** GET `/v3/enterprise/organizations`; for orgs of interest (or all if few), GET `/v3/enterprise/consumption/daily/organizations/{org_id}` for the same window and GET `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits`. Show each org's Local Agent `local_agent.cycle_acu_limit`, cloud-agent limit if present, legacy `max_cycle_acu_limit`/`max_session_acu_limit` fields if present, and consumption vs cap.
4. **Default user limit.** GET `/v3beta1/enterprise/users/consumption/acu-limits` and report the default Local Agent per-user limit (`<unset>` if absent).
5. **Per-user + per-model detail** (Windsurf key only). One GET `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `group_by=user,model_uid`, `page_size=10000`; follow pagination. One query — 10/hour rate limit. No Windsurf key: skip; report product split only and note the gap. In IDP-group mode, use `/v3/enterprise/consumption/daily/users/{user_id}` for every matched user so last-3-days status is available even without the Windsurf key; use the Windsurf call only for optional model/IDE enrichment.
6. **Compute** (with jq or a short shell pipeline — show your work):
   - total ACUs consumed (step 2 `total_acus`); remaining = pool − consumed
   - days elapsed and days left in the cycle (epoch arithmetic)
   - daily run-rate = consumed / days elapsed
   - projected cycle-end = consumed + run-rate × days left
   - verdict: **UNDER** or **OVER** the pool, and by how much
   - product split: ACUs by product (devin / cascade / terminal / review), share of total
   - if step 5 ran: top-10 consumers by ACU with share of total, and per-model burn sorted desc
   - in IDP-group mode: group total consumed, sum of effective caps, OVER/NEAR/OK counts, last-3-days total, last-3-days avg/day, last-3-days product mix, and each member's cap status
7. **Report.** Compact tables: headline (consumed / remaining / projection / verdict), trajectory numbers, product split, org split vs Local Agent hard caps, default user limit, top-10 users, per-model burn. If IDP-group mode is active, replace top-10 enterprise users with the group member table sorted by last-3-days burn, then cap pressure. If the ledger exists and is fresh, also show `sum_caps` vs pool and users close to/over their allocated cap. Print UI instruction: `app.devin.ai > Enterprise Settings > Consumption` shows current-cycle Local Agent usage by product/user; configured limits are API-managed and verified via GET output. Flag anomalies you notice (e.g. one user > 3× median, a model or product dominating burn).
