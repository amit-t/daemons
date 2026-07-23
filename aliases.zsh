#!/usr/bin/env zsh
# Global daemon entrypoints sourced by Profiles.

ai-cmux-conductor() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/codex/ai-cmux-conductor/bin/ai-cmux-conductor"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "ai-cmux-conductor: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}

aicc() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/codex/ai-cmux-conductor/bin/aicc"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "aicc: missing daemon entrypoint at $daemon_entry"
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

# Dotted shorthands: cx = base aicc (codex parent), cl = claude-parent aicc.
alias cx.aicc='aicc'
alias cl.aicc='aicc --claude'

# Parent-agent shorthands: same daemons, different base agent. Kid agents unchanged.
aicc--claude() { aicc --agent claude "$@" }
aicc--codex()  { aicc --agent codex "$@" }
aicc--devin()  { aicc --agent devin "$@" }
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
