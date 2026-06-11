# devin-acu-governor (`dag`)

Devin Enterprise ACU governor. A thin zsh launcher hands each job to a Claude agent session (`clscb` by default), armed with a playbook: the API contract, deterministic jq math, and confirmation gates before any write. You drive the run interactively inside the agent session.

- **Spec:** `docs/superpowers/specs/2026-06-10-devin-acu-governor-design.md`
- **Plan:** `docs/superpowers/plans/2026-06-10-devin-acu-governor.md`

## Plan reality (Cognition platform SKU, verified 2026-06-10)

The org bills on **consumption-based ACUs** — no seat-credit ledger. Consequences, confirmed against live APIs:

- The Windsurf credit endpoints (`GetTeamCreditBalance`, `UsageConfig`, `GetUsageConfig`) fail **structurally** on this SKU (`permission_denied` / `invalid_argument`, permanently). dag no longer calls them.
- **No per-user ACU cap API exists** — not in Devin v3, not in Windsurf. Per-user caps are **soft allocations** recorded in dag's local ledger; the platform does not enforce them.
- Hard caps exist only **per organization**: `max_cycle_acu_limit` and `max_session_acu_limit`, settable via `PATCH /v3/enterprise/organizations/{org_id}`.
- No remaining-balance endpoint. Remaining = `DAG_MONTHLY_ACU_POOL` − consumed (from consumption endpoints).

dag therefore uses **two API families with two keys**:

| Family | Base | Key | Role |
|---|---|---|---|
| Devin API v3 | `api.devin.ai` | `cog_` service-user key (**required**) | cycles, enterprise/org/per-user ACU consumption, roster, org hard caps, metrics |
| Windsurf analytics | `server.codeium.com` | Windsurf service key (**optional**) | per-**model** and per-**IDE** ACU breakdown (only source), roster activity |

---

## What it can do — at a glance

| Command | Writes? | One-line capability |
|---|---|---|
| `dag set-limits` | ✅ ledger (+ optional org caps) | Distribute the monthly ACU pool across enterprise members as prorated per-user **soft caps**; report violators; optionally set org-level hard caps |
| `dag boost <email> [acus]` | ✅ ledger | Zero-sum reallocation: raise a heavy user's soft cap by taking ACUs from the lowest consumers (Σ caps unchanged → no overage). Recommends amount + donors |
| `dag user <email>` | ❌ read-only | Deep-dive one user: cycle ACUs, run-rate, projection, product split, models/IDEs (Windsurf key), daily trend |
| `dag status` | ❌ read-only | Enterprise consumption, remaining ACUs, run-rate, cycle-end projection + UNDER/OVER verdict, org split vs hard caps, top consumers, per-model burn |
| `dag models [file\|names…]` | ❌ report | Per-model ACU burn report + desired-allowlist diff + Admin Portal walkthrough (needs Windsurf key) |
| `dag doctor` | ❌ probe | Probe both keys and report which capabilities they hold |
| `dag dashboard` | ❌ read-only | Local HTML burn-rate + forecast dashboard: headline cards, daily burn chart, product split, org cap table, warnings. No agent, no writes |
| `dag help` | ❌ | Usage text |

Every API write is gated: the agent shows a full plan and waits for your explicit confirmation. Ledger writes get a plan preview + confirmation too, but are local and reversible. No silent mutations.

---

## Commands in full

### `dag set-limits`
Distribute `DAG_MONTHLY_ACU_POOL` (default 24,000) across enterprise members as per-user **soft caps** in the ledger.

What it does, in order:
1. Current cycle from `GET /v3/enterprise/consumption/cycles` (epoch boundaries).
2. Roster + email↔user_id map from `GET /v3/enterprise/members/users`.
3. Per-user cycle consumption — one Windsurf `consumption` call (`group_by=user`) when that key exists, else a per-user loop over `GET /v3/enterprise/consumption/daily/users/{user_id}`. Cross-checked against the enterprise total.
4. Shows headcount **N** and asks you to confirm or override it.
5. Computes caps via `lib/compute-caps.jq`:
   - **Day-1 (nothing consumed):** one flat cap = `floor(pool / N)` for everyone.
   - **Mid-cycle (remaining-pool split):** `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`. Splits *what's left* evenly; heavy users keep what they've spent plus an even share of the remainder.
   - **Pool exhausted / near-exhausted:** freezes caps at current consumption and warns.
6. Shows a preview table (email, consumed, new soft cap, Σ caps vs pool) → waits for confirmation. States plainly that the platform does not enforce these per user.
7. Writes the allocation ledger (`$DAG_STATE_DIR/allocations.json`) — the source of truth for caps.
8. Lists violators (consumed > cap) — the follow-up/boost candidates.
9. Optional: shows current org hard caps and offers `PATCH /v3/enterprise/organizations/{org_id}` to set `max_cycle_acu_limit` so Σ org caps = pool. Separate confirmation; the only hard enforcement on this SKU.

```zsh
dag set-limits
```

### `dag boost <email> [acus]`
Raise a heavy, legitimate consumer's soft cap **without spending more money** — the ACUs come from the lowest consumers, so total allocation (Σ caps) is unchanged.

What it does:
1. Requires a fresh ledger (matching the live cycle) — else stops and points to `dag set-limits`.
2. Reads cycle + per-user consumption; derives the recipient's `consumed`, daily run-rate, days left.
3. Current caps from the ledger; ranks the **lowest consumers** as donor candidates.
4. Runs `lib/boost-plan.jq`:
   - **Recommended cap** = `ceil(projected_month_end × 1.15)` (override by passing `[acus]`, which boosts by exactly that delta).
   - **Donor takes:** greedily pulls from the lowest consumers first, never cutting a donor below `consumed + 10% of an even share`.
   - Returns a Σ-invariant plan: `sum_before == sum_after`.
5. Shows a **before/after table** proving zero-sum; surfaces warnings. On `shortfall`: accept partial, add donors, or knowingly cover from pool headroom (`lib/boost-check.jq`).
6. On confirmation, updates the ledger and shows the changed entries back. Notes the recipient's headroom against their org's hard cap if one is set.

```zsh
dag boost alice@corp.com         # recommend amount from alice's run-rate; auto-pick donors
dag boost alice@corp.com 50      # boost alice by exactly 50 ACUs, funded from low consumers
```

Argument rules (validated before any agent launch):
- `<email>` must look like an email (`*@*.*`) — else exit 2.
- `[acus]`, if given, must be a positive integer — else exit 2. Omit it to use the recommendation.

### `dag user <email>`
Read-only deep dive on one person. No gates, nothing written.

Reports:
- **Headline:** ACUs consumed this cycle (`/v3/.../consumption/daily/users/{user_id}`), soft cap from the ledger, headroom, % used.
- **Trajectory:** daily run-rate, projected cycle-end, whether/when they'll exhaust their cap.
- **Product split:** ACUs by devin / cascade / terminal / review.
- **Model + IDE breakdown** (Windsurf key only): ACUs + message count per `model_uid`, per `ide`.
- **Daily trend** with spike call-outs; **team context** (share of enterprise total).
- **Activity** (Windsurf key only): active days, last-usage timestamps.
- Points to `dag boost <email>` if they're near/over cap.

```zsh
dag user alice@corp.com
```

### `dag status`
Read-only health check. No gates, nothing written.

Reports:
- Total enterprise ACUs this cycle (`/v3/enterprise/consumption/daily`), remaining vs pool.
- Days elapsed / left; daily run-rate; **projected cycle-end total**; **UNDER / OVER** verdict.
- Product split (devin / cascade / terminal / review).
- Org split vs each org's `max_cycle_acu_limit` / `max_session_acu_limit`.
- Top-10 consumers + per-model burn (Windsurf key only).
- If the ledger is fresh: Σ caps vs pool and users over their soft cap.
- Flags anomalies (e.g. one user > 3× median, a product or model dominating).

```zsh
dag status
```

### `dag models [file | names…]`
Model governance and reporting. **Requires the Windsurf key** — model-level ACU data exists only in that family (Devin v3 is product-level).

> **Limitation (verified 2026-06-10):** no API endpoint enables/disables models. Availability is controlled only in the Admin Portal UI. This command *reports and instructs*; the playbook re-checks the docs for a new API on every run and will use it automatically if one ships.

What it does:
1. Re-checks `docs.devin.ai/llms.txt` for a model-config API.
2. Pulls per-model ACU burn (Windsurf `consumption`, `group_by=model_uid`).
3. With a desired allowlist: diffs observed vs allowed — allowed & in use, allowed & unused, and **in use but NOT allowed** (with ACU burn and the users most affected).
4. Prints exact Admin Portal steps (Settings → Models Configuration → enable/disable → optional Default Model Override).

```zsh
dag models                                   # report current per-model burn only
dag models claude-sonnet-4-6 swe-1.6         # diff against an inline allowlist
dag models ./allowlist.txt                   # diff against a file
```

### `dag doctor`
Deterministic local diagnostic — **no agent launch, no token cost**. Probes both keys:

| Capability | Probe | Present |
|---|---|---|
| Consumption Read (required) | GET `/v3/enterprise/consumption/cycles` | 200 |
| Org Read (required) | GET `/v3/enterprise/organizations` | 200 |
| Org-cap Write | PATCH a nonexistent org (mutates nothing) | 404/422; **403 is inconclusive** — the API masks unknown orgs as 403, so write permission is only proven at write time |
| Roster Read (required) | GET `/v3/enterprise/members/users?limit=1` | 200 |
| Metrics Read (required) | GET `/v3/enterprise/metrics/usage` | 200 |
| Teams Read-only (optional) | POST `UserPageAnalytics` | 200 |
| Analytics Read (optional) | GET Windsurf `consumption` (1-day, `page_size=1`) | 200 |

Missing/failed **optional** Windsurf capabilities warn (per-model/IDE breakdown degraded) but exit 0. Exit `3` when a required v3 capability is missing, `1` when no cog key is found.

```zsh
dag doctor                              # probe everything
DAG_DOCTOR_SKIP_ANALYTICS=1 dag doctor  # skip the Windsurf analytics probe (saves 1 of 10/hr calls)
```

Run it right after creating a key to confirm capabilities before any real work.

### `dag dashboard`
Local, deterministic, **read-only** ACU burn dashboard — **no agent launch, no token cost, no API writes**. Fetches the current cycle, enterprise daily consumption, organizations, and per-org daily consumption (GETs only), computes burn-rate + forecast with `lib/dashboard.jq`, and writes a static HTML/CSS/JS app that opens straight from the file path (no local server, no npm).

```zsh
dag dashboard                          # write + open $DAG_STATE_DIR/dashboard/latest/dashboard.html
dag dashboard --no-open                # write, print paths, don't open a browser
dag dashboard --out /tmp/dag-dashboard # write to a specific directory
dag dashboard --json-only              # only data.json + dashboard-data.js, no app files, no open
```

What the dashboard shows:
- **Headline cards** — consumed, remaining vs `DAG_MONTHLY_ACU_POOL`, daily run rate, projected cycle-end, UNDER/OVER verdict.
- **Daily burn chart** — dependency-free SVG bars with per-product tooltips.
- **Product split** — devin / cascade / terminal / review totals.
- **Org table** — consumed, run rate, projected, cycle/session hard caps, % of cap, status badge (`ok` / `warning` ≥85% / `critical` ≥95% / `forecast_over` / `over` / `uncapped`).
- **Warnings panel** — orgs over cap, forecast over cap, or uncapped.

Generated files (`--out` dir, default `$DAG_STATE_DIR/dashboard/latest/`):

| File | Content |
|---|---|
| `data.json` | The computed data document (cycle, enterprise forecast, product split, daily series, org rows, warnings) |
| `dashboard-data.js` | `window.DAG_DASHBOARD_DATA = {…};` — data injection without CORS/file-fetch issues |
| `dashboard.html` / `.css` / `.js` | Static app copied from `web/dashboard/` |

Forecast math (all in `lib/dashboard.jq`, no mental arithmetic): `elapsed_days = max(1, ceil((min(now, before) − after) / 86400))`, `daily_run_rate = consumed / elapsed_days`, `projected_cycle_total = daily_run_rate × cycle_days`, `remaining = pool − consumed`. Org status uses unrounded projections; `forecast_over` outranks `critical`/`warning`.

Endpoints called (Devin v3, Bearer `cog_` key, all GET): `/v3/enterprise/consumption/cycles`, `/v3/enterprise/consumption/daily`, `/v3/enterprise/organizations`, `/v3/enterprise/consumption/daily/organizations/{org_id}`.

Limitations: snapshot, not live — re-run to refresh; per-user breakdown and per-model split are not included (use `dag user` / `dag status` / `dag models`); the pool is config (`DAG_MONTHLY_ACU_POOL`), not an API balance — no remaining-balance endpoint exists on this SKU. Any failed read (non-200, curl transport error, or invalid JSON body) aborts with the exact diagnostics quoted; nothing is written. The key is passed to curl via a header file inside a `0700` temp dir (`-H @file`), never argv — invisible to `ps`; `curl -q` ignores `~/.curlrc`. `DAG_NOW_EPOCH` pins "now" for deterministic output (used by tests).

### `dag help`
Prints usage and config reference. Also `dag -h`, `dag --help`.

---

## One-time setup — keys

### Required: Devin API v3 service-user key (`cog_…`)

1. Open **app.devin.ai → Settings → Service users** (enterprise settings if visible — enterprise-scoped keys reach `/v3/enterprise/*` and every org).
2. Create a service user with permissions: **ManageBilling** (consumption), **ViewOrgSessions** (sessions), **ViewAccountMetrics** (metrics), **ManageOrganizations** (only if you want org hard-cap writes).
3. Copy the `cog_…` key (shown once) and store it:

```zsh
security add-generic-password -s devin-cog-key -a "$USER" -w 'cog_…'
```

Fallback: `export DEVIN_COG_KEY=cog_…`. Keychain wins when both exist.

### Optional: Windsurf service key (per-model/IDE breakdown + roster activity)

1. Open **https://windsurf.com/team/settings** → Service Keys.
2. Scopes: **Analytics Read** + **Teams Read-only** (Billing scopes are useless on this SKU).
3. Store it:

```zsh
security add-generic-password -s devin-service-key -a "$USER" -w '<paste-key>'
```

Fallback: `export DEVIN_SERVICE_KEY=<key>`. Without this key dag still runs; model/IDE breakdown and activity context are skipped.

Keys are exported only into the agent session's environment — never printed, logged, or embedded in a prompt.

---

## Configuration

`environment.env` holds defaults; **shell environment variables override them** per-run.

| Variable | Default | Meaning |
|---|---|---|
| `DAG_MONTHLY_ACU_POOL` | `24000` | Monthly ACU pool to distribute |
| `DAG_LAUNCHER` | `clscb` | Agent launcher command the prompt is handed to |
| `DAG_COG_KEYCHAIN_SERVICE` | `devin-cog-key` | Keychain item, Devin v3 `cog_` key |
| `DAG_KEYCHAIN_SERVICE` | `devin-service-key` | Keychain item, Windsurf service key |
| `DAG_STATE_DIR` | `~/.local/state/devin-acu-governor` | Allocation ledger directory |
| `DAG_PRINT_PROMPT` | _(unset)_ | If set, print the assembled prompt and exit — **does not launch the agent** |
| `DAG_DOCTOR_SKIP_ANALYTICS` | _(unset)_ | If set, `dag doctor` skips the Windsurf analytics probe |
| `DAG_NOW_EPOCH` | _(unset)_ | If set, `dag dashboard` uses this Unix epoch as "now" (deterministic forecast; used by tests) |
| `DAG_API_BASE_V3` | `https://api.devin.ai` | Devin v3 base URL `dag doctor` probes (override for testing) |
| `DAG_API_BASE` | `https://server.codeium.com` | Windsurf base URL `dag doctor` probes (override for testing) |

```zsh
DAG_MONTHLY_ACU_POOL=30000 dag set-limits        # try a different pool for one run
DAG_PRINT_PROMPT=1 dag boost bob@corp.com 100     # see the exact prompt, launch nothing
DAG_LAUNCHER=clb dag status                        # use a different Claude wrapper
```

---

## How a run works

```
dag set-limits
 └─ bin/dag: load environment.env (shell env wins)
 └─ validate args (boost email/amount; unknown cmd → exit 2)
 └─ resolve keys: cog (Keychain → $DEVIN_COG_KEY → exit 1 with setup hint, required)
                  windsurf (Keychain → $DEVIN_SERVICE_KEY, optional — absence noted in prompt)
 └─ assemble prompt: playbooks/_common.md + playbooks/<cmd>.md + Run context
    (today, pool, jq program paths, ledger path, key availability, command args)
 └─ export DEVIN_COG_KEY (+ DEVIN_SERVICE_KEY if present) into the child shell only
 └─ exec  zsh -ic "clscb '<prompt>'"   → interactive agent session opens
 └─ agent: API reads → jq math → preview → YOUR confirmation → ledger/API writes → verify
```

The **allocation ledger** (`$DAG_STATE_DIR/allocations.json`) is the source of truth for per-user soft caps:

```json
{ "cycle_start": 1778918400, "cycle_end": 1781596800, "updated": "…",
  "caps": { "alice@corp.com": 280, "…": 230 }, "sum_caps": 23980 }
```

`boost` requires it; it's stale when `cycle_start` no longer matches the live cycle's `after` epoch.

---

## Safety model

- **No API write without confirmation.** The only API write is the organizations PATCH (org hard caps) — full plan + explicit confirm first. Ledger writes also get a preview + confirm.
- **Reads gate writes.** Any failed read stops the run before any write; the exact API error body is quoted.
- **Deterministic math.** All cap/headroom numbers come from the jq programs, never agent mental arithmetic.
- **Rate-limit aware.** Windsurf consumption allows 10 req/hr/team; playbooks fetch once per run and back off on 429 instead of retrying. Devin v3 calls are batched sensibly.
- **No key leakage.** Neither key ever appears in prompts, output, logs, or the ledger.

---

## API surface touched

| Endpoint | Method | Family / auth | Used by |
|---|---|---|---|
| `/v3/enterprise/consumption/cycles` | GET | v3, Bearer `cog_` | all commands (cycle boundaries) |
| `/v3/enterprise/consumption/daily` | GET | v3 | status, set-limits (cross-check), user (team context), dashboard |
| `/v3/enterprise/consumption/daily/organizations/{org_id}` | GET | v3 | status, dashboard |
| `/v3/enterprise/consumption/daily/users/{user_id}` | GET | v3 | user, set-limits/boost (fallback path) — URL-encode the `\|` in user_id |
| `/v3/enterprise/members/users` | GET | v3 | set-limits, boost, user (roster, email↔user_id) |
| `/v3/enterprise/organizations` | GET | v3 | status, set-limits, boost (hard-cap context), dashboard |
| `/v3/enterprise/organizations/{org_id}` | PATCH | v3 | set-limits optional org hard caps (gated) |
| `/v3/enterprise/metrics/usage` | GET | v3 | doctor |
| `/api/v2alpha/analytics/consumption` | GET | Windsurf, Bearer | set-limits, boost, user, status, models (per-user/model/IDE detail) |
| `/api/v1/UserPageAnalytics` | POST | Windsurf, body key | user (activity), doctor |

Not called (structurally broken on this SKU): `GetTeamCreditBalance`, `UsageConfig`, `GetUsageConfig`. Full field-level contract lives in `playbooks/_common.md`.

---

## Files

| Path | Responsibility |
|---|---|
| `bin/dag` | Dispatch, arg validation, env load, dual-key resolution, prompt assembly, agent launch |
| `lib/key-resolve.zsh` | `dag_resolve_cog_key()` + `dag_resolve_service_key()`: Keychain → env var |
| `lib/doctor.zsh` | `dag_doctor()`: deterministic dual-family HTTP probe (no agent) |
| `lib/dashboard.zsh` | `dag_dashboard()`: fetch v3 consumption, compute forecast, write + open the local dashboard (no agent) |
| `lib/dashboard.jq` | Burn-rate/forecast math + org cap status classification → dashboard data document |
| `web/dashboard/` | Static dashboard app (`dashboard.html` / `.css` / `.js`), copied verbatim into the output dir |
| `lib/compute-caps.jq` | Remaining-pool split; day-1 flat split; exhausted-pool warnings |
| `lib/boost-plan.jq` | Zero-sum boost: recommended cap from projection, donor takes, Σ-invariant |
| `lib/boost-check.jq` | Pool-headroom check (shortfall→overage path) |
| `playbooks/_common.md` | API contract (both families) + hard rules (gates, rate limits, no key leakage) |
| `playbooks/{set-limits,boost,user,status,models}.md` | Per-command step flows |
| `environment.env` | Default config (env vars override) |
| `test/` | zsh test files + `run.zsh` runner |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (or `help`, or `DAG_PRINT_PROMPT` print-and-exit, or doctor with only optional warnings) |
| `1` | No Devin v3 `cog_` key found (Keychain miss + `DEVIN_COG_KEY` unset), or a `dashboard` API read failed (exact body quoted) |
| `2` | Usage error: no command, unknown command, or bad `boost`/`user`/`dashboard` arguments |
| `3` | `dag doctor`: one or more **required** v3 capabilities missing or uncertain |
| `127` | `dag` alias wrapper couldn't find the daemon entrypoint |

---

## Verification

```zsh
zsh claude/devin-acu-governor/test/run.zsh                 # all test files (197 assertions)
zsh -n claude/devin-acu-governor/bin/dag                   # parse check
DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=x dag status               # inspect assembled prompt, launch nothing
dag dashboard --no-open --out /tmp/dag-dashboard            # smoke the local dashboard (read-only)
```

Test coverage: dual-key resolution order (10), cap math incl. day-1/mid-month/exhausted/fractional/single-user (15), boost-plan zero-sum reallocation incl. fund/shortfall/override/no-op + Σ-invariant (21), pool-headroom check (6), CLI dispatch + validation + prompt assembly + dual-key-leak guard (31), doctor capability classification + exit codes + key-leak guard (21), dashboard artifacts + deterministic forecast math + all six org statuses (incl. exact 0.85 / consumed==limit boundaries) + every read-failure path (non-200, invalid JSON, curl transport rc) + read-only curl guard + key-leak guard (93, fixture-driven with mocked `curl`/`open`).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dag: no Devin API v3 service-user key` | cog key not stored. `security add-generic-password -s devin-cog-key -a "$USER" -w 'cog_…'` or `export DEVIN_COG_KEY`. |
| `note — no Windsurf service key` | Optional key absent; model/IDE breakdown skipped. Add it from windsurf.com/team/settings if needed. |
| `dag: missing daemon entrypoint` (127) | Repo moved or `bin/dag` not executable. `chmod +x claude/devin-acu-governor/bin/dag`. |
| `dag boost: first argument must be a user email` | Pass email then amount: `dag boost alice@corp.com 50`. |
| v3 calls return `403 {"detail":"Unauthorized"}` | Wrong key family (Windsurf key on api.devin.ai) or missing RBAC permission. Recreate the `cog_` key enterprise-scoped with the permissions listed above. |
| `GetTeamCreditBalance` "feature not available for your plan" | Expected on the Cognition/ACU SKU — that endpoint serves seat-credit plans. dag doesn't call it anymore. |
| `UsageConfig` `invalid_argument` | Expected on this SKU — per-user credit caps don't exist on ACU billing. dag doesn't call it anymore. |
| Windsurf consumption 429 | Hit the 10/hr team limit. Wait; the playbook reports when to retry. |
| Caps look wrong mid-cycle | Expected: remaining-pool split keeps heavy users' spend and splits only the remainder. See `dag status`. |

---

## Scope notes

- **In scope:** manual, on-demand soft-cap distribution + zero-sum boosts (ledger), org-level hard caps (gated PATCH), consumption/product/model reporting.
- **Out of scope (this round):** automated/scheduled enforcement (cron auto-throttle), per-user hard caps (no API exists on this SKU), org-group limits (`/v3/enterprise/org-group-limits` — 404, feature flag not enabled for this enterprise), and model enable/disable via API (no endpoint exists). The playbook structure makes new `dag <command>` verbs cheap — drop a `playbooks/<cmd>.md` and a `case` arm in `bin/dag`.
