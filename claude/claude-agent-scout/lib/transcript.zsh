#!/usr/bin/env zsh
# transcript.zsh — resolve Claude Code session transcripts and process metadata.
# Claude Code writes one JSONL transcript per session at:
#   ~/.claude/projects/<cwd-with-slashes-as-dashes>/<session-id>.jsonl

: ${CAS_PROJECTS_DIR:=${HOME}/.claude/projects}

# Encode an absolute cwd the way Claude Code names its project dir: every "/"
# becomes "-" (so a leading slash yields a leading dash).
cas_escape_cwd() { print -r -- "${1//\//-}" }

# $1 = cwd, $2 = session-id -> transcript path (may not exist).
cas_transcript_path() {
  [[ -n "$1" && -n "$2" ]] || return 1
  print -r -- "${CAS_PROJECTS_DIR}/$(cas_escape_cwd "$1")/${2}.jsonl"
}

# Extract the --session-id value from a process command line.
cas_session_from_cmd() {
  local c="$1" s
  [[ "$c" == *"--session-id "* ]] || return 1
  s="${c##*--session-id }"
  print -r -- "${s%% *}"
}

# Working directory of a running pid (via lsof), empty if unavailable.
cas_cwd_of_pid() {
  local line
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | while IFS= read -r line; do
    [[ "$line" == n* ]] && { print -r -- "${line#n}"; return 0; }
  done
  return 1
}

# Human mtime of a file, e.g. "Jul 23 11:05".
cas_file_mtime() {
  [[ -f "$1" ]] || return 1
  stat -f '%Sm' -t '%b %d %H:%M' "$1" 2>/dev/null
}

# Age of a file in seconds.
cas_file_age_secs() {
  [[ -f "$1" ]] || return 1
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || return 1
  print -r -- $(( $(date +%s) - m ))
}

# Compact age string from seconds: 45s / 15m / 3h / 2d.
cas_fmt_age() {
  local s=${1:-0}
  if   (( s < 60 ));    then print -r -- "${s}s"
  elif (( s < 3600 ));  then print -r -- "$(( s / 60 ))m"
  elif (( s < 86400 )); then print -r -- "$(( s / 3600 ))h"
  else                       print -r -- "$(( s / 86400 ))d"
  fi
}

# Locate a transcript file by session-id alone (searches every project dir),
# for sessions that are no longer running. Prints the newest match, or empty.
cas_find_transcript_by_sid() {
  local sid="$1" hit
  [[ -n "$sid" ]] || return 1
  for hit in "${CAS_PROJECTS_DIR}"/*/"${sid}.jsonl"(Nom); do
    print -r -- "$hit"; return 0
  done
  return 1
}

# Find the pid of a running claude CLI session by its session-id, or empty.
cas_pid_for_session() {
  local want="$1" line
  ps -axww -o pid=,command= 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == *"--session-id ${want}"* ]]; then
      print -r -- "${${(z)line}[1]}"
      return 0
    fi
  done
  return 1
}
