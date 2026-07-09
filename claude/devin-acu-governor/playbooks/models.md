# Playbook: models

Model governance. Constraint, verified 2026-06-10: **no API endpoint enables/disables models** — model availability is controlled only in the Admin Portal UI ("Models Configuration", plus "Default Model Override"). Model-level ACU data exists only in the Windsurf analytics family (Devin v3 reports product-level only). This playbook reports model usage, diffs the desired allowlist, and walks the user through applying it in the portal.

The desired allowlist (if provided) is in Run context — either inline names or file contents. **Requires the Windsurf key** — without it, stop after reporting the v3 product split and say model-level data needs the Windsurf service key.

## Steps

1. **Re-check for an API.** Fetch `https://docs.devin.ai/llms.txt` and scan for a model-configuration endpoint (model allowlist, team model settings). If one now exists, fetch its reference page and use it instead of the manual walkthrough below — present the plan and gate writes per the hard rules.
2. **Cycle.** GET `/v3/enterprise/consumption/cycles` → current cycle start date.
3. **Observed models.** GET Windsurf `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `group_by=model_uid`, `page_size=10000`. Build a table: `model_uid`, ACUs burned, share of total. One query — 10/hour rate limit. (Add `user` to `group_by` in the same single call if a diff against an allowlist is expected — see step 4.)
4. **Diff.** If a desired allowlist was provided, split observed models into: allowed and in use, allowed but unused, and **in use but NOT on the allowlist** (these are the ones disabling will affect — show their ACU burn and the users hit hardest from the `group_by=user,model_uid` view of the same data).
5. **Walkthrough.** Print exact steps: Admin Portal → Settings → Models Configuration → filter by model/provider → enable the allowlist entries, disable the rest → optionally set Default Model Override (only enabled models can be the default). Remind: this changes what every team member sees immediately.
6. **No allowlist given?** Stop after the usage table and note the walkthrough is available when they bring a list.
