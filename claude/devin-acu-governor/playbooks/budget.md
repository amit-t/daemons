# Playbook: budget (set one budget's monthly or temporary ACU allocation)

Use the unified Budgets API, not the deprecated organization Local Agent/Cloud gate endpoints. This command changes one budget without donor cuts or zero-sum rebalancing. A child allocation may exceed its parent; the parent still enforces combined actual usage.

`dag budgets` is read-only list mode: fetch every page in step 1, show each active and archived budget with ID, name, parent, linked org IDs, monthly and temporary limits, and stop. Do not resolve a selector in list mode. All subsequent steps require `dag budget <selector> <monthly|temporary> <amount|clear>`.

1. Read `GET /v3beta1/enterprise/usage-policies/budgets?first=200`; while `has_next_page` is true, request the next page with `after=<end_cursor>`. Stop if the feature is unavailable, a page fails, the cursor is missing/repeated, or an ID repeats. This requires an enterprise service user with `ManageAcuLimits` or delegated budget access. Resolve the selector against `budget_id`, linked `org_ids`, or an exact case-insensitive budget name. Require exactly one match; print candidates and stop on ambiguity. Reject archived targets.
2. Interpret `monthly` as `cycle_acu_limit` and `temporary` as `temporary_cycle_acu_limit`. The amount is a nonnegative integer or `clear` (JSON `null`). A temporary limit replaces the monthly limit for the current billing window; clearing it restores the monthly limit. `null` monthly with no temporary limit is uncapped, subject to ancestors.
3. Compute the preview with this exact jq program on the complete, live budget array. Do not substitute an org-gate sum, `DAG_MONTHLY_ACU_POOL`, or a stale dashboard snapshot for the account budget. Set `field` and `value` from step 2:

   ```zsh
   jq -n --argjson bs "$budgets" --arg id "$budget_id" --arg field "$field" --argjson value "$value" '
     def effective: .temporary_cycle_acu_limit // .cycle_acu_limit;
     ($bs | map(select(.budget_id == $id))[0]) as $target
     | ($bs | map(if .budget_id == $id then .[$field] = $value else . end)) as $proposed
     | ($proposed | map(select(.budget_id == $id))[0]) as $after
     | (if $target.parent_budget_id == null then $id else $target.parent_budget_id end) as $parent_id
     | ($proposed | map(select(.budget_id == $parent_id))[0]) as $parent
     | ($proposed | map(select(.parent_budget_id == $parent_id and .status == "active") | effective)) as $child_limits
     | (if any($child_limits[]; . == null) then null else ($child_limits | add // 0) end) as $allocated
     | ($proposed | map(select(.parent_budget_id == null and .status == "active"))[0]) as $root
     | {target: $target.budget_id, field: $field, old: $target[$field], new: $value,
        effective_before: ($target | effective), effective_after: ($after | effective),
        parent: $parent_id, parent_effective: ($parent | effective), direct_child_allocated: $allocated,
        parent_overallocated: (($parent | effective) != null and ($allocated == null or $allocated > ($parent | effective))),
        account_budget: $root.budget_id, account_effective: ($root | effective)}
   '
   ```

4. Show the exact jq invocation and JSON, the target budget/name/org links, old → new monthly and temporary values, effective limit, direct children's proposed allocation versus their parent, and account root effective limit. `direct_child_allocated: null` means an uncapped child, not zero. Explicitly flag `parent_overallocated` (including an uncapped child) without refusing the change: the parent budget blocks actual usage at its own limit. For a grandchild, show its direct parent warning separately from the root's unchanged direct-child allocation. Warn when the new effective limit is below known current usage; if current usage cannot be attributed exactly, say so instead of claiming a safe threshold. Show endpoint `PATCH /v3beta1/enterprise/usage-policies/budgets/{budget_id}` and the JSON body containing **only** the selected field. Point to `dag dashboard > Budgets` and `app.devin.ai > Enterprise Settings > Budgets` for the live budget UI; the legacy Consumption UI hint is not a substitute. If unchanged, stop without writing.
5. Stop and wait for a later same-session `CONFIRM DAG WRITE`. This authorizes only the displayed target, field, and JSON body. Re-read all budget pages immediately before PATCH; if the selected budget or its parent's effective limit changed, re-plan and request a fresh confirmation. Send PATCH; accept only the documented updated-budget response; re-read all budget pages and verify the changed field equals the requested value. On failure, report the HTTP status and exact API error body (redact any credential), whether the PATCH may already have applied, and the last verified values. No donor/ledger entries change.
