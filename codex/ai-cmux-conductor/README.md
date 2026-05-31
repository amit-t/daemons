# ai-cmux-conductor (`aicc`)

`ai-cmux-conductor` is a cMUX AI workspace conductor. The short command is `aicc`.

## Purpose

Run from any project directory, `aicc` makes Codex the base orchestrator tab and coordinates Claude and Devin side panes in the same cMUX workspace.

## Behavior

1. Outside cMUX, attempt one handoff:

   ```zsh
   cmux new-workspace --name "${PWD:t}" --cwd "$PWD" --focus true --command aicc
   ```

2. Inside cMUX, rename the current workspace to the current directory basename.
3. Reuse exact-title `Claude` and `Devin` surfaces when present.
4. Create only missing panes.
5. Launch missing panes with:
   - Claude: `zsh -lc 'cd <cwd> && clscb'`
   - Devin: `zsh -lc 'cd <cwd> && dey'`
6. Open Codex as the base orchestrator with stable cMUX workspace/surface IDs.

## Files

- `ai-cmux-conductor` — Bun executable entrypoint.
- `bin/aicc` — short zsh wrapper.
- `bin/ai-cmux-conductor` — full-name zsh wrapper.
- `src/ai-cmux-conductor/` — daemon-specific TypeScript source.
- `test/` — daemon-specific tests.

## Usage

```zsh
aicc
ai-cmux-conductor --help
aicc "ask Claude and Devin to inspect the auth flow"
```

## Verification

```zsh
bun install --frozen-lockfile
bun test
bun run typecheck
zsh -n bin/aicc
zsh -n bin/ai-cmux-conductor
bun ai-cmux-conductor --help
```
