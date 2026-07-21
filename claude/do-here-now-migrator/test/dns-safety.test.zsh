#!/usr/bin/env zsh
# The safety-critical tests. If any of these regress, a migration can silently
# destroy the owner's email by deleting MX or DKIM records.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common dns

# ---- the allowlist predicate -------------------------------------------------

# Only A, AAAA, and CNAME may ever be touched.
assert_ok   "A is mutable"        dhm_dns_type_is_mutable A
assert_ok   "AAAA is mutable"     dhm_dns_type_is_mutable AAAA
assert_ok   "CNAME is mutable"    dhm_dns_type_is_mutable CNAME
assert_ok   "lowercase a"         dhm_dns_type_is_mutable a

local t
for t in MX TXT CAA SRV NS SOA DNSKEY PTR ALIAS; do
  assert_fails "${t} is immutable" dhm_dns_type_is_mutable "$t"
done

# Only the apex and www may ever be touched.
assert_ok    "apex is mutable"    dhm_dns_host_is_mutable '@'
assert_ok    "www is mutable"     dhm_dns_host_is_mutable www
assert_ok    "WWW case-folds"     dhm_dns_host_is_mutable WWW

local h
for h in api mail blog staging _dmarc _domainkey 'selector1._domainkey' '*'; do
  assert_fails "host ${h} is immutable" dhm_dns_host_is_mutable "$h"
done

# The combined predicate must require BOTH conditions.
assert_ok    "A @ mutable"          dhm_dns_record_is_mutable A '@'
assert_ok    "CNAME www mutable"    dhm_dns_record_is_mutable CNAME www
assert_fails "MX @ immutable"       dhm_dns_record_is_mutable MX '@'
assert_fails "TXT @ immutable"      dhm_dns_record_is_mutable TXT '@'
assert_fails "A api immutable"      dhm_dns_record_is_mutable A api
assert_fails "CNAME mail immutable" dhm_dns_record_is_mutable CNAME mail

# ---- classification of a real-shaped zone -----------------------------------

local zone classified replaceable preserved
zone=$(<"$(dhm_test_fixture zone-amittiwari-me.json)")
classified=$(dhm_dns_classify "$zone")
replaceable=$(jq -c '.replaceable' <<<"$classified")
preserved=$(jq -c '.preserved' <<<"$classified")

# The zone fixture holds 4 replaceable records (2 A, 2 AAAA at apex) plus a www
# CNAME, and everything else must be preserved.
assert_eq "replaceable count" 5 "$(jq 'length' <<<"$replaceable")"

# Every mail-critical record must land in `preserved`.
local kind
for kind in MX TXT CAA SRV NS SOA; do
  assert_ne "${kind} preserved" "" "$(jq -r --arg k "$kind" 'map(select(.type==$k)) | length | select(.>0)' <<<"$preserved")"
done

# Nothing preserved may be of a mutable type at a mutable host — that would
# mean the classifier let something through.
assert_eq "no mutable record hides in preserved" "0" \
  "$(jq '[.[] | select((.type|ascii_upcase) as $t | ["A","AAAA","CNAME"] | index($t))
          | select((.name|ascii_downcase) as $n | ["@","www"] | index($n))] | length' <<<"$preserved")"

# And nothing replaceable may be a record type we promised never to touch.
assert_eq "no immutable record leaked into replaceable" "0" \
  "$(jq '[.[] | select((.type|ascii_upcase) as $t | ["A","AAAA","CNAME"] | index($t) | not)] | length' <<<"$replaceable")"

# The specific record that broke email in the original migration.
assert_eq "zoho MX preserved" "3" \
  "$(jq '[.[] | select(.type=="MX" and (.data|test("zoho")))] | length' <<<"$preserved")"

# ---- refusal to apply an empty instruction set -------------------------------
# Deleting records and putting nothing back must be impossible.
DHM_DRY_RUN=1
local out rc
out=$(dhm_dns_apply example.invalid '[]' 600 2>&1); rc=$?
assert_ne "empty instructions rejected" 0 "$rc"
assert_contains "empty instruction message" "$out" "refusing to delete"

report
