# devin-acu-governor (`dve`)

Devin Enterprise ACU governor. A thin zsh launcher hands each job to a Claude agent session (`clscb` by default), armed with a playbook: the full Devin Desktop API contract, deterministic jq math, and confirmation gates before any write. You drive the run interactively inside the agent session.

- **Spec:** `docs/superpowers/specs/2026-06-10-devin-acu-governor-design.md`
- **Plan:** `docs/superpowers/plans/2026-06-10-devin-acu-governor.md`

---

## What it can do — at a glance

| Command | Writes? | One-line capability |
|---|---|---|
| `dve set-limits` | ✅ caps | Distribute the monthly ACU pool across all approved devs as prorated per-user caps |
| `dve boost <email> <acus>` | ✅ one cap | Raise one user's cap by N ACUs, with a pool-headroom check |
| `dve status` | ❌ read-only | Consumption, remaining ACUs, run-rate, month-end projection + UNDER/OVER verdict, top consumers, per-model burn |
| `dve models [file\|names…]` | ❌ report | Per-model ACU burn report + desired-allowlist diff + Admin Portal walkthrough |
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

### `dve boost <email> <acus>`
Raise one user's cap when they're a heavy, legitimate consumer — without re-running the whole distribution.

What it does:
1. Reads the user's current cap (`GetUsageConfig`).
2. Reads the allocation ledger for the current Σ caps; rebuilds it from the API if missing or cycle-stale.
3. Runs `lib/boost-check.jq`: `new_cap = current + acus`, recomputes Σ and headroom (`pool − Σ`).
4. If the boost pushes total allocation **past the pool**, warns explicitly (this is knowing overage spend) → waits for confirmation either way.
5. Writes the new cap (`UsageConfig`), verifies it, updates the ledger.

```zsh
dve boost alice@corp.com 50      # +50 ACUs to alice's cap
```

Argument rules (validated before any agent launch):
- `<email>` must look like an email (`*@*.*`) — else exit 2.
- `<acus>` must be a positive integer — else exit 2.

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
| `/api/v1/GetTeamCreditBalance` | POST | Billing Read | set-limits, boost, status, models |
| `/api/v1/GetUsageConfig` | POST | Billing Read | set-limits (verify), boost |
| `/api/v1/UsageConfig` | POST | Billing Write | set-limits, boost |
| `/api/v2alpha/analytics/consumption` | GET | Analytics Read | set-limits, status, models |
| `/api/v1/UserPageAnalytics` | POST | Teams Read-only | set-limits, boost (ledger rebuild) |

Full field-level contract lives in `playbooks/_common.md`.

---

## Files

| Path | Responsibility |
|---|---|
| `bin/dve` | Dispatch, arg validation, env load, key resolution, prompt assembly, agent launch |
| `lib/key-resolve.zsh` | `dve_resolve_service_key()`: Keychain → `$DEVIN_SERVICE_KEY` |
| `lib/compute-caps.jq` | Remaining-pool split; day-1 flat split; exhausted-pool warnings |
| `lib/boost-check.jq` | New cap, new allocation sum, headroom, over-pool flag |
| `playbooks/_common.md` | API contract (5 endpoints) + hard rules (gates, rate limits, no key leakage) |
| `playbooks/set-limits.md` | set-limits step flow |
| `playbooks/boost.md` | boost step flow |
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
| `127` | `dve` alias wrapper couldn't find the daemon entrypoint |

---

## Verification

```zsh
zsh claude/devin-acu-governor/test/run.zsh           # all test files (44 assertions)
zsh -n claude/devin-acu-governor/bin/dve             # parse check
DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=x dve status     # inspect assembled prompt, launch nothing
```

Test coverage: key resolution order (4), cap math incl. day-1/mid-month/exhausted/fractional/single-user (15), boost headroom (6), CLI dispatch + validation + prompt assembly + key-leak guard (19).

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
