#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
source "${script_dir}/../lib/key-resolve.zsh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Fake `security` that succeeds, echoing the requested service name.
mkdir -p "${tmpdir}/security-hit"
cat > "${tmpdir}/security-hit/security" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == *"find-generic-password"* ]]; then
  svc=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "-s" ]] && svc="$a"
    prev="$a"
  done
  print -r -- "keychain:${svc}"
  exit 0
fi
exit 1
EOF
chmod +x "${tmpdir}/security-hit/security"

# Fake `security` that fails (item not found).
mkdir -p "${tmpdir}/security-miss"
cat > "${tmpdir}/security-miss/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/security-miss/security"

# --- Windsurf service key ---

# 1. Keychain hit wins even when env var is set; default service name used.
out=$(PATH="${tmpdir}/security-hit:$PATH" DEVIN_SERVICE_KEY="key-from-env" dag_resolve_service_key)
assert_eq "ws keychain wins" "keychain:devin-service-key" "$out"

# 2. Keychain miss falls back to env var.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="key-from-env" dag_resolve_service_key)
assert_eq "ws env fallback" "key-from-env" "$out"

# 3. Both missing -> non-zero return, empty output.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="" dag_resolve_service_key); rc=$?
assert_exit "ws both missing rc" 1 $rc
assert_eq "ws both missing out" "" "$out"

# --- Devin v3 cog key ---

# 4. Keychain hit on its own default service name.
out=$(PATH="${tmpdir}/security-hit:$PATH" DEVIN_COG_KEY="cog-from-env" dag_resolve_cog_key)
assert_eq "cog keychain wins" "keychain:devin-cog-key" "$out"

# 5. Keychain miss falls back to DEVIN_COG_KEY.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_COG_KEY="cog-from-env" dag_resolve_cog_key)
assert_eq "cog env fallback" "cog-from-env" "$out"

# 6. Both missing -> non-zero return, empty output.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_COG_KEY="" dag_resolve_cog_key); rc=$?
assert_exit "cog both missing rc" 1 $rc
assert_eq "cog both missing out" "" "$out"

# 7. Custom keychain service name override.
out=$(PATH="${tmpdir}/security-hit:$PATH" DAG_COG_KEYCHAIN_SERVICE="my-cog" dag_resolve_cog_key)
assert_eq "cog custom service" "keychain:my-cog" "$out"

# 8. Cog resolution ignores the Windsurf env var and vice versa.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="ws-key" DEVIN_COG_KEY="" dag_resolve_cog_key); rc=$?
assert_exit "cog ignores ws env" 1 $rc

report
