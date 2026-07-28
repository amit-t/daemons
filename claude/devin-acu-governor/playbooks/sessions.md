# Playbook: sessions (session logs + prompt traces)

Read-only forensic extraction. Pull **every** Devin Cloud session the enterprise ran inside the Run-context time window, pull each session's **prompt trace** (the full chronological user ↔ Devin message log), write the raw data to disk as a series of files, then write one `OVERVIEW.md` on top that summarises who did what.

Nothing is written to the Devin API. The only mutations permitted in this command are the artifact files under the Run-context `output directory` — no repository files, no ledger, no PATCH/POST/DELETE.

Every path, the window epochs, and the filters are already resolved in Run context. **Do not recompute the window.** Do not widen it, do not round it, do not substitute "today" for it.

## Required permission

Session reads need the enterprise session-view scope on the `cog_` service user — `ViewOrgSessions` in `dag doctor` and the older docs, `ViewAccountSessions` in the current API reference. The roster map additionally needs `ViewAccountMembership`. The configured DAG key held both when this playbook was verified live, so a `403` means the key changed, not that the endpoint is wrong. If any call returns `401`/`403`, stop immediately, quote the exact response body, and tell the user which permission to add at `app.devin.ai > Settings > Service users`. Do not fall back to guessing session data from consumption endpoints.

## Endpoints

Base `https://api.devin.ai`, header `Authorization: Bearer $DEVIN_COG_KEY` on every call. Rows marked **verified live** were curl-probed against this enterprise on 2026-07-28; trust them over the published docs where the two disagree.

| Endpoint | Purpose |
|---|---|
| `GET /v3/enterprise/sessions` | **Verified live.** Session list across every org in one cursor stream — this is the entry point, not the per-org endpoint. Query: `first` (page size), `after` (opaque cursor, URL-encode it), `created_after`, `created_before`. Ordered **newest-first** by `created_at`. Items carry `session_id, url, status, status_detail, title, tags, playbook_id, user_id, service_user_id, org_id, created_at, updated_at, is_archived, acus_consumed, pull_requests[], parent_session_id, child_session_ids, category, subcategory, origin, structured_output`. |
| `GET /v3/organizations/{org_id}/sessions/{session_id}/messages` | **Verified live. The prompt trace.** Query `first` + `after` (URL-encode the cursor — it contains `=`). Items carry `event_id, source (user\|devin), message, created_at`, ordered **oldest-first**. `total` is always `null` here — loop on `has_next_page`, never on a count. |
| `GET /v3/enterprise/members/users` | **Verified live.** `user_id` ↔ `email`/`name` map. Paginates with `after=<end_cursor>` — the wrong cursor param is silently ignored and loops on the same page forever. Needs `ViewAccountMembership`. |
| `GET /v3/enterprise/organizations` | **Verified live.** `org_id` ↔ org `name` map. Same cursor contract. |
| `GET /v3/organizations/{org_id}/sessions` | **Verified live.** One org's sessions. Only worth calling when you need explicit per-org partitioning; the enterprise stream already covers every org in one pass. |
| `GET /v3/organizations/{org_id}/sessions/{session_id}` | **Verified live — and redundant.** The payload was byte-for-byte the session's list item: metadata only, no prompts. **Do not call it.** The list row already carries every field. |
| `GET /v3/enterprise/sessions/insights` | Documented, not live-verified here. Adds `num_user_messages`, `num_devin_messages`, `session_size (xs\|s\|m\|l\|xl)`, and `analysis` (`action_items`, `issues`, `timeline`, `classification`, `suggested_prompt`, `note_usage`). Call **only** when Run context says session insights are ENABLED, and if it 404s, note that in `errors.log` and carry on — it is enrichment, not core data. |

Pagination contract, identical on every endpoint above: request `first=N` (plus `after=<URL-encoded cursor>` after the first page), response `{items[], end_cursor, has_next_page, total}`, loop while `has_next_page` is true. `session_id` is used **raw** on the org-scoped message path — do not add a `devin-` prefix. `user_id` is opaque and contains `|`; URL-encode it anywhere it reaches a path or query.

### Window parameters — use the right ones

- `created_after` / `created_before`, Unix epoch seconds, are the **only** verified server-side filter. They filter `created_at`, and the interval is **half-open: `[created_after, created_before)`** — a session created exactly at `created_after` is included, one created exactly at `created_before` is not. Run context already gives you both epochs.
- `time_after` / `time_before` are **silently ignored**: the API returns HTTP 200 with a byte-identical unfiltered body. Never send them — a run that used them would quietly report the enterprise's entire session history as if it were the window.
- Every other documented filter (`user_ids`, `org_ids`, `origins`, `tags`, `repo_names`, `category`, …) is unverified on this deployment. Because an unrecognised parameter is ignored rather than rejected, **apply org / user / origin filters client-side** on the fetched window, as Run context instructs. The window is small; correctness beats one saved round trip.

### What a "prompt trace" actually contains

The messages endpoint returns the **visible conversation only**: `source=user` events are the initial prompt and every follow-up the human sent, `source=devin` events are Devin's user-facing replies. The initial prompt is the first `source=user` event, and in sampled sessions its `created_at` equalled the session's `created_at`.

v3 exposes **no** tool calls, shell commands, command output, code edits, browser actions, or internal reasoning — the `/events` and `/logs` subresources both return `404`. A coding session that ran for thousands of ACUs still exposed only its handful of chat events. Say this plainly in `OVERVIEW.md`; never present these traces as a full execution log.

Attachments arrive inline, embedded in the message string as `ATTACHMENT:{"url":"…","fileSize":…}`. There is no separate attachment field. Leave them in the raw trace verbatim.

## Steps

1. **Create the output tree.** `mkdir -p <output directory>/traces`. Touch `<errors log>` so a clean run still leaves an (empty) error file.
2. **Identity maps.** GET `/v3/enterprise/organizations` → `organizations.json`. GET `/v3/enterprise/members/users` (paginate with `after=<end_cursor>`; the wrong cursor param is silently ignored and loops forever) → `users.json`. These give every later table real emails and org names instead of raw ids.
3. **Resolve filters.** If Run context names an org filter, resolve it to `org_id`(s) from `organizations.json`; if it names a user filter, resolve the email to a `user_id` from `users.json`. Stop with a clear message if a named org or email does not exist in the roster. These resolve to **client-side match keys** — the window query itself carries only `created_after`/`created_before`.
4. **List sessions.** Page `GET /v3/enterprise/sessions` with `first=200` plus the Run-context `created_after`/`created_before`, following the URL-encoded `end_cursor` while `has_next_page` is true. This one stream covers every org — do not loop the per-org endpoint. Results arrive newest-first; keep them in a stable order of your choosing but record the order you used. Then apply the resolved org/user/origin filters client-side. Write the filtered set to `sessions.json` and `sessions.ndjson`, and record page count, pre-filter item count, and post-filter item count for the manifest.
   - Sanity check before going further: if the response `total` equals the enterprise's all-time session count, the window filter did not apply — stop and report it rather than producing a report covering all history.
5. **Insights (only if ENABLED).** Page `GET /v3/enterprise/sessions/insights` over the same window, write it to `insights.json`, and merge `num_user_messages`, `num_devin_messages`, `session_size`, and `analysis` into the per-session records used by the report. This endpoint is documented but was not live-verified: if it 404s or errors, log it in `errors.log`, note it in the overview, and continue — it is enrichment, not core data. If insights are DISABLED, do not call it and leave `insights.json` absent.
6. **Prompt traces (only if ENABLED).** For every session kept in step 4, page `GET /v3/organizations/{org_id}/sessions/{session_id}/messages` with `first=200` — using that session's own `org_id` and its raw `session_id`, no `devin-` prefix — until `has_next_page` is false. `total` is `null` on this endpoint, so never use it as a loop bound. Then write two files per session:
   - `traces/<session_id>.json` — `{"session_id", "org_id", "session": <the session's list-metadata object>, "messages": [<verbatim merged items, oldest-first>]}`. No reordering, no truncation, no summarising. This is the raw evidence file, and it is self-contained: metadata plus transcript in one place.
   - `traces/<session_id>.md` — a readable transcript (format below).
   A per-session failure is not fatal: append one line to `errors.log`, mark that session `trace_status: "failed"` in the manifest, and continue. A first-call `403` on the messages endpoint *is* fatal for traces — report the permission gap once and stop retrying every session.
7. **Manifest.** Write `manifest.json` (schema below) last among the data files, so it records what actually landed on disk.
8. **Overview.** Write `OVERVIEW.md` using the template below. It is the human deliverable; the JSON files are its evidence.
9. **Report to the terminal.** Print the output directory path, the counts (sessions / traces / messages / errors), and the executive-summary bullets from `OVERVIEW.md` so the user gets the answer without opening a file.

## Output file contract

Everything lands under the Run-context `output directory`. Exact names — other DAG tooling and follow-up runs depend on them.

| Path | Content |
|---|---|
| `manifest.json` | Run metadata: window, filters, endpoints called, page/item counts, per-session trace status, truncation record, error count. Schema below. |
| `sessions.json` | `{"items": [...]}` — the enterprise-stream session index for the window, session objects **verbatim** as the API returned them, after client-side filtering. |
| `sessions.ndjson` | The same session objects, one compact JSON object per line, for grep/jq streaming. |
| `insights.json` | `{"items": [...]}` from `/v3/enterprise/sessions/insights`. Present only when `--insights` was passed and the call succeeded. |
| `traces/<session_id>.json` | `{"session_id", "org_id", "session": {...}, "messages": [...]}` — that session's list metadata plus its verbatim oldest-first message array. |
| `traces/<session_id>.md` | Readable transcript of the same trace (format below). |
| `users.json` | `{"items": [...]}` roster snapshot used for the `user_id` → email/name map. |
| `organizations.json` | `{"items": [...]}` org roster used for the `org_id` → name map. |
| `errors.log` | One line per failed call: `<ISO timestamp>\t<HTTP status>\t<endpoint>\t<exact response body, single line>`. Empty file on a clean run. |
| `OVERVIEW.md` | The executive summary. Written last. |

`manifest.json` schema:

```json
{
  "run_id": "<Run-context run id>",
  "generated_at": "<ISO 8601 timestamp>",
  "command": "<Run-context requested shell command>",
  "window": {
    "start_epoch": 0, "end_epoch": 0,
    "start_utc": "", "end_utc": "",
    "hours": 24, "source": "<Run-context window source>"
  },
  "filters": {"org": null, "user": null, "origin": null, "max_sessions": 0},
  "options": {"traces": true, "insights": false},
  "endpoints": ["GET /v3/enterprise/sessions", "..."],
  "fetch": {
    "session_pages": 0,
    "items_before_filter": 0,
    "items_after_filter": 0,
    "window_basis": "created_at, half-open [created_after, created_before)",
    "truncated_to": null,
    "dropped_sessions": 0
  },
  "totals": {
    "sessions": 0, "acus_consumed": 0.0, "users": 0, "service_users": 0,
    "orgs": 0, "traces_written": 0, "messages": 0,
    "user_messages": 0, "devin_messages": 0,
    "pull_requests": 0, "errors": 0
  },
  "sessions": [
    {"session_id": "", "user": "", "org": "", "acus_consumed": 0.0,
     "status": "", "trace_status": "ok|failed|skipped", "messages": 0}
  ]
}
```

Transcript format for `traces/<session_id>.md`:

```markdown
# <title or session_id>

- session: <session_id> · <url>
- user: <email or service-user id> · org: <org name>
- status: <status> / <status_detail> · origin: <origin> · category: <category>
- created: <UTC> · updated: <UTC> · ACUs: <acus_consumed>
- PRs: <pr_url (pr_state)>, …

---

### [1] user · <UTC timestamp>

<message verbatim>

### [2] devin · <UTC timestamp>

<message verbatim>
```

Message bodies are copied **verbatim** — never paraphrase, redact, or trim a trace. Fence any message that contains markdown headings so it cannot break the document structure.

## Executive summary template — `OVERVIEW.md`

Fill every section. Write `—` where data is genuinely unavailable and say why; never drop a section silently.

```markdown
# Devin session overview — <window start local> → <window end local>

Generated <ISO timestamp> by `<requested shell command>` · run `<run id>` · artifacts in `<output directory>`

## Executive summary

<5–8 bullets, each a claim with a number behind it. Lead with the single most
consequential fact of the window. Cover: total spend and how it compares to the
run-rate implied by the monthly pool; who drove it; what work actually got done
(PRs merged/opened, categories); the biggest single session; anything that went
wrong (errors, usage-limit statuses, sessions stuck waiting); and one thing the
reader should do next.>

## At a glance

| Metric | Value |
|---|---:|
| Window | <hours>h (<start> → <end>) |
| Sessions | <n> |
| ACUs consumed | <n> |
| Distinct users | <n> (+ <n> service users) |
| Orgs | <n> |
| Messages captured | <n> (<n> user / <n> Devin) |
| Pull requests | <n> opened, <n> merged |
| Sessions still running / waiting | <n> / <n> |
| Failed or errored sessions | <n> |
| Fetch errors | <n> |

## Who did what

| User | Org | Sessions | ACUs | Share | PRs | Top theme |
|---|---|---:|---:|---:|---:|---|

Sorted by ACUs descending. Session rows carry only an opaque `user_id`, never an
email — resolve every one through the `users.json` roster map. A `user_id` with
no roster match is reported under its `service_user_id` when present, otherwise
under the raw `user_id`, tagged `(unmapped)`; service-user rows are tagged
`(service)`. Never drop a session because its owner could not be named.

Then, for each user with meaningful activity, 2–4 sentences naming their actual
tasks — pulled from session titles and the opening user prompt of each trace,
not invented. Name repositories and PRs where the trace shows them.

## By organization

| Org | Sessions | ACUs | Share | Users |
|---|---:|---:|---:|---:|

## What was worked on

Cluster the sessions into themes using `category`/`subcategory` when present and
the opening user prompt when not. For each theme: session count, ACUs, the users
involved, and one line on the outcome.

| Theme | Sessions | ACUs | Users | Outcome |
|---|---:|---:|---|---|

## Notable sessions

| Session | User | ACUs | Status | Why it stands out |
|---|---|---:|---|---|

Include: the highest-ACU session, the longest-running, anything that ended in
`error` or a `usage_limit_exceeded`/`out_of_quota` `status_detail`, anything
still `waiting_for_user`, and any session whose trace shows repeated retries.
Link each to its `traces/<session_id>.md`.

## Prompt-trace observations

What the prompts themselves show: are requests specific or vague, do sessions
stall on missing context, do users re-prompt heavily on the same task, are
playbooks being used. Quote short verbatim fragments as evidence. If
`--insights` ran, fold in `analysis.suggested_prompt` and `analysis.issues`.

## Risks and anomalies

Bullets. Include any user burning disproportionately (> 3× the median), sessions
blocked by a limit, repeated failures on one repo, secrets or credentials
appearing in prompt text (flag the session, never quote the secret), and any
window coverage gap caused by fetch errors.

## Recommended actions

Numbered, specific, each naming the `dag` command or admin action that follows —
for example `dag boost <email>` for a user hitting their cap, `dag user <email>`
for a deep dive, `dag status` for cycle context.

## Coverage and caveats

- Sessions fetched: <n> across <n> pages; <n> after org/user/origin filtering
- Window basis: session `created_at`, half-open `[<start>, <end>)`. Sessions created
  before this window but still active inside it are **not** included — widen with
  `--since`/`--hours` to catch them.
- Traces written: <n> of <n> sessions (<n> failed — see `errors.log`)
- Trace depth: visible conversation only (user prompts + Devin chat replies). The v3
  API exposes no tool calls, shell commands, command output, code edits, or internal
  reasoning, so these traces are **not** a full execution log.
- Truncation: <none | kept top <n> by ACU, dropped <n>>
- Insights: <enabled | disabled — re-run with `--insights` for AI session analysis>
- Data source: Devin API v3 enterprise session endpoints, read-only

## Files

| File | What it holds |
|---|---|
```

## Hard requirements for this command

1. **Read-only against the API.** No PATCH, POST, PUT, or DELETE to any Devin endpoint — including `POST /v3/enterprise/sessions/{id}/insights/generate` and the tag endpoints. `--insights` reads existing analysis; it never triggers generation.
2. **Raw before summary.** `sessions.json` and every `traces/*.json` are verbatim API output. The overview is derived from them, never the other way round. If you cannot fetch something, it goes in `errors.log` — you do not fill the gap with an estimate.
3. **No silent truncation.** If a `max sessions` cap is set, or a fetch failed, or a trace is missing, that is stated in both `manifest.json` and the OVERVIEW "Coverage and caveats" section.
4. **Never print or write either API key.** Traces can contain user-pasted secrets: if a message body appears to hold a credential, flag the session in "Risks and anomalies" by id and never reproduce the secret in `OVERVIEW.md`. The raw `traces/*.json` stays verbatim — say so, so the user knows the directory is sensitive.
5. **The output directory is sensitive.** After writing, tell the user it contains full prompt text and set it `chmod 700`.
6. **Window discipline.** Use the Run-context epochs exactly, on `created_after`/`created_before` only. If the window returns zero sessions, say so plainly, print the exact query used, and suggest `--hours`/`--days`/`--since` to widen it — do not silently widen it yourself, and do not substitute an unfiltered fetch.
7. **Claim only what the API returned.** The traces are visible conversation, not execution logs; the window is by `created_at`, not activity; only `created_after`/`created_before` are verified server-side filters. Every one of those limits belongs in `OVERVIEW.md`. Do not infer what Devin "did" inside a session beyond what the messages and the session metadata actually show.
