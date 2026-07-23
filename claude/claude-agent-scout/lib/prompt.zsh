#!/usr/bin/env zsh
# prompt.zsh — assemble the agent prompt for `cas ask`. Seeds the playbooks,
# a live scan snapshot, the resolved target's metadata, and a transcript tail,
# so the launched agent can answer "what is this agent doing" from real state.

# cas_build_ask_prompt <target> <question...>
#   target: pid | session-id | cwd path | "" / "all"
cas_build_ask_prompt() {
  local target="${1:-}"; shift 2>/dev/null || true
  local question="$*"

  local pid="" sid="" cwd="" tp="" cmd="" scope="all live Claude agents"
  if [[ -n "$target" && "$target" != all ]]; then
    if [[ "$target" == <-> ]]; then
      pid="$target"
      cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null)
      sid=$(cas_session_from_cmd "${cmd:-}") || sid=""
      cwd=$(cas_cwd_of_pid "$pid") || cwd=""
    elif [[ "$target" == /* ]]; then
      cwd="$target"
    else
      sid="$target"
      pid=$(cas_pid_for_session "$sid") || pid=""
      [[ -n "$pid" ]] && { cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null); cwd=$(cas_cwd_of_pid "$pid"); }
    fi
    [[ -n "$cwd" && -n "$sid" ]] && tp=$(cas_transcript_path "$cwd" "$sid")
    # Ended session (no live pid): still locate its transcript by session-id.
    [[ -z "$tp" && -n "$sid" ]] && tp=$(cas_find_transcript_by_sid "$sid")
    [[ -z "$cwd" && -n "$tp" ]] && cwd="${${tp:h:t}//-//}"
    scope="target ${target}"
  fi

  cat "${daemon_dir}/playbooks/_common.md" "${daemon_dir}/playbooks/ask.md"

  print -r -- ""
  print -r -- "## Run context"
  print -r -- "- today: $(date '+%Y-%m-%d %H:%M')"
  print -r -- "- scope: ${scope}"
  [[ -n "$question" ]] && print -r -- "- user question: ${question}"
  [[ -z "$question" ]] && print -r -- "- user question: (none given) — summarize what the target agent is currently doing and its recent activity"
  [[ -n "$pid" ]] && print -r -- "- target pid: ${pid}"
  [[ -n "$sid" ]] && print -r -- "- target session-id: ${sid}"
  [[ -n "$cwd" ]] && print -r -- "- target cwd: ${cwd}"
  [[ -n "$tp"  ]] && print -r -- "- target transcript (JSONL, read it directly): ${tp}"
  if [[ -n "$cmd" ]]; then
    print -r -- "- target command line:"
    print -r -- '  ```'
    print -r -- "  ${cmd}"
    print -r -- '  ```'
  fi

  print -r -- ""
  print -r -- "## Live scan snapshot"
  print -r -- '```'
  cas_scan_report 2>/dev/null
  print -r -- '```'

  if [[ -n "$tp" && -f "$tp" ]]; then
    print -r -- ""
    print -r -- "## Target transcript — recent turns"
    print -r -- "Full transcript at the path above; the last turns follow for convenience."
    print -r -- '```'
    local t role text
    cas_transcript_turns "$tp" 20 | while IFS=$'\t' read -r t role text; do
      text="${text//$'\n'/ }"
      print -r -- "[${t}] ${role}: ${text[1,300]}"
    done
    print -r -- '```'
  fi
}
