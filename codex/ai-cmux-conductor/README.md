# ai-cmux-conductor (`aicc`)

`ai-cmux-conductor` is a cMUX AI workspace conductor. The short command is `aicc`.

## Purpose

Run from any project directory, `aicc` makes Codex the base orchestrator tab with Amit's `cxscb` launcher and coordinates Claude plus Devin side panes in the same cMUX workspace. It reuses existing Claude/Devin panes when present, creates only missing panes, and registers Claude panes with a durable auto-resume daemon that watches for Claude usage/session limits and sends `continue` after the reset time.

## Behavior

1. Outside cMUX, attempt one handoff:

   ```zsh
   cmux new-workspace --name "${PWD:t}" --cwd "$PWD" --focus true --command aicc
   ```

2. Inside cMUX, rename the current tab to `codex`.
3. Read the cMUX tree and preserve any existing managed side-agent surfaces (`Claude`, `Devin`). AICC does not close, kill, or respawn an existing Claude/Devin pane during bootstrap.
4. Fill missing layout pieces only:
   - Codex/current pane stays on the left.
   - Claude is created to the right of Codex only when no Claude surface exists.
   - Devin is enabled by default and split below Claude only when no Devin surface exists.
5. Launch only newly-created panes with:
   - Codex: `cxscb <orchestrator prompt>`
   - Claude: `zsh -lc 'cd <cwd> && clscb'`
   - Devin, when enabled: `zsh -lc 'cd <cwd> && dey'`
6. Rename the current workspace to the title-cased current directory basename (`wb-gitlore` → `Wb-Gitlore`) and verify cMUX reports the new title. If the direct rename command does not stick, fall back to cMUX's workspace action and verify again.
7. Register the Claude surface in durable auto-resume state and ensure the AICC watcher daemon is running.
8. Pass stable cMUX workspace/surface IDs into the Codex orchestrator prompt.

## Feature flags

Feature flags live in [`environment.env`](./environment.env).

```env
AICC_CREATE_DEVIN_PANEL=true
```

- `true` (current default): create/reuse Devin below Claude and include Devin routing commands in the Codex orchestrator prompt.
- `false`: do not create or manage Devin. Existing Devin panes are left untouched.

An exported shell environment variable with the same name overrides `environment.env`.

Additional auto-resume controls:

```env
AICC_CLAUDE_AUTO_RESUME_DAEMON=true   # default; set false to avoid auto-starting the watcher
AICC_STATE_DIR=~/.local/state/ai-cmux-conductor
```

`AICC_STATE_DIR` defaults to `$XDG_STATE_HOME/ai-cmux-conductor` or `~/.local/state/ai-cmux-conductor`.

## Devin yolo panel routing

When Devin is enabled, AICC creates the Devin pane below Claude with:

```zsh
zsh -lc 'cd <cwd> && dey'
```

`dey` is Amit's interactive Devin launcher with yolo permissions. The Codex orchestrator prompt also tells future AICC sessions that "ask Devin" / "send to Devin" means:

1. Use the existing Devin pane when it is healthy.
2. If Devin is missing, closed, dead, or not running Devin, split below the Claude surface with `cmux new-split down`, rename the new surface to `Devin`, launch `zsh -lc 'cd <cwd> && dey'`, wait for the Devin CLI UI, and then send the pending prompt.
3. Treat the user's explicit Devin-routing request as approval to open/repair only the Devin pane; never close Codex, Claude, or unrelated terminal panes.

## Claude usage-limit auto-resume

The watcher uses cMUX only; it never kills, closes, or respawns agent panes. It reads registered Claude screens with:

```zsh
cmux read-screen --workspace <workspace-id> --surface <surface-id> --scrollback --lines 160
```

When it sees text such as:

```text
You've hit your session limit · resets 10:50pm (Asia/Calcutta)
```

it normalizes `Asia/Calcutta` to `Asia/Kolkata`, resolves the next reset occurrence, persists a job for reset time + 60 seconds, then sends:

```zsh
cmux send --workspace <workspace-id> --surface <resolved-claude-surface> -- $'continue\n'
```

Durable state lives at `claude-auto-resume.json` in `AICC_STATE_DIR` and records:

- `workspaceId`, `surfaceId`, `agentIdentity`, and optional `windowId`/workspace name.
- `resetAt`, `sendAt`, `message: "continue\n"`, `sourceExcerpt`, and `status`.
- attempts, final errors, exact cMUX send result, and recent events.

Deduplication key: `workspaceId + agentIdentity + resetAt`. If the original surface ID is stale, the watcher re-reads `cmux tree` and finds a terminal surface whose title contains `Claude`. Failed sends retry three total attempts at one-minute spacing; overdue pending jobs send after restart when within the 30-minute grace window and become stale after that. No `nohup`, `sleep`, or shell scheduler is used.

User-visible status:

```zsh
aicc --status
# Claude limited until 10:50 PM Asia/Kolkata; auto-continue scheduled for 10:51 PM Asia/Kolkata.
# Auto-continue sent at ...
# Auto-continue failed: ...
# Claude surface recovered: surface:stale → surface:fresh
```

Daemon controls:

```zsh
aicc --daemon       # run watcher loop in foreground
aicc --stop-daemon  # stop detached watcher started by normal aicc bootstrap
```

## Claude surface health guard

Bootstrap preservation is strict: an existing `Claude` or `Devin` pane is reused and not closed during AICC startup. Separately, the health guard prevents prompts from being routed to stale Claude surfaces that are not actually running Claude Code. Before sending a prompt to a registered Claude surface, the health guard:

1. Reads the surface screen with `cmux read-screen --workspace <workspace-id> --surface <surface-id> --scrollback --lines 160`
2. Checks for Claude Code UI markers (e.g., "Claude Code", "Welcome to Claude", "Opus", "Sonnet", "Haiku")
3. Detects unhealthy conditions:
   - Normal shell prompt with no Claude Code UI markers
   - Prompt text previously echoed into zsh as commands (e.g., "zsh: command not found")
4. On unhealthy surface with exact title `Claude`:
   - Closes only that stale surface
   - Creates a fresh terminal surface in the same pane
   - Renames the new surface to `Claude`
   - Launches `zsh -lc 'cd <cwd> && clscb'`
   - Waits for Claude UI markers to appear
   - Re-registers the new surface in auto-resume state
   - Sends the pending prompt to the new surface
5. Logs recovery events in `aicc --status` output

Safety boundaries:
- Only closes exact-title `Claude` surfaces that fail the health check
- Never closes Codex surfaces
- Never closes unrelated user terminal tabs
- Only auto-closes when the surface title is exactly `Claude` and the screen shows no Claude Code UI

The health guard is available via the `sendClaudePromptWithHealthGuard` function in `claude-auto-resume.ts` for use by any component that sends prompts to Claude surfaces.

## Files

- `ai-cmux-conductor` — Bun executable entrypoint.
- `bin/aicc` — short zsh wrapper.
- `bin/ai-cmux-conductor` — full-name zsh wrapper.
- `environment.env` — daemon feature flags; `AICC_CREATE_DEVIN_PANEL=true` enables Devin by default. Set it to `false` to skip Devin.
- `src/ai-cmux-conductor/claude-auto-resume.ts` — durable Claude usage-limit detector, scheduler, retry loop, state store, and status formatter.
- `src/ai-cmux-conductor/` — daemon-specific TypeScript source.
- `test/` — daemon-specific tests.

## Usage

```zsh
aicc
ai-cmux-conductor --help
aicc "ask Claude and Devin to inspect the auth flow"
aicc --status
aicc --stop-daemon
```

## Verification

```zsh
bun install --frozen-lockfile
bun test
bun run typecheck
zsh -n bin/aicc
zsh -n bin/ai-cmux-conductor
bun ai-cmux-conductor --help
bun ai-cmux-conductor --status
```
