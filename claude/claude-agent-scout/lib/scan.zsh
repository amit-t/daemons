#!/usr/bin/env zsh
# scan.zsh — enumerate and classify every Claude-related process, then render
# a categorized table (or JSON). Pure local, read-only, no agent, no cost.

# Classify one command line. Prints "class|detail|consumes".
#   class:    skip | cli-agent | desktop-app | desktop-renderer | mcp | helper | other
#   detail:   short human label
#   consumes: API | subscription | tool | no | ?
cas_classify() {
  local c="$1"

  # Our own daemon repo paths (they contain ".../claude/...") and this scout: ignore.
  [[ "$c" == *"/daemons/claude/"* || "$c" == *"claude-agent-scout"* ]] && { print -r -- "skip||"; return; }

  # MCP servers spawned to serve a Claude session's tools.
  if [[ "$c" == *modelcontextprotocol* || "$c" == *"mcp-server"* || "$c" == *"server-pdf"* || "$c" == *"@modelcontextprotocol"* ]]; then
    print -r -- "mcp|MCP tool server|tool"; return
  fi

  # Claude Desktop: renderer processes are the chat / cowork / remote-session surfaces.
  if [[ "$c" == *"Claude Helper (Renderer)"* ]]; then
    print -r -- "desktop-renderer|Desktop renderer / chat·cowork surface|subscription"; return
  fi

  # Claude Desktop: crash + extension infra (no inference).
  [[ "$c" == *"chrome_crashpad_handler"* && "$c" == *Claude* ]] && { print -r -- "helper|crashpad handler|no"; return; }
  [[ "$c" == *"chrome-native-host"* && "$c" == *[Cc]laude* ]]  && { print -r -- "helper|browser-extension native host|no"; return; }

  # Claude Desktop: other Electron helper processes (gpu/network/audio/video/utility).
  if [[ "$c" == *"Claude Helper"* || ( "$c" == *"Electron Framework"* && "$c" == *Claude* ) ]]; then
    local sub="helper"
    if [[ "$c" == *"--utility-sub-type="* ]]; then
      sub="${c##*--utility-sub-type=}"; sub="${sub%% *}"
    elif [[ "$c" == *"--type="* ]]; then
      sub="${c##*--type=}"; sub="${sub%% *}"
    fi
    print -r -- "helper|${sub}|no"; return
  fi

  # Claude Desktop: the main app process.
  [[ "$c" == *"Claude.app/Contents/MacOS/Claude"* ]] && { print -r -- "desktop-app|Claude Desktop app (main)|subscription"; return; }

  # Claude Code CLI session: a lowercase `claude` binary invocation (not the .app).
  # Distinguish "/claude " or trailing "/claude" from directory paths like "/claude/".
  if [[ "$c" == *"/claude "* || "$c" == *"/claude" || "$c" == "claude "* || "$c" == "claude" ]]; then
    print -r -- "cli-agent|Claude Code CLI session|API"; return
  fi

  print -r -- "other|claude-related process|?"
}

# Populate the global CAS_ROWS array with "class<TAB>pid<TAB>started<TAB>consumes<TAB>detail<TAB>cmd".
cas_collect() {
  local show_all=${1:-0}
  typeset -ga CAS_ROWS=()
  local line pid started cmd class detail consumes ci rest
  local -a f
  while IFS= read -r line; do
    f=(${=line})
    (( ${#f} >= 7 )) || continue
    pid=$f[1]
    # lstart tokens: dow mon day HH:MM:SS year  ->  "mon day HH:MM"
    started="$f[3] $f[4] ${f[5][1,5]}"
    cmd="${(j: :)f[7,-1]}"
    ci=$(cas_classify "$cmd")
    class=${ci%%|*}; rest=${ci#*|}; detail=${rest%%|*}; consumes=${rest##*|}
    [[ "$class" == skip ]] && continue
    [[ "$class" == other && "$show_all" != 1 ]] && continue
    CAS_ROWS+=("${class}	${pid}	${started}	${consumes}	${detail}	${cmd}")
  done < <(ps -axww -o pid=,lstart=,command=)
}

# Render the categorized human table.
cas_scan_report() {
  local json=0 show_all=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --all)  show_all=1 ;;
      *) print -ru2 -- "cas list: unknown flag '$a' (expected --json, --all)"; return 2 ;;
    esac
  done

  cas_collect "$show_all"

  if (( json )); then cas_scan_json; return; fi

  local -a cli desktop helper mcp other
  local r class pid started consumes detail cmd
  for r in "${CAS_ROWS[@]}"; do
    IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
    case "$class" in
      cli-agent)                     cli+=("$r") ;;
      desktop-app|desktop-renderer)  desktop+=("$r") ;;
      mcp)                           mcp+=("$r") ;;
      helper)                        helper+=("$r") ;;
      *)                             other+=("$r") ;;
    esac
  done

  print -r -- ""
  print -r -- "CLAUDE AGENT SCOUT — $(date '+%Y-%m-%d %H:%M')"

  # --- Claude Code CLI sessions (real API-usage consumers) ---
  print -r -- ""
  print -r -- "▌ Claude Code CLI sessions  (consume API usage)"
  if (( ${#cli} == 0 )); then
    print -r -- "    none running"
  else
    printf '    %-7s %-13s %-10s %-34s %s\n' PID STARTED SESSION DIR "LAST ACTIVITY"
    for r in "${cli[@]}"; do
      IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
      local sid cwd tp shortsid dir="?" last="—"
      sid=$(cas_session_from_cmd "$cmd") || sid=""
      cwd=$(cas_cwd_of_pid "$pid") || cwd=""
      shortsid="${sid[1,8]:-????????}"
      [[ -n "$cwd" ]] && dir="${cwd/#${HOME}\/Projects\//}"
      if [[ -n "$cwd" && -n "$sid" ]]; then
        tp=$(cas_transcript_path "$cwd" "$sid")
        if [[ -f "$tp" ]]; then
          last="$(cas_file_mtime "$tp") (idle $(cas_fmt_age $(cas_file_age_secs "$tp")))"
        fi
      fi
      printf '    %-7s %-13s %-10s %-34s %s\n' "$pid" "$started" "$shortsid" "${dir[1,34]}" "$last"
    done
  fi

  # --- Claude Desktop ---
  print -r -- ""
  print -r -- "▌ Claude Desktop  (consumes subscription usage when active)"
  if (( ${#desktop} == 0 )); then
    print -r -- "    not running"
  else
    printf '    %-7s %-13s %s\n' PID STARTED WHAT
    for r in "${desktop[@]}"; do
      IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
      printf '    %-7s %-13s %s\n' "$pid" "$started" "$detail"
    done
  fi

  # --- MCP tool servers ---
  if (( ${#mcp} > 0 )); then
    print -r -- ""
    print -r -- "▌ MCP tool servers  (spawned tools — no direct usage)"
    printf '    %-7s %-13s %s\n' PID STARTED WHAT
    for r in "${mcp[@]}"; do
      IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
      # try to name the server package
      local name="$detail"
      [[ "$cmd" == *"@modelcontextprotocol/"* ]] && { name="${cmd##*@modelcontextprotocol/}"; name="@modelcontextprotocol/${name%% *}"; }
      printf '    %-7s %-13s %s\n' "$pid" "$started" "$name"
    done
  fi

  # --- Desktop helper processes (collapsed unless --all) ---
  if (( ${#helper} > 0 )); then
    print -r -- ""
    if (( show_all )); then
      print -r -- "▌ Desktop helper processes  (infra — no usage)"
      printf '    %-7s %-13s %s\n' PID STARTED WHAT
      for r in "${helper[@]}"; do
        IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
        printf '    %-7s %-13s %s\n' "$pid" "$started" "$detail"
      done
    else
      local subs=""
      for r in "${helper[@]}"; do
        IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
        subs+="${detail}, "
      done
      print -r -- "▌ ${#helper} Desktop helper processes (infra — no usage): ${subs%, }"
      print -r -- "    (run 'cas list --all' to expand)"
    fi
  fi

  if (( ${#other} > 0 && show_all )); then
    print -r -- ""
    print -r -- "▌ Other claude-related processes"
    printf '    %-7s %-13s %s\n' PID STARTED CMD
    for r in "${other[@]}"; do
      IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
      printf '    %-7s %-13s %s\n' "$pid" "$started" "${cmd[1,80]}"
    done
  fi

  # --- Summary ---
  print -r -- ""
  print -r -- "Summary: ${#cli} CLI session(s), ${#desktop} desktop process(es), ${#mcp} MCP server(s), ${#helper} helper(s)."
  if (( ${#cli} > 0 )); then
    print -r -- "Ask what one is doing:  cas ask <pid>     |  Deep-dive locally:  cas show <pid>"
  fi
  print -r -- ""
}

# Render the scan as a JSON array (requires jq).
cas_scan_json() {
  if ! (( $+commands[jq] )); then
    print -ru2 -- "cas list --json: jq not found"; return 1
  fi
  local r class pid started consumes detail cmd sid cwd tp first=1
  print -r -- "["
  for r in "${CAS_ROWS[@]}"; do
    IFS=$'\t' read -r class pid started consumes detail cmd <<< "$r"
    sid=""; cwd=""; tp=""
    if [[ "$class" == cli-agent ]]; then
      sid=$(cas_session_from_cmd "$cmd") || sid=""
      cwd=$(cas_cwd_of_pid "$pid") || cwd=""
      [[ -n "$cwd" && -n "$sid" ]] && tp=$(cas_transcript_path "$cwd" "$sid")
    fi
    (( first )) || print -r -- ","
    first=0
    jq -nc \
      --arg class "$class" --arg pid "$pid" --arg started "$started" \
      --arg consumes "$consumes" --arg detail "$detail" \
      --arg session "$sid" --arg cwd "$cwd" --arg transcript "$tp" \
      --arg cmd "$cmd" \
      '{pid:($pid|tonumber),class:$class,consumes:$consumes,started:$started,detail:$detail,session:$session,cwd:$cwd,transcript:$transcript,cmd:$cmd}'
  done
  print -r -- "]"
}
