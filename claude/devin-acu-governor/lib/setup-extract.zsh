#!/usr/bin/env zsh
# dag setup-extract — print pasteable keychain setup commands for another Mac.
#
# This command intentionally writes live API keys to stdout because its purpose is
# migration. Run only in a trusted terminal, copy directly to the target machine,
# then clear shell history/clipboard as appropriate.
#
# Requires lib/key-resolve.zsh to be sourced already.

_dag_setup_quote() {
  local value="$1"
  print -r -- "${(qq)value}"
}

dag_setup_extract() {
  if (( $# != 0 )); then
    print -ru2 -- "dag setup-extract: no arguments expected"
    return 2
  fi

  local cog_service="${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key}"
  local ws_service="${DAG_KEYCHAIN_SERVICE:-devin-service-key}"
  local cog_key ws_key

  if ! cog_key=$(dag_resolve_cog_key); then
    print -ru2 -- "dag setup-extract: missing Devin API v3 key (${cog_service})."
    print -ru2 -- "  Add it on this machine first, then rerun dag setup-extract."
    return 1
  fi
  if ! ws_key=$(dag_resolve_service_key); then
    print -ru2 -- "dag setup-extract: missing Windsurf service key (${ws_service})."
    print -ru2 -- "  Add it on this machine first, then rerun dag setup-extract."
    return 1
  fi

  print -ru2 -- "dag setup-extract: WARNING — printing live API keys to stdout. Paste only into a trusted target machine."
  print -r -- "# Paste into the target Mac's zsh terminal:"
  print -r -- "security add-generic-password -U -s ${cog_service} -a \"\$USER\" -w $(_dag_setup_quote "$cog_key")"
  print -r -- "security add-generic-password -U -s ${ws_service} -a \"\$USER\" -w $(_dag_setup_quote "$ws_key")"
  print -r -- "# Verify after installing dag on target: dag doctor"
}
