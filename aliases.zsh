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

dve() {
  local daemon_entry="${HOME}/Projects/Tools-Utilities/daemons/claude/devin-acu-governor/bin/dve"

  if [[ ! -x "$daemon_entry" ]]; then
    print -ru2 -- "dve: missing daemon entrypoint at $daemon_entry"
    return 127
  fi

  "$daemon_entry" "$@"
}
