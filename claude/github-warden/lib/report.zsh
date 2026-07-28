#!/usr/bin/env zsh
# ghw report — per-login CSV/JSON reports (import spec §8) + source parsing (P6).
# Reports persist under ${GHW_STATE_DIR}/reports/<job_id>/ and are never deleted.

ghw_report_init() {  # $1 job id
  typeset -g GHW_REPORT_DIR="${GHW_STATE_DIR}/reports/$1"
  mkdir -p "$GHW_REPORT_DIR"
  print -r -- "login,phase,status,state,role,detail" > "${GHW_REPORT_DIR}/report.csv"
}

_ghw_csv_field() {  # quote a field iff it contains comma/quote
  local f="$1"
  if [[ "$f" == *[,\"]* ]]; then
    print -rn -- "\"${f//\"/\"\"}\""
  else
    print -rn -- "$f"
  fi
}

ghw_report_row() {  # login phase status state role detail
  local -a fields=("$1" "$2" "$3" "$4" "$5" "$6")
  local out="" f
  for f in "${fields[@]}"; do
    out+="$(_ghw_csv_field "$f"),"
  done
  print -r -- "${out%,}" >> "${GHW_REPORT_DIR}/report.csv"
}

ghw_report_finish() {  # $1 summary text — writes summary + JSON, prints dir
  print -r -- "$1" > "${GHW_REPORT_DIR}/summary.txt"
  jq -R -s '
    split("\n") | map(select(length > 0)) | .[1:] |
    map(
      # naive-safe CSV split: report fields never contain embedded newlines
      [scan("(?:^|,)(\"(?:[^\"]|\"\")*\"|[^,]*)")] | flatten |
      map(if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end) |
      {login: .[0], phase: .[1], status: .[2], state: .[3], role: .[4], detail: .[5]}
    )' "${GHW_REPORT_DIR}/report.csv" > "${GHW_REPORT_DIR}/report.json"
  print -r -- "$GHW_REPORT_DIR"
}

ghw_parse_source() {  # $1 csv path, $2 column name — prints deduped logins
  local csv="$1" column="$2"
  if [[ ! -f "$csv" ]]; then
    print -ru2 -- "SOURCE_INVALID: file not found: $csv"
    return 6
  fi
  local raw
  raw=$(awk -F',' -v col="$column" '
    NR==1 { for (i=1;i<=NF;i++) { h=$i; gsub(/^[" \r]+|[" \r]+$/,"",h); if (h==col) c=i }
            if (!c) exit 2; next }
    { v=$c; gsub(/^[" \r]+|[" \r]+$/,"",v); if (v!="") print v }
  ' "$csv")
  if (( $? == 2 )); then
    print -ru2 -- "SOURCE_INVALID: column '${column}' not found in ${csv}"
    return 6
  fi
  local -a logins out
  local u
  typeset -A seen
  logins=("${(@f)raw}")
  out=()
  for u in "${logins[@]}"; do
    [[ -z "$u" ]] && continue
    if [[ -n "${seen[$u]:-}" ]]; then
      print -ru2 -- "ghw: duplicate login in source deduped: ${u}"
      continue
    fi
    seen[$u]=1
    out+=("$u")
  done
  if (( ${#out} == 0 )); then
    print -ru2 -- "SOURCE_INVALID: no logins parsed from ${csv} column '${column}'"
    return 6
  fi
  print -rl -- "${out[@]}"
}
