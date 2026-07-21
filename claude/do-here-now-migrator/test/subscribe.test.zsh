#!/usr/bin/env zsh
# Subscribe provider resolution. Substack is a default suggestion, never an
# assumption: `none` must be a first-class outcome, and no provider API is ever
# contacted.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common subscribe

# ---- provider registry -------------------------------------------------------

local p
for p in substack buttondown convertkit mailchimp beehiiv ghost custom none; do
  assert_ok "${p} is a provider" dhm_subscribe_is_provider "$p"
done
assert_fails "tinyletter is not a known provider" dhm_subscribe_is_provider tinyletter
assert_fails "empty is not a provider"            dhm_subscribe_is_provider ""

# ---- URL derivation from a handle -------------------------------------------

assert_eq "substack handle"   "https://myblog.substack.com/subscribe" \
  "$(dhm_subscribe_url_for_handle substack myblog)"
assert_eq "buttondown handle" "https://buttondown.com/myblog" \
  "$(dhm_subscribe_url_for_handle buttondown myblog)"
assert_eq "beehiiv handle"    "https://myblog.beehiiv.com/subscribe" \
  "$(dhm_subscribe_url_for_handle beehiiv myblog)"
assert_fails "custom has no derivable URL" dhm_subscribe_url_for_handle custom myblog
assert_fails "empty handle rejected"       dhm_subscribe_url_for_handle substack ""

# ---- resolution --------------------------------------------------------------

# `none` short-circuits: no URL, no probe, no network.
local result
result=$(dhm_subscribe_resolve none "" "")
assert_eq "none provider"  "none" "$(jq -r '.provider' <<<"$result")"
assert_eq "none has no url" "null" "$(jq -r '.url' <<<"$result")"

# An unknown provider is rejected before anything else happens.
assert_fails "unknown provider rejected" dhm_subscribe_resolve mailerlite "https://x.example" ""

# A non-https URL is rejected. A subscribe link is a place users type an email
# address into, so plaintext is not acceptable.
DHM_SKIP_SUBSCRIBE_PROBE=1
assert_fails "http rejected" dhm_subscribe_resolve substack "http://example.com/subscribe" ""

# With the probe skipped, a valid https URL resolves and is marked unverified.
result=$(dhm_subscribe_resolve substack "https://example.substack.com/subscribe" "")
assert_eq "provider recorded" "substack" "$(jq -r '.provider' <<<"$result")"
assert_eq "url recorded" "https://example.substack.com/subscribe" "$(jq -r '.url' <<<"$result")"
assert_eq "skipped probe is not verified" "false" "$(jq -r '.verified' <<<"$result")"
assert_eq "status records the skip" "skipped" "$(jq -r '.status' <<<"$result")"

# A handle is enough; the URL is derived.
result=$(dhm_subscribe_resolve beehiiv "" "myblog")
assert_eq "derived from handle" "https://myblog.beehiiv.com/subscribe" "$(jq -r '.url' <<<"$result")"
unset DHM_SKIP_SUBSCRIBE_PROBE

# ---- non-interactive behaviour -----------------------------------------------

# With no provider, no terminal, and no way to ask, the answer must be `none`.
# Guessing a subscribe URL and shipping it as a button would be worse than
# shipping no button at all.
result=$(dhm_subscribe_resolve "" "" "" </dev/null 2>/dev/null)
assert_eq "non-interactive defaults to none" "none" "$(jq -r '.provider' <<<"$result")"

# A provider with no URL and no handle cannot be resolved unattended.
local rc
dhm_subscribe_resolve substack "" "" </dev/null >/dev/null 2>&1; rc=$?
assert_ne "provider without url fails unattended" 0 "$rc"

report
