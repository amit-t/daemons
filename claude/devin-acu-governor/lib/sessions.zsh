#!/usr/bin/env zsh
# dag sessions — argument parsing, time-window resolution, and output-path
# planning for the session-logs / prompt-traces command.
#
# Pure computation: this file performs no API calls and creates no files. It
# turns CLI flags into a validated window plus a fixed artifact layout, which
# bin/dag then hands to the agent session as Run-context lines. Keeping the
# window math here (rather than in the playbook) means the agent never has to
# do date arithmetic, and the whole surface is unit-testable without a key.
#
# "now" is `date +%s` unless DAG_SESSIONS_NOW pins it (tests, replayed runs).

# Format one epoch. $1=epoch $2=strftime format $3=utc|local (default local).
# Tries BSD `date -r` (macOS) first, falls back to GNU `date -d @`.
_dag_sessions_fmt_epoch() {
  local epoch=$1 fmt=$2 zone=${3:-local}
  if [[ "$zone" == "utc" ]]; then
    date -u -r "$epoch" +"$fmt" 2>/dev/null || date -u -d "@${epoch}" +"$fmt" 2>/dev/null
  else
    date -r "$epoch" +"$fmt" 2>/dev/null || date -d "@${epoch}" +"$fmt" 2>/dev/null
  fi
}

# Convert a local wall-clock midnight to an epoch, optionally N days later.
# $1=YYYY-MM-DD $2=day offset (0 or 1). The offset uses real calendar
# arithmetic rather than +86400 so a DST transition cannot shift the boundary.
_dag_sessions_date_to_epoch() {
  local d=$1 offset=${2:-0} e
  if (( offset == 0 )); then
    if e=$(date -j -f "%Y-%m-%d %H:%M:%S" "${d} 00:00:00" +%s 2>/dev/null); then
      print -r -- "$e"
      return 0
    fi
    if e=$(date -d "${d} 00:00:00" +%s 2>/dev/null); then
      print -r -- "$e"
      return 0
    fi
    return 1
  fi
  if e=$(date -j -v+${offset}d -f "%Y-%m-%d %H:%M:%S" "${d} 00:00:00" +%s 2>/dev/null); then
    print -r -- "$e"
    return 0
  fi
  if e=$(date -d "${d} 00:00:00 +${offset} day" +%s 2>/dev/null); then
    print -r -- "$e"
    return 0
  fi
  return 1
}

# Resolve a --since/--until value to an epoch.
# Accepts a Unix epoch (>= 9 digits) or YYYY-MM-DD.
# $1=label (for errors) $2=value $3=start|end.
#
# The Devin API window is half-open — `[created_after, created_before)` was
# verified live against /v3/enterprise/sessions (lower bound inclusive, upper
# bound exclusive). So a bare date becomes local midnight for a start bound and
# the FOLLOWING local midnight for an end bound: `--since 2026-07-01 --until
# 2026-07-07` then covers all seven whole days, the 7th included.
_dag_sessions_resolve_instant() {
  local label=$1 value=$2 kind=$3 epoch offset=0
  if [[ "$value" == <-> && ${#value} -ge 9 ]]; then
    print -r -- "$value"
    return 0
  fi
  if [[ ! "$value" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]]; then
    print -ru2 -- "dag sessions: ${label} expects YYYY-MM-DD or a Unix epoch (got: ${value})"
    return 2
  fi
  [[ "$kind" == "end" ]] && offset=1
  if ! epoch=$(_dag_sessions_date_to_epoch "$value" "$offset"); then
    print -ru2 -- "dag sessions: ${label} is not a real calendar date (got: ${value})"
    return 2
  fi
  print -r -- "$epoch"
}

# Parse `dag sessions` flags. $1 = the spelling the user invoked (used verbatim
# in the "requested shell command" context line), rest = flags.
# On success sets the _dag_sessions_* globals below and returns 0.
# On any validation failure prints to stderr and returns 2.
dag_sessions_parse() {
  local invoked=$1
  shift

  typeset -g _dag_sessions_invoked="$invoked"
  typeset -g _dag_sessions_hours=""
  typeset -g _dag_sessions_days=""
  typeset -g _dag_sessions_since_raw=""
  typeset -g _dag_sessions_until_raw=""
  typeset -g _dag_sessions_org=""
  typeset -g _dag_sessions_user=""
  typeset -g _dag_sessions_origin=""
  typeset -g _dag_sessions_out=""
  typeset -g _dag_sessions_max="0"
  typeset -g _dag_sessions_traces=1
  typeset -g _dag_sessions_insights=0

  local arg value
  local -a raw_args
  raw_args=("$@")
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --hours=*|--days=*|--since=*|--until=*|--org=*|--user=*|--origin=*|--out=*|--max-sessions=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        set -- "$arg" "$value" "${@[2,-1]}"
        continue
        ;;
      --hours|--days|--since|--until|--org|--user|--origin|--out|--max-sessions)
        value="${2:-}"
        if [[ -z "$value" || "$value" == --* ]]; then
          print -ru2 -- "dag sessions: ${arg} expects a value"
          return 2
        fi
        case "$arg" in
          --hours)        _dag_sessions_hours="$value" ;;
          --days)         _dag_sessions_days="$value" ;;
          --since)        _dag_sessions_since_raw="$value" ;;
          --until)        _dag_sessions_until_raw="$value" ;;
          --org)          _dag_sessions_org="$value" ;;
          --user)         _dag_sessions_user="$value" ;;
          --origin)       _dag_sessions_origin="$value" ;;
          --out)          _dag_sessions_out="$value" ;;
          --max-sessions) _dag_sessions_max="$value" ;;
        esac
        shift 2
        ;;
      --no-traces)
        _dag_sessions_traces=0
        shift
        ;;
      --traces)
        _dag_sessions_traces=1
        shift
        ;;
      --insights|--include-insights)
        _dag_sessions_insights=1
        shift
        ;;
      --*)
        print -ru2 -- "dag sessions: unknown flag '${arg}' (expected --hours/--days/--since/--until/--org/--user/--origin/--out/--max-sessions/--no-traces/--insights)"
        return 2
        ;;
      *)
        print -ru2 -- "dag sessions: unexpected argument '${arg}' (all inputs are flags; see dag help)"
        return 2
        ;;
    esac
  done

  # Window selectors are mutually exclusive: pick exactly one of
  # --hours, --days, or --since[/--until]. Default is --hours 24.
  local -a selectors
  selectors=()
  [[ -n "$_dag_sessions_hours" ]] && selectors+=("--hours")
  [[ -n "$_dag_sessions_days" ]] && selectors+=("--days")
  [[ -n "$_dag_sessions_since_raw" ]] && selectors+=("--since")
  if (( ${#selectors} > 1 )); then
    print -ru2 -- "dag sessions: ${(j: and :)selectors} are mutually exclusive; pick one window selector"
    return 2
  fi
  if [[ -n "$_dag_sessions_until_raw" && -z "$_dag_sessions_since_raw" ]]; then
    print -ru2 -- "dag sessions: --until requires --since"
    return 2
  fi

  if [[ -n "$_dag_sessions_hours" && "$_dag_sessions_hours" != <-> ]]; then
    print -ru2 -- "dag sessions: --hours expects a positive integer (got: ${_dag_sessions_hours})"
    return 2
  fi
  if [[ -n "$_dag_sessions_hours" ]] && (( _dag_sessions_hours < 1 || _dag_sessions_hours > 8760 )); then
    print -ru2 -- "dag sessions: --hours must be between 1 and 8760 (got: ${_dag_sessions_hours})"
    return 2
  fi
  if [[ -n "$_dag_sessions_days" && "$_dag_sessions_days" != <-> ]]; then
    print -ru2 -- "dag sessions: --days expects a positive integer (got: ${_dag_sessions_days})"
    return 2
  fi
  if [[ -n "$_dag_sessions_days" ]] && (( _dag_sessions_days < 1 || _dag_sessions_days > 365 )); then
    print -ru2 -- "dag sessions: --days must be between 1 and 365 (got: ${_dag_sessions_days})"
    return 2
  fi
  if [[ "$_dag_sessions_max" != <-> ]]; then
    print -ru2 -- "dag sessions: --max-sessions expects a positive integer (got: ${_dag_sessions_max})"
    return 2
  fi
  if [[ -n "$_dag_sessions_user" && "$_dag_sessions_user" != *@*.* ]]; then
    print -ru2 -- "dag sessions: --user expects a user email (got: ${_dag_sessions_user})"
    return 2
  fi
  if [[ -n "$_dag_sessions_origin" ]]; then
    local -a valid_origins
    valid_origins=(webapp slack teams api linear jira automation cli desktop code_scan other)
    if (( ! ${valid_origins[(Ie)$_dag_sessions_origin]} )); then
      print -ru2 -- "dag sessions: --origin must be one of ${(j:, :)valid_origins} (got: ${_dag_sessions_origin})"
      return 2
    fi
  fi

  typeset -g _dag_sessions_now="${DAG_SESSIONS_NOW:-$(date +%s)}"
  if [[ "$_dag_sessions_now" != <-> ]]; then
    print -ru2 -- "dag sessions: DAG_SESSIONS_NOW must be a Unix epoch (got: ${_dag_sessions_now})"
    return 2
  fi

  typeset -g _dag_sessions_start=0 _dag_sessions_end=0 _dag_sessions_window_source=""
  if [[ -n "$_dag_sessions_since_raw" ]]; then
    _dag_sessions_start=$(_dag_sessions_resolve_instant "--since" "$_dag_sessions_since_raw" start) || return 2
    if [[ -n "$_dag_sessions_until_raw" ]]; then
      _dag_sessions_end=$(_dag_sessions_resolve_instant "--until" "$_dag_sessions_until_raw" end) || return 2
    else
      _dag_sessions_end=$_dag_sessions_now
    fi
    _dag_sessions_window_source="explicit --since/--until"
  else
    local hours=24
    if [[ -n "$_dag_sessions_hours" ]]; then
      hours=$_dag_sessions_hours
      _dag_sessions_window_source="--hours ${hours}"
    elif [[ -n "$_dag_sessions_days" ]]; then
      hours=$(( _dag_sessions_days * 24 ))
      _dag_sessions_window_source="--days ${_dag_sessions_days} (${hours}h)"
    else
      _dag_sessions_window_source="default 24h"
    fi
    _dag_sessions_hours=$hours
    _dag_sessions_end=$_dag_sessions_now
    _dag_sessions_start=$(( _dag_sessions_now - hours * 3600 ))
  fi

  if (( _dag_sessions_end <= _dag_sessions_start )); then
    print -ru2 -- "dag sessions: window end (${_dag_sessions_end}) must be after window start (${_dag_sessions_start})"
    return 2
  fi
  # Report the effective span for every path, including explicit --since/--until.
  typeset -g _dag_sessions_span_hours
  _dag_sessions_span_hours=$(( (_dag_sessions_end - _dag_sessions_start + 1799) / 3600 ))
  (( _dag_sessions_span_hours < 1 )) && _dag_sessions_span_hours=1

  typeset -g _dag_sessions_run_id
  _dag_sessions_run_id=$(_dag_sessions_fmt_epoch "$_dag_sessions_now" "%Y%m%dT%H%M%SZ" utc)
  if [[ -z "$_dag_sessions_run_id" ]]; then
    print -ru2 -- "dag sessions: could not format the run timestamp from epoch ${_dag_sessions_now}"
    return 2
  fi

  typeset -g _dag_sessions_dir
  if [[ -n "$_dag_sessions_out" ]]; then
    _dag_sessions_dir="${_dag_sessions_out:A}"
  else
    _dag_sessions_dir="${DAG_STATE_DIR}/sessions/${_dag_sessions_run_id}"
  fi

  typeset -g _dag_sessions_cmdline
  if (( ${#raw_args} )); then
    _dag_sessions_cmdline="dag ${invoked} ${(j: :)raw_args}"
  else
    _dag_sessions_cmdline="dag ${invoked}"
  fi
  return 0
}

# Build the Run-context lines for the assembled prompt from the parsed globals.
# Sets the global array _dag_sessions_context.
dag_sessions_context() {
  local start_local end_local start_utc end_utc
  start_local=$(_dag_sessions_fmt_epoch "$_dag_sessions_start" "%Y-%m-%d %H:%M:%S %Z" local)
  end_local=$(_dag_sessions_fmt_epoch "$_dag_sessions_end" "%Y-%m-%d %H:%M:%S %Z" local)
  start_utc=$(_dag_sessions_fmt_epoch "$_dag_sessions_start" "%Y-%m-%dT%H:%M:%SZ" utc)
  end_utc=$(_dag_sessions_fmt_epoch "$_dag_sessions_end" "%Y-%m-%dT%H:%M:%SZ" utc)

  typeset -ga _dag_sessions_context
  _dag_sessions_context=(
    "requested shell command: ${_dag_sessions_cmdline}"
    "scope: read-only session-log + prompt-trace extraction across the whole enterprise; GET only, no PATCH/POST/DELETE to the Devin API at any point"
    "window hours: ${_dag_sessions_span_hours} (source: ${_dag_sessions_window_source})"
    "window start epoch: ${_dag_sessions_start}"
    "window end epoch: ${_dag_sessions_end}"
    "window start local: ${start_local}"
    "window end local: ${end_local}"
    "window start utc: ${start_utc}"
    "window end utc: ${end_utc}"
    "window filter contract: pass created_after=${_dag_sessions_start} and created_before=${_dag_sessions_end} to /v3/enterprise/sessions. Verified live semantics: the window is half-open on created_at — [created_after, created_before) — lower bound inclusive, upper bound exclusive. Do NOT pass time_after/time_before: they are accepted with HTTP 200 and silently ignored, which would return the whole unfiltered history."
    "window membership rule: created_at only. A session created before the window but updated inside it is NOT included; say so in the OVERVIEW coverage section and tell the user to widen with --since/--hours if they want it."
    "run id: ${_dag_sessions_run_id}"
    "output directory: ${_dag_sessions_dir}"
    "overview file: ${_dag_sessions_dir}/OVERVIEW.md"
    "manifest file: ${_dag_sessions_dir}/manifest.json"
    "sessions raw file: ${_dag_sessions_dir}/sessions.json"
    "sessions ndjson file: ${_dag_sessions_dir}/sessions.ndjson"
    "traces directory: ${_dag_sessions_dir}/traces"
    "insights file: ${_dag_sessions_dir}/insights.json"
    "users file: ${_dag_sessions_dir}/users.json"
    "organizations file: ${_dag_sessions_dir}/organizations.json"
    "errors log: ${_dag_sessions_dir}/errors.log"
  )
  if (( _dag_sessions_traces )); then
    _dag_sessions_context+=("prompt traces: ENABLED — fetch /v3/organizations/{org_id}/sessions/{session_id}/messages for every session in the window and write both the raw JSON and the readable transcript")
    _dag_sessions_context+=("prompt trace scope: visible conversation only. v3 exposes user prompts and Devin's chat replies; it exposes NO tool calls, shell commands, command output, code edits, or internal reasoning (the /events and /logs subresources return 404). State this limitation in OVERVIEW.md — never imply the traces are a full execution log.")
  else
    _dag_sessions_context+=("prompt traces: DISABLED (--no-traces) — write session metadata only, leave traces/ empty, and say so in OVERVIEW.md")
  fi
  if (( _dag_sessions_insights )); then
    _dag_sessions_context+=("session insights: ENABLED (--insights) — also fetch /v3/enterprise/sessions/insights for the same window and merge num_user_messages, num_devin_messages, session_size, and analysis into the per-session records")
  else
    _dag_sessions_context+=("session insights: DISABLED — do not call /v3/enterprise/sessions/insights; suggest --insights in OVERVIEW.md if the analysis would have helped")
  fi
  _dag_sessions_context+=("filter application: apply org/user/origin filters CLIENT-SIDE on the fetched window. Only created_after/created_before are verified to filter server-side; other documented query parameters have not been confirmed on this deployment, and an ignored filter would silently widen the result set instead of erroring.")
  if [[ -n "$_dag_sessions_org" ]]; then
    _dag_sessions_context+=("org filter: ${_dag_sessions_org} — match session org_id, resolving the name via GET /v3/enterprise/organizations")
  else
    _dag_sessions_context+=("org filter: none — pull every org in the enterprise")
  fi
  if [[ -n "$_dag_sessions_user" ]]; then
    _dag_sessions_context+=("user filter: ${_dag_sessions_user} — resolve the email to a user_id via GET /v3/enterprise/members/users, then match session user_id")
  else
    _dag_sessions_context+=("user filter: none — pull every user and service user")
  fi
  if [[ -n "$_dag_sessions_origin" ]]; then
    _dag_sessions_context+=("origin filter: ${_dag_sessions_origin} — match session origin")
  else
    _dag_sessions_context+=("origin filter: none — include every origin (webapp, slack, teams, api, linear, jira, automation, cli, desktop, code_scan, other)")
  fi
  if (( _dag_sessions_max > 0 )); then
    _dag_sessions_context+=("max sessions: ${_dag_sessions_max} — if the window holds more, keep the highest-ACU sessions, record the exact dropped count in manifest.json, and state the truncation in OVERVIEW.md; never truncate silently")
  else
    _dag_sessions_context+=("max sessions: unlimited — extract every session in the window")
  fi
}
