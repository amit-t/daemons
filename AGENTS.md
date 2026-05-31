# Daemons Repository Agent Instructions

This repository owns daemon source code for Amit.

## Ownership boundary

- Daemon implementation code lives here, not in `/Users/amittiwari/Profiles`.
- `/Users/amittiwari/Profiles` is only a global exposure layer: PATH wrappers and shell sourcing may delegate here.
- Codex-related daemons live under `codex/<daemon-name>/`.
- Namespace each daemon's source under its own name, for example `src/ai-cmux-conductor/`.
- Do not introduce generic daemon-runtime directory names for Codex daemons; use daemon-specific names.

## Documentation rule

For every daemon creation or daemon behavior change, create or update the relevant README:

- Root `README.md` for repository layout/global exposure conventions.
- `<family>/<daemon-name>/README.md` for daemon-specific purpose, usage, files, and verification.

## Shell preference

- Prefer zsh for shell entrypoints and wrappers.
- Use `#!/usr/bin/env zsh` and validate with `zsh -n`.
- Do not use shellcheck for zsh files.
