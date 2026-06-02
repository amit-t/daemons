# ai-cmux-conductor (`aicc`)

`ai-cmux-conductor` is a cMUX AI workspace conductor. The short command is `aicc`.

## Purpose

Run from any project directory, `aicc` makes Codex the base orchestrator tab with Amit's `cxscb` launcher and coordinates Claude plus optional Devin side panes in the same cMUX workspace. It also registers Claude panes with a durable auto-resume daemon that watches for Claude usage/session limits and sends `continue` after the reset time.

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
7. Register the Claude surface in durable auto-resume state and ensure the AICC watcher daemon is running.
8. Pass stable cMUX workspace/surface IDs into the Codex orchestrator prompt.

## Feature flags

Feature flags live in [`environment.env`](./environment.env).

```env
AICC_CREATE_DEVIN_PANEL=false
```

- `false` (current default): create Claude only; do not create a Devin panel. Existing exact-title `Devin` surfaces are still closed during layout reset.
- `true`: create Devin below Claude and include Devin routing commands in the Codex orchestrator prompt.

An exported shell environment variable with the same name overrides `environment.env`.

Additional auto-resume controls:

```env
AICC_CLAUDE_AUTO_RESUME_DAEMON=true   # default; set false to avoid auto-starting the watcher
AICC_STATE_DIR=~/.local/state/ai-cmux-conductor
```

`AICC_STATE_DIR` defaults to `$XDG_STATE_HOME/ai-cmux-conductor` or `~/.local/state/ai-cmux-conductor`.

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
```

Daemon controls:

```zsh
aicc --daemon       # run watcher loop in foreground
aicc --stop-daemon  # stop detached watcher started by normal aicc bootstrap
```

## Files

- `ai-cmux-conductor` — Bun executable entrypoint.
- `bin/aicc` — short zsh wrapper.
- `bin/ai-cmux-conductor` — full-name zsh wrapper.
- `environment.env` — daemon feature flags; set `AICC_CREATE_DEVIN_PANEL=true` to enable the Devin panel.
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
