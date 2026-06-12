# Daemons Repository Claude Instructions

Claude agents working in this repository must follow `AGENTS.md`.

## Completion commit/push rule

- When you finish user-requested work, run the relevant verification before reporting completion.
- If verification passes, commit the scoped work with a clear message and push the current branch.
- If the branch has no upstream, push with upstream tracking (`git push -u origin HEAD`) unless the push is rejected.
- Stage only files you intentionally changed. Do not include unrelated dirty work from other agents or earlier tasks.
- If verification fails, required credentials are missing, or push is rejected, do not claim completion; report the exact blocker and leave the work unpushed.
- Never commit secrets, tokens, generated credentials, or local-only scratch artifacts.
