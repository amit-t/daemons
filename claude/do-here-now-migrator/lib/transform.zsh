#!/usr/bin/env zsh
# do-here-now-migrator — phase 4: transform (the agent phase).
#
# This is the only phase where judgement is required, so it is the only phase
# handed to an AI agent. Infrastructure — deletion, DNS, domain binding — stays
# in deterministic zsh, because an agent that improvises there can destroy a
# database or point a domain at the wrong site.
#
# The launchers are zsh functions and aliases in the user's interactive shell,
# so the session is started through `zsh -ic` exactly as the other daemons in
# this repository do.

# Map an agent selector to its launcher command. Both the logical name and the
# raw command are accepted, because the user thinks in both.
dhm_agent_launcher() {  # dhm_agent_launcher <agent>
  case "${1:l}" in
    claude|co|opus)         print -r -- "${DHM_LAUNCHER_CLAUDE:-co}" ;;
    cf|claude-fable|fable|fast)
                            print -r -- "${DHM_LAUNCHER_CLAUDE_FABLE:-cf}" ;;
    codex|cxscb)            print -r -- "${DHM_LAUNCHER_CODEX:-cxscb}" ;;
    devin|dey)              print -r -- "${DHM_LAUNCHER_DEVIN:-dey}" ;;
    "")                     print -r -- "${DHM_LAUNCHER:-co}" ;;
    *)
      dhm_error "unknown agent '${1}'"
      dhm_error "valid: claude (co), cf (claude-fable), codex (cxscb), devin (dey)"
      return 2
      ;;
  esac
}

dhm_agent_canonical() {  # dhm_agent_canonical <agent>
  case "${1:l}" in
    claude|co|opus)                    print -r -- claude ;;
    cf|claude-fable|fable|fast)        print -r -- claude-fable ;;
    codex|cxscb)                       print -r -- codex ;;
    devin|dey)                         print -r -- devin ;;
    "")                                print -r -- claude ;;
    *)                                 return 2 ;;
  esac
}

# Render prompts/transform.md with the run's facts substituted in. Placeholders
# are {{UPPER_SNAKE}} so nothing in ordinary prose collides with them.
dhm_transform_render_prompt() {  # dhm_transform_render_prompt <daemon-dir> <vars-json>
  local daemon_dir=$1 vars=$2
  local common="${daemon_dir}/prompts/_common.md"
  local body="${daemon_dir}/prompts/transform.md"
  [[ -r "$body" ]] || { dhm_error "missing prompt template ${body}"; return 1 }

  local text=""
  [[ -r "$common" ]] && text+="$(<"$common")"$'\n\n'
  text+="$(<"$body")"

  # Substitute every key present in the vars object.
  local key value
  for key in ${(f)"$(jq -r 'keys[]' <<<"$vars")"}; do
    value=$(jq -r --arg k "$key" '.[$k] // ""' <<<"$vars")
    text=${text//\{\{${key}\}\}/${value}}
  done
  print -r -- "$text"
}

# Persist the prompt next to the state file so a failed session can be
# inspected, replayed, or pasted into a different agent by hand.
dhm_transform_write_prompt() {  # dhm_transform_write_prompt <site> <text>
  local site=$1 text=$2 dir file
  dir="$(dhm_state_dir)/${site}"
  mkdir -p "$dir" || return 1
  file="${dir}/transform-prompt.md"
  print -r -- "$text" > "$file" || return 1
  chmod 600 "$file"
  print -r -- "$file"
}

# Hand the job to the agent. This replaces the current process, exactly like
# `dag`, so the user lands directly in the agent session. The daemon is
# re-entered afterwards through `dhm continue`, which the prompt instructs the
# agent to run.
dhm_transform_launch() {  # dhm_transform_launch <launcher> <prompt-text>
  local launcher=$1 prompt=$2

  if [[ -n "${DHM_PRINT_LAUNCHER:-}" ]]; then
    print -r -- "$launcher"
    return 0
  fi
  if [[ -n "${DHM_PRINT_PROMPT:-}" ]]; then
    print -r -- "$prompt"
    return 0
  fi
  if dhm_dry "launch '${launcher}' with the transform prompt"; then return 0; fi

  dhm_info "handing the transform to: ${launcher}"
  dhm_info "when the agent finishes it will run 'dhm continue' to resume this migration"
  exec zsh -ic "${launcher} $(printf '%q' "$prompt")"
}

# Create the isolated branch the agent works on, so main is never touched
# mid-migration and the whole transform can be abandoned with one branch delete.
dhm_transform_prepare_branch() {  # dhm_transform_prepare_branch <repo> <branch>
  local repo=$1 branch=$2
  if dhm_dry "create branch ${branch} in ${repo}"; then return 0; fi
  if git -C "$repo" rev-parse --verify "$branch" >/dev/null 2>&1; then
    dhm_log "branch ${branch} already exists; reusing it"
    git -C "$repo" checkout "$branch" >/dev/null 2>&1 || return 1
  else
    git -C "$repo" checkout -b "$branch" >/dev/null 2>&1 || {
      dhm_error "could not create branch ${branch}"; return 1
    }
    dhm_ok "created branch ${branch}"
  fi
}
