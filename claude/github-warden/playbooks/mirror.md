# ghw mirror playbook

Objective: scaffold a new GitHub repo mirroring a reference repo's settings, protection, security flags, access, and (optionally) Pages docs.

Steps:
1. Read the gh-repo-mirror skill at `~/.claude/skills/gh-repo-mirror/SKILL.md` and follow its workflow. The helper script is `~/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh`.
2. Run context gives you the reference target (repo arg or "origin of the launch directory") and any pass-through flags. Interview Amit only for required values the flags don't cover (new repo name, description, Pages choices).
3. Auth: `GH_TOKEN` is already exported for the right account profile — verify `gh api user --jq .login` matches the expected login from Run context before creating anything.
4. Prefer `--dry-run` first when the flag set is ambiguous; show Amit the plan, then run for real.
5. Report: new repo URL, which settings/protection/access mirrored, any warnings (unresolvable teams, dropped flags), and Pages/DNS follow-ups.
