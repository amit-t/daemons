#!/usr/bin/env zsh
# hivemind surface registry — the global agent-instruction surfaces synced across machines.
#
# Format: "surface-id|kind|live-path-relative-to-HOME|snapshot-relative-path"
#   kind = file    → single file, copied verbatim
#   kind = dir-md  → top-level *.md files of that directory (subdirectories ignored)
#
# Scope rule: global instruction/memory MARKDOWN only. Never add settings/config
# files that can carry credentials (settings.json, config.toml, auth.json).
# Project-level steering (per-repo CLAUDE.md/AGENTS.md) is intentionally per-project
# and never synced here.

typeset -ga HIVE_SURFACES
HIVE_SURFACES=(
  "claude-global|file|.claude/CLAUDE.md|claude/CLAUDE.md"
  "codex-agents|file|.codex/AGENTS.md|codex/AGENTS.md"
  "codex-memories|dir-md|.codex/memories|codex/memories"
  "gemini-global|file|.gemini/GEMINI.md|gemini/GEMINI.md"
)

# Add machine-agnostic surfaces here as agents grow new global instruction files.
# Known candidates, currently excluded on purpose:
#   ~/.devin              — no global instruction .md (skills are synced via repos)
#   ~/.gemini/antigravity — brain/ + knowledge/ are per-conversation artifacts, not global rules
#   ~/.windsurf           — extensions only, no global rules file yet
