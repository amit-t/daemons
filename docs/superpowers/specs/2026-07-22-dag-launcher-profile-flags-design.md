# DAG Launcher Profile Flags Design

**Date:** 2026-07-22
**Status:** Approved

## Objective

Allow callers to select the new model-pinned Claude and Devin shell launchers directly from `dag`:

```zsh
dag --co status
dag --cf status
dag --deo status
dag --def status
```

The change is additive. Existing default behavior, `--agent`, `--claude`, `--codex`, and `--devin` remain compatible.

## Launcher Mapping

| DAG flag | Interactive zsh launcher | Runtime profile |
|---|---|---|
| `--co` | `co` | Claude, Opus, precision + superpowers + caveman + boil |
| `--cf` | `cf` | Claude, Fable, precision + superpowers + caveman + boil |
| `--deo` | `deo` | Devin, Opus, precision + boil |
| `--def` | `def` | Devin, Fable, precision + boil |

Each mapping has an environment override consistent with DAG's existing launcher configuration:

- `DAG_LAUNCHER_CO`
- `DAG_LAUNCHER_CF`
- `DAG_LAUNCHER_DEO`
- `DAG_LAUNCHER_DEF`

The override value is a launcher command prefix. Its default is the corresponding shell function name.

## CLI Behavior

New profile flags are accepted in the existing global selector position, before the DAG command. For example, `dag --co boost alice@example.com 250` is valid; `dag boost --co alice@example.com 250` is not treated as a launcher selection.

`--agent` continues to accept only `claude`, `codex`, or `devin`. The new names are launcher profiles, not additional canonical agents, so forms such as `dag --agent co status` remain invalid. This keeps existing terminology and validation stable.

If multiple selectors are supplied before the command, existing parser behavior remains unchanged: the last selector wins. Local-only commands continue to parse and ignore launcher selection because they do not start an agent session.

## Implementation Shape

`claude/devin-acu-governor/bin/dag` will:

1. Recognize `--co`, `--cf`, `--deo`, and `--def` in the pre-command selector loop.
2. Normalize each flag to a launcher profile distinct from the canonical `--agent` values.
3. Resolve the profile through its matching `DAG_LAUNCHER_*` override or default shell function.
4. Keep the current `exec zsh -ic ...` launch path so interactive shell functions remain available.

Prompt assembly does not change. Every profile receives the same common playbook, command playbook, global instructions, and run context already supplied to Claude, Codex, and Devin.

## Errors and Compatibility

- Missing DAG command behavior remains unchanged: print usage and exit `2`.
- Invalid `--agent` values keep the existing error and exit `2`.
- Existing environment variables and selectors keep their current meaning.
- No changes are required in `/Users/amittiwari/Profiles`; `co`, `cf`, `deo`, and `def` already exist there and are loaded by interactive zsh.

## Tests

Extend `claude/devin-acu-governor/test/dag-cli.test.zsh` test-first to cover:

1. `DAG_PRINT_LAUNCHER=1` resolves each new flag to `co`, `cf`, `deo`, or `def`.
2. Each `DAG_LAUNCHER_CO|CF|DEO|DEF` override wins for its matching flag.
3. Existing selectors still resolve exactly as before.
4. All four new profiles receive global instructions and the same assembled playbook prompt.
5. Profile flags do not leak into prompt content.
6. Help output documents new flags and configuration variables.

Run the focused CLI test through a red-green cycle, then run:

```zsh
zsh claude/devin-acu-governor/test/run.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/lib/*.zsh
```

## Documentation

Update:

- `claude/devin-acu-governor/README.md` with profile mappings, examples, compatibility, and environment overrides.
- Root `README.md` with the expanded DAG launcher-selection summary.

No alias wrappers are added because the requested interface is `dag --co|--cf|--deo|--def <command>`, not `dag--co`-style global functions.
