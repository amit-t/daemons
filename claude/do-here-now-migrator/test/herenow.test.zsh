#!/usr/bin/env zsh
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common herenow

# Live custom-domain state exposes root mounts on GET /api/v1/domains/:domain.
# The legacy links readback can return `No handle found` even after POST /links
# created the mount successfully.
local fake_bin curl_args curl_response old_path slug family_status
fake_bin=$(mktemp -d)
curl_args="${fake_bin}/args"
curl_response="${fake_bin}/response.json"
old_path=$PATH
cat > "${fake_bin}/curl" <<'ZSH'
#!/usr/bin/env zsh
print -r -- "$@" >> "$DHM_TEST_CURL_ARGS"
local url arg
for arg in "$@"; do [[ "$arg" == https://* ]] && url=$arg; done
if jq -e '.domains' "$DHM_TEST_CURL_RESPONSE" >/dev/null 2>&1 \
    && [[ "$url" != */api/v1/domains ]]; then
  jq -c --arg domain "${url:t}" '.domains[] | select(.domain == $domain)' \
    "$DHM_TEST_CURL_RESPONSE"
else
  cat "$DHM_TEST_CURL_RESPONSE"
fi
ZSH
chmod +x "${fake_bin}/curl"
export DHM_TEST_CURL_ARGS=$curl_args
export DHM_TEST_CURL_RESPONSE=$curl_response
PATH="${fake_bin}:$PATH"
dhm_hn_key() { print -r -- test-key }

: > "$curl_args"
print -r -- '{"domain":"example.com","mounts":[{"mount_path":"","slug":"expected-site"}]}' \
  > "$curl_response"
slug=$(dhm_hn_root_link_slug example.com)
assert_eq "root mount slug comes from domain state" expected-site "$slug"
assert_contains "root mount readback uses domain endpoint" "$(<$curl_args)" \
  "/api/v1/domains/example.com"

# An apex domain is not ready until its automatically-paired www domain is
# active too. Otherwise the production verification races www TLS issuance.
print -r -- '{"domains":[{"domain":"example.com","status":"active","is_apex":true},{"domain":"www.example.com","status":"pending","is_apex":false}]}' \
  > "$curl_response"
family_status=$(dhm_hn_domain_family_status example.com)
assert_eq "paired www keeps domain family pending" pending "$family_status"

print -r -- '{"domains":[{"domain":"example.com","status":"active","is_apex":true},{"domain":"www.example.com","status":"active","is_apex":false}]}' \
  > "$curl_response"
family_status=$(dhm_hn_domain_family_status example.com)
assert_eq "domain family activates together" active "$family_status"

print -r -- '{"domains":[{"domain":"example.com","status":"active","is_apex":true}]}' \
  > "$curl_response"
family_status=$(dhm_hn_domain_family_status example.com)
assert_eq "missing paired www keeps apex pending" pending "$family_status"

print -r -- '{"domains":[{"domain":"blog.example.com","status":"active","is_apex":false}]}' \
  > "$curl_response"
family_status=$(dhm_hn_domain_family_status blog.example.com)
assert_eq "active subdomain needs no www pair" active "$family_status"

# Readback must fail closed. An API error is not evidence that no mount exists,
# so bind must stop before issuing a POST that could repoint a live domain.
: > "$curl_args"
print -r -- '{"error":"Forbidden"}' > "$curl_response"
assert_fails "root mount API errors fail readback" \
  dhm_hn_root_link_slug example.com
assert_fails "bind aborts when root mount cannot be read" \
  dhm_hn_bind_root example.com replacement-site
assert_eq "failed readback does not issue mount POST" 2 \
  "$(wc -l < "$curl_args" | tr -d ' ')"

PATH=$old_path
unset DHM_TEST_CURL_ARGS DHM_TEST_CURL_RESPONSE
rm -rf -- "$fake_bin"

report
