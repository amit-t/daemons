#!/usr/bin/env zsh
# State machine: phase recording, resume, and the ordering guarantees the
# pipeline depends on.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common

dhm_test_state_sandbox || exit 1
trap 'rm -rf -- "$DHM_TEST_SANDBOX"' EXIT
# Guard the guard: if the sandbox did not take effect, the test would
# write into the operator's real state directory.
assert_contains "sandbox is in effect" "$(dhm_state_file demo)" "$DHM_TEST_SANDBOX"

# ---- initialisation ----------------------------------------------------------

assert_ok "state init" dhm_state_init demo /tmp/demo claude
assert_eq "state file exists" "1" "$([[ -s "$(dhm_state_file demo)" ]] && print 1 || print 0)"
assert_eq "state file is 0600" "600" \
  "$(command stat -f '%Lp' "$(dhm_state_file demo)" 2>/dev/null || command stat -c '%a' "$(dhm_state_file demo)")"
assert_eq "site recorded"  "demo"      "$(dhm_state_get demo '.site')"
assert_eq "repo recorded"  "/tmp/demo" "$(dhm_state_get demo '.repo')"
assert_eq "agent recorded" "claude"    "$(dhm_state_get demo '.agent')"

# Re-initialising must not clobber an in-flight migration.
dhm_fact_set demo slug keep-me
dhm_state_init demo /tmp/demo codex
assert_eq "re-init preserves facts" "keep-me" "$(dhm_fact_get demo slug)"

# ---- facts -------------------------------------------------------------------

dhm_fact_set demo domain example.com
assert_eq "fact round-trip" "example.com" "$(dhm_fact_get demo domain)"
assert_eq "missing fact is empty" "" "$(dhm_fact_get demo nonexistent)"

# Values with spaces and slashes must survive.
dhm_fact_set demo backup_dir "/tmp/some path/backups-2026"
assert_eq "fact with spaces" "/tmp/some path/backups-2026" "$(dhm_fact_get demo backup_dir)"

# ---- phases ------------------------------------------------------------------

assert_eq "unknown phase is pending" "pending" "$(dhm_phase_status demo preflight)"
dhm_phase_mark demo preflight done
assert_eq "phase marked done" "done" "$(dhm_phase_status demo preflight)"
assert_ok "is_done true" dhm_phase_is_done demo preflight

dhm_phase_mark demo backup failed
assert_eq "phase marked failed" "failed" "$(dhm_phase_status demo backup)"
assert_fails "is_done false for failed" dhm_phase_is_done demo backup

# A timestamp must be recorded, so a stalled migration can be diagnosed.
assert_ne "phase has a timestamp" "" "$(dhm_state_get demo '.phases.preflight.at')"

# ---- state edits are atomic and never corrupt the document -------------------

local before after
before=$(jq -c '.' "$(dhm_state_file demo)")
dhm_state_edit demo '.facts.extra = "x"'
after=$(jq -c '.' "$(dhm_state_file demo)")
assert_ne "edit changed the document" "$before" "$after"
assert_ok "document is still valid JSON" jq -e '.' "$(dhm_state_file demo)"

# A failing jq expression must leave the original intact rather than truncating it.
dhm_state_edit demo '.broken | error("boom")' 2>/dev/null
assert_ok "document survived a failed edit" jq -e '.site == "demo"' "$(dhm_state_file demo)"

# ---- unknown site ------------------------------------------------------------

assert_fails "edit on unknown site fails" dhm_state_edit nosuchsite '.x = 1'
assert_fails "get on unknown site fails"  dhm_state_get nosuchsite '.site'

# ---- helpers -----------------------------------------------------------------

assert_eq "slugify" "my-cool-site" "$(dhm_slugify 'My Cool  Site!')"
assert_eq "slugify trims" "abc" "$(dhm_slugify '  --abc--  ')"

assert_ok    "valid slug"        dhm_is_valid_slug urban-finch-9va5
assert_fails "slug with capital" dhm_is_valid_slug Urban-Finch
assert_fails "slug with dot"     dhm_is_valid_slug urban.finch
assert_fails "slug leading dash" dhm_is_valid_slug -urban

assert_ok    "valid domain"      dhm_is_valid_domain amittiwari.in
assert_ok    "valid subdomain"   dhm_is_valid_domain blog.example.co.uk
assert_fails "bare label"        dhm_is_valid_domain localhost
assert_fails "url is not domain" dhm_is_valid_domain https://example.com

# ---- redaction ---------------------------------------------------------------
# Anything that reaches a log must not carry a live credential.

local redacted
redacted=$(print -r -- 'mongodb+srv://user:s3cr3t@host/db' | dhm_redact)
assert_not_contains "mongo password redacted" "$redacted" "s3cr3t"
assert_contains     "mongo host kept"         "$redacted" "host/db"

redacted=$(print -r -- 'postgresql://u:pw123@pg.example.com:5432/app' | dhm_redact)
assert_not_contains "postgres password redacted" "$redacted" "pw123"

redacted=$(print -r -- 'Authorization: Bearer abc123XYZ_token' | dhm_redact)
assert_not_contains "bearer redacted" "$redacted" "abc123XYZ_token"

redacted=$(print -r -- 'token dop_v1_abcdef0123 and ghp_ABCDEF012345' | dhm_redact)
assert_not_contains "DO token redacted" "$redacted" "dop_v1_abcdef0123"
assert_not_contains "gh token redacted" "$redacted" "ghp_ABCDEF012345"

report
