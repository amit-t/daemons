#!/usr/bin/env zsh
# Global daemon entrypoints sourced by Profiles.

ai-cmux-orchestrator() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/codex/ai-cmux-orchestrator/bin/ai-cmux-orchestrator"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "ai-cmux-orchestrator: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

aico() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/codex/ai-cmux-orchestrator/bin/aico"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "aico: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

dag() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/devin-acu-governor/bin/dag"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "dag: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

dhm() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/do-here-now-migrator/bin/dhm"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "dhm: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

cas() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/claude-agent-scout/bin/cas"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "cas: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

# Dotted shorthands: cx = base aico (codex parent), cl = claude-parent aico.
alias cx.aico='aico'
alias cl.aico='aico --claude'

# Parent-agent shorthands: same daemons, different base agent. Kid agents unchanged.
aico--claude() { aico --agent claude "$@" }
aico--codex()  { aico --agent codex "$@" }
aico--devin()  { aico --agent devin "$@" }
dag--claude()  { dag --agent claude "$@" }
dag--codex()   { dag --agent codex "$@" }
dag--devin()   { dag --agent devin "$@" }
dhm--claude()  { dhm --agent claude "$@" }
dhm--cf()      { dhm --agent cf "$@" }
dhm--codex()   { dhm --agent codex "$@" }
dhm--devin()   { dhm --agent devin "$@" }

# cas `ask` launcher selectors: pick which agent explains the target session.
cas--claude()  { cas --agent claude "$@" }
cas--codex()   { cas --agent codex "$@" }
cas--devin()   { cas --agent devin "$@" }
cas--deo()     { cas --deo "$@" }
cas--def()     { cas --def "$@" }

# ghw — github-warden: GitHub org/repo management daemon.
ghw() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/github-warden/bin/ghw"
  if [[ ! -x "$daemon_entry" && ! -f "$daemon_entry" ]]; then
    print -ru2 -- "ghw: missing daemon entrypoint at $daemon_entry"
    return 1
  fi
  zsh "$daemon_entry" "$@"
}

# hive — cross-machine sync of global agent instructions/memories.
# Public project: https://github.com/amit-t/hive (clone to ~/Projects/Tools-Utilities/hive).
# Private defaults live here, never in the public repo.
hive() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/hive/bin/hive"
  if [[ ! -f "$daemon_entry" ]]; then
    print -ru2 -- "hive: missing entrypoint at $daemon_entry — clone github.com/amit-t/hive there"
    return 127
  fi
  HIVE_LAUNCHER="${HIVE_LAUNCHER:-cf}"   HIVE_REMOTE_DENYLIST="${HIVE_REMOTE_DENYLIST:-Invenco-Cloud-Systems-ICS,github.com-atv}"     zsh "$daemon_entry" "$@"
}
hive--claude() { HIVE_LAUNCHER=cf hive "$@" }
hive--codex()  { HIVE_LAUNCHER=cxscb hive "$@" }
hive--devin()  { HIVE_LAUNCHER=deo hive "$@" }
hive--co()     { HIVE_LAUNCHER=co hive "$@" }
