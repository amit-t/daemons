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
- [`claude/do-here-now-migrator`](./claude/do-here-now-migrator) — `dhm`, a DigitalOcean-to-here.now static site migrator that runs any repository through a resumable phase pipeline (preflight, inventory, backup, here.now account, transform, build, publish, domain, verify, CI, decommission, report), splitting responsibility so that deterministic zsh owns every operation that can lose data — resource attribution, database dumps, DNS edits, domain mounts, publishing, and deletion — while an AI agent owns only the source transformation (parent agent selectable with `dhm --agent claude|cf|codex|devin`, or the `--claude`/`--cf`/`--codex`/`--devin` shorthands, launching `co`/`cf`/`cxscb`/`dey`). It never assumes a here.now account (running the email one-time-code flow when no credential exists, and treating an anonymous 24-hour publish as a hard failure) and never assumes a newsletter provider (Substack is one of eight `--subscribe` options including `none`, with the URL probed before use and no provider API ever called). Destruction is gated on a backup that was written and read back, on the live site verifying byte-for-byte against the published Site — the check that catches a verified-but-unmounted domain returning HTTP 200 from here.now's placeholder — and on the operator typing each resource's exact name; DNS edits are confined to apex and `www` `A`/`AAAA`/`CNAME` records so `MX`, `TXT`, `DKIM`, `DMARC`, `CAA`, and `SRV` always survive.
- [`claude/devin-acu-governor`](./claude/devin-acu-governor) — `dag`, a Devin Enterprise ACU governor that launches agent playbook sessions (default `clscb`; parent agent selectable with `dag --agent claude|codex|devin <command>` or `--claude`/`--codex`/`--devin`; model-pinned profiles selectable with `--co` → `co`, `--cf` → `cf`, `--deo` → `deo`, and `--def` → `def`, with every engine prompt seeded from `~/.codex/memories/global-zsh-and-dag-instructions.md` when present) to prorate remaining ACUs and set enforceable per-user Local Agent limits (`set-limits`, plus targeted `set-limits <email>` to cap one uncapped user by Borrowing from active capped donors), Boost/Borrow limits across engineers (`boost`), set all org-level Local Agent caps (or one selected org) with live verification (`set limit global`), deep-dive users (`user`), report trajectory (`status`, including `status --group` for exact IDP groups), audit model burn (`models`), locally report per-user usage (`usage`, including `usage --user-email` for one user's daily/product ACU breakdown and `usage --group` with last-3-days detail), open a generic Devin API/DAG command lab seeded with live docs and all playbooks (`all commands`), probe API keys (`doctor`), print local keychain migration commands (`setup-extract`), and render a local dashboard (`dashboard`) with org and user consumed-vs-cap ACUs plus manual Refresh-now backend refetch and optional 5/10/15/30-minute auto-refresh.
