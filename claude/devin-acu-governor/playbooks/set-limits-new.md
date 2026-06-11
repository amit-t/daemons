# Playbook: set-limits-new (Seed caps for the uncapped, by Borrowing)

Give an enforceable per-user **Local Agent limit** to engineers who currently have **no explicit cap** (they ride the inherited org/default limit), and fund those new caps **zero-sum** by Borrowing cap headroom from the **lowest-consuming** users who already have explicit caps. Σ explicit caps stays unchanged, so the team never tips into overage. This is the targeted complement to `dag set-limits` (which (re)prorates *everyone*): use `set-limits-new` to onboard newly-added engineers without disturbing existing capped users beyond the borrow.

Recipients = uncapped users. Donors = capped users, ranked lowest consumer first. Recipients are never donors; donors are never re-capped upward. The remaining borrowable budget is prorated **evenly** across recipients (`floor(consumed_i) + share`); when donor headroom is too thin to fund everyone, the cheapest recipients are funded first and the rest are reported as still-uncapped (no overage is ever created).

## Steps

1. **Cycle dates.** GET `/v3/enterprise/consumption/cycles`. Current cycle = item with `after <= now < before`. Convert epochs to dates for display.
2. **Roster / user IDs.** GET `/v3/enterprise/members/users` (paginate via `end_cursor`). Build rows `{email, user_id, name}`. URL-encode every `user_id` in endpoint paths (it can contain `|`).
3. **Per-user consumption.** Get current-cycle per-user ACUs:
   - Windsurf key available: one GET `consumption` (`product=agent`, `group_by=user`, `start_date`=cycle start, `end_date`=today, `page_size=10000`; follow `next_page_cursor`). Sum `billed_acus` per `user_email`. Mind the 10/hour rate limit.
   - No Windsurf key: loop GET `/v3/enterprise/consumption/daily/users/{user_id}` (URL-encoded) over the roster with the cycle's `time_after`/`time_before`; take each `total_acus`. Batch with `xargs -P4`.
4. **Read live current limits — classify capped vs uncapped.** For **every** roster user, GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`. The GET returns an **explicit override only**, not the inherited default. Partition:
   - **Recipients** = users whose `local_agent.cycle_acu_limit` is **unset** (no explicit override).
   - **Donors** = users whose `local_agent.cycle_acu_limit` **is** set.
   If a fresh ledger has caps but live is unset, the live API is authoritative — treat as uncapped (recipient) unless the user asks to seed live limits from the ledger first.
5. **Confirm the recipient set.** Present the uncapped headcount N plus their email/user_id/consumed table. Ask the user to confirm engineers to cap (remove service accounts / non-engineers). Do not cap users outside the confirmed set. If N = 0, report "all users already have explicit caps — nothing to seed" and stop.
6. **Plan the borrow.** Build the `borrow_caps_jq` input:
   ```json
   {"donor_buffer": 0.10,
    "recipients": [{"email": ..., "user_id": ..., "consumed": ...}, ...],
    "donors":     [{"email": ..., "user_id": ..., "cap": ..., "consumed": ...}, ...]}
   ```
   Run `jq -f <borrow_caps_jq>`. It returns:
   - `mode` — `even_share` (full prorate, `share` ≥ 1), `min_cover` (caps == consumption, no headroom), or `partial` (some recipients could not be funded zero-sum).
   - `recipients_capped[]` `{email, user_id, consumed, cap}` — the new per-user caps.
   - `recipients_skipped[]` — uncapped users left untouched (partial mode).
   - `donor_takes[]` `{email, cap_before, cap_after, given}` — Borrow draws, lowest consumer first; no donor cut below its consumed ACUs + `donor_buffer`.
   - `borrowed`, `sum_before`, `sum_after`, `zero_sum` (must be `true`), plus `warnings`.
   Surface every warning. Note: a capped user is never set below their own current consumption (`cap_i ≥ consumed_i`).
7. **Preview and confirm.** Show two tables:
   - **Recipients (new caps):** email, user_id, consumed, new `cycle_acu_limit`, headroom (cap − consumed).
   - **Donors (borrowed from):** email, cap_before → cap_after, given.
   Plus `mode`, `borrowed`, and `sum_before == sum_after` (prove zero-sum). If `mode` is `partial`, list `recipients_skipped` and explain the options: (a) accept partial and leave them uncapped, (b) add more/larger donors, or (c) raise total exposure via pool headroom (out of scope here — use `dag boost` or `dag set-limits`). Print UI instruction: `app.devin.ai > Enterprise Settings > Consumption`. Wait for explicit confirmation.
8. **PATCH changed users.** For each `recipients_capped` user **and** each `donor_takes` donor, PATCH `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` with body `{"local_agent":{"cycle_acu_limit":<cap>}}`. Do not include `billing_org_id` unless the user explicitly asked to change attribution. Never PATCH a `recipients_skipped` user.
9. **Live verify.** GET each changed user limit after PATCH. Confirm `local_agent.cycle_acu_limit` equals the planned value for every recipient and donor. Report applied/failed/verified lists. On any failure, quote the exact body, stop further writes when safe, and offer a resume plan for only the failed subset.
10. **Update ledger.** Refresh the ledger (path in Run context) for every changed entry with `{user_id, cap, consumed}` and a new timestamp; re-read and show changed entries. Because the borrow is zero-sum, `sum_caps` should be unchanged vs before (modulo any FP rounding in the donor buffer). The live API remains authoritative; the ledger supports later boost/borrow planning.
11. **Report.** List newly-capped engineers, donors and what each gave, and any users left uncapped. Point to `dag boost <email> [acus]` for single-user top-ups and `dag set-limits` for a full re-prorate.
