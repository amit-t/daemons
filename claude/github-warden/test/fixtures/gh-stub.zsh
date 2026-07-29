#!/usr/bin/env zsh
# Fake gh for ghw auth tests. Understands: auth token --user <login>
# Logs the full invocation (one line per call) to $GHW_GH_STUB_LOG when set,
# so tests can assert exactly what args ghw passed (e.g. --user <login>).
# Prints $GHW_GH_STUB_TOKEN (empty by default) for `auth token`, exit 0.
# Anything else exits 1 with no output — mirrors a real `gh` failure mode
# closely enough for ghw_token_for's non-empty-output check.
set -u
[[ -n "${GHW_GH_STUB_LOG:-}" ]] && print -r -- "$*" >> "$GHW_GH_STUB_LOG"
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  print -rn -- "${GHW_GH_STUB_TOKEN:-}"
  exit 0
fi
exit 1
