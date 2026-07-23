# claude-agent-scout (`cas`)

Scout every **Claude-related process on this machine that could consume your
Claude usage**, in one categorized view — then deep-dive or interrogate any one
of them.

It answers three questions:

1. *What Claude things are running right now, and which ones actually burn usage?* → `cas list`
2. *What is this specific session, where is it, and what has it touched?* → `cas show <target>`
3. *What is this agent actually doing?* → `cas ask <target> [question]`

`list`, `show`, and `doctor` are **pure local zsh — read-only, no agent, no
cost**. Only `ask` launches an agent (and therefore spends anything).

## What it detects

| Kind | Class | Consumes | How it is found |
|------|-------|----------|-----------------|
| Claude Code CLI session | `cli-agent` | **API usage** | a lowercase `claude --session-id <uuid>` process; enriched with its cwd (`lsof`) and JSONL transcript |
| Claude Desktop (main) | `desktop-app` | subscription (when active) | `Claude.app/Contents/MacOS/Claude` |
| Desktop chat / cowork / remote surface | `desktop-renderer` | subscription (when active) | `Claude Helper (Renderer)` |
| MCP tool server | `mcp` | tool (no direct usage) | `@modelcontextprotocol/*`, `mcp-server`, `server-pdf`, spawned for a session |
| Electron infra helper | `helper` | none | gpu / network / audio / video / utility / crashpad / native-host |

The scout's own daemon paths (`…/daemons/claude/…`) and the `devin` runner are
deliberately excluded so they never masquerade as Claude usage.

### Where CLI transcripts live

Claude Code writes one JSONL transcript per session at:

```
~/.claude/projects/<cwd-with-every-slash-turned-into-a-dash>/<session-id>.jsonl
```

e.g. cwd `/Users/amit/Projects/x` → `~/.claude/projects/-Users-amit-Projects-x/<sid>.jsonl`.
`cas` resolves the transcript in three ways, in order:

1. explicit `--session-id` from the process command line + cwd;
2. a bare session-id located across all project dirs (so `show`/`ask` work for **ended** sessions);
3. **newest `.jsonl` in the cwd's project dir** — the common case, since most sessions
   run *without* `--session-id` (Claude Code auto-generates one); the session-id is then
   read back from the transcript filename.

## Usage

```
cas [list] [--all] [--json]           # scan (default command)
cas show <pid|session-id>             # local read-only deep-dive of one target
cas ask [selector] [pid|session|cwd|all] [question...]
cas doctor                            # check prerequisites
cas help
```

Examples:

```zsh
cas                                   # the categorized table
cas list --all                        # also list infra helper processes
cas list --json | jq '.[]|select(.consumes=="API")'
cas show 23994                        # deep-dive a running session by pid
cas show 45ddba05-…                   # deep-dive an ended session by id
cas ask 23994 what is it working on right now?
cas ask                               # investigate every live agent
cas --deo ask 23994                   # force the deo launcher
```

### `ask` launcher selection

`ask` seeds a read-only investigator playbook (`playbooks/_common.md` +
`playbooks/ask.md`) with a live scan snapshot, the target's metadata, and a
transcript tail, then hands off to an agent launcher:

- default: `deo` (override with `CAS_LAUNCHER`)
- `--agent claude|codex|devin` or `--claude` / `--codex` / `--devin`
- model-pinned profiles: `--co` / `--cf` / `--deo` / `--def`

Shorthands (from `aliases.zsh`): `cas--claude`, `cas--codex`, `cas--devin`,
`cas--deo`, `cas--def`.

## Configuration (`environment.env`; shell env vars override)

| Variable | Default | Purpose |
|----------|---------|---------|
| `CAS_LAUNCHER` | `deo` | default launcher for `ask` |
| `CAS_LAUNCHER_CLAUDE` | `clscb` | launcher for `--agent claude` |
| `CAS_LAUNCHER_CODEX` | `cxscb` | launcher for `--agent codex` |
| `CAS_LAUNCHER_DEVIN` | `devin --permission-mode dangerous` | launcher for `--agent devin` (cas appends `--` before the prompt for devin-family launchers) |
| `CAS_LAUNCHER_CO/CF/DEO/DEF` | `co`/`cf`/`deo`/`def` | model-pinned profile launchers |
| `CAS_PROJECTS_DIR` | `~/.claude/projects` | Claude Code transcript root |

Dry-run (assemble but do not launch): `CAS_PRINT_PROMPT=1 cas ask <target>` prints
the prompt; `CAS_PRINT_LAUNCHER=1 cas ask <target>` prints the resolved launcher.

## Layout

```
claude/claude-agent-scout/
├── bin/cas               # thin zsh launcher: arg/selector parse + dispatch
├── lib/
│   ├── scan.zsh          # process enumeration, classification, table + JSON
│   ├── show.zsh          # single-target deep-dive + transcript turns/tokens
│   ├── transcript.zsh    # cwd/session/transcript resolution + time helpers
│   └── prompt.zsh        # `ask` prompt assembly
├── playbooks/
│   ├── _common.md        # investigator role + read-only ground rules
│   └── ask.md            # the "explain what this agent is doing" task
├── environment.env       # launcher/config defaults
└── README.md
```

Division of responsibility: deterministic zsh owns the scan, classification, and
transcript inspection; an AI agent is used only to *interpret* a target's live
state under `ask` — and never mutates, kills, or signals the target.

## Prerequisites

- `lsof` (cwd resolution) and `jq` (JSON output, token totals, transcript turns) —
  both standard on macOS / Homebrew. `cas doctor` reports what is present.

## Verification

```zsh
zsh -n bin/cas lib/*.zsh          # parse-check (no shellcheck for zsh)
cas doctor                        # prerequisites + launcher resolution
cas list                          # scan
CAS_PRINT_PROMPT=1 cas ask <sid>  # prompt assembly, no agent launched
```
