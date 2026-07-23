#!/usr/bin/env zsh
# show.zsh — local, read-only deep-dive of a single Claude target (pid or
# session-id): full command line, cwd, transcript location, token usage, and
# the most recent conversation turns.

# Extract up to N recent user/assistant turns from a transcript as
# "timestamp<TAB>role<TAB>text". Requires jq.
cas_transcript_turns() {
  local f="$1" n="${2:-8}"
  (( $+commands[jq] )) || return 1
  jq -rc '
    select(.type=="user" or .type=="assistant") |
    { t: (.timestamp // ""),
      role: (.message.role // .type),
      text: ( (.message.content) as $c |
        if ($c|type)=="string" then $c
        elif ($c|type)=="array" then
          ([ $c[]? |
             if .type=="text" then .text
             elif .type=="tool_use" then "⚙ " + (.name // "tool")
             elif .type=="tool_result" then "↩ tool_result"
             elif .type=="thinking" then "…thinking"
             else empty end ] | join(" · "))
        else "" end )
    }
    | .text |= (gsub("\\s+"; " ") | sub("^ "; ""))
    | "\(.t)\t\(.role)\t\(.text)"
  ' "$f" 2>/dev/null | tail -n "$n"
}

# Sum token usage across a transcript (requires jq). Prints a one-line summary.
cas_transcript_tokens() {
  local f="$1"
  (( $+commands[jq] )) || return 1
  jq -sr '
    [ .[] | .message.usage? // empty ] |
    { input:  (map(.input_tokens // 0)              | add // 0),
      output: (map(.output_tokens // 0)             | add // 0),
      cache_read:  (map(.cache_read_input_tokens // 0)   | add // 0),
      cache_write: (map(.cache_creation_input_tokens // 0)| add // 0) }
    | "input \(.input)  ·  output \(.output)  ·  cache_read \(.cache_read)  ·  cache_write \(.cache_write)"
  ' "$f" 2>/dev/null
}

cas_show() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    print -ru2 -- "cas show: needs a PID or session-id. Try 'cas list' first."
    return 2
  fi

  local pid="" sid=""
  if [[ "$target" == <-> ]]; then
    pid="$target"
  else
    sid="$target"
    pid=$(cas_pid_for_session "$sid") || pid=""
  fi

  local cmd=""
  if [[ -n "$pid" ]]; then
    cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null)
    if [[ -z "$cmd" ]]; then
      print -ru2 -- "cas show: no running process with PID ${pid}."
      return 1
    fi
  fi

  local ci class detail consumes
  ci=$(cas_classify "${cmd:-}")
  class=${ci%%|*}; detail=${ci#*|}; consumes=${detail##*|}; detail=${detail%%|*}

  [[ -z "$sid" && -n "$cmd" ]] && sid=$(cas_session_from_cmd "$cmd")
  local cwd="" tp=""
  [[ -n "$pid" ]] && cwd=$(cas_cwd_of_pid "$pid")
  [[ -n "$cwd" && -n "$sid" ]] && tp=$(cas_transcript_path "$cwd" "$sid")
  # Ended session (no live pid ⇒ no cwd): locate the transcript by session-id.
  [[ -z "$tp" && -n "$sid" ]] && tp=$(cas_find_transcript_by_sid "$sid")
  # If we found a transcript for a non-running target, it was a CLI session.
  if [[ -z "$pid" && -n "$tp" ]]; then
    class="cli-agent"; detail="Claude Code CLI session (ended)"; consumes="API"
    [[ -z "$cwd" ]] && cwd="${${tp:h:t}//-//}"
  fi

  print -r -- ""
  print -r -- "CLAUDE TARGET — ${target}"
  print -r -- "  pid:        ${pid:-<not running>}"
  print -r -- "  class:      ${class} (${detail}) — consumes: ${consumes}"
  [[ -n "$sid" ]] && print -r -- "  session:    ${sid}"
  [[ -n "$cwd" ]] && print -r -- "  cwd:        ${cwd}"
  if [[ -n "$cmd" ]]; then
    print -r -- "  command:"
    print -r -- "    ${cmd[1,400]}"
    (( ${#cmd} > 400 )) && print -r -- "    … (${#cmd} chars total; full via: ps -ww -o command= -p ${pid})"
  fi

  print -r -- ""
  if [[ -z "$tp" ]]; then
    print -r -- "  transcript: (not a Claude Code CLI session, or none found)"
    print -r -- ""
    return 0
  fi
  if [[ ! -f "$tp" ]]; then
    print -r -- "  transcript: ${tp}"
    print -r -- "              (file not found — session may not have written yet)"
    print -r -- ""
    return 0
  fi

  local entries age
  entries=$(wc -l < "$tp" | tr -d ' ')
  age=$(cas_fmt_age "$(cas_file_age_secs "$tp")")
  print -r -- "  transcript: ${tp}"
  print -r -- "  entries:    ${entries}   last activity: $(cas_file_mtime "$tp") (${age} ago)"
  local toks
  toks=$(cas_transcript_tokens "$tp") && [[ -n "$toks" ]] && print -r -- "  tokens:     ${toks}"

  print -r -- ""
  print -r -- "  recent turns:"
  local t role text
  cas_transcript_turns "$tp" 10 | while IFS=$'\t' read -r t role text; do
    local ts="${t[12,19]}"   # HH:MM:SS from an ISO timestamp, if present
    [[ -z "$ts" ]] && ts="--------"
    text="${text//$'\n'/ }"
    printf '    %-8s %-9s %s\n' "$ts" "$role" "${text[1,110]}"
  done
  print -r -- ""
  print -r -- "  Interrogate live:  cas ask ${pid:-$sid}"
  print -r -- ""
}
