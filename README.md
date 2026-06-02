# Daemons

Source of truth for Amit's local daemon implementations.

## Repository contract

- Daemon implementation code lives in this repository.
- Profiles (`/Users/amittiwari/Profiles`) may expose commands globally through PATH wrappers and shell sourcing, but should delegate daemon behavior here.
- Codex-related daemons live under `codex/<daemon-name>/`.
- Daemon internals should be namespaced under the daemon name.

## Global shell entrypoints

Profiles sources this file when available:

```zsh
source /Users/amittiwari/Projects/Tools-Utilities/daemons/aliases.zsh
```

That keeps global commands available while this repository remains the source of truth.

## Current daemons

- [`codex/ai-cmux-conductor`](./codex/ai-cmux-conductor) — `aicc`, a cMUX AI workspace conductor that opens Codex with `cxscb`, reuses existing Claude/Devin panes when present, creates missing panes, launches Devin below Claude with `dey` yolo mode, names the workspace after the current project, and runs a durable Claude usage-limit auto-resume watcher.
