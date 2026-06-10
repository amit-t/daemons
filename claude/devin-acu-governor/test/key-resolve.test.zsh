#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
source "${script_dir}/../lib/key-resolve.zsh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Fake `security` that succeeds.
mkdir -p "${tmpdir}/security-hit"
cat > "${tmpdir}/security-hit/security" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == *"find-generic-password"* ]]; then
  print -r -- "key-from-keychain"
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

# 1. Keychain hit wins even when env var is set.
out=$(PATH="${tmpdir}/security-hit:$PATH" DEVIN_SERVICE_KEY="key-from-env" dve_resolve_service_key)
assert_eq "keychain wins" "key-from-keychain" "$out"

# 2. Keychain miss falls back to env var.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="key-from-env" dve_resolve_service_key)
assert_eq "env fallback" "key-from-env" "$out"

# 3. Both missing -> non-zero return, empty output.
out=$(PATH="${tmpdir}/security-miss:$PATH" DEVIN_SERVICE_KEY="" dve_resolve_service_key); rc=$?
assert_exit "both missing rc" 1 $rc
assert_eq "both missing out" "" "$out"

report
