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

report
