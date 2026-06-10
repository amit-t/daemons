# Playbook: user (per-user deep dive)

Read-only deep dive on one user. No confirmation gates, nothing written. Target email is in Run context (`user`).

## Steps

1. **Cycle.** POST `GetTeamCreditBalance` for `billingCycleStart`/`billingCycleEnd`.
2. **This user's consumption.** GET `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `granularity=daily`, `group_by=model_uid,ide`, `user_id` set to the target (resolve `user_id` from a `group_by=user` row or `UserPageAnalytics` if you only have the email). Follow pagination. One query — 10/hour rate limit.
3. **Their cap.** POST `GetUsageConfig` for the `user_email` → `addOnCreditCap` (or unset).
4. **Roster context.** POST `UserPageAnalytics` → this user's `name`, `role`, `activeDays`, `teamStatus`, last autocomplete/chat/command usage times.
5. **Compute & report** (show your work):
   - **Headline:** total ACUs consumed this cycle, cap, headroom (cap − consumed), % of cap used.
   - **Trajectory:** daily run-rate, projected month-end ACU, whether they'll exhaust their cap and roughly when.
   - **Model breakdown:** ACUs and `message_count` per `model_uid`, sorted desc, with each model's share — i.e. exactly which models they lean on and how expensive each is.
   - **IDE breakdown:** ACUs per `ide`.
   - **Daily trend:** ACUs per day; call out spikes.
   - **Team context:** their rank by ACU among all users, and consumption vs team median.
   - **Activity:** active days and last-used timestamps; flag if heavy spend is concentrated in few days.
6. **Pointers.** If they're near or over their cap, note that `dve boost <email>` can reallocate ACUs to them from low consumers. If a single costly model dominates their burn, say so plainly.
