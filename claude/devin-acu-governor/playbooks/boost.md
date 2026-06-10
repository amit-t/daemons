# Playbook: boost

Raise one user's ACU cap by an increment, with a pool headroom check. Target email and increment are in Run context (`boost target`, `increment`).

## Steps

1. **Current cap.** POST `GetUsageConfig` with the target `user_email`. If the response is `{}` the user has no cap; tell the user and ask whether to treat the current cap as 0 or abort.
2. **Allocation total.** Read the ledger (path in Run context). If it is missing, or stale (its `cycle_start` differs from `billingCycleStart` returned by `GetTeamCreditBalance`), rebuild it: fetch the roster via `UserPageAnalytics` (approved members), POST `GetUsageConfig` per member, and write a fresh ledger before continuing. Use the ledger's `sum_caps`.
3. **Headroom check.** Build `{"pool": <DVE_MONTHLY_ACU_POOL>, "current_cap": <from step 1>, "increment": <from Run context>, "sum_caps": <from step 2>}` and run `jq -f <boost_check_jq>`. Show the output: `new_cap`, `new_sum`, `headroom_after`, `over_pool`.
4. **Confirm.** If `over_pool` is true, warn explicitly: the boost pushes total allocation past the monthly pool by `-headroom_after` ACUs — overage spend if fully used. Either way, present new cap and headroom and wait for explicit confirmation.
5. **Write.** POST `UsageConfig` with `"user_email"` and `"set_add_on_credit_cap": <new_cap>`.
6. **Verify.** POST `GetUsageConfig` for the user; confirm `addOnCreditCap == new_cap`. Quote any mismatch.
7. **Ledger.** Update the user's entry and `sum_caps`, refresh `updated`, write the file.
