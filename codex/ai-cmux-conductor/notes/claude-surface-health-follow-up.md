# Follow-up: AICC Claude surface health guard

## Problem observed

In workspace `Wb-Gitlore`, cMUX surface `surface:5` had title `Claude`, but it was only an interactive zsh prompt. The orchestrator routed a long Claude prompt to that surface, so zsh executed each prompt line as shell commands instead of sending it to Claude Code.

Manual recovery used today:

```zsh
cmux close-surface --workspace workspace:3 --surface surface:5
cmux new-surface --workspace workspace:3 --pane pane:4 --type terminal --focus true
cmux rename-tab --workspace workspace:3 --surface surface:23 Claude
cmux send --workspace workspace:3 --surface surface:23 "zsh -lc 'cd '\''/Users/amittiwari/Projects/Tools-Utilities/wb-gitlore'\'' && clscb'"
cmux send-key --workspace workspace:3 --surface surface:23 Enter
```

Expected AICC behavior: if the Claude tab is not actually running Claude Code, AICC should close that stale tab and start a fresh Claude tab with `clscb` before routing prompts.

## Requested daemon change

Update `codex/ai-cmux-conductor` so Claude routing and/or bootstrap does not trust tab title alone.

Required behavior:

1. Before sending a user prompt to a registered Claude surface, read the surface screen with:

   ```zsh
   cmux read-screen --workspace <workspace-id> --surface <surface-id> --scrollback --lines 160
   ```

2. Treat the surface as unhealthy when any of these are true:
   - Screen shows a normal shell prompt and no Claude Code UI markers.
   - Prompt text was previously echoed into zsh as commands.
   - `cmux tree` shows title `Claude` but no Claude Code process is attached to that surface, if process data is available.

3. On unhealthy Claude surface:
   - Close only that stale `Claude` surface.
   - Create a fresh terminal surface in the Claude pane when possible, or recreate the right-side Claude pane when the pane is gone.
   - Rename new surface to `Claude`.
   - Launch:

     ```zsh
     zsh -lc 'cd <cwd> && clscb'
     ```

   - Re-register the new surface in Claude auto-resume state.
   - Send the pending prompt only after the fresh Claude UI is ready.

4. Keep safety boundaries:
   - Do not close Codex surfaces.
   - Do not close unrelated user terminal tabs.
   - Only auto-close exact-title `Claude` surfaces that fail the health check.
   - Log recovery action in `aicc --status` output or recent events.

## Suggested code areas

- `src/ai-cmux-conductor/conductor.ts`
  - `createAgentSurface`
  - `closeManagedAgentSurfaces`
  - orchestrator prompt text that tells Codex how to route Claude messages
- `src/ai-cmux-conductor/claude-auto-resume.ts`
  - `resolveClaudeSurface`
  - `readClaudeScreen`
  - `isPlausibleClaudeSurface`
- `test/ai-cmux-conductor-setup.test.ts`
- Any auto-resume tests that cover stale surface resolution

## Verification target

Add tests for:

1. Exact-title `Claude` surface with shell prompt is detected unhealthy.
2. AICC closes that stale surface and launches a new `clscb` surface.
3. Prompt routing uses the new surface ID, not the stale one.
4. Healthy Claude Code UI remains untouched.
5. `aicc --status` reports recovery event.

Run:

```zsh
bun test
zsh -n bin/aicc
zsh -n bin/ai-cmux-conductor
```

## Implementation status

Implemented in `src/ai-cmux-conductor/claude-auto-resume.ts` via `sendClaudePromptWithHealthGuard`, `isPlausibleClaudeSurface`, recovery events, and status output. Bootstrap behavior remains separate: AICC preserves existing Claude/Devin panes and only creates missing panes.
