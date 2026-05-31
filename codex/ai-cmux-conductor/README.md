# ai-cmux-conductor (`aicc`)

`ai-cmux-conductor` is a cMUX AI workspace conductor. The short command is `aicc`.

## Purpose

Run from any project directory, `aicc` makes Codex the base orchestrator tab with Amit's `cxscb` launcher and coordinates Claude plus optional Devin side panes in the same cMUX workspace.

## Behavior

1. Outside cMUX, attempt one handoff:

   ```zsh
   cmux new-workspace --name "${PWD:t}" --cwd "$PWD" --focus true --command aicc
   ```

2. Inside cMUX, rename the current tab to `codex`.
3. Close exact-title managed side-agent surfaces (`Claude`, `Devin`) so stale layouts do not survive.
4. Recreate a deterministic layout:
   - Codex/current pane stays on the left.
   - Claude is created to the right of Codex.
   - Devin is split below Claude only when `AICC_CREATE_DEVIN_PANEL=true`.
5. Launch panes with:
   - Codex: `cxscb <orchestrator prompt>`
   - Claude: `zsh -lc 'cd <cwd> && clscb'`
   - Devin, when enabled: `zsh -lc 'cd <cwd> && dey'`
6. Rename the current workspace to the title-cased current directory basename (`wb-gitlore` → `Wb-Gitlore`) and verify cMUX reports the new title. If the direct rename command does not stick, fall back to cMUX's workspace action and verify again.
7. Pass stable cMUX workspace/surface IDs into the Codex orchestrator prompt.

## Feature flags

Feature flags live in [`environment.env`](./environment.env).

```env
AICC_CREATE_DEVIN_PANEL=false
```

- `false` (current default): create Claude only; do not create a Devin panel. Existing exact-title `Devin` surfaces are still closed during layout reset.
- `true`: create Devin below Claude and include Devin routing commands in the Codex orchestrator prompt.

An exported shell environment variable with the same name overrides `environment.env`.

## Files

- `ai-cmux-conductor` — Bun executable entrypoint.
- `bin/aicc` — short zsh wrapper.
- `bin/ai-cmux-conductor` — full-name zsh wrapper.
- `environment.env` — daemon feature flags; set `AICC_CREATE_DEVIN_PANEL=true` to enable the Devin panel.
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
