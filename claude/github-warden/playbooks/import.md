# ghw import playbook

Objective: reconcile the source logins into the target org (and team, if given), then explain the outcome.

Steps:
0. If Run context lists `missing inputs`, interview Amit first:
   - Ask for each missing value: target org, CSV file path. Also offer the optional flags — `--team <slug>`, `--column <name>` (login column, default `login`), `--role member|maintainer`, `--org-role member`, and a `--dry-run` preview.
   - Verify the CSV file exists; show Amit its header line and row count before proceeding.
   - Assemble the engine command from the `engine command template` line (it re-enters `bin/ghw` with `--script`, which infers the account profile from the org and resolves the token itself). Confirm the final command with Amit, then treat it as the `engine command` for step 1.
1. Run the deterministic engine exactly as provided in Run context (`engine command` line). Do not re-implement any part of it.
2. If it exits 5 (precondition) or 6 (source), relay the named failure + remediation and stop.
3. On completion read `report.csv` in the printed report dir. Summarize: added / skipped / not_found / failed counts per phase, the before→after org and team counts, and every `not_found` or `failed` row verbatim — those need Amit's action (fix source data or investigate).
4. `note` rows like "org owner auto-elevated" are GitHub semantics, not errors — mention, don't alarm.
5. If any row failed verification (`phase: verify`), flag it as the top item: live state diverged from expected.
