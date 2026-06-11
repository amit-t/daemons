#!/usr/bin/env zsh
# dag usage — local read-only per-user consumed-vs-cap report.
# Drives bin/dag with a stubbed curl so the whole fetch/paginate/encode/compute
# path runs offline. Asserts ratios, precedence, pagination, URL-encoding, flags,
# read-only behavior, and key non-leakage.
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

# Fake security: always miss, so DEVIN_COG_KEY drives key resolution.
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

# Stub curl. Routes by URL; records any write verb to $DAG_TEST_WRITES.
# Output mirrors real curl with -w $'\n%{http_code}': body, newline, code.
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env zsh
url="" prev=""
for a in "$@"; do
  [[ "$prev" == "-X" && "$a" != GET ]] && print -r -- "$a" >> "${DAG_TEST_WRITES:-/dev/null}"
  [[ "$a" == http* ]] && url=$a
  prev=$a
done
body='{}' code=404
case "$url" in
  *consumption/cycles*)
    body='{"items":[{"after":0,"before":500000}]}'; code=200 ;;
  *users/consumption/acu-limits*)              # default per-user cap
    body='{"local_agent":{"cycle_acu_limit":300}}'; code=200 ;;
  *members/idp-users*)
    body='{"items":[
      {"user_id":"u1","email":"a@x.io","name":"A","idp_role_assignments":[{"idp_group_name":"Core Eng","org_id":"org-alpha","role":{"role_name":"Engineer"}}]},
      {"user_id":"okta|u3","email":"c@x.io","name":"C","idp_role_assignments":[{"idp_group_name":"Core Eng","org_id":"org-beta","role":{"role_name":"Engineer"}}]},
      {"user_id":"u2","email":"b@x.io","name":"B","idp_role_assignments":[{"idp_group_name":"Other Eng","org_id":"org-gamma","role":{"role_name":"Engineer"}}]}
    ],"has_next_page":false,"total":3}'; code=200 ;;
  *members/users*)
    if [[ "$url" == *after=CUR1* ]]; then
      body='{"items":[{"user_id":"u2","email":"b@x.io","name":"B"}],"has_next_page":false}'; code=200
    else
      body='{"items":[{"user_id":"u1","email":"a@x.io","name":"A"},{"user_id":"okta|u3","email":"c@x.io","name":"C"}],"has_next_page":true,"end_cursor":"CUR1"}'; code=200
    fi ;;
  *consumption/daily/users/*)
    case "$url" in
      *daily/users/u1*)          body='{"total_acus":350,"consumption_by_date":[{"date":0,"acus":200,"acus_by_product":{"devin":100,"cascade":50,"terminal":30,"review":20}},{"date":172800,"acus":60,"acus_by_product":{"devin":20,"cascade":20,"terminal":10,"review":10}},{"date":259200,"acus":90,"acus_by_product":{"devin":50,"cascade":20,"terminal":10,"review":10}}]}'; code=200 ;;
      *daily/users/okta%7Cu3*)   body='{"total_acus":50,"consumption_by_date":[{"date":0,"acus":20,"acus_by_product":{"devin":5,"cascade":5,"terminal":5,"review":5}},{"date":259200,"acus":30,"acus_by_product":{"devin":10,"cascade":10,"terminal":5,"review":5}}]}';  code=200 ;;
      *daily/users/u2*)          body='{"total_acus":120,"consumption_by_date":[{"date":259200,"acus":120,"acus_by_product":{"devin":100,"cascade":10,"terminal":5,"review":5}}]}'; code=200 ;;
      *)                         body='{"total_acus":0}';   code=200 ;;
    esac ;;
  *enterprise/users/*/consumption/acu-limits*) # per-user override
    case "$url" in
      *users/u2/consumption/acu-limits*) body='{"local_agent":{"cycle_acu_limit":500}}'; code=200 ;;
      *)                                 body='{}'; code=404 ;;   # no override -> inherit default
    esac ;;
esac
printf '%s\n%s' "$body" "$code"
EOF
chmod +x "${tmpdir}/bin/curl"

writes="${tmpdir}/writes.log"; : > "$writes"
run_usage() {
  PATH="${tmpdir}/bin:$PATH" DAG_TEST_WRITES="$writes" \
    DEVIN_COG_KEY=test-cog-key DAG_NOW_EPOCH=345600 \
    zsh "$dag" usage "$@"
}

# 1. Default table run.
out=$(run_usage 2>/dev/null); rc=$?
assert_exit "usage rc" 0 $rc
assert_contains "usage header" "$out" "per-user consumed vs Local Agent cap"
assert_contains "usage default cap line" "$out" "default per-user Local Agent cap: 300"
assert_contains "usage user a" "$out" "a@x.io"
assert_contains "usage user b (page 2)" "$out" "b@x.io"      # pagination via after=CUR1
assert_contains "usage user c" "$out" "c@x.io"
assert_contains "usage over state" "$out" "OVER"
# a: 350/300 = 116.7% (override 404 -> inherits default 300)
assert_contains "usage a ratio" "$out" "116.7"
# c: 50/300 = 16.7% via URL-encoded user_id okta%7Cu3
assert_contains "usage c ratio (uri-encoded id)" "$out" "16.7"
assert_contains "usage totals" "$out" "3 users"
assert_contains "usage ui instruction" "$out" "Enterprise Settings > Consumption"

# 2. Read-only: stub saw no write verb.
nwrites=$(wc -l < "$writes" | tr -d ' ')
assert_eq "usage no write verbs" 0 "$nwrites"

# 3. Key never leaks into output.
if [[ "$out" == *test-cog-key* ]]; then _fail "usage key leaked"; else _ok; fi

# 4. JSON mode -> structured, sorted, precedence correct.
js=$(run_usage --json 2>/dev/null); rc=$?
assert_exit "usage --json rc" 0 $rc
assert_eq "usage json row count" 3 "$(jq '.rows|length' <<<"$js")"
assert_eq "usage json top email" "a@x.io" "$(jq -r '.rows[0].email' <<<"$js")"
assert_eq "usage json top source (default inherited)" "default" "$(jq -r '.rows[0].source' <<<"$js")"
assert_eq "usage json top state" "OVER" "$(jq -r '.rows[0].state' <<<"$js")"
assert_eq "usage json b override precedence" "override" "$(jq -r '.rows[]|select(.email=="b@x.io").source' <<<"$js")"
assert_eq "usage json b cap" "500" "$(jq -r '.rows[]|select(.email=="b@x.io").cap' <<<"$js")"
assert_eq "usage json sum_caps" "1100" "$(jq -r '.totals.sum_caps' <<<"$js")"
assert_eq "usage json n_over" "1" "$(jq -r '.totals.n_over' <<<"$js")"

# 5. --top limits rows.
out=$(run_usage --top 1 2>/dev/null); rc=$?
assert_exit "usage --top rc" 0 $rc
assert_contains "usage --top keeps top" "$out" "a@x.io"
if [[ "$out" == *b@x.io* ]]; then _fail "usage --top should drop b@x.io"; else _ok; fi

# 6. Flag validation.
out=$(run_usage --top 0 2>&1); rc=$?; assert_exit "usage --top 0" 2 $rc
out=$(run_usage --top abc 2>&1); rc=$?; assert_exit "usage --top non-int" 2 $rc
out=$(run_usage --bogus 2>&1); rc=$?; assert_exit "usage bad flag" 2 $rc
assert_contains "usage bad flag msg" "$out" "unknown flag"

# 6b. IDP group mode prompts when no group is supplied, then filters to that group
# and adds detailed current-cycle + last-3-days status columns.
out=$(print -r -- "Core Eng" | run_usage --group 2>/dev/null); rc=$?
assert_exit "usage --group prompt rc" 0 $rc
assert_contains "usage --group title" "$out" "IDP group: Core Eng"
assert_contains "usage --group last3 header" "$out" "LAST3"
assert_contains "usage --group a" "$out" "a@x.io"
assert_contains "usage --group c" "$out" "c@x.io"
if [[ "$out" == *b@x.io* ]]; then _fail "usage --group should exclude b@x.io"; else _ok; fi
assert_contains "usage --group a last3" "$out" "150"
assert_contains "usage --group totals" "$out" "Group totals: 2 users"
assert_contains "usage --group product mix" "$out" "last3 product mix"

# 6c. IDP group mode accepts unquoted multi-word names before later flags.
js=$(run_usage --group Core Eng --json 2>/dev/null); rc=$?
assert_exit "usage --group json rc" 0 $rc
assert_eq "usage --group json name" "Core Eng" "$(jq -r '.group.name' <<<"$js")"
assert_eq "usage --group json row count" 2 "$(jq '.rows|length' <<<"$js")"
assert_eq "usage --group json total last3" "180" "$(jq -r '.totals.last3_acus' <<<"$js")"
assert_eq "usage --group json a last3" "150" "$(jq -r '.rows[]|select(.email=="a@x.io").last3_acus' <<<"$js")"

# 6d. Alternate compact command spelling is accepted.
out=$(PATH="${tmpdir}/bin:$PATH" DAG_TEST_WRITES="$writes" \
  DEVIN_COG_KEY=test-cog-key DAG_NOW_EPOCH=345600 zsh "$dag" usage--group Core Eng 2>/dev/null); rc=$?
assert_exit "usage--group alias rc" 0 $rc
assert_contains "usage--group alias title" "$out" "IDP group: Core Eng"
nwrites=$(wc -l < "$writes" | tr -d ' ')
assert_eq "usage --group no write verbs" 0 "$nwrites"

# 6e. Missing group fails with known group guidance.
out=$(run_usage --group Missing Group 2>&1); rc=$?
assert_exit "usage --group missing rc" 1 $rc
assert_contains "usage --group missing msg" "$out" "no users found for IDP group 'Missing Group'"
assert_contains "usage --group missing candidates" "$out" "Core Eng"

# 7. Missing cog key -> exit 1 with setup hint.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DAG_NOW_EPOCH=1000 zsh "$dag" usage 2>&1); rc=$?
assert_exit "usage no key rc" 1 $rc
assert_contains "usage no key hint" "$out" "devin-cog-key"

# 8. help text advertises the command.
out=$(PATH="${tmpdir}/bin:$PATH" zsh "$dag" help 2>&1)
assert_contains "help lists usage" "$out" "dag usage"
assert_contains "help lists usage group" "$out" "dag usage --group"

report
