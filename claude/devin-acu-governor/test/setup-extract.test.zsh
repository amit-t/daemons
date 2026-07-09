#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

records="${tmpdir}/records.log"
: > "$records"

cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
cmd="${1:-}"
shift || true
svc="" acct="" key="" prev=""
for a in "$@"; do
  [[ "$prev" == "-s" ]] && svc="$a"
  [[ "$prev" == "-a" ]] && acct="$a"
  [[ "$prev" == "-w" ]] && key="$a"
  prev="$a"
done

case "$cmd" in
  find-generic-password)
    case "$svc" in
      devin-cog-key)     print -r -- "cog key with ' quote" ;;
      devin-service-key) print -r -- 'ws$key with spaces' ;;
      missing-cog)       exit 44 ;;
      missing-ws)        exit 44 ;;
      *)                 exit 44 ;;
    esac
    ;;
  add-generic-password)
    print -r -- "${svc}|${acct}|${key}" >> "${DAG_TEST_RECORDS}"
    ;;
esac
EOF
chmod +x "${tmpdir}/bin/security"

run_extract() {
  PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DEVIN_SERVICE_KEY="" zsh "$dag" setup-extract "$@"
}

# 1. Output is pasteable zsh that sets both expected keychain services.
out=$(run_extract 2>/dev/null); rc=$?
assert_exit "extract rc" 0 $rc
assert_contains "extract cog command" "$out" "security add-generic-password -U -s devin-cog-key -a \"\$USER\" -w 'cog key with '\\'' quote'"
assert_contains "extract ws command" "$out" "security add-generic-password -U -s devin-service-key -a \"\$USER\" -w 'ws\$key with spaces'"
assert_contains "extract verify hint" "$out" "dag doctor"

# 2. Generated commands preserve exact secrets when executed on a target machine.
PATH="${tmpdir}/bin:$PATH" USER=target-user DAG_TEST_RECORDS="$records" zsh -c "$out"
assert_contains "execute cog record" "$(<"$records")" "devin-cog-key|target-user|cog key with ' quote"
assert_contains "execute ws record" "$(<"$records")" 'devin-service-key|target-user|ws$key with spaces'

# 3. Missing source key exits non-zero and prints no setup command.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_COG_KEYCHAIN_SERVICE=missing-cog DEVIN_COG_KEY="" DEVIN_SERVICE_KEY="" zsh "$dag" setup-extract 2>&1); rc=$?
assert_exit "missing cog rc" 1 $rc
assert_contains "missing cog message" "$out" "missing Devin API v3 key"
if [[ "$out" == *"add-generic-password"* ]]; then _fail "missing cog should not print partial setup commands"; else _ok; fi

# 4. Help advertises setup-extract.
out=$(PATH="${tmpdir}/bin:$PATH" zsh "$dag" help 2>&1)
assert_contains "help setup-extract" "$out" "dag setup-extract"

# 5. Args are rejected so accidental junk never changes output shape.
out=$(run_extract extra 2>&1); rc=$?
assert_exit "extra arg rc" 2 $rc
assert_contains "extra arg message" "$out" "no arguments expected"

report
