# Daemons

Source of truth for Amit's local daemon implementations.

## Repository contract

- Daemon implementation code lives in this repository.
- Profiles (`/Users/amittiwari/Profiles`) may expose commands globally through PATH wrappers and shell sourcing, but should delegate daemon behavior here.
- Codex-related daemons live under `codex/<daemon-name>/`.
- Claude-powered daemons (runtime is a Claude agent session) live under `claude/<daemon-name>/`.
- Daemon internals should be namespaced under the daemon name.

## Global shell entrypoints

Profiles sources this file when available:

```zsh
source /Users/amittiwari/Projects/Tools-Utilities/daemons/aliases.zsh
```

That keeps global commands available while this repository remains the source of truth.

## Current daemons

- [`codex/ai-cmux-conductor`](./codex/ai-cmux-conductor) — `aicc`, a cMUX AI workspace conductor that opens a base Codex orchestrator with `cxscb` while suppressing Codex Apps/external MCP startup (parent agent selectable per launch with `--agent claude|codex|devin` or the `--claude`/`--codex`/`--devin` shorthands; kid panes unchanged), creates/reuses kid-named Claude and extra Codex side panels (`kid-claude`, `kid-codex`) by default, leaves `kid-devin` disabled unless `AICC_CREATE_DEVIN_PANEL=true`, lets Claude/Codex/Devin panels be independently disabled, makes ordinary non-trivial tasks default to kid-panel decomposition with goal-marking delegation prompts, names the workspace after the current project, runs a durable 60-second AICC poller with safe event-inbox notices plus Claude auto-resume, and supports an exact `Reset` command that refuses active enabled-agent work before closing enabled AICC-managed AI surfaces down to one basic terminal.
