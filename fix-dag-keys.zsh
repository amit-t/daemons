#!/usr/bin/env zsh
# ONE-SHOT: repair dag keys on another Mac, verify with `dag doctor`, then delete
# this file from the repo (git rm + commit + push). Contains no secrets.
#
# For each key (Devin cog_ key required, Windsurf service key optional):
#   1. current keychain item valid? keep it.
#   2. else scan the login keychain for devin/cog/dag/windsurf/codeium items,
#      probe each value live, install the first that authenticates.
#   3. else take it from the clipboard (Universal Clipboard from the source Mac),
#      then clear the clipboard.
#   4. else hidden paste prompt.
# Stale items under the dag service name are replaced; nothing else is touched.
#
# Source Mac, before running this here (Universal Clipboard carries it over):
#   security find-generic-password -s devin-cog-key -w | pbcopy
#
# Run:  zsh fix-dag-keys.zsh
# Env:  DAG_FIX_NO_DESTROY=1  keep this file after success (testing)
#       DAG_FIX_NO_PROMPT=1   never prompt (non-interactive)

emulate -L zsh
setopt pipe_fail no_unset

script_path=${0:A}
repo_dir=${script_path:h}
dag_bin="${repo_dir}/claude/devin-acu-governor/bin/dag"
v3base="${DAG_API_BASE_V3:-https://api.devin.ai}"
wsbase="${DAG_API_BASE:-https://server.codeium.com}"
cog_service="${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key}"
ws_service="${DAG_KEYCHAIN_SERVICE:-devin-service-key}"

say()  { print -r -- "fix-dag-keys: $*" }
warn() { print -ru2 -- "fix-dag-keys: $*" }

for c in security curl jq git; do
  (( $+commands[$c] )) || { warn "missing command: $c"; exit 1 }
done
[[ -f "$dag_bin" ]] || { warn "dag not found at $dag_bin — run from the daemons repo checkout"; exit 1 }

# Probes pass the key through curl's stdin config, never argv.
probe_cog() {  # <key> -> HTTP code of GET consumption/cycles
  local k=$1
  curl -sS -o /dev/null -w '%{http_code}' -K - "${v3base}/v3/enterprise/consumption/cycles" 2>/dev/null \
    <<< "header = \"Authorization: Bearer ${k}\"" || print -rn -- 000
}

probe_ws() {  # <key> -> HTTP code of POST UserPageAnalytics
  local k=$1 body
  body=$(jq -cn --arg k "$k" '{service_key: $k}')
  curl -sS -o /dev/null -w '%{http_code}' -X POST -K - "${wsbase}/api/v1/UserPageAnalytics" 2>/dev/null \
    <<< "header = \"Content-Type: application/json\"
data = $(jq -Rn --arg b "$body" '$b')" || print -rn -- 000
}

kc_get() { security find-generic-password -s "$1" ${2:+-a "$2"} -w 2>/dev/null }

# Candidate "service<TAB>account" pairs from the login keychain, name-filtered.
kc_candidates() {
  security dump-keychain 2>/dev/null | awk '
    /^keychain: / { if (svc != "") print svc "\t" acct; svc=""; acct="" }
    /"acct"<blob>="/ { s=$0; sub(/.*"acct"<blob>="/, "", s); sub(/"$/, "", s); acct=s }
    /"svce"<blob>="/ { s=$0; sub(/.*"svce"<blob>="/, "", s); sub(/"$/, "", s); svc=s }
    END { if (svc != "") print svc "\t" acct }
  ' | grep -Ei 'devin|cog|dag|windsurf|codeium' | grep -vi 'safe storage' | sort -u
}

install_key() {  # <service> <key>
  local svc=$1 key=$2 n=0
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do
    (( ++n > 20 )) && break
  done
  security add-generic-password -U -s "$svc" -a "$USER" -w "$key" >/dev/null
}

# resolve <label> <service> <probe-fn> <prefix-regex> -> 0 when a valid key sits in <service>
resolve() {
  local label=$1 svc=$2 probe=$3 shape=$4
  local cur code line csvc cacct val
  typeset -A seen

  cur=$(kc_get "$svc")
  if [[ -n "$cur" ]]; then
    code=$($probe "$cur")
    if [[ $code == 200 ]]; then say "$label: keychain item '$svc' valid [200] — kept"; return 0; fi
    say "$label: keychain item '$svc' rejected [$code] — searching for a valid key"
    seen[$cur]=1
  else
    say "$label: keychain item '$svc' absent — searching for a valid key"
  fi

  for line in ${(f)"$(kc_candidates)"}; do
    csvc=${line%%$'\t'*}; cacct=${line#*$'\t'}
    val=$(kc_get "$csvc" "$cacct") || continue
    [[ -n "$val" && "$val" =~ $shape && -z "${seen[$val]:-}" ]] || continue
    seen[$val]=1
    code=$($probe "$val")
    say "$label: candidate '$csvc' (acct '$cacct') [$code]"
    if [[ $code == 200 ]]; then
      install_key "$svc" "$val" && { say "$label: installed from '$csvc' into '$svc'"; return 0 }
    fi
  done

  if (( $+commands[pbpaste] )); then
    val=$(pbpaste 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$val" && "$val" =~ $shape && -z "${seen[$val]:-}" ]]; then
      code=$($probe "$val")
      say "$label: clipboard candidate [$code]"
      if [[ $code == 200 ]]; then
        install_key "$svc" "$val" && { print -n | pbcopy; say "$label: installed from clipboard into '$svc' (clipboard cleared)"; return 0 }
      fi
    fi
  fi

  if [[ -z "${DAG_FIX_NO_PROMPT:-}" && -t 0 ]]; then
    print -rn -- "fix-dag-keys: paste $label (hidden, Enter to skip): "
    read -rs val; print
    val=${val//[[:space:]]/}
    if [[ -n "$val" ]]; then
      code=$($probe "$val")
      say "$label: pasted key [$code]"
      if [[ $code == 200 ]]; then
        install_key "$svc" "$val" && { say "$label: installed from paste into '$svc'"; return 0 }
      fi
    fi
  fi
  return 1
}

say "repairing dag keys (cog_ service '$cog_service', Windsurf service '$ws_service')"
if ! resolve "Devin cog_ key" "$cog_service" probe_cog '^cog_[A-Za-z0-9_-]+$'; then
  warn "no valid Devin cog_ key found. On the source Mac run:"
  warn "  security find-generic-password -s devin-cog-key -w | pbcopy"
  warn "then rerun: zsh ${script_path}"
  exit 1
fi
resolve "Windsurf service key" "$ws_service" probe_ws '^[A-Za-z0-9_-]{16,}$' \
  || warn "no valid Windsurf service key found (optional — per-model/IDE analytics degraded)"

[[ -n "${DEVIN_COG_KEY:-}" ]] && say "note: DEVIN_COG_KEY is set in env; keychain wins, env is only a fallback"

print
zsh "$dag_bin" doctor
rc=$?
print
if (( rc != 0 )); then
  warn "dag doctor exit $rc — keeping ${script_path:t} for a rerun"
  exit $rc
fi

if [[ -n "${DAG_FIX_NO_DESTROY:-}" ]]; then
  say "success; DAG_FIX_NO_DESTROY set — ${script_path:t} kept"
  exit 0
fi

# Self-destruct: remove from the repo and push, committing only this path.
rel=${script_path#${repo_dir}/}
if git -C "$repo_dir" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
  local_email=$(git -C "$repo_dir" config user.email || true)
  typeset -a idc
  if git -C "$repo_dir" remote -v | grep -q 'github.com[:/]amit-t/' && [[ "$local_email" != tiwari.m.amit@gmail.com ]]; then
    idc=(-c user.email=tiwari.m.amit@gmail.com)
    say "using personal identity tiwari.m.amit@gmail.com for the removal commit (repo user.email was '${local_email}')"
  fi
  git -C "$repo_dir" rm -q -- "$rel" \
    && git -C "$repo_dir" $idc commit -q -m "chore: remove one-shot dag key repair script" -- "$rel" \
    || { warn "git rm/commit failed — delete ${rel} manually"; exit 1 }
  if git -C "$repo_dir" push -q 2>/dev/null \
     || { git -C "$repo_dir" pull -q --rebase --autostash && git -C "$repo_dir" push -q }; then
    say "done — ${rel} removed, committed, pushed"
  else
    warn "removal committed locally but push failed — run: git -C ${repo_dir} push"
  fi
else
  rm -f -- "$script_path"
  say "done — ${script_path:t} deleted (untracked)"
fi
