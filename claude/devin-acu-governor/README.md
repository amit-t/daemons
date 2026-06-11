# devin-acu-governor (`dag`)

`dag` governs Devin Enterprise ACU spend from the terminal.

Runtime shape:
- Most commands launch a Claude-agent playbook through `clscb` with deterministic jq math and explicit write gates.
- `doctor`, `dashboard`, `usage`, `usage --group`, `setup-extract`, and `set limit global` run locally with zsh/curl/jq and do **not** launch an agent.
- `all commands` launches a broad Claude-agent lab seeded with the Devin docs index, the pinned ACU/UsageConfig docs, and every current DAG playbook so ad hoc tasks can graduate into exact `dag ...` commands. It can open without a Devin key for docs/design work, but live API calls require `DEVIN_COG_KEY`.

Current ACU-limit contract comes from Devin docs: <https://docs.devin.ai/admin/billing/acu-limits>. Generic DAG sessions also seed from the full docs index at <https://docs.devin.ai/llms.txt> and the Windsurf/Devin Desktop UsageConfig reference at <https://docs.devin.ai/desktop/accounts/api-reference/usage-config#overview>.

## What changed for Local Agent limits

Local Agent ACU limits cover Devin Desktop, Windsurf JetBrains, and Devin CLI.

Enforcement has two independent gates:
1. per-user effective limit: individual override, else default user limit, else no per-user limit;
2. organization-level Local Agent limit for the user's billing org.

Both gates must pass. All limits reset monthly. A user override replaces the default; it does not add to it. `cycle_acu_limit: 0` blocks that scope. `local_agent: null` clears that scope.

`dag` now uses the V3 beta ACU-limit endpoints:
- `PATCH /v3beta1/enterprise/users/{user_id}/consumption/acu-limits`
- `GET /v3beta1/enterprise/users/{user_id}/consumption/acu-limits`
- `PATCH /v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits`
- `GET /v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits`

UI note printed after limit work: open `app.devin.ai > Enterprise Settings > Consumption` to view current-cycle Local Agent usage by product/user. Configured Local Agent limits are API-managed; `dag` proves writes with live GET verification.

## Commands

| Command | Mutates | Purpose |
|---|---:|---|
| `dag set-limits` | ✅ user limits + ledger | Discover engineers/user IDs, compute remaining-pool prorated caps, PATCH every user's Local Agent override, live-GET verify each write |
| `dag set-limits-new` | ✅ user limits + ledger | Cap only users who have **no explicit cap** yet, funded zero-sum by Borrowing headroom from the lowest-consuming capped users; PATCH recipients + donors; live-GET verify; Σ caps unchanged |
| `dag set limit global <acus> [org_id\|org_name]` | ✅ org limit | Local one-time command: set every org's aggregate Local Agent limit when selector is omitted, or one selected org when passed; live-GET verify each |
| `dag set-limit global <acus> [org_id\|org_name]` | ✅ org limit | Alias for `dag set limit global` |
| `dag boost <email> [acus]` | ✅ user limits + ledger | Boost one engineer by Borrowing from low consumers; PATCH recipient + donors; live-GET verify every changed user |
| `dag user <email>` | ❌ read-only | Deep-dive one user's consumption, explicit/default/effective Local Agent limit, product/model/IDE burn |
| `dag usage [--json] [--top <n>]` | ❌ read-only | Local table of every user's consumed ACUs, effective Local Agent cap, and consumed/cap ratio; no agent, no writes |
| `dag usage --group [idp_group_name] [--json] [--top <n>]` | ❌ read-only | Local exact-IDP-group report; prompts when name is omitted; adds last-3-days per-user usage/product/status detail |
| `dag usage--group [idp_group_name] [--json] [--top <n>]` | ❌ read-only | Alias for `dag usage --group` |
| `dag status` | ❌ read-only | Enterprise burn, projection, org Local Agent caps, default user limit, top users/models |
| `dag status --group [idp_group_name]` | ❌ read-only | Agent status report scoped to one exact IDP group; prompts when name is omitted; emphasizes last-3-days user patterns |
| `dag status--group [idp_group_name]` | ❌ read-only | Alias-style compact spelling for `dag status --group` |
| `dag models [file\|names…]` | ❌ report | Per-model burn + Admin Portal allowlist walkthrough |
| `dag all commands [task…]` | ⚠️ gated by task | Generic Devin API/DAG command lab: fetches live docs index, seeds ACU/UsageConfig docs plus all DAG playbooks, handles ad hoc tasks, and turns good tasks into exact `dag ...` commands/specs when asked to "spin it up" |
| `dag all-commands [task…]` | ⚠️ gated by task | Alias for `dag all commands` |
| `dag doctor` | ❌ probe | Probe required v3/v3beta1 key permissions plus optional Windsurf scopes |
| `dag dashboard` | ❌ read-only | Local burn-rate + forecast dashboard with org and user consumed-vs-cap ACUs; no agent, no writes; optional `--refresh` auto-regeneration |
| `dag setup-extract` | ❌ local secret output | Print pasteable target-machine `security add-generic-password` commands containing the currently configured DAG keys |
| `dag help` | ❌ | Usage text |

Every agent-driven API write is gated: the agent shows endpoint, old value, new value, body, and waits for explicit confirmation. The local `dag set limit global` command is itself the explicit one-time write command and verifies immediately.

## `dag set-limits`

Goal: distribute `DAG_MONTHLY_ACU_POOL` (default 24,000 ACUs) across confirmed engineers, prorated by current cycle burn.

Flow:
1. GET current cycle from `/v3/enterprise/consumption/cycles`.
2. GET roster from `/v3/enterprise/members/users`; build email ↔ `user_id` map.
3. Fetch per-user cycle consumption:
   - Windsurf key: one `server.codeium.com/api/v2alpha/analytics/consumption?product=agent&group_by=user` request.
   - No Windsurf key: loop `/v3/enterprise/consumption/daily/users/{user_id}`.
4. Cross-check summed users against enterprise total.
5. Confirm engineer set.
6. Run `lib/compute-caps.jq` on `{pool, users:[{user_id,email,consumed}]}`.
7. Read current user overrides with `GET /v3beta1/enterprise/users/{user_id}/consumption/acu-limits`.
8. Preview email, user_id, consumed, old override, new cap, delta, Σ caps vs pool, UI instruction.
9. On confirmation, PATCH every user: `{"local_agent":{"cycle_acu_limit":<cap>}}`.
10. GET each changed user limit after PATCH and confirm exact cap.
11. Write `$DAG_STATE_DIR/allocations.json` as audit/resume data.
12. List users near/over cap; point to `dag boost`.

Proration math: `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`. If nothing has been consumed, everyone gets `floor(pool / N)`. If pool is exhausted, caps freeze at current consumption and warnings print.

```zsh
dag set-limits
```

## `dag set-limits-new` — Seed caps for the uncapped, by Borrowing

Goal: give an enforceable Local Agent cap to engineers who currently have **no explicit override** (they ride the inherited org/default limit) — e.g. newly-added hires — **without** disturbing existing capped users beyond a zero-sum Borrow. Total Σ explicit caps is unchanged, so the team never tips into overage. Use this instead of `dag set-limits` when you only want to onboard the uncapped, not re-prorate everyone.

Roles:
- **Recipients** = users whose live `local_agent.cycle_acu_limit` is **unset**. They get new caps.
- **Donors** = users whose cap **is** set, ranked lowest consumer first. They lend cap headroom. Recipients are never donors; no donor is cut below its consumed ACUs + 10% buffer.

Flow:
1. GET current cycle, roster, and per-user consumption (Windsurf one-shot or `daily/users/{user_id}` loop).
2. GET every user's live override and partition into recipients (unset) vs donors (set).
3. Confirm the recipient set (drop service accounts / non-engineers). If none, report "all users already capped" and stop.
4. Run `lib/borrow-caps.jq` on `{donor_buffer, recipients:[{user_id,email,consumed}], donors:[{user_id,email,cap,consumed}]}`.
5. Preview the recipient caps and donor Borrow table; the output proves `sum_before == sum_after` (`zero_sum: true`).
6. On confirmation, PATCH every recipient and tapped donor via `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`; GET each to verify.
7. Update the ledger; report newly-capped users, donors + given, and any left uncapped.

Borrow math (`lib/borrow-caps.jq`), zero-sum in every mode:
- `even_share` — donors have ample headroom: `cap_i = floor(consumed_i) + share`, `share = floor((Σ donor_headroom − Σ floor(consumed)) / N)` (≥ 1). Remaining budget is prorated evenly.
- `min_cover` — headroom covers consumption only: `cap_i = ceil(consumed_i)`, no growth headroom (warns).
- `partial` — headroom too thin: fund the cheapest recipients first, leave the rest uncapped (listed), never create overage.

No recipient is ever capped below its own current consumption. The borrow draws from the lowest consumers first.

```zsh
dag set-limits-new
```

## `dag set limit global <acus> [org_id|org_name]`

One-time local command for the org-level Local Agent gate. No agent launch. If `org_id|org_name` is omitted, it applies the same limit to **all organizations** returned by `/v3/enterprise/organizations`.

Behavior:
1. Resolves the `cog_` key.
2. GETs `/v3/enterprise/organizations`.
3. If no selector is passed, iterates over every organization returned by `/v3/enterprise/organizations`. If a selector is passed, matches it by `org_id` or exact case-insensitive name.
4. PATCHes `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits` with `{"local_agent":{"cycle_acu_limit":N}}`.
5. GETs each changed resource and confirms `local_agent.cycle_acu_limit == N`.
6. Prints UI instructions.

Examples:

```zsh
dag set limit global 2400                  # set every org's Local Agent cap to 2400 ACUs
dag set limit global 2400 org-xyz789       # explicit org id
dag set-limit global 2400 "Platform Eng"  # alias + org name
```

`0` is allowed and blocks Local Agent usage for that org until increased or cleared.

## `dag boost <email> [acus]` — Boost + Borrow

Goal: raise one legitimate heavy user's enforceable Local Agent user limit without increasing total allocation, by borrowing ACUs from the lowest consumers.

Flow:
1. Resolve target email to `user_id` from roster.
2. Fetch per-user consumption and live current user limits.
3. Rank lowest consumers as Borrow donors.
4. Run `lib/boost-plan.jq`:
   - recommended cap = `ceil(projected_month_end × 1.15)` unless `[acus]` is passed;
   - donor floor = `consumed + 10% of even share`;
   - output proves `sum_before == sum_after` when fully funded.
5. Preview recipient Boost and donor Borrow table.
6. On confirmation, PATCH recipient and donors via `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`.
7. GET every changed user limit after PATCH and confirm planned caps.
8. Update ledger and print UI instruction.

```zsh
dag boost alice@corp.com         # recommend amount from alice's run-rate
dag boost alice@corp.com 50      # boost alice by exactly 50 ACUs, funded from low consumers
```

Argument rules:
- `<email>` must look like an email (`*@*.*`) — else exit 2.
- `[acus]`, if given, must be a positive integer — else exit 2. Omit it to use the recommendation.

## `dag user <email>`

Read-only. Reports:
- current-cycle ACUs from `/v3/enterprise/consumption/daily/users/{user_id}`;
- explicit user override and billing org from `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`;
- default user limit from `/v3beta1/enterprise/users/consumption/acu-limits`;
- effective per-user Local Agent limit, headroom, % used, trajectory;
- product split, daily trend, team context;
- model/IDE breakdown and activity when the optional Windsurf key exists;
- UI instruction for Enterprise Settings > Consumption.

```zsh
dag user alice@corp.com
```

## `dag usage`

Local, deterministic, read-only. One table of **every** enterprise user with current-cycle consumed ACUs, effective Local Agent cap, and consumed/cap ratio. No agent launch, no token cost, no writes. All arithmetic lives in `lib/usage.jq`.

Flow:
1. Resolve the `cog_` key.
2. GET current cycle from `/v3/enterprise/consumption/cycles`.
3. GET the default per-user Local Agent cap from `/v3beta1/enterprise/users/consumption/acu-limits` (inherited when a user has no override).
4. GET the roster from `/v3/enterprise/members/users` (cursor pagination via `after`/`end_cursor`).
5. Per user: GET `/v3/enterprise/consumption/daily/users/{user_id}` for cycle consumption and GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for the explicit override (`user_id` is URL-encoded; a `404` means no override).
6. `lib/usage.jq` resolves each user's effective cap (override → default → none), computes `ratio = consumed/cap`, tags state, and sorts most-pressured first.

Effective cap precedence: explicit per-user override, else default user limit, else none (an override replaces, not adds to, the default). State tags: `OVER` (ratio ≥ 1), `NEAR` (≥ 0.8), `OK`, `UNLIMITED` (no cap → `∞`, sorts last), `BLOCKED` (cap 0, unused).

```zsh
dag usage                 # full table, sorted by consumed/cap ratio desc
dag usage --top 10        # only the 10 most-pressured users
dag usage --json          # structured rows + totals (no table), for piping to jq
```

Columns: `EMAIL  CONSUMED  CAP  USED%  SOURCE  STATE`, then a totals line (`sum_caps`, `OVER/NEAR/UNLIMITED/BLOCKED` counts) and the Enterprise Settings UI instruction. No Windsurf key needed — Devin v3 per-user consumption covers it.

### `dag usage --group`

Local, deterministic, read-only. Filters the report to users whose enterprise membership includes an exact IDP group assignment. `--group` prompts for the group name when omitted; group names with spaces can be passed either quoted or as bare words before later flags.

Flow:
1. Resolve the `cog_` key.
2. GET current cycle and the default per-user Local Agent cap, same as `dag usage`.
3. GET `/v3/enterprise/members/idp-users` with cursor pagination, then keep only rows whose `idp_role_assignments[].idp_group_name` exactly matches the requested group.
4. Per matching user: GET current-cycle `/v3/enterprise/consumption/daily/users/{user_id}` and explicit `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`.
5. Compute effective cap, current-cycle consumed ACUs, cap state, last-3-days ACUs, last-3-days average/day, and last-3-days product mix (`devin`, `cascade`, `terminal`, `review`).
6. Sort the visible table by last-3-days burn, then pressure.

```zsh
dag usage --group                       # prompt: IDP group name
dag usage --group "Platform Eng"        # exact IDP group match
dag usage --group Platform Eng --json   # unquoted multi-word group before later flags
dag usage--group "Platform Eng" --top 5 # compact spelling
```

Columns: `EMAIL  CYCLE  LAST3  3D/DAY  DEVIN  CASCADE  TERMINAL  REVIEW  CAP  USED%  STATE  ROLES`, then group totals and last-3-days product mix. If no users match, the command exits 1 and prints visible IDP group names as guidance.

## `dag status`

Read-only. Reports:
- enterprise ACUs consumed, remaining vs `DAG_MONTHLY_ACU_POOL`, run-rate, projected cycle-end, UNDER/OVER verdict;
- product split;
- org consumption plus Local Agent org limits from `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits`;
- default user Local Agent limit;
- top-10 users and per-model burn when the Windsurf key exists;
- fresh ledger exposure if present;
- UI instruction for Enterprise Settings > Consumption.

```zsh
dag status
dag status --group              # prompt: IDP group name, then launch scoped status playbook
dag status --group "Core Eng"   # scoped exact-IDP-group status
dag status--group Core Eng      # compact spelling
```

`dag status --group` keeps `dag status` agent-driven, but seeds the playbook with the exact IDP group name and a GET-only scope. The agent must resolve membership through `/v3/enterprise/members/idp-users`, then report only those users with current-cycle usage/status and a detailed last-3-days pattern. It does not write.

## `dag models [file | names…]`

Read-only model governance. Requires the optional Windsurf key for model-level ACU burn.

```zsh
dag models
dag models claude-sonnet-4-6 swe-1.6
dag models ./allowlist.txt
```

Model enable/disable is still Admin Portal UI work unless Devin ships an API. The playbook re-checks docs before giving final instructions.

## `dag all commands [task…]`

Generic Devin API/DAG command lab. It launches a Claude-agent session with:
- the common `dag` API contract and write-safety rules;
- the complete current DAG playbooks (`set-limits`, `set-limits-new`, `boost`, `user`, `status`, `models`);
- startup instructions to fetch `https://docs.devin.ai/llms.txt` before making API claims;
- pinned documentation seeds for ACU limits, API overview/auth/pagination, and UsageConfig;
- a "spin it up" contract for promoting useful ad hoc work into either an exact existing `dag ...` command or a ready-to-implement new command spec.

```zsh
dag all commands
dag all commands "design a weekly session spend audit"
dag all-commands "find the cleanest API path for repository indexing drift"
```

Use it when you are not sure which specialized DAG command exists yet, or when you want to explore a new Devin admin/API workflow before baking it into a dedicated command. It still follows the common hard rules: reads can proceed, but PATCH/POST/DELETE calls require explicit endpoint/target/body confirmation and live verification.

Unlike the specialized API commands, `dag all commands` can start without `DEVIN_COG_KEY`; the prompt marks that state as docs/design mode and tells the agent to ask for key setup before live API calls.

## `dag doctor`

Local deterministic diagnostic. No agent launch.

Required `cog_` probes:
- Consumption Read: `GET /v3/enterprise/consumption/cycles`
- Org Read: `GET /v3/enterprise/organizations`
- ACU Limit Read: `GET /v3beta1/enterprise/users/consumption/acu-limits`
- ACU Limit Write: PATCH nonexistent org ACU-limit resource; `404/422` proves authz, `403` is inconclusive and verified at real write time
- Roster Read: `GET /v3/enterprise/members/users?limit=1`
- IDP Group Read: `GET /v3/enterprise/members/idp-users?first=1`
- Metrics Read: `GET /v3/enterprise/metrics/usage`

Optional Windsurf probes:
- Teams Read-only: `POST /api/v1/UserPageAnalytics`
- Analytics Read: one low-cost consumption request unless `DAG_DOCTOR_SKIP_ANALYTICS=1`

```zsh
dag doctor
DAG_DOCTOR_SKIP_ANALYTICS=1 dag doctor
```

## `dag dashboard`

Local, read-only dashboard. Fetches cycle, enterprise daily consumption, orgs, per-org daily consumption, enterprise users, each user's current-cycle ACUs, the default per-user Local Agent cap, and each user's explicit Local Agent override. Writes static files under `$DAG_STATE_DIR/dashboard/latest/` by default.

```zsh
dag dashboard
dag dashboard --no-open
dag dashboard --out /tmp/dag-dashboard
dag dashboard --json-only
dag dashboard --refresh 30
dag dashboard --refresh 5 --no-open --out /tmp/dag-dashboard
```

The dashboard shows:

- enterprise consumed/remaining/run-rate/projection cards;
- daily burn chart and product split;
- organization consumed/projected/cap/status table;
- user consumed/effective-cap/headroom/status table, where effective cap is explicit user override if present, otherwise the default per-user Local Agent cap;
- warnings for org cap risk and users already over effective cap.

`--refresh <minutes>` accepts `5`, `10`, `15`, or `30`. It keeps the command running, regenerates the dashboard files on that cadence, and writes refresh metadata so the open browser page reloads itself on the same interval. Keep the terminal process alive; stop with `Ctrl-C`.

Generated files: `data.json`, `dashboard-data.js`, `dashboard.html`, `dashboard.css`, `dashboard.js`. No API writes; tests assert no curl write verbs.

## One-time setup — keys

### Required: Devin API v3 service-user key (`cog_…`)

1. Open `app.devin.ai > Settings > Service users`.
2. Create an enterprise-scoped service user with:
   - **ViewAccountConsumption** — read ACU-limit settings;
   - **ManageBilling** — update/delete ACU-limit settings;
   - **ViewOrgSessions** — consumption/session context;
   - **ViewAccountMetrics** — metrics probe;
   - **ViewAccountMembership** — IDP group membership for `usage --group` and `status --group`.
3. Store the key:

```zsh
security add-generic-password -s devin-cog-key -a "$USER" -w 'cog_…'
```

Fallback: `export DEVIN_COG_KEY=cog_…`. Keychain wins when both exist.

### Migrating keys to another Mac

`dag setup-extract` prints pasteable zsh commands that set both DAG keychain items on a target machine. It intentionally prints live secrets to stdout; run only in a trusted terminal and paste directly into the other Mac.

```zsh
dag setup-extract
```

Output shape:

```zsh
security add-generic-password -U -s devin-cog-key -a "$USER" -w '...'
security add-generic-password -U -s devin-service-key -a "$USER" -w '...'
# Verify after installing dag on target: dag doctor
```

If either source key is missing, the command exits non-zero and prints no setup commands.

### Optional: Windsurf service key

Used for per-model/IDE breakdown and roster activity.

```zsh
security add-generic-password -s devin-service-key -a "$USER" -w '<paste-key>'
```

Fallback: `export DEVIN_SERVICE_KEY=<key>`.

Keys are exported only into child commands/sessions — never printed, logged, or embedded in prompts. Dashboard stores the Authorization header in a 0600 temp file to keep the key out of process args.

## Configuration

`environment.env` holds defaults; shell environment variables override per run.

| Variable | Default | Meaning |
|---|---:|---|
| `DAG_MONTHLY_ACU_POOL` | `24000` | Monthly ACU pool to distribute |
| `DAG_LAUNCHER` | `clscb` | Agent launcher for playbook commands |
| `DAG_COG_KEYCHAIN_SERVICE` | `devin-cog-key` | Keychain item for Devin `cog_` key |
| `DAG_KEYCHAIN_SERVICE` | `devin-service-key` | Keychain item for optional Windsurf key |
| `DAG_STATE_DIR` | `~/.local/state/devin-acu-governor` | Ledger/dashboard state directory |
| `DAG_PRINT_PROMPT` | unset | For agent commands, print prompt and exit |
| `DAG_DOCTOR_SKIP_ANALYTICS` | unset | Skip Windsurf analytics probe |
| `DAG_NOW_EPOCH` | unset | Pin dashboard "now" for deterministic tests |
| `DAG_API_BASE_V3` | `https://api.devin.ai` | Devin v3/v3beta1 base URL |
| `DAG_API_BASE` | `https://server.codeium.com` | Windsurf base URL |

## Safety model

- Agent writes require explicit confirmation.
- Local global command is explicit and verifies immediately.
- Reads gate writes: any failed read stops writes and quotes exact response body.
- Every write is verified with a GET of the same ACU-limit resource.
- Math lives in jq, not agent mental arithmetic.
- Windsurf consumption calls are rate-limit aware.
- Keys never appear in prompts, stdout, generated dashboard files, or ledgers.

## API surface touched

| Endpoint | Method | Used by |
|---|---|---|
| `/v3/enterprise/consumption/cycles` | GET | all agent commands, dashboard, usage, doctor |
| `/v3/enterprise/consumption/daily` | GET | set-limits, status, user context, dashboard |
| `/v3/enterprise/consumption/daily/organizations/{org_id}` | GET | status, dashboard |
| `/v3/enterprise/consumption/daily/users/{user_id}` | GET | set-limits fallback, boost fallback, user, dashboard, usage |
| `/v3/enterprise/members/users` | GET | set-limits, boost, user, dashboard, usage, doctor |
| `/v3/enterprise/organizations` | GET | status, global command, dashboard, doctor |
| `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits` | GET/PATCH | global command, status, optional org guardrails |
| `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` | GET/PATCH | set-limits, boost, user, dashboard, usage |
| `/v3beta1/enterprise/users/consumption/acu-limits` | GET | status, user, dashboard, usage, doctor |
| `/v3/enterprise/metrics/usage` | GET | doctor |
| `/api/v2alpha/analytics/consumption` | GET | set-limits, boost, user, status, models |
| `/api/v1/UserPageAnalytics` | POST | user, doctor |
| `https://docs.devin.ai/llms.txt` | GET | all commands, models doc re-check |
| `https://docs.devin.ai/admin/billing/acu-limits` | GET | all commands seed, common contract source |
| `https://docs.devin.ai/desktop/accounts/api-reference/usage-config#overview` | GET | all commands seed |

## Files

| Path | Responsibility |
|---|---|
| `bin/dag` | Dispatch, arg validation, env load, prompt assembly, local command dispatch |
| `lib/key-resolve.zsh` | Keychain/env key resolution |
| `lib/local-agent-limits.zsh` | Local `dag set limit global` implementation + live GET verification |
| `lib/doctor.zsh` | Local capability probe |
| `lib/dashboard.zsh` / `lib/dashboard.jq` | Local static dashboard fetch + forecast math |
| `lib/usage.zsh` / `lib/usage.jq` | Local `dag usage` per-user consumed-vs-cap fetch + ratio table math |
| `web/dashboard/` | Static dashboard assets |
| `lib/compute-caps.jq` | Per-user cap proration, preserving `user_id` |
| `lib/boost-plan.jq` | Boost + Borrow zero-sum plan |
| `lib/boost-check.jq` | Pool-headroom check for overage path |
| `lib/borrow-caps.jq` | Zero-sum cap-seeding for `set-limits-new` (uncapped users funded by Borrowing from lowest consumers) |
| `playbooks/_common.md` | API contract, safety rules, UI instructions |
| `playbooks/{set-limits,set-limits-new,boost,user,status,models,all-commands}.md` | Agent command flows |
| `test/` | zsh tests + fixtures |

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success/help/print-prompt/local read success |
| `1` | Missing key or read/write/verification failure |
| `2` | Usage error |
| `3` | `dag doctor`: required capability missing/uncertain |
| `127` | global wrapper cannot find daemon entrypoint |

## Verification

```zsh
zsh claude/devin-acu-governor/test/run.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/lib/*.zsh
DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=x dag set-limits
DEVIN_COG_KEY=x dag set limit global 2400 org-xyz789   # live command; use only with real intent
```

Test coverage spans key resolution, setup-extract command generation, cap math, Boost/Borrow math, zero-sum cap-seeding math (`set-limits-new`), CLI prompt assembly, all-commands docs/playbook seeding, no-key docs/design mode, global org Local Agent limit write+verify, doctor v3beta1 + IDP membership probes, dashboard artifact/error/read-only behavior, and `dag usage` ratio/group math + pagination + URL-encoding + read-only/key-leak guards.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dag: no Devin API v3 service-user key` | Store `cog_…` in Keychain or `DEVIN_COG_KEY`. |
| `ACU Limit Read missing` in doctor | Key lacks `ViewAccountConsumption`. |
| `ACU Limit Write missing` or real PATCH 403 | Key lacks `ManageBilling`, wrong key family, or wrong org scope. |
| `IDP Group Read missing` in doctor | Key lacks `ViewAccountMembership`; `dag usage --group` and `dag status --group` need it. |
| Only one org should change | Pass `org_id` or exact org name; omitting selector intentionally updates all orgs. |
| Verification mismatch after PATCH | The API did not persist the requested limit; output quotes the GET body. Do not assume success. |
| Windsurf analytics 429 | Rate limit is 10 req/hr/team. Retry later or skip model/IDE detail. |
