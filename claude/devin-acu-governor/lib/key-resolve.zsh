#!/usr/bin/env zsh
# Resolve dag API keys.
#
# Primary — Devin API v3 service-user key (cog_..., api.devin.ai):
#   Keychain item DAG_COG_KEYCHAIN_SERVICE (default devin-cog-key), then $DEVIN_COG_KEY.
# Secondary — Windsurf service key (server.codeium.com analytics):
#   Keychain item DAG_KEYCHAIN_SERVICE (default devin-service-key), then $DEVIN_SERVICE_KEY.
#
# Each function prints the key on stdout; returns 1 if neither source is set.

dag_resolve_cog_key() {
  local service="${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key}"
  local key
  if key=$(security find-generic-password -s "$service" -w 2>/dev/null) && [[ -n "$key" ]]; then
    print -r -- "$key"
    return 0
  fi
  if [[ -n "${DEVIN_COG_KEY:-}" ]]; then
    print -r -- "$DEVIN_COG_KEY"
    return 0
  fi
  return 1
}

dag_resolve_service_key() {
  local service="${DAG_KEYCHAIN_SERVICE:-devin-service-key}"
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
