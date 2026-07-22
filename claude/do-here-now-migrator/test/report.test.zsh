#!/usr/bin/env zsh
# Migration report must distinguish resources that are still rollback-capable
# from resources that were actually destroyed.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common report

dhm_test_state_sandbox || exit 1
typeset -g DHM_TEST_REPO
DHM_TEST_REPO=$(mktemp -d) || exit 1
trap 'rm -rf -- "$DHM_TEST_SANDBOX" "$DHM_TEST_REPO"' EXIT

dhm_state_init demo "$DHM_TEST_REPO" claude
dhm_fact_set demo domain example.com
dhm_fact_set demo slug example-site
dhm_fact_set demo database_backup_dir /tmp/backups/tt-pg-final

inventory=$(jq -n '{
  claimed: {
    apps: [{name: "example-app", id: "app-123"}],
    databases: []
  },
  untouched: {apps: [], databases: []}
}')

dhm_report_write_doc demo "$DHM_TEST_REPO" "$inventory" >/dev/null
pending=$(<"$DHM_TEST_REPO/docs/migration-to-here-now.md")
assert_contains "pending report labels app pending" "$pending" \
  "## Pending DigitalOcean decommission"
assert_contains "pending report says app remains active" "$pending" \
  "remains active"
assert_not_contains "pending report does not claim destruction" "$pending" \
  "## Destroyed on DigitalOcean"

dhm_phase_mark demo decommission done
dhm_report_write_doc demo "$DHM_TEST_REPO" "$inventory" >/dev/null
destroyed=$(<"$DHM_TEST_REPO/docs/migration-to-here-now.md")
assert_contains "completed report labels app destroyed" "$destroyed" \
  "## Destroyed on DigitalOcean"
assert_not_contains "completed report has no pending heading" "$destroyed" \
  "## Pending DigitalOcean decommission"

# An explicitly-attributed standalone database must remain visible even when
# no App Platform app owns it. Record the exact final backup, not only the
# migration's broad backup root.
db_only_inventory=$(jq -n '{
  claimed: {
    apps: [],
    databases: [{name: "tt-pg", id: "db-123", engine: "pg"}]
  },
  untouched: {apps: [], databases: []}
}')
dhm_report_write_doc demo "$DHM_TEST_REPO" "$db_only_inventory" >/dev/null
database_report=$(<"$DHM_TEST_REPO/docs/migration-to-here-now.md")
assert_contains "standalone database appears in destroyed table" "$database_report" \
  '| `tt-pg` | managed pg | `db-123` |'
assert_contains "final database backup path is recorded" "$database_report" \
  '/tmp/backups/tt-pg-final'
assert_contains "portable PostgreSQL archive glob is documented" "$database_report" \
  '*.pgcustom'
assert_contains "destroyed database rollback names database" "$database_report" \
  'DigitalOcean database has been destroyed'
assert_not_contains "destroyed database rollback does not invent origin" "$database_report" \
  'DigitalOcean origin has been destroyed'

dhm_phase_mark demo decommission pending
dhm_report_write_doc demo "$DHM_TEST_REPO" "$db_only_inventory" >/dev/null
pending_database_report=$(<"$DHM_TEST_REPO/docs/migration-to-here-now.md")
assert_contains "pending database rollback names database" "$pending_database_report" \
  'DigitalOcean database remains available'
assert_not_contains "pending database rollback does not invent app" "$pending_database_report" \
  'DigitalOcean app remains available'

report
