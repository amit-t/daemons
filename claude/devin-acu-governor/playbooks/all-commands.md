# Playbook: all-commands

Generic Devin API + DAG command lab. Use this when the user wants to explore an arbitrary Devin, Enterprise, Local Agent, billing, usage, session, metrics, repository, knowledge, playbook, or governance task before promoting it into a dedicated `dag` command.

This session is intentionally broad: you have the DAG common contract, the complete current DAG command playbooks appended below, and documentation seed URLs. Use existing DAG commands when they fit. Design new commands only when the user's task repeats enough to deserve a stable command.

## Startup documentation seed

Before answering task-specific questions:

1. Fetch `https://docs.devin.ai/llms.txt`. Devin docs pages say this is the complete documentation index and should be used to discover available pages before exploring further.
2. Fetch any task-relevant Devin documentation pages from that index before making API claims. Prefer V3 pages over legacy V1/V2 pages unless the task is explicitly about a legacy endpoint.
3. Always include these pinned seed pages when the task touches billing, limits, Local Agent, Windsurf usage caps, or API setup:
   - `https://docs.devin.ai/admin/billing/acu-limits`
   - `https://docs.devin.ai/api-reference/overview`
   - `https://docs.devin.ai/api-reference/authentication`
   - `https://docs.devin.ai/api-reference/concepts/pagination`
   - `https://docs.devin.ai/desktop/accounts/api-reference/usage-config#overview`
4. Treat local `dag` playbooks and live docs as inputs, not gospel. If docs changed, prefer live docs and call out the delta before proposing work.

## Generic task mode

1. Restate the user's requested task in one sentence.
2. Classify it:
   - **existing DAG command** — answer by giving the exact `dag ...` command and any required arguments;
   - **one-off API task** — execute or guide it in this session with confirmation gates for writes;
   - **candidate DAG command** — design a repeatable command with usage, playbook, tests, docs, and verification.
3. Identify required permissions and keys before any API call:
   - Devin V3 service-user key: `$DEVIN_COG_KEY`.
   - Windsurf service key: `$DEVIN_SERVICE_KEY`, only when Run context says it is available.
4. For reads, fetch live API data and cite exact endpoints used.
5. For writes, obey all common hard rules: no PATCH/POST/DELETE until the user confirms endpoint, target, old value, new value, and request body.
6. Never print secrets.

## Existing command routing

Use the appended playbooks to route known tasks:

- Use `dag status` for enterprise burn, projection, org/user limits, top consumers, and model burn.
- Use `dag status --group [idp_group_name]` for an agent status report scoped to one exact IDP group, with last-3-days member usage/status patterns.
- Use `dag user <email>` for one user's consumption, effective Local Agent limit, product/model/IDE split, and trajectory.
- Use `dag usage [--json] [--top <n>]` for a local no-agent per-user consumed-vs-cap table.
- Use `dag usage --group [idp_group_name] [--json] [--top <n>]` for a local no-agent exact-IDP-group usage/status table with last-3-days detail.
- Use `dag set-limits` for prorated per-user Local Agent limit writes across confirmed engineers.
- Use `dag boost <email> [acus]` for Boost/Borrow user cap adjustments.
- Use `dag set limit global <acus> [org_id|org_name]` for deterministic org-level Local Agent cap writes.
- Use `dag models [file|names...]` for model burn and Admin Portal allowlist walkthroughs.
- Use `dag dashboard` for a local static burn-rate dashboard.
- Use `dag doctor` for key/capability probes.

## "spin it up" contract

When the user says **"spin it up"**:

1. If an existing command fits, output exactly:
   - command to run;
   - required env/key setup;
   - expected read/write behavior;
   - confirmation gates that will appear.
2. If a new DAG command is warranted, output a ready-to-implement command spec:
   - command name and usage;
   - command purpose and non-goals;
   - mutability (`read-only`, `write gated`, or `local deterministic write`);
   - API endpoints and docs pages to seed;
   - required permissions;
   - playbook steps;
   - tests to add;
   - README sections to update;
   - verification command list.
3. Do not edit the daemon repository from this launched session unless the user explicitly asks you to implement the new command now. Otherwise, hand them the exact command/spec so the repo agent can add it cleanly.
