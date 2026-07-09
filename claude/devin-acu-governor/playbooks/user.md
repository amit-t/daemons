# Playbook: user (per-user deep dive)

Read-only deep dive on one user. No confirmation gates, nothing written. Target email is in Run context (`user`).

## Steps

1. **Cycle.** GET `/v3/enterprise/consumption/cycles` → current cycle epochs.
2. **Resolve the user.** GET `/v3/enterprise/members/users` (paginate) → this email's `user_id`, `name`, `role_assignments` (org memberships + roles). Stop with a clear message if the email is not in the roster.
3. **Their daily ACUs.** GET `/v3/enterprise/consumption/daily/users/{user_id}` (URL-encoded) with the cycle's `time_after`/`time_before` → `total_acus` + per-day `acus_by_product` (devin / cascade / terminal / review).
4. **Model + IDE breakdown** (Windsurf key only). GET `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `granularity=daily`, `group_by=model_uid,ide`, `user_id` = the Windsurf user id (resolve via a `group_by=user` row matching the email). One query — 10/hour rate limit. No Windsurf key: skip, note the gap, rely on step 3's product split.
5. **Their Local Agent limit.** GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`. Report explicit `local_agent.cycle_acu_limit` override and `billing_org_id` if present. Also GET `/v3beta1/enterprise/users/consumption/acu-limits` for the default per-user limit so you can state the effective per-user limit when no override exists.
6. **Activity context** (Windsurf key only). POST `UserPageAnalytics` → `activeDays`, last-usage timestamps.
7. **Compute & report** (show your work):
   - **Headline:** total ACUs consumed this cycle, explicit override, default limit, effective per-user Local Agent limit, headroom (limit − consumed), % used.
   - **Trajectory:** daily run-rate, projected month-end ACU, whether they'll exhaust their cap and roughly when.
   - **Product split:** ACUs by product (devin / cascade / terminal / review) from step 3.
   - **Model breakdown** (if step 4 ran): ACUs and `message_count` per `model_uid`, sorted desc, with each model's share.
   - **IDE breakdown** (if step 4 ran): ACUs per `ide`.
   - **Daily trend:** ACUs per day; call out spikes.
   - **Team context:** their share of `/v3/enterprise/consumption/daily` `total_acus` for the cycle; rank among users if per-user data for the team is already in hand (don't spend extra rate-limited calls just for rank).
   - **Activity** (if step 6 ran): active days and last-used timestamps; flag if heavy spend is concentrated in few days.
   - **UI instruction:** `app.devin.ai > Enterprise Settings > Consumption` shows current-cycle Local Agent usage by product/user; configured limits are API-managed and verified via GET output.
8. **Pointers.** If they're near or over their effective Local Agent limit, note that `dag boost <email>` can Boost them by Borrowing ACUs from low consumers. If a single costly model dominates their burn, say so plainly.
