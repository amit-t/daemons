# Daemons Repository Agent Instructions

This repository owns daemon source code for Amit.

## Ownership boundary

- Daemon implementation code lives here, not in `/Users/amittiwari/Profiles`.
- `/Users/amittiwari/Profiles` is only a global exposure layer: PATH wrappers and shell sourcing may delegate here.
- Codex-related daemons live under `codex/<daemon-name>/`.
- Claude-powered daemons live under `claude/<daemon-name>/`; their runtime is a Claude agent session launched from a thin zsh wrapper.
- Namespace each daemon's source under its own name, for example `src/ai-cmux-conductor/`.
- Do not introduce generic daemon-runtime directory names for Codex daemons; use daemon-specific names.

## Documentation rule

For every daemon creation or daemon behavior change, create or update the relevant README:

- Root `README.md` for repository layout/global exposure conventions.
- `<family>/<daemon-name>/README.md` for daemon-specific purpose, usage, files, and verification.

## Completion commit/push rule

- When you finish user-requested work, run the relevant verification before reporting completion.
- If verification passes, commit the scoped work with a clear message and push the current branch.
- If the branch has no upstream, push with upstream tracking (`git push -u origin HEAD`) unless the push is rejected.
- Stage only files you intentionally changed. Do not include unrelated dirty work from other agents or earlier tasks.
- If verification fails, required credentials are missing, or push is rejected, do not claim completion; report the exact blocker and leave the work unpushed.
- Never commit secrets, tokens, generated credentials, or local-only scratch artifacts.

## Shell preference

- Prefer zsh for shell entrypoints and wrappers.
- Use `#!/usr/bin/env zsh` and validate with `zsh -n`.
- Do not use shellcheck for zsh files.
