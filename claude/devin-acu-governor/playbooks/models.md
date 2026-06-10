# Playbook: models

Model governance. Constraint, verified 2026-06-10: **the Devin Desktop API has no endpoint for enabling/disabling models** — model availability is controlled only in the Admin Portal UI ("Models Configuration", plus "Default Model Override"). This playbook reports model usage, diffs the desired allowlist, and walks the user through applying it in the portal.

The desired allowlist (if provided) is in Run context — either inline names or file contents.

## Steps

1. **Re-check for an API.** Fetch `https://docs.devin.ai/llms.txt` and scan for a model-configuration endpoint (model allowlist, team model settings). If one now exists, fetch its reference page and use it instead of the manual walkthrough below — present the plan and gate writes per the hard rules.
2. **Observed models.** GET `consumption` with `start_date` = cycle start (from `GetTeamCreditBalance`), `end_date` = today, `product=agent`, `group_by=model_uid`, `page_size=10000`. Build a table: `model_uid`, ACUs burned, share of total. One query — 10/hour rate limit.
3. **Diff.** If a desired allowlist was provided, split observed models into: allowed and in use, allowed but unused, and **in use but NOT on the allowlist** (these are the ones disabling will affect — show their ACU burn and the users hit hardest via a `group_by=user,model_uid` view of the same data if already fetched).
4. **Walkthrough.** Print exact steps: Admin Portal → Settings → Models Configuration → filter by model/provider → enable the allowlist entries, disable the rest → optionally set Default Model Override (only enabled models can be the default). Remind: this changes what every team member sees immediately.
5. **No allowlist given?** Stop after the usage table and note the walkthrough is available when they bring a list.
