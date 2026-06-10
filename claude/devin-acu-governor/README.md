# devin-acu-governor (`dve`)

Devin Enterprise ACU governor. A thin zsh launcher hands each job to a Claude agent session (`clscb` by default), armed with a playbook: the full Devin Desktop API contract, deterministic jq math, and confirmation gates before any write. You drive the run interactively inside the agent session.

- **Spec:** `docs/superpowers/specs/2026-06-10-devin-acu-governor-design.md`
- **Plan:** `docs/superpowers/plans/2026-06-10-devin-acu-governor.md`

---

## What it can do — at a glance

| Command | Writes? | One-line capability |
|---|---|---|
| `dve set-limits` | ✅ caps | Distribute the monthly ACU pool across all approved devs as prorated per-user caps |
| `dve boost <email> [acus]` | ✅ caps | Zero-sum reallocation: raise a heavy user's cap by taking ACUs from the lowest consumers (Σ caps unchanged → no overage). Recommends amount + donors |
| `dve user <email>` | ❌ read-only | Deep-dive one user: consumption, run-rate, projection, which models/IDEs they use, daily trend, team rank |
| `dve status` | ❌ read-only | Consumption, remaining ACUs, run-rate, month-end projection + UNDER/OVER verdict, top consumers, per-model burn |
| `dve models [file\|names…]` | ❌ report | Per-model ACU burn report + desired-allowlist diff + Admin Portal walkthrough |
| `dve doctor` | ❌ probe | Check the service key against each endpoint and report which of the 4 scopes it actually holds |
| `dve help` | ❌ | Usage text |

Every write is gated: the agent shows a full plan (every email, every cap, sum vs pool) and waits for your explicit confirmation before calling the API. No silent mutations.

---

## Commands in full

### `dve set-limits`
Distribute `DVE_MONTHLY_ACU_POOL` (default 24,000) across approved team members as per-user add-on credit caps.

What it does, in order:
1. Reads the billing cycle dates (`GetTeamCreditBalance`).
2. Pulls per-user consumption for the cycle so far (`consumption`, `group_by=user`).
3. Pulls the roster (`UserPageAnalytics`), keeps only `USER_TEAM_STATUS_APPROVED` members, merges with consumption.
4. Shows headcount **N** and asks you to confirm or override it.
5. Computes caps via `lib/compute-caps.jq`:
   - **Day-1 (nothing consumed):** one flat `team_level` cap = `floor(pool / N)` — a single API call for the whole team.
   - **Mid-month (remaining-pool split):** `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)`. Splits *what's left* evenly so nobody is instantly blocked; heavy users keep what they've already spent plus an even share of the remainder.
   - **Pool exhausted / near-exhausted:** freezes caps at current consumption and warns.
6. Shows a preview table (email, consumed, new cap, Σ caps vs pool) → waits for confirmation.
7. Writes caps (`UsageConfig`) — one team-level call on day-1, else one call per user.
8. Spot-verifies 5 random users (or all if N ≤ 5) via `GetUsageConfig`.
9. Writes the allocation ledger (`$DVE_STATE_DIR/allocations.json`).

```zsh
dve set-limits
```

### `dve boost <email> [acus]`
Raise a heavy, legitimate consumer's cap **without spending more money** — the ACUs come from the lowest consumers, so total allocation (Σ caps) is unchanged and the team stays out of overage.

What it does:
1. Reads cycle dates + per-user consumption; derives the recipient's `consumed`, daily run-rate, and days left.
2. Reads the recipient's current cap (`GetUsageConfig`).
3. Ranks the **lowest consumers** as donor candidates (excludes the recipient).
4. Runs `lib/boost-plan.jq`:
   - **Recommended cap** = `ceil(projected_month_end × 1.15)` — the user's run-rate projection plus a 15% comfort buffer (override by passing `[acus]`, which boosts by exactly that delta).
   - **Donor takes:** greedily pulls from the lowest consumers first, never cutting a donor below `consumed + 10% of an even share` (so no donor is retroactively blocked).
   - Returns a Σ-invariant plan: `sum_before == sum_after`.
5. Shows a **before/after table** (recipient + each donor, proving zero-sum), surfaces warnings. If donors can't fully fund the recommendation (`shortfall`), offers: accept the partial raise, add donors, or knowingly cover the rest from pool headroom (overage).
6. On your confirmation, writes every cap atomically (`UsageConfig`), verifies, updates the ledger. Partial-failure → reports applied/failed and offers rollback.

```zsh
dve boost alice@corp.com         # recommend amount from alice's run-rate; auto-pick donors
dve boost alice@corp.com 50      # boost alice by exactly 50 ACUs, funded from low consumers
```

Argument rules (validated before any agent launch):
- `<email>` must look like an email (`*@*.*`) — else exit 2.
- `[acus]`, if given, must be a positive integer — else exit 2. Omit it to use the recommendation.

### `dve user <email>`
Read-only deep dive on one person. No gates, nothing written.

Reports:
- **Headline:** ACUs consumed this cycle, their cap, headroom, % of cap used.
- **Trajectory:** daily run-rate, projected month-end, whether/when they'll exhaust their cap.
- **Model breakdown:** ACUs + message count per `model_uid`, sorted — exactly which models they lean on and how costly each is.
- **IDE breakdown**, **daily trend** (with spike call-outs).
- **Team context:** their rank by ACU and consumption vs team median.
- **Activity:** active days, last autocomplete/chat/command usage; flags spend concentrated in few days.
- Points to `dve boost <email>` if they're near/over cap.

```zsh
dve user alice@corp.com
```

### `dve status`
Read-only health check. No gates, nothing written.

Reports:
- Total ACUs consumed this cycle, remaining vs pool.
- Days elapsed / left in the cycle.
- Daily run-rate and **projected month-end total**.
- **UNDER / OVER** verdict and by how much.
- Top-10 consumers by ACU with share of total.
- Per-model burn (ACUs by `model_uid`, descending).
- If the ledger exists: Σ caps vs pool (allocation exposure).
- Flags anomalies (e.g. one user > 3× median, a single model dominating).

```zsh
dve status
```

### `dve models [file | names…]`
Model governance and reporting.

> **Limitation (verified 2026-06-10):** the Devin Desktop API has **no** endpoint to enable/disable models. Availability is controlled only in the Admin Portal UI. So this command *reports and instructs*; it does not flip models itself. The playbook re-checks the docs for a new API on every run and will use it automatically if one ships.

What it does:
1. Re-checks `docs.devin.ai/llms.txt` for a model-config API.
2. Pulls per-model ACU burn (`consumption`, `group_by=model_uid`).
3. If you supply a desired allowlist, diffs observed vs allowed:
   - allowed & in use, allowed & unused, and **in use but NOT allowed** (the ones disabling will hit — with their ACU burn and the users most affected).
4. Prints exact Admin Portal steps to apply the allowlist (Settings → Models Configuration → filter by model/provider → enable/disable → optional Default Model Override).

```zsh
dve models                                   # report current per-model burn only
dve models claude-sonnet-4-6 swe-1.6         # diff against an inline allowlist
dve models ./allowlist.txt                   # diff against a file (one model per line / any text)
```

### `dve doctor`
Deterministic local diagnostic — **no agent launch, no token cost**. Probes the resolved service key against each endpoint and reports which of the four scopes it actually holds, by mapping HTTP status codes:

| Scope | Probe | Present | Missing |
|---|---|---|---|
| Billing Read | POST `GetTeamCreditBalance` | 200 | 401/403 |
| Billing Write | POST `UsageConfig` with no scope/cap fields — **mutates nothing** (authz passes → 400 validation; scope absent → 401/403) | 200/400 | 401/403 |
| Analytics Read | GET `consumption` (1-day, `page_size=1`) | 200 | 401/403 |
| Teams Read-only | POST `UserPageAnalytics` | 200 | 401/403 |

`429` (analytics rate limit) and `000` (unreachable) report as inconclusive. Exit `0` when all probed scopes pass, `3` when any is missing/uncertain, `1` when no key is found.

```zsh
dve doctor                              # probe all four scopes
DVE_DOCTOR_SKIP_ANALYTICS=1 dve doctor  # skip the analytics probe (saves 1 of 10/hr consumption calls)
```

Run it right after creating the key to confirm scopes before any real work.

### `dve help`
Prints usage and config reference. Also `dve -h`, `dve --help`.

---

## One-time setup — get and store the service key

Service keys are created in the team admin UI (not via API):

1. Open **https://windsurf.com/team/settings** as a team admin.
2. **Service Keys** → create a new key.
3. Assign all four scopes `dve` needs:
   - **Billing Read** — `GetTeamCreditBalance`, `GetUsageConfig`
   - **Billing Write** — `UsageConfig` (set/clear caps)
   - **Analytics Read** — `/api/v2alpha/analytics/consumption`
   - **Teams Read-only** — `UserPageAnalytics`
4. Keep it **team-scoped** (not group-scoped) so it sees the whole org.
5. Copy the key (shown once) and store it:

```zsh
security add-generic-password -s devin-service-key -a "$USER" -w '<paste-key>'
```

Fallback if you can't use Keychain: `export DEVIN_SERVICE_KEY=<key>`. Keychain wins when both exist. The key is exported only into the agent session's environment — never printed, logged, or embedded in a prompt.

---

## Configuration

`environment.env` holds defaults; **shell environment variables override them** per-run.

| Variable | Default | Meaning |
|---|---|---|
| `DVE_MONTHLY_ACU_POOL` | `24000` | Monthly ACU pool to distribute |
| `DVE_LAUNCHER` | `clscb` | Agent launcher command the prompt is handed to |
| `DVE_KEYCHAIN_SERVICE` | `devin-service-key` | Keychain item name holding the key |
| `DVE_STATE_DIR` | `~/.local/state/devin-acu-governor` | Allocation ledger directory |
| `DVE_PRINT_PROMPT` | _(unset)_ | If set, print the assembled prompt and exit — **does not launch the agent**. Inspection/debugging. |
| `DVE_DOCTOR_SKIP_ANALYTICS` | _(unset)_ | If set, `dve doctor` skips the analytics probe (saves 1 of 10/hr consumption calls). |
| `DVE_API_BASE` | `https://server.codeium.com` | API base URL `dve doctor` probes (override for testing). |

Example overrides:

```zsh
DVE_MONTHLY_ACU_POOL=30000 dve set-limits        # try a different pool for one run
DVE_PRINT_PROMPT=1 dve boost bob@corp.com 100     # see the exact prompt, launch nothing
DVE_LAUNCHER=clb dve status                        # use a different Claude wrapper
```

---

## How a run works

```
dve set-limits
 └─ bin/dve: load environment.env (shell env wins)
 └─ validate args (boost email/amount; unknown cmd → exit 2)
 └─ resolve key: Keychain → $DEVIN_SERVICE_KEY → exit 1 with setup hint
 └─ assemble prompt: playbooks/_common.md + playbooks/<cmd>.md + Run context
    (today, pool, jq program paths, ledger path, command args)
 └─ export DEVIN_SERVICE_KEY into the child shell only
 └─ exec  zsh -ic "clscb '<prompt>'"   → interactive agent session opens
 └─ agent: API reads → jq math → preview → YOUR confirmation → writes → verify → ledger
```

The **allocation ledger** (`$DVE_STATE_DIR/allocations.json`) records per-user caps and their sum per billing cycle:

```json
{ "cycle_start": "...", "cycle_end": "...", "updated": "...",
  "caps": { "alice@corp.com": 280, "...": 230 }, "sum_caps": 23980 }
```

`boost` uses it for headroom; it's rebuilt from the API when missing or when its `cycle_start` no longer matches the live billing cycle.

---

## Safety model

- **No write without confirmation.** Every `UsageConfig` set/clear is preceded by a full plan and an explicit confirm.
- **Reads gate writes.** Any failed read stops the run before any write; the exact API error body is quoted.
- **Deterministic math.** All cap/headroom numbers come from the jq programs, never agent mental arithmetic.
- **Rate-limit aware.** The consumption endpoint allows 10 req/hr/team; playbooks fetch once per run, reuse ETags, and back off on 429 instead of retrying.
- **No key leakage.** The service key never appears in prompts, output, logs, or the ledger.

---

## Devin Desktop API surface touched

Base: `https://server.codeium.com`.

| Endpoint | Method | Scope | Used by |
|---|---|---|---|
| `/api/v1/GetTeamCreditBalance` | POST | Billing Read | set-limits, boost, user, status, models, doctor |
| `/api/v1/GetUsageConfig` | POST | Billing Read | set-limits (verify), boost (recipient + donors), user |
| `/api/v1/UsageConfig` | POST | Billing Write | set-limits, boost, doctor (no-op probe) |
| `/api/v2alpha/analytics/consumption` | GET | Analytics Read | set-limits, boost, user, status, models, doctor |
| `/api/v1/UserPageAnalytics` | POST | Teams Read-only | set-limits, boost (donors), user, doctor |

Full field-level contract lives in `playbooks/_common.md`.

---

## Files

| Path | Responsibility |
|---|---|
| `bin/dve` | Dispatch, arg validation, env load, key resolution, prompt assembly, agent launch |
| `lib/key-resolve.zsh` | `dve_resolve_service_key()`: Keychain → `$DEVIN_SERVICE_KEY` |
| `lib/doctor.zsh` | `dve_doctor()`: deterministic per-scope HTTP probe (no agent) |
| `lib/compute-caps.jq` | Remaining-pool split; day-1 flat split; exhausted-pool warnings |
| `lib/boost-plan.jq` | Zero-sum boost: recommended cap from projection, donor takes (consumed+buffer floor), Σ-invariant |
| `lib/boost-check.jq` | Pool-headroom check (used for the shortfall→overage path) |
| `playbooks/_common.md` | API contract (5 endpoints) + hard rules (gates, rate limits, no key leakage) |
| `playbooks/set-limits.md` | set-limits step flow |
| `playbooks/boost.md` | zero-sum boost step flow (donors → recipient) |
| `playbooks/user.md` | per-user deep-dive step flow |
| `playbooks/status.md` | status step flow |
| `playbooks/models.md` | models step flow + portal walkthrough |
| `environment.env` | Default config (env vars override) |
| `test/` | zsh test files + `run.zsh` runner |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (or `help`, or `DVE_PRINT_PROMPT` print-and-exit) |
| `1` | No service key found (Keychain miss + `DEVIN_SERVICE_KEY` unset) |
| `2` | Usage error: no command, unknown command, or bad `boost` arguments |
| `3` | `dve doctor`: one or more scopes missing or uncertain |
| `127` | `dve` alias wrapper couldn't find the daemon entrypoint |

---

## Verification

```zsh
zsh claude/devin-acu-governor/test/run.zsh           # all test files (92 assertions)
zsh -n claude/devin-acu-governor/bin/dve             # parse check
DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=x dve status     # inspect assembled prompt, launch nothing
```

Test coverage: key resolution order (4), cap math incl. day-1/mid-month/exhausted/fractional/single-user (15), boost-plan zero-sum reallocation incl. fund/shortfall/override/no-op + Σ-invariant (21), pool-headroom check (6), CLI dispatch + validation + prompt assembly + key-leak guard (27), doctor scope classification + exit codes + key-leak guard (19).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dve: no Devin service key found` | Key not stored. Run the `security add-generic-password …` setup, or `export DEVIN_SERVICE_KEY`. |
| `dve: missing daemon entrypoint` (127) | Repo moved or `bin/dve` not executable. `chmod +x claude/devin-acu-governor/bin/dve`. |
| `dve boost: first argument must be a user email` | Pass email then amount: `dve boost alice@corp.com 50`. |
| API 401 / insufficient permission | Key missing a scope. Recreate with all four scopes at windsurf.com/team/settings. |
| consumption 429 | Hit the 10/hr team limit. Wait; the playbook reports when to retry. |
| Caps look wrong mid-month | Expected: remaining-pool split keeps heavy users' spend and splits only the remainder. See `dve status` for the picture. |

---

## Scope notes

- **In scope:** manual, on-demand cap distribution, per-user boosts, consumption reporting, model-burn reporting.
- **Out of scope (this round):** automated/scheduled enforcement (cron auto-throttle), the Devin Cloud API (`api.devin.ai` v2/v3 org-level limits), and model enable/disable via API (no endpoint exists). The `claude/` family and playbook structure make adding new `dve <command>` verbs cheap — drop a `playbooks/<cmd>.md` and a `case` arm in `bin/dve`.
