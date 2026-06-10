# devin-acu-governor (`dve`)

Devin Enterprise ACU governor. A thin zsh launcher hands each job to a Claude agent session (`clscb` by default) armed with a playbook: the full Devin Desktop API contract, deterministic jq math, and confirmation gates before any write. You drive the run interactively inside the agent session.

Spec: `docs/superpowers/specs/2026-06-10-devin-acu-governor-design.md`.

## Commands

| Command | Does |
|---|---|
| `dve set-limits` | Distributes the monthly ACU pool (default 24,000) across approved team members as per-user caps. Mid-month runs use a remaining-pool split — `cap_i = floor(consumed_i) + floor((pool − total_consumed) / N)` — so nobody is instantly blocked. Day-1 runs degenerate to one flat `team_level` cap. Preview table + confirmation before writes; spot-verifies 5 users after. |
| `dve boost <email> <acus>` | Raises one user's cap by `<acus>` after a pool headroom check against the allocation ledger. Over-pool boosts require an explicit informed confirmation. |
| `dve status` | Read-only report: ACUs consumed/remaining, daily run-rate, projected month-end total with an UNDER/OVER verdict, top-10 consumers, per-model burn. |
| `dve models [file\|names...]` | Per-model ACU report and desired-allowlist diff. The Desktop API has no model enable/disable endpoint (verified 2026-06-10; Admin Portal UI only), so the agent prints exact portal steps — and re-checks the docs for a new API on every run. |

## One-time setup

Store a Devin service key with **Billing Read + Write, Analytics Read, Teams Read-only** permissions:

```zsh
security add-generic-password -s devin-service-key -a "$USER" -w '<key>'
```

Fallback: `export DEVIN_SERVICE_KEY=<key>`. Keychain wins when both exist. The key is exported only into the agent session's environment, never printed or embedded in prompts.

## Configuration

`environment.env` holds defaults; shell environment variables override them.

| Variable | Default | Meaning |
|---|---|---|
| `DVE_MONTHLY_ACU_POOL` | `24000` | Monthly ACU pool to distribute |
| `DVE_LAUNCHER` | `clscb` | Agent launcher command |
| `DVE_KEYCHAIN_SERVICE` | `devin-service-key` | Keychain item name |
| `DVE_STATE_DIR` | `~/.local/state/devin-acu-governor` | Allocation ledger directory |

## How a run works

```
dve set-limits
 └─ bin/dve: load environment.env (env wins) → resolve key (Keychain → env → exit 1)
 └─ assemble prompt: playbooks/_common.md + playbooks/set-limits.md + run context
    (today, pool, jq program paths, ledger path, command args)
 └─ exec zsh -ic "clscb '<prompt>'" — interactive agent session opens
 └─ agent: API reads → jq math → preview table → your confirmation → writes → verify
```

The allocation ledger (`$DVE_STATE_DIR/allocations.json`) records per-user caps and their sum per billing cycle; `boost` uses it for headroom checks and rebuilds it from the API when missing or cycle-stale.

## Files

| Path | Responsibility |
|---|---|
| `bin/dve` | Dispatch, arg validation, env load, prompt assembly, agent launch |
| `lib/key-resolve.zsh` | `dve_resolve_service_key()`: Keychain → `$DEVIN_SERVICE_KEY` |
| `lib/compute-caps.jq` | Remaining-pool split; warns on exhausted/near-exhausted pools |
| `lib/boost-check.jq` | New cap, new allocation sum, headroom, over-pool flag |
| `playbooks/_common.md` | API contract (5 endpoints) + hard rules (gates, rate limits, no key leakage) |
| `playbooks/<cmd>.md` | Step flow per command |
| `test/` | zsh test files + `run.zsh` runner |

## Verification

```zsh
zsh claude/devin-acu-governor/test/run.zsh      # all test files
zsh -n claude/devin-acu-governor/bin/dve        # parse check
DVE_PRINT_PROMPT=1 DEVIN_SERVICE_KEY=x dve status   # inspect assembled prompt without launching
```
