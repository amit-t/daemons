# hivemind (`hive`)

Cross-machine sync daemon for **global** agent instructions and memories. One mind, many machines: every Mac ends up with the exact same `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.codex/memories/*.md`, and `~/.gemini/GEMINI.md`. Project-level steering and skills stay per-project on purpose.

Deterministic zsh engines own every snapshot, git write, and live-file overwrite. An agent playbook session owns only the judgment step: reconciling two diverged machines into one golden set.

## Model

The sync ledger lives in the Profiles repo (`~/Profiles/agent-sync/`), which is already synced between machines via GitHub:

```
agent-sync/
  machines/<host>/    per-machine snapshot of global surfaces + manifest.json
                      (host, captured_at, per-file sha256/mtime)
  golden/             the reconciled truth set both machines converge to
  state.json          golden timestamp + per-host applied markers
```

State machine (`hive plan`, read-only):

| action | meaning | what happens |
|---|---|---|
| `NEED_OTHER_MACHINE` | only this host ever snapshotted | run `hive` on the other machine |
| `APPLY_GOLDEN` | a golden set exists this host hasn't applied | `hive apply` overwrites live surfaces, no questions — the decision was already made on the other machine |
| `STALE_OTHER` | other snapshot older than `HIVE_MAX_AGE_HOURS` (24) | asks: refresh the other machine first, or `HIVE_FORCE=1` |
| `IN_SYNC` | all snapshots byte-identical | report and done |
| `RECONCILE` | all fresh, content diverged | agent builds a reconciliation plan (both/only-A/only-B/dupes), Amit approves, golden is built + applied here; other machine hits `APPLY_GOLDEN` on its next run |

Convergence loop: run `hive` on A (reconcile, golden decided, A converged) → run `hive` on B (auto-applies golden) → both identical. Any later drift on either side flips plan back to `RECONCILE`.

## Commands

```
hive [sync]                          full flow as an agent playbook (default launcher cf;
                                     --agent claude|codex|devin, --co/--cf shorthands)
hive snapshot                        pull, snapshot this machine, commit + push
hive plan                            print next action as key=value lines (read-only)
hive apply                           converge live surfaces from golden/ (backs up first)
hive golden init --from <host>       seed golden/ from a machine snapshot
hive golden finalize --hosts <A,B>   stamp golden manifest + state, push
hive status                          hosts, ages, golden state, IN SYNC / DIVERGED
hive diff [--golden | <A> <B>]       content diff between snapshots
hive doctor                          health: jq, Profiles repo, identity, surfaces
```

`hive` always operates from the Profiles directory regardless of where it is invoked; the playbook's first mandated step is `cd` there.

## Safety

- **Backups:** everything `apply` overwrites or removes is copied to `~/.local/state/hivemind/backups/<timestamp>-<host>/` first.
- **Secret guard:** files with credential-looking content (`ghp_…`, `sk-ant-…`, `xox…`, AWS keys, private keys) are refused at snapshot and at golden finalize. Only instruction markdown is registered in `config/surfaces.zsh`; settings/config files that can carry tokens are excluded by design.
- **Personal repo only:** `doctor` fails if the Profiles remote looks like a company repo.
- **Engines-only writes:** the agent never edits live global files by hand; its only hand-written artifact is the staged `agent-sync/golden/` tree.

## Surfaces

Registered in [`config/surfaces.zsh`](./config/surfaces.zsh) as `id|kind|live-path|snapshot-path` (kinds: `file`, `dir-md` = top-level `*.md` only). Absent surfaces are recorded in the manifest, not errors. Add new global instruction files there as agents grow them (Devin/Antigravity/Windsurf candidates documented in the file).

## Config (env)

| var | default | purpose |
|---|---|---|
| `HIVE_PROFILES_DIR` | `~/Profiles` | ledger repo |
| `HIVE_MAX_AGE_HOURS` | `24` | other-machine freshness window |
| `HIVE_LAUNCHER` | `cf` | agent launcher for `sync` |
| `HIVE_FORCE` | unset | `1` = reconcile despite stale other snapshot |
| `HIVE_STATE_DIR` | `~/.local/state/hivemind` | backups |
| `HIVE_HOME`, `HIVE_HOST`, `HIVE_NOW`, `HIVE_NO_GIT`, `HIVE_DRY_LAUNCH`, `HIVE_PRINT_LAUNCHER` | — | test/dry-run hooks |

## Tests

```
zsh claude/hivemind/test/run.zsh
```

Four files, 67 assertions, sandboxed (fake `$HOME`, throwaway local git repo): collect/secret-guard/missing-surface, all five plan actions, golden seed→edit→finalize→apply→backup→idempotence→drift, CLI/launcher/prompt assembly.
