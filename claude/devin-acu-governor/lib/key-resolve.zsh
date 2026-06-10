#!/usr/bin/env zsh
# Resolve the Devin service key.
# Order: macOS Keychain item (DVE_KEYCHAIN_SERVICE, default devin-service-key),
# then $DEVIN_SERVICE_KEY. Prints the key on stdout; returns 1 if neither is set.

dve_resolve_service_key() {
  local service="${DVE_KEYCHAIN_SERVICE:-devin-service-key}"
  local key
  if key=$(security find-generic-password -s "$service" -w 2>/dev/null) && [[ -n "$key" ]]; then
    print -r -- "$key"
    return 0
  fi
  if [[ -n "${DEVIN_SERVICE_KEY:-}" ]]; then
    print -r -- "$DEVIN_SERVICE_KEY"
    return 0
  fi
  return 1
}
