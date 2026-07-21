#!/usr/bin/env zsh
# Resource attribution. Over-claiming here destroys someone else's project;
# under-claiming leaves the operator paying for a site they migrated away from.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common inventory

local apps mine other tt
apps=$(<"$(dhm_test_fixture do-apps.json)")
mine=$(jq -c '.[0]' <<<"$apps")   # amittiwari-me: matches repo and domains
tt=$(jq -c '.[1]' <<<"$apps")     # tiny-trauma:   unrelated project
other=$(jq -c '.[2]' <<<"$apps")  # static-site:   different repo, no domains

# ---- positive attribution ----------------------------------------------------

assert_eq "matched by repo" "repo" \
  "$(dhm_do_app_matches "$mine" "amit-t/amittiwari-me" "")"

# The repo may be unknown (no git remote); domains alone must still attribute.
assert_eq "matched by domain" "domain" \
  "$(dhm_do_app_matches "$mine" "" "amittiwari.me")"

# A www-only spec entry must still match the apex the operator named.
assert_eq "matched by www domain" "domain" \
  "$(dhm_do_app_matches "$other" "" "www-only.example")"

# Repo match takes precedence, so the reason is reported accurately.
assert_eq "repo wins over domain" "repo" \
  "$(dhm_do_app_matches "$mine" "amit-t/amittiwari-me" "amittiwari.me")"

# ---- negative attribution: the safety property -------------------------------

# An unrelated app must never be claimed, whichever way it is probed.
assert_fails "unrelated app not claimed by repo" \
  dhm_do_app_matches "$tt" "amit-t/amittiwari-me" "amittiwari.me"
assert_fails "unrelated app not claimed by domain" \
  dhm_do_app_matches "$tt" "" "amittiwari.me"
assert_fails "unrelated app not claimed with no criteria" \
  dhm_do_app_matches "$tt" "" ""

# A substring must not match. `amittiwari.me` is not `notamittiwari.me`, and
# `amit-t/amittiwari` is not `amit-t/amittiwari-me`.
assert_fails "domain substring does not match" \
  dhm_do_app_matches "$mine" "" "wari.me"
assert_fails "repo substring does not match" \
  dhm_do_app_matches "$mine" "amit-t/amittiwari" ""

# An empty repo and empty domain must claim nothing at all. This is the case
# where a misconfigured run could otherwise sweep up the whole account.
local a
for a in "$mine" "$tt" "$other"; do
  assert_fails "empty criteria claim nothing" dhm_do_app_matches "$a" "" ""
done

# ---- specs with no github block ----------------------------------------------

local nogit
nogit=$(jq -c '.[3]' <<<"$apps")  # image-based app, no git source at all
assert_fails "image-only app not claimed by repo" \
  dhm_do_app_matches "$nogit" "amit-t/amittiwari-me" ""
assert_eq "image-only app still claimed by its domain" "domain" \
  "$(dhm_do_app_matches "$nogit" "" "images.example")"

# ---- rendering ---------------------------------------------------------------

local inv rendered
inv=$(<"$(dhm_test_fixture inventory.json)")
rendered=$(dhm_inventory_render "$inv" 2>&1)
assert_contains "render shows destruction header" "$rendered" "WILL BE DESTROYED"
assert_contains "render shows retention header"   "$rendered" "LEFT ALONE"
assert_contains "render names the claimed app"    "$rendered" "amittiwari-me"
assert_contains "render names the claimed db"     "$rendered" "db-mongodb-amittiwar-me-blr"
assert_contains "render names the spared app"     "$rendered" "tiny-trauma"
assert_contains "render promises DNS is kept"     "$rendered" "DNS zones"

report
