# DAG Defu Launcher Design

**Date:** 2026-09-22
**Status:** Approved

## Objective

Expose `defu` as a first-class DAG launcher profile for every agent-driven command while preserving local-only command behavior:

```zsh
dag --defu status
dag --defu boost all
dag--defu sessions --hours 72
```

The change is additive. Existing defaults, canonical `--agent` values, launcher profiles, commands, and prompt assembly remain compatible.

## Launcher Contract

`--defu` is a launcher profile, not a canonical parent-agent identity. `--agent` therefore remains restricted to `claude`, `codex`, and `devin`.

The profile resolves through:

```zsh
${DAG_LAUNCHER_DEFU:-DEFU_YOLO=1 defu}
```

DAG classifies `defu` as a Devin-family launcher and inserts the prompt separator:

```zsh
DEFU_YOLO=1 defu -- "<assembled DAG prompt>"
```

`DEFU_YOLO=1` is deliberate: the user selected dangerous permission mode for DAG-launched Defu sessions. The environment contract enables dangerous mode in the standalone binary without passing its wrapper-only `--yolo` flag through the Profiles `defu` function to Devin; that function already launches in dangerous mode. Defu still owns Fusion model selection and its precision, boil-the-ocean, and caveman mode prompt.

## CLI Behavior

`--defu` is accepted by the existing pre-command selector loop. It works with every agent-driven command because launcher resolution occurs before shared command routing and prompt assembly.

`aliases.zsh` adds:

```zsh
dag--defu() { dag --defu "$@" }
```

Local-only commands—`doctor`, `dashboard`, `usage`, `usage --group`, `setup-extract`, and `set limit global`—continue to execute locally. They parse and ignore launcher selectors exactly as they do for existing profiles.

If multiple selectors appear before the command, existing last-selector-wins behavior remains unchanged. `dag command --defu` is not a launcher selection because selectors must precede the command.

## Implementation

`claude/devin-acu-governor/bin/dag` will:

1. Document `--defu` in usage, examples, and configuration output.
2. Accept `--defu` in the profile-selector branch.
3. Validate `defu` as a known profile.
4. Resolve `defu` through `DAG_LAUNCHER_DEFU`, defaulting to `DEFU_YOLO=1 defu`.
5. Include `defu` in Devin-family `--` separator handling, including default-launcher command-text detection.

`aliases.zsh` will add the global `dag--defu` wrapper.

No playbook, API, key-resolution, write-gate, or prompt-content changes are required.

## Errors and Compatibility

- Missing commands still print usage and exit `2`.
- Invalid `--agent` values keep the existing error and exit `2`.
- Existing selector ordering and override semantics remain unchanged.
- A missing `defu` executable fails only when an agent-driven `--defu` command reaches launch, matching other shell launcher profiles.
- `DAG_LAUNCHER_DEFU` can replace the full launcher command prefix for tests or local customization.

## Tests

Extend `claude/devin-acu-governor/test/dag-cli.test.zsh` test-first to prove:

1. `--defu` receives the same assembled prompt and global instructions as every other profile.
2. `DAG_PRINT_LAUNCHER=1 dag --defu status` resolves to `DEFU_YOLO=1 defu --`.
3. `DAG_LAUNCHER_DEFU` overrides the default and retains the separator.
4. Help lists `--defu` and `DAG_LAUNCHER_DEFU`.
5. Existing selectors continue to resolve unchanged.
6. Local-only commands remain local when prefixed with `--defu`.
7. `dag--defu` forwards its arguments as `dag --defu` without rewriting them.

Observe the new assertions fail before changing production code, then pass after the minimal implementation.

## Documentation

Update:

- `claude/devin-acu-governor/README.md`: runtime behavior, profile examples, separator contract, and environment override.
- Root `README.md`: DAG launcher profile and wrapper exposure.

## Verification

```zsh
zsh -n aliases.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/test/dag-cli.test.zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
zsh claude/devin-acu-governor/test/run.zsh
git diff --check
```
