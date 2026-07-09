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


# Dotted shorthands: cx = base aicc (codex parent), cl = claude-parent aicc.
alias cx.aicc='aicc'
alias cl.aicc='aicc --claude'

# Parent-agent shorthands: same daemons, different base agent. Kid agents unchanged.
aicc--claude() { aicc --agent claude "$@" }
aicc--codex()  { aicc --agent codex "$@" }
aicc--devin()  { aicc --agent devin "$@" }
