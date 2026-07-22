# devin-acu-governor (`dag`)

`dag` governs Devin Enterprise ACU spend from the terminal.

Runtime shape:
- Most commands launch a Claude-agent playbook through `clscb` with deterministic jq math and explicit write gates.
- The parent agent is selectable per run: `dag --agent claude|codex|devin <command ...>` (shorthands `--claude`, `--codex`, `--devin`, placed before the command; global wrappers `dag--claude`/`dag--codex`/`dag--devin` from `aliases.zsh`). Default stays Claude via `clscb`; `--agent codex` uses `cxscb`; `--agent devin` uses `devin --permission-mode dangerous -- <prompt>`.
- Model-pinned launcher profiles are also selectable before the command: `--co` launches Claude Opus through `co`, `--cf` launches Claude Fable through `cf`, `--deo` launches Devin Opus through `deo`, and `--def` launches Devin Fable through `def`. These are direct profile flags; canonical `--agent` values remain `claude`, `codex`, and `devin` only.
- The assembled playbook prompt is identical for every agent and launcher profile.
- Every agent prompt also includes Amit's durable global instructions from `~/.codex/memories/global-zsh-and-dag-instructions.md` when that file exists. Missing memory is non-fatal. That file carries shell preferences only — all DAG policy lives in `playbooks/_common.md`, which is injected into every dag session for every engine.
- `doctor`, `dashboard`, `usage`, `usage --group`, `setup-extract`, and `set limit global` run locally with zsh/curl/jq and do **not** launch an agent.
- `all commands` launches a broad Claude-agent lab seeded with the Devin docs index, the pinned ACU/UsageConfig docs, and every current DAG playbook so ad hoc tasks can graduate into exact `dag ...` commands. It can open without a Devin key for docs/design work, but live API calls require `DEVIN_COG_KEY`.

Launcher-profile examples:

```zsh
dag --co status
dag --cf status
dag --deo status
dag --def status
```

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
| `dag set-limits` | ✅ user limits + ledger | Discover active current-member engineers/user IDs, compute remaining-pool prorated caps, PATCH each active user's Local Agent override, live-GET verify each write |
| `dag set-limits <email>` | ✅ target user + donor limits + ledger | Cap only one active current-member user who has no explicit cap yet, funded zero-sum by Borrowing headroom from active capped users; no other uncapped users are capped |
| `dag set-limits-new` | ✅ user limits + ledger | Cap only active current-member users who have **no explicit cap** yet, funded zero-sum by Borrowing headroom from the lowest-consuming active capped users; PATCH recipients + donors; live-GET verify; Σ active caps unchanged |
| `dag new-cycle` | ✅ user limits + ledger | Start-of-cycle full reset: verify the new billing cycle is live (guarded), rebuild every active user's cap from the full monthly pool via `compute-caps.jq`, clear stale excluded-user overrides, live-GET verify, rewrite the ledger fresh |
| `dag set limit global <acus> [org_id\|org_name]` | ✅ org limit | Local one-time command: set every org's aggregate Local Agent limit when selector is omitted, or one selected org when passed; live-GET verify each |
| `dag set-limit global <acus> [org_id\|org_name]` | ✅ org limit | Alias for `dag set limit global` |
| `dag boost <email> [acus]` | ✅ user limits + ledger | Boost one engineer by Borrowing from low consumers; PATCH recipient + donors; live-GET verify every changed user |
| `dag boost over` / `dag over` | ✅ user limits + ledger | Boost every user currently over budget in one batch, each funded zero-sum from low consumers; discovers the over set live |
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
| `dag dashboard` | ❌ read-only | Local React burn-rate + forecast dashboard (interactive charts, filterable/sortable org + user cap tables, explicit Details-button per-user detail view with daily ACU chart, model/IDE split, and Devin Cloud session stats) served on `127.0.0.1`; no agent, no writes; optional `--refresh` background data refresh without page reloads |
| `dag setup-extract` | ❌ local secret output | Print pasteable target-machine `security add-generic-password` commands containing the currently configured DAG keys |
| `dag help` | ❌ | Usage text |

Every agent-driven API write is gated: the agent shows endpoint, old value, new value, body, then stops — writes happen only after the user sends the exact token `CONFIRM DAG WRITE` in the same session (see `playbooks/_common.md` "DAG execution contract"). The local `dag set limit global` command is itself the explicit one-time write command and verifies immediately.

## `dag set-limits`

Goal: distribute `DAG_MONTHLY_ACU_POOL` (default 24,000 ACUs) across confirmed active current-member engineers, prorated by current cycle burn. Former users, non-current members, and inactive users are excluded by default so `dag` does not reserve ACUs for people who are not active members. If an excluded user still has a known stale explicit override, the default write plan clears it with `{"local_agent":null}` after confirmation.

Flow:
1. GET current cycle from `/v3/enterprise/consumption/cycles`.
2. GET roster from `/v3/enterprise/members/users`; build email ↔ `user_id` map.
3. Fetch per-user cycle consumption:
   - Windsurf key: one `server.codeium.com/api/v2alpha/analytics/consumption?product=agent&group_by=user` request.
   - No Windsurf key: loop `/v3/enterprise/consumption/daily/users/{user_id}`.
4. With Windsurf analytics, join `/api/v1/UserPageAnalytics` by email and default eligibility to rows whose `teamStatus` is active. Without that key, use current roster membership as the fallback, label active evidence unavailable, and ask the user to remove inactive users before any write.
5. Cross-check summed users against enterprise total.
6. Confirm active engineer set and show excluded inactive/former users separately.
7. Run `lib/compute-caps.jq` on `{pool, users:[{user_id,email,consumed,member,active}]}`; the jq program filters out `member:false` and `active:false`.
8. Read current user overrides with `GET /v3beta1/enterprise/users/{user_id}/consumption/acu-limits`.
9. Preview email, user_id, consumed, old override, new cap, delta, Σ caps vs pool, excluded users, stale excluded-cap cleanup rows, UI instruction.
10. On confirmation, PATCH every active target user: `{"local_agent":{"cycle_acu_limit":<cap>}}`; clear stale explicit overrides for excluded users with `{"local_agent":null}` when their `user_id` is known.
11. GET each changed user limit after PATCH and confirm exact cap or cleared override.
12. Write `$DAG_STATE_DIR/allocations.json` as audit/resume data.
13. List active users near/over cap; point to `dag boost` (or `dag boost over` to clear the whole over set at once).

Proration math for eligible active members: `cap_i = floor(consumed_i) + floor((pool − eligible_total_consumed) / N)`. If nothing has been consumed, everyone active gets `floor(pool / N)`. If pool is exhausted, caps freeze at current consumption and warnings print. Excluded inactive/former users receive no cap row and no pool reservation.

```zsh
dag set-limits
```

### `dag set-limits <email>` — Cap one uncapped user by Borrowing

Targeted mode is for adding an enforceable cap to exactly one active current-member user — for example, one new hire — without re-prorating everyone and without capping other uncapped users.

Behavior:
1. Resolve `<email>` to one current-member `user_id`.
2. Fetch the target's current-cycle consumption and live explicit Local Agent override.
3. If the target already has an explicit cap, stop and report it; use `dag boost <email> [acus]` to raise an existing cap.
4. If the target is uncapped, run `lib/borrow-caps.jq` with `recipients` containing only that target and `donors` containing active capped users. Donors are ranked highest-safe-surplus-first, then lowest consumption, and keep their consumed ACUs plus the donor buffer.
5. Preview one target cap plus donor reductions, proving `zero_sum: true` and `sum_before == sum_after`.
6. After explicit confirmation, PATCH only the target and tapped donors, then GET-verify each changed user.
7. Update the ledger and print the Enterprise Settings > Consumption UI instruction.

```zsh
dag set-limits alice@corp.com
```

## `dag set-limits-new` — Seed caps for the uncapped, by Borrowing

Goal: give an enforceable Local Agent cap to active current-member engineers who currently have **no explicit override** (they ride the inherited org/default limit) — e.g. newly-added hires — **without** disturbing existing active capped users beyond a zero-sum Borrow. Inactive/former users are excluded by default and receive no new reservation; known stale explicit overrides on excluded users are cleared after confirmation. Total Σ explicit caps for the active eligible set is unchanged, so the team never tips into overage. Use this instead of `dag set-limits` when you only want to onboard the uncapped, not re-prorate everyone.

Roles:
- **Recipients** = active current-member users whose live `local_agent.cycle_acu_limit` is **unset**. They get new caps.
- **Donors** = active current-member users whose cap **is** set, ranked highest safe surplus first, then lowest consumption. They lend cap headroom. Recipients are never donors; no donor is cut below its consumed ACUs + 10% buffer.
- **Excluded** = inactive users or users not in the current roster. They are shown for audit but do not get new caps and do not inflate active-member donor headroom.

Flow:
1. GET current cycle, roster, and per-user consumption (Windsurf one-shot or `daily/users/{user_id}` loop).
2. With Windsurf analytics, join `/api/v1/UserPageAnalytics` by email and default eligibility to active current members.
3. GET every user's live override and partition active users into recipients (unset) vs donors (set); put inactive/former users in the excluded audit list.
4. Confirm the recipient set (drop service accounts / non-engineers). If none, report "all active users already capped" and stop.
5. Run `lib/borrow-caps.jq` on `{donor_buffer, recipients:[{user_id,email,consumed,member,active}], donors:[{user_id,email,cap,consumed,member,active}]}`; the jq program filters out `member:false` and `active:false`.
6. Preview the recipient caps, donor Borrow table, excluded inactive/former users, and stale excluded-cap cleanup rows; the output proves `sum_before == sum_after` (`zero_sum: true`) for the active eligible set.
7. On confirmation, PATCH every active recipient and tapped active donor via `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`; clear stale explicit overrides for excluded users with `{"local_agent":null}` when their `user_id` is known; GET each to verify.
8. Update the ledger; report newly-capped active users, donors + given, excluded inactive/former users, cleared stale caps, and any active users left uncapped.

Borrow math (`lib/borrow-caps.jq`), zero-sum in every mode:
- `even_share` — donors have ample headroom: `cap_i = floor(consumed_i) + min(share, max_headroom)`, `share = floor((Σ donor_headroom − Σ floor(consumed)) / N)` (≥ 1). The playbook passes `max_headroom: 250` by default; 250–500 only on explicit in-session user request; above 500 never — the jq built-in default of 500 is the backstop clamp.
- `min_cover` — headroom covers consumption only: `cap_i = ceil(consumed_i)`, no growth headroom (warns).
- `partial` — headroom too thin: fund the cheapest recipients first, leave the rest uncapped (listed), never create overage.

No recipient is ever capped below its own current consumption. Donors may carry an optional `run_rate` (last-7-day average ACUs/day, with cycle `days_left` in the input): the donor's protected floor then covers projected end-of-cycle consumption — `ceil((consumed + run_rate × days_left) × 1.1)` — so heavy burners with big nominal surplus are protected while long-idle users with little nominal headroom become safe donors. The borrow draws from the highest projected safe surplus first (consumed as tie-break); without `run_rate` the legacy consumed-plus-buffer floor applies unchanged.

```zsh
dag set-limits-new
```

## `dag new-cycle` — Start-of-cycle full reset

Run once at the start of every billing cycle. Resets all Local Agent limits and rebuilds the whole cap table from `DAG_MONTHLY_ACU_POOL` (default 24,000) and the current active engineer count — at cycle start consumed ≈ 0, so every confirmed active engineer gets an even `floor(pool / N)` cap.

Flow:
1. **Fresh-cycle guard.** GET `/v3/enterprise/consumption/cycles` and confirm a new cycle is actually current: cycle start within ~3 days **or** consumed total near zero. If the old cycle is still running, the playbook warns loudly and requires explicit confirmation — default is to stop and suggest `dag set-limits`.
2. Full roster + per-user consumption + activity filter (same pattern as `set-limits`); confirm the active engineer set.
3. Rebuild the cap table from scratch with `lib/compute-caps.jq` on the **full** pool (not the remaining pool).
4. Clear stale explicit overrides on excluded inactive/former users with `{"local_agent":null}`.
5. Preview, explicit confirmation, PATCH every active user, live-GET verify each write.
6. **Rewrite the ledger fresh** with the new cycle's epochs — old-cycle data is never merged.

```zsh
dag new-cycle
```

Takes no arguments — `dag new-cycle whatever` exits 2.

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
2. Fetch per-user consumption and live current user limits; derive each donor's `run_rate` (last-7-day average ACUs/day) and the cycle's `days_left`.
3. Rank Borrow donors by highest projected safe surplus (consumed as tie-break) when run rates are supplied; lowest consumers first otherwise.
4. Run `lib/boost-plan.jq`:
   - recommended cap = `ceil(projected_month_end × 1.15)` unless `[acus]` is passed (a passed `[acus]` is planning input only, never write authorization), always clamped to `consumed + max_headroom` — the playbook passes `max_headroom: 250` by default, 250–500 only on explicit in-session request, above 500 never (jq's built-in 500 default is the backstop); the clamp also applies to an explicit `[acus]` and emits a warning;
   - donor floor = `max(consumed + 10% of even share, 50)`, raised to `ceil((consumed + run_rate × days_left) × 1.1)` when the donor's `run_rate` is known — projected heavy burners are protected, long-idle low-headroom users become safe donors;
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

## `dag boost over` — Boost everyone over budget at once

Goal: do exactly what `dag boost` does, but for *every* user currently over their Local Agent cap — without naming anyone. The over set is discovered live each run, so you never enumerate the heavy users yourself.

Over set = state `OVER` from `dag usage`: a user with a finite effective cap (explicit override, else org default) whose `consumed >= cap` (a `cap == 0` blocked user with `consumed > 0` counts too). Unlimited/None caps are never over.

Flow:
1. Fetch roster, per-user consumption, and live current user limits.
2. Select the over set (`consumed >= effective cap`). If empty, report "no users over budget" and stop.
3. Report the over set first — email, consumed, cap, ratio, over-by — sorted most-over first, with the count.
4. Rank lowest consumers as a single shared Borrow donor pool; track each donor's remaining headroom as it is spent across recipients.
5. Run `lib/boost-plan.jq` per recipient (most-over first), carrying donor `cap_after` forward so the batch stays zero-sum (`Σ caps before == Σ caps after`).
6. Show one combined Boost/Borrow preview. Per-recipient `shortfall > 0` offers the same choices as `boost` (partial, more donors, or pool-headroom overage).
7. On one confirmation covering the whole batch, PATCH every recipient and donor, GET-verify each, update the ledger, print the UI instruction.

```zsh
dag boost over    # boost whoever is over budget right now, each funded zero-sum
dag over          # same thing, shorter
```

Argument rules:
- Takes no positional arguments — `dag boost over alice@corp.com` exits 2. The recipients are whoever is over at run time.

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

### `dag usage --user-email`

Local, deterministic, read-only. Resolves one email address to a Devin `user_id`, then prints that user's current-cycle ACU total and daily breakdown. Email input is trimmed, lowercased for lookup, and rejected before API calls when it is empty or not email-like.

Flow:
1. Resolve the `cog_` key.
2. GET current cycle and the default per-user Local Agent cap, same as `dag usage`.
3. Resolve the email in this order:
   - exact email query against `/v3/enterprise/members/users`;
   - paginated `/v3/enterprise/members/users` roster scan, filtered client-side by exact email;
   - paginated exact email query against `/v3/enterprise/members/idp-users` for IDP-derived users.
4. Fail closed on no exact match (`exit 1`) or duplicate exact matches (`exit 1`, listing visible `user_id`s).
5. GET `/v3/enterprise/consumption/daily/users/{user_id}` for the current cycle, and GET `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` for the explicit cap override.
6. Render total ACUs, effective Local Agent cap, and daily rows with product columns (`devin`, `cascade`, `terminal`, `review`) when present in the v3 response.

Date behavior: uses the active billing cycle returned by `/v3/enterprise/consumption/cycles`; there are no custom date flags. Tests pin the clock with `DAG_NOW_EPOCH`.

```zsh
dag usage --user-email alice@corp.com
dag usage --user-email Alice@Corp.com --json
```

Columns: `DATE  ACUS  DEVIN  CASCADE  TERMINAL  REVIEW`, followed by product totals and the Enterprise Settings UI instruction. Permission/auth failures exit `1` and print the HTTP status/body plus a permission hint; tokens are never printed.

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
- the complete current DAG playbooks (`set-limits`, `set-limits-new`, `boost`, `over`, `user`, `status`, `models`);
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

Local, read-only dashboard — a React app (`web/dashboard-app/`, Vite + recharts) served from a localhost-only HTTP server. Fetches cycle, enterprise daily consumption, orgs, per-org daily consumption, enterprise users, each user's current-cycle daily ACUs, the default per-user Local Agent cap, each user's explicit Local Agent override, the cycle's Devin Cloud sessions, and (optionally, with the Windsurf key) the per-user model/IDE ACU split into `data.json`, stages the built app next to it under `$DAG_STATE_DIR/dashboard/latest/` by default, and serves it at `http://127.0.0.1:8642/`. Local-only by design: the server binds `127.0.0.1` and nothing is deployed.

```zsh
dag dashboard
dag dashboard --no-open
dag dashboard --out /tmp/dag-dashboard
dag dashboard --json-only
dag dashboard --port 9000
dag dashboard --refresh 30
dag dashboard --refresh 5 --no-open --out /tmp/dag-dashboard
dag dashboard --rebuild
```

The dashboard shows:

- enterprise consumed/remaining/run-rate/projection/verdict cards with cycle progress, plus a capped-user-total card showing the sum of finite effective user caps (the ACUs consumed if capped users all use their full caps);
- interactive daily burn chart (stacked per-product bars, plus a cumulative + forecast view with the pool reference line) and a product-split donut;
- organization table: sortable columns, status filter chips, per-row cap meters;
- user cap table: free-text search (name/email/org), status and cap-source filter chips, sortable columns, headroom and % of cap, where effective cap is explicit user override if present, otherwise the default per-user Local Agent cap; each email has an adjacent explicit `Copy` button, and each row has a dedicated `Details` button for opening the drawer;
- top-bar refresh status: a live **`next refresh in 4m 32s`** countdown to the next backend refetch, a **`Refreshing N%`** progress bar (with the current phase, e.g. `user dailies (19/40)`) that replaces the `Refresh now` button while the backend is fetching, immediate `Refreshing…` feedback after manual clicks, and a `data refreshed X ago` resting state with a `Refresh now` button for static snapshots;
- warnings for org cap risk and users already over effective cap;
- **per-user detail view**: click a user row's `Details` button to open a drawer with that user's daily ACU line chart over the cycle (with a dashed "cap pace" reference line), Devin Cloud session stats (sessions initiated this cycle + their summed ACUs, from `/v3/enterprise/sessions`), the user's product split (devin/cascade/terminal/review), and — when the optional Windsurf service key is configured — the model split and surface split (Devin Desktop / Windsurf / JetBrains / Devin CLI) of their Devin Desktop & Local usage, with billed ACUs and message counts per row. Close with `Esc`, the `✕` button, or a click outside.

Dashboard cap statuses follow the same zero-cap contract as `dag usage`: no cap is `uncapped`; a zero cap with zero consumed ACUs is `blocked` and does **not** emit an over-cap warning; a zero cap with any consumed ACUs is `over`; positive caps become `over` when consumed ACUs meet or exceed the cap, with `warning`/`critical` thresholds before that.

**First run builds the app once** (`npm install && npm run build` in `web/dashboard-app/`; requires Node.js). Later runs reuse the build; `--rebuild` forces a fresh one (run after pulling app changes).

`--refresh <minutes>` accepts `5`, `10`, `15`, or `30`. It keeps the command running and refetches `data.json` on that cadence **in the background**. Both the terminal and the browser get live feedback through a small `status.json` written next to `data.json`:

- **Terminal.** Between refreshes a single self-rewriting line counts down — `⟳ next refresh in 4m 32s · Ctrl-C to stop`. During a refresh it shows phase progress — `⟳ refreshing 47% · user dailies (19/40)` — across the cycle/daily/org/user fetches, so the long first fetch (before the browser even opens) is no longer a silent wait.
- **Browser.** The app polls `status.json` every second and turns `next_refresh_epoch` into the same `next refresh in …` countdown. Clicking `Refresh now` sends a same-origin, header-gated POST to a localhost-only `__dag_refresh_now` endpoint, which interrupts the backend countdown and queues an immediate refetch; the app hides the button and shows `Refreshing…` until `status.json` catches up. When the backend starts fetching, the button is replaced by a `Refreshing N%` progress bar (with the current phase); when the new snapshot lands, the app pulls the fresh `data.json` (detected via a changed `generated_at`) and returns to `data refreshed X ago` — no page reloads.

`Refresh now` works with or without `--refresh`: in refresh mode it breaks the countdown and starts the next backend fetch early; in static mode it asks the still-running dashboard process to fetch a fresh snapshot on demand. If the app is served by an older/static file server without the endpoint, it falls back to re-pulling the latest written `data.json`. Stop with `Ctrl-C`; the server is killed with the command (also on TERM/HUP).

Port: default `8642`; pin with `--port <n>` or `DAG_DASHBOARD_PORT`. If the default port is busy, a free one is picked automatically (warned on stderr).

Generated files in the output dir: `data.json` (the snapshot), `status.json` (the live refresh/countdown channel), plus the staged app build (`index.html`, `assets/`). Manual refresh uses a local signal file beside those artifacts; Devin API traffic remains read-only. `--json-only` writes `data.json` + `status.json` — no build, no server, no browser. No API writes; tests assert no curl write verbs.

**Transient-failure resilience.** Every GET retries gateway/overload classes — HTTP `429`, `502`, `503`, `504` (e.g. a `504 Gateway Time-out` with an HTML body), and curl transport errors — with bounded linear backoff (`DAG_FETCH_RETRIES`, default 3; `DAG_FETCH_RETRY_SLEEP` seconds × attempt, default 2). If the two per-user ACU-limit endpoints still fail transiently after retries, the dashboard **degrades instead of aborting**: a failed per-user override falls back to the default cap (`cap_source: default`), and a failed default-cap endpoint leaves uncapped users marked `uncapped`. Each degradation prints a warning to stderr. Hard errors (`4xx`/`500`) and any other endpoint remain fatal and quote the exact response body — a single flaky user-limit call no longer takes down the whole dashboard.

**Detail-view enrichments degrade, never abort.** The two data sources that exist only for the per-user detail drawer are treated as optional:

- *Devin Cloud sessions* (`/v3/enterprise/sessions`, needs **ViewOrgSessions**): any failure — including a key without the permission — marks `sessions_info.available: false`; user rows carry `sessions: null` and the drawer shows `—`.
- *Windsurf model/IDE analytics* (`GET https://server.codeium.com/api/v2alpha/analytics/consumption?…&group_by=user,model_uid,ide`, needs the optional Windsurf service key with **Analytics Read**): without the key the drawer simply omits the model split (`model_analytics.reason: no_windsurf_key`). The endpoint is rate-limited to **10 requests/hour/team**, so the dashboard fetches it at most once per `DAG_MODEL_ANALYTICS_TTL_MINUTES` (default 20) and otherwise reuses the section from the previous `data.json`. If a refetch is refused (e.g. the rate limit), the previous snapshot is carried forward and flagged `stale: true` in the UI; with no previous snapshot it degrades to `available: false`.

## One-time setup — keys

### Required: Devin API v3 service-user key (`cog_…`)

1. Open `app.devin.ai > Settings > Service users`.
2. Create an enterprise-scoped service user with:
   - **ViewAccountConsumption** — read ACU-limit settings;
   - **ManageBilling** — update/delete ACU-limit settings;
   - **ViewOrgSessions** — consumption/session context;
   - **ViewAccountMetrics** — metrics probe;
   - **ViewAccountMembership** — enterprise/IDP membership for `usage`, `usage --user-email`, `usage --group`, and `status --group`.
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
| `DAG_LAUNCHER` | `clscb` | Default agent launcher for playbook commands when no selector is given |
| `DAG_LAUNCHER_CLAUDE` | `clscb` | Launcher used by `--agent claude` |
| `DAG_LAUNCHER_CODEX` | `cxscb` | Launcher used by `--agent codex` |
| `DAG_LAUNCHER_DEVIN` | `devin --permission-mode dangerous --` | Launcher used by `--agent devin`; prompt is appended after the trailing `--` |
| `DAG_LAUNCHER_CO` | `co` | Claude Opus profile launcher used by `--co` |
| `DAG_LAUNCHER_CF` | `cf` | Claude Fable profile launcher used by `--cf` |
| `DAG_LAUNCHER_DEO` | `deo` | Devin Opus profile launcher used by `--deo` |
| `DAG_LAUNCHER_DEF` | `def` | Devin Fable profile launcher used by `--def` |
| `DAG_PRINT_LAUNCHER` | unset | For agent commands, print the resolved launcher and exit |
| `DAG_COG_KEYCHAIN_SERVICE` | `devin-cog-key` | Keychain item for Devin `cog_` key |
| `DAG_KEYCHAIN_SERVICE` | `devin-service-key` | Keychain item for optional Windsurf key |
| `DAG_STATE_DIR` | `~/.local/state/devin-acu-governor` | Ledger/dashboard state directory |
| `DAG_PRINT_PROMPT` | unset | For agent commands, print prompt and exit; useful for verifying included playbooks, run context, and global instructions |
| `DAG_DOCTOR_SKIP_ANALYTICS` | unset | Skip Windsurf analytics probe |
| `DAG_NOW_EPOCH` | unset | Pin dashboard "now" for deterministic tests |
| `DAG_API_BASE_V3` | `https://api.devin.ai` | Devin v3/v3beta1 base URL |
| `DAG_API_BASE` | `https://server.codeium.com` | Windsurf base URL |
| `DAG_FETCH_RETRIES` | `3` | Dashboard: retries for transient fetch failures (429/502/503/504, transport) |
| `DAG_FETCH_RETRY_SLEEP` | `2` | Dashboard: backoff seconds × attempt between transient retries |
| `DAG_DASHBOARD_PORT` | unset | Dashboard: pin the local server port (same as `--port`) |
| `DAG_DASHBOARD_DEFAULT_PORT` | `8642` | Dashboard: port tried when none is pinned |
| `DAG_DASHBOARD_APP_DIR` | `web/dashboard-app` | Dashboard: React app source/build directory |
| `DAG_DASHBOARD_NPM` | `npm` | Dashboard: npm command for the one-time app build |
| `DAG_DASHBOARD_PYTHON` | `python3` | Dashboard: python used for the localhost static server |
| `DAG_MODEL_ANALYTICS_TTL_MINUTES` | `20` | Dashboard: minimum minutes between Windsurf model-analytics refetches (endpoint allows 10 req/hr/team) |
| `DAG_WINDSURF_API_BASE` | `https://server.codeium.com` | Dashboard: Windsurf analytics base URL |

## Safety model

- Agent writes require explicit confirmation.
- Local global command is explicit and verifies immediately.
- Reads gate writes: any failed read stops writes and quotes exact response body.
- Every write is verified with a GET of the same ACU-limit resource.
- Math lives in jq, not agent mental arithmetic.
- Direct cap headroom policy in every flow: default plans pass `max_headroom: 250` to the jq programs; 250–500 only on explicit in-session user request; above 500 never — the jq built-in 500 default is the backstop clamp, and raising it means changing repository policy, not a session instruction.
- Writes require the exact in-session token `CONFIRM DAG WRITE` after the preview; shell commands, scope confirmations, and requested increments are planning input only.
- `playbooks/_common.md` carries a DAG execution contract: the assembled prompt is the complete DAG policy for the session, conflicting saved memories/global instructions are ignored, and dag sessions never modify, commit, or push repository files.
- Windsurf consumption calls are rate-limit aware.
- Keys never appear in prompts, stdout, generated dashboard files, or ledgers.

## Future parity hardening (untested)

For the strongest Claude/Codex startup parity, the engines could run in customization-minimal modes — `claude --bare` / `--safe-mode`, `codex exec --ignore-user-config` — with all needed runtime configuration injected explicitly via the dag prompt. Untested against the real `clscb`/`cxscb` wrappers' auth/permission behavior; inspect the wrappers before enabling.

## API surface touched

| Endpoint | Method | Used by |
|---|---|---|
| `/v3/enterprise/consumption/cycles` | GET | all agent commands, dashboard, usage, doctor |
| `/v3/enterprise/consumption/daily` | GET | set-limits, status, user context, dashboard |
| `/v3/enterprise/consumption/daily/organizations/{org_id}` | GET | status, dashboard |
| `/v3/enterprise/consumption/daily/users/{user_id}` | GET | set-limits fallback, boost fallback, user, dashboard, usage |
| `/v3/enterprise/members/users` | GET | set-limits, boost, user, dashboard, usage, doctor |
| `/v3/enterprise/members/idp-users` | GET | usage `--user-email` fallback, usage `--group`, status `--group`, doctor |
| `/v3/enterprise/organizations` | GET | status, global command, dashboard, doctor |
| `/v3beta1/enterprise/organizations/{org_id}/consumption/acu-limits` | GET/PATCH | global command, status, optional org guardrails |
| `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits` | GET/PATCH | set-limits, boost, user, dashboard, usage |
| `/v3beta1/enterprise/users/consumption/acu-limits` | GET | status, user, dashboard, usage, doctor |
| `/v3/enterprise/metrics/usage` | GET | doctor |
| `/v3/enterprise/sessions` | GET | dashboard (per-user Devin Cloud session stats; degrades if unavailable) |
| `/api/v2alpha/analytics/consumption` | GET | set-limits, boost, user, status, models, dashboard (per-user model/IDE split; TTL-cached) |
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
| `lib/dashboard.zsh` / `lib/dashboard.jq` | Dashboard data fetch + forecast math, one-time app build, localhost server |
| `lib/usage.zsh` / `lib/usage.jq` | Local `dag usage` per-user consumed-vs-cap fetch + ratio table math |
| `web/dashboard-app/` | React dashboard app (Vite + recharts); `dist/` and `node_modules/` are gitignored, built on first `dag dashboard` run |
| `lib/compute-caps.jq` | Per-user cap proration, preserving `user_id` |
| `lib/boost-plan.jq` | Boost + Borrow zero-sum plan |
| `lib/boost-check.jq` | Pool-headroom check for overage path |
| `lib/borrow-caps.jq` | Zero-sum cap-seeding for `set-limits-new` and targeted `set-limits <email>` (uncapped users funded by Borrowing from lowest consumers) |
| `playbooks/_common.md` | API contract, safety rules, UI instructions |
| `playbooks/{set-limits,set-limits-new,new-cycle,boost,over,user,status,models,all-commands}.md` | Agent command flows |
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
DAG_PRINT_LAUNCHER=1 DEVIN_COG_KEY=x dag --co status
DAG_PRINT_LAUNCHER=1 DEVIN_COG_KEY=x dag --def status
DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=x dag set-limits
DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=x dag set-limits alice@corp.com
DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=x dag new-cycle
DEVIN_COG_KEY=x dag set limit global 2400 org-xyz789   # live command; use only with real intent
```

Test coverage spans key resolution, setup-extract command generation, cap math, Boost/Borrow math (including the consumed+500 headroom clamp with and without an explicit increment, donor `run_rate` projected floors, and projected-surplus donor ranking), zero-sum cap-seeding math (`set-limits-new` and targeted `set-limits <email>` prompt/validation), CLI prompt assembly (`new-cycle` guard/ledger context and no-arg validation included), all-commands docs/playbook seeding, no-key docs/design mode, global org Local Agent limit write+verify, doctor v3beta1 + IDP membership probes, dashboard artifact/error/read-only behavior including transient-504 retry-recovery and graceful per-user/default ACU-limit degradation, and `dag usage` ratio/group/user-email math + pagination + URL-encoding + read-only/key-leak guards.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dag: no Devin API v3 service-user key` | Store `cog_…` in Keychain or `DEVIN_COG_KEY`. |
| `ACU Limit Read missing` in doctor | Key lacks `ViewAccountConsumption`. |
| `ACU Limit Write missing` or real PATCH 403 | Key lacks `ManageBilling`, wrong key family, or wrong org scope. |
| `IDP Group Read missing` in doctor | Key lacks `ViewAccountMembership`; `dag usage --user-email` IDP fallback, `dag usage --group`, and `dag status --group` need it. |
| Only one org should change | Pass `org_id` or exact org name; omitting selector intentionally updates all orgs. |
| Verification mismatch after PATCH | The API did not persist the requested limit; output quotes the GET body. Do not assume success. |
| Windsurf analytics 429 | Rate limit is 10 req/hr/team. Retry later or skip model/IDE detail. |
| `dashboard: GET … [504] transient; retry` | Devin edge returned a gateway timeout; the fetch auto-retries. Persistent on a per-user ACU-limit endpoint degrades to the default cap (warns on stderr) rather than aborting. Raise `DAG_FETCH_RETRIES` if your gateway is slow. |
| Dashboard exits on `504`/`502`/`503` for cycles/daily/orgs | Those reads are required; transient retries are exhausted. Re-run, or raise `DAG_FETCH_RETRIES`/`DAG_FETCH_RETRY_SLEEP`. |
