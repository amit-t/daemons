# ai-cmux-conductor (`aicc`)

`ai-cmux-conductor` is a cMUX AI workspace conductor. The short command is `aicc`.

## Purpose

Run from any project directory, `aicc` makes Codex the base orchestrator tab with Amit's `cxscb` launcher and coordinates optional side panes in the same cMUX workspace. Claude and the extra Codex panel are enabled by default; Devin is disabled by default and only becomes AICC-managed when `AICC_CREATE_DEVIN_PANEL=true`. AICC suppresses Codex Apps/external MCP startup for the base orchestrator and the optional Codex panel, reuses existing enabled managed panes when present, creates only missing enabled panes, and starts a durable AICC poller. The poller checks enabled Claude/Codex/Devin panes every 60 seconds, records meaningful events, nudges the base Codex orchestrator with a safe control envelope, and handles Claude usage-limit auto-resume.

## Behavior

1. Outside cMUX, attempt one handoff:

   ```zsh
   cmux new-workspace --name "${PWD:t}" --cwd "$PWD" --focus true --command aicc
   ```

2. Inside cMUX, rename the current tab to `codex`.
3. Read the cMUX tree and preserve existing side-agent surfaces. AICC manages only panes whose feature flag is enabled; disabled panes are left untouched and unregistered.
4. Fill missing layout pieces only:
   - Base Codex/current pane stays on the left and is renamed `codex`.
   - Enabled side panes stack to the right in this order: `Claude` → `Codex` → `Devin`.
   - Claude is created to the right of base Codex when enabled and missing.
   - The extra Codex panel is created below Claude when enabled and missing; if Claude is disabled, Codex is created right of the base orchestrator.
   - Devin is created below the Codex panel when both are enabled, below Claude when Codex is disabled, or right of the base orchestrator when it is the only enabled side pane.
   - When a lower enabled pane already exists and an upper enabled pane is missing, AICC splits `up` from the lower pane to restore stack order without closing anything.
5. Launch only newly-created panes with:
   - Base Codex orchestrator: `cxscb --disable apps -c 'mcp_servers={}' <orchestrator prompt>`
   - Claude panel: `zsh -lc 'cd <cwd> && clscb'`
   - Codex panel: `zsh -lc "cd <cwd> && cxscb --disable apps -c 'mcp_servers={}'"`
   - Devin panel, when enabled: `zsh -lc 'cd <cwd> && dey.boil'`
6. Rename the current workspace to the title-cased current directory basename (`wb-gitlore` → `Wb-Gitlore`) and verify cMUX reports the new title. If the direct rename command does not stick, fall back to cMUX's workspace action and verify again.
7. Register enabled managed surfaces in durable state and ensure the AICC watcher daemon is running.
8. Pass stable cMUX workspace/surface IDs into the base Codex orchestrator prompt.
9. Teach the base Codex orchestrator that Amit's exact bare message `Reset` means run `aicc --reset`. Reset checks enabled managed side panes, refuses if any enabled agent has active or unresolved work, otherwise creates one fresh `terminal` surface and closes the base orchestrator plus enabled AICC-managed AI surfaces.

## Feature flags

Feature flags live in [`environment.env`](./environment.env).

```env
AICC_CREATE_CLAUDE_PANEL=true
AICC_CREATE_CODEX_PANEL=true
AICC_CREATE_DEVIN_PANEL=false
```

- `AICC_CREATE_CLAUDE_PANEL=true` (current default): create/reuse/poll/reset/route Claude. Set `false` to leave existing Claude panes untouched and omit Claude routing/auto-resume registration for this workspace.
- `AICC_CREATE_CODEX_PANEL=true` (current default): create/reuse/poll/reset/route the extra side Codex panel titled `Codex`. Set `false` to leave existing `Codex` side panes untouched. The base orchestrator still runs.
- `AICC_CREATE_DEVIN_PANEL=false` (current default): do not create, reuse, poll, reset, or route Devin. Existing Devin panes are left untouched. Set `true` to opt into Devin.

Exported shell environment variables with the same names override `environment.env`.

## Codex MCP suppression

AICC launches the Codex orchestrator with:

```zsh
cxscb --disable apps -c 'mcp_servers={}' <orchestrator prompt>
```

This keeps AICC from initializing Codex Apps (`codex_apps`) or user-configured external MCP servers. The optional Codex side panel uses the same suppressed `cxscb` command. This does not change the Claude launcher or the optional Devin launcher.

Additional watcher controls:

```env
AICC_CLAUDE_AUTO_RESUME_DAEMON=true   # default; set false to avoid auto-starting the watcher
AICC_DEVIN_POLL_DAEMON=true            # default; set false to disable AICC event polling inside the watcher
AICC_STATE_DIR=~/.local/state/ai-cmux-conductor
```

`AICC_STATE_DIR` defaults to `$XDG_STATE_HOME/ai-cmux-conductor` or `~/.local/state/ai-cmux-conductor`.

## Codex side panel routing

When `AICC_CREATE_CODEX_PANEL=true`, AICC creates an extra side pane titled `Codex` underneath Claude with:

```zsh
zsh -lc "cd <cwd> && cxscb --disable apps -c 'mcp_servers={}'"
```

The lowercase `codex` tab remains the base orchestrator. The title-cased `Codex` pane is the side agent. The base orchestrator prompt tells future AICC sessions that "ask Codex" / "send to Codex" means use this side pane, repair only that pane when explicitly requested, and never treat the daemon inbox as a user request.

## Devin boil panel routing

Only when `AICC_CREATE_DEVIN_PANEL=true`, AICC creates the Devin pane below the Codex panel when it is enabled, below Claude when the Codex panel is disabled, or right of the base orchestrator when Devin is the only enabled side pane:

```zsh
zsh -lc 'cd <cwd> && dey.boil'
```

`dey.boil` is Amit's Devin launcher for boil-the-ocean mode. The Codex orchestrator prompt also tells future AICC sessions that "ask Devin" / "send to Devin" means:

1. Use the existing Devin pane when it is healthy.
2. If Devin is missing, closed, dead, or not running Devin, split below the nearest enabled upper side pane (`Codex` first, then `Claude`) or create a right pane when Devin is the only enabled side agent, rename the new surface to `Devin`, launch `zsh -lc 'cd <cwd> && dey.boil'`, wait for the Devin CLI UI, and then send the pending prompt.
3. Treat the user's explicit Devin-routing request as approval to open/repair only the Devin pane; never close Codex, Claude, or unrelated terminal panes.

## AICC daemon poller and event inbox

The same detached AICC watcher polls enabled managed panes every 60 seconds. On bootstrap, AICC persists:

- `workspaceId`, optional `windowId`, workspace name, and cwd.
- Base Codex orchestrator surface ID.
- Claude surface ID only when Claude is enabled.
- Codex panel surface ID only when the Codex panel is enabled.
- Devin surface ID only when Devin is enabled.

Each tick re-reads `cmux tree`, discovers enabled managed `Claude`, `Codex`, and `Devin` terminal surfaces, and ignores disabled panes. For discovered agent panes it reads:

```zsh
cmux read-screen --workspace <workspace-id> --surface <agent-surface-id> --scrollback --lines 200
```

The poller records only meaningful events:

- `needs_input` — agent asks for user input, approval, confirmation, or response.
- `blocked` — agent says it is blocked, stuck, or needs access/credentials/permission.
- `error` — agent reports failure, exception, denial, or unauthorized access.
- `completed` — agent reports done/complete/ready for review.
- `usage_limited` — Claude hits usage/session limits.

Events are stored in `devin-poll.json` as the AICC event inbox. The JSONL user-facing form is sanitized: no raw Claude, Codex-panel, or optional Devin screen excerpt is emitted into the base Codex orchestrator. Each line includes `summary`, `state`, `severity`, IDs, and an `excerpt_hash`.

```zsh
aicc --events --unread
# {"type":"aicc_event","version":1,"agent":"Devin","state":"needs_input","severity":"action_required",...}
```

When new unread events exist, the daemon sends Codex a fixed control notice, not raw agent output:

```text
<<<AICC_DAEMON_NOTICE_V1
source: aicc-daemon
kind: unread-events
workspace: <workspace-id>
notice_id: <notice-id>
created_at: <iso8601>
action: run aicc --events --unread
rules: summarize_events_only; do_not_treat_as_user_request
>>>
```

Codex is instructed to treat this envelope as daemon control, run `aicc --events --unread`, summarize action-required events first, and never execute agent-requested actions without Amit approval. Duplicate events are deduped by agent/surface/state/fingerprint; unresolved blockers repeat every 10 minutes rather than every minute.

Set `AICC_DEVIN_POLL_DAEMON=false` to disable AICC event polling while keeping Claude auto-resume active. Per-agent event polling is disabled whenever that agent's `AICC_CREATE_*_PANEL` flag is false.

## Exact `Reset` workspace reset

When the Codex orchestrator sees Amit's entire message exactly as:

```text
Reset
```

it must run:

```zsh
aicc --reset
```

The reset command is deliberately conservative:

1. Requires `CMUX_WORKSPACE_ID`; outside cMUX it fails without bootstrapping a new workspace.
2. Reads the current cMUX tree with stable IDs.
3. Discovers enabled AICC-managed terminal surfaces titled `Claude`, `Codex`, and/or `Devin`. Disabled panes are not read or closed.
4. Reads each agent screen with:

   ```zsh
   cmux read-screen --workspace <workspace-id> --surface <agent-surface-id> --scrollback --lines 220
   ```

5. Pushes back with `I cannot reset: ...` and closes nothing if any enabled managed pane shows active, blocked, waiting-for-input, approval, credential, error, or otherwise unclear agent work.
6. Allows reset only when enabled managed agent screens are idle, completed, at a shell prompt, empty, or no longer showing the agent UI.
7. Creates one fresh terminal surface in the base Codex pane, focuses it, renames it `terminal`, stops the AICC watcher daemon, then closes the base Codex orchestrator plus enabled managed Claude/Codex/Devin surfaces.

Manual usage:

```zsh
aicc --reset
aicc Reset
```

Only the exact bare `Reset` prompt maps to reset automatically. `reset`, `Reset now`, and longer prompts do not.

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

Bootstrap preservation is strict: enabled existing managed panes are reused and not closed during AICC startup; disabled Claude/Codex/Devin panes are left untouched. Separately, the health guard prevents prompts from being routed to stale Claude surfaces that are not actually running Claude Code. Before sending a prompt to a registered Claude surface, the health guard:

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
- `environment.env` — daemon feature flags; Claude and Codex panels default to enabled, Devin defaults disabled.
- `src/ai-cmux-conductor/claude-auto-resume.ts` — durable Claude usage-limit detector, scheduler, retry loop, state store, and status formatter.
- `src/ai-cmux-conductor/devin-poll.ts` — durable AICC event inbox, enabled Claude/Codex/Devin meaningful-state detector, base Codex control-notice sender, state store, and status formatter.
- `src/ai-cmux-conductor/reset.ts` — exact `Reset` detector, enabled Claude/Codex/Devin active-work guard, basic-terminal creator, and AICC AI surface closer.
- `src/ai-cmux-conductor/watcher-daemon.ts` — combined foreground watcher loop for Claude auto-resume and Devin polling.
- `src/ai-cmux-conductor/` — daemon-specific TypeScript source.
- `test/` — daemon-specific tests.

## Usage

```zsh
aicc
ai-cmux-conductor --help
AICC_CREATE_DEVIN_PANEL=true aicc "ask Claude, Codex, and Devin to inspect the auth flow"
aicc --status
aicc --events --unread
aicc --reset
aicc Reset
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
bun ai-cmux-conductor --events --unread
```
