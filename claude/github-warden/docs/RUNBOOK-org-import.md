# Runbook — `ghw import` (org/team CSV reconciliation)

Operational runbook for the recurring job this daemon was built for: importing a CSV of GitHub logins into an org (and optionally one team). See [`../README.md`](../README.md) for full command reference, flag semantics, and the import engine's algorithm/safety properties; this document is the "what do I actually type, in what order, under pressure" checklist. See [`ACCOUNTS.md`](ACCOUNTS.md) for which account owns which org.

## Preconditions checklist

Before running anything:

- [ ] You know the target `--org` and, if applicable, the target `--team` **slug** (not display name — check the GitHub UI or `ghw members --org <org>` team column if unsure).
- [ ] `ghw doctor` exits 0 for the account that owns the target org. If it doesn't, fix credentials first — see [README § Troubleshooting](../README.md#troubleshooting).
- [ ] The account is an **org admin** on the target org, not just a member (`ghw doctor` shows `role=admin` for it; `ghw doctor --strict` fails loudly if not).
- [ ] The token has `admin:org` scope (classic PAT) or **Organization Members: read & write** (fine-grained PAT) — `gh auth login`/`gh auth refresh` already grants this for both of Amit's accounts; re-check with `ghw doctor` if unsure.
- [ ] You have the source CSV in hand and know which column holds the logins (default column name is `login`).

## Get the CSV into the required shape

The parser (`ghw_parse_source` in `lib/report.zsh`) is strict on purpose — it refuses to guess:

- **Plain CSV only. No quoted fields.** If any line in the file contains a `"` character, the whole file is refused with `SOURCE_INVALID: quoted CSV fields are not supported — export a plain CSV` (exit 6) — even if the quote is nowhere near the logins column. Re-export without quoting (most spreadsheet tools have a "plain CSV" / "CSV UTF-8" export option that avoids quoting unless a field actually contains a comma; if a field does contain a comma, strip or replace it before import).
- **Header row required.** The first line is scanned for a column matching `--column` (default `login`); leading/trailing whitespace and stray quote characters around header names are stripped before matching.
- **Whitespace/quote-trimming applies to values too**, but embedded quotes inside a field will still trip the blanket quoted-CSV refusal above — this isn't a per-field quoting parser, it's a plain-CSV parser with cosmetic trimming.
- **Empty logins are dropped silently**, exact-duplicate logins are dropped with a stderr warning (`ghw: duplicate login in source deduped: <login>`) — not a hard failure.
- **Zero parsed logins is a hard failure**: `SOURCE_INVALID: no logins parsed from <csv> column '<column>'` (exit 6).

If your source is a `ghw members --org <org> --csv out.csv` export, it already satisfies all of the above and uses column `login` — it round-trips directly.

## Dry-run first

Always. No exceptions, no "I'm confident this time."

```zsh
ghw import --org <org> [--team <slug>] --csv <file> [--column login] \
           [--role member|maintainer] [--org-role member|admin] \
           --dry-run --script
```

`--script` bypasses the agent playbook and runs `lib/import-engine.zsh` directly — for a scripted/recurring job this is almost always what you want (deterministic, no agent narration to parse). Omit `--script` only if you want the agent to interview you and narrate; it is instructed (`playbooks/import.md`) to run the exact same engine command, never to improvise around it.

### How to read dry-run output

Stdout ends with:

```
dry-run: would add <N> to org, <M> to team <slug|'(none)'>
report: <path to reports/<job_id>/>
```

Open `report.csv` in that directory. Every row's `status` is one of `would_add` or `skipped`:

- `would_add` — this login is not currently a member of the org (or team) and a real run would `PUT` it.
- `skipped` — already a member; a real run will not touch it. This is the safety mechanism working, not a sign something is wrong.

Sanity-check the counts: `would_add` count for `org` phase + existing org member count should roughly match your expected post-import org size. If the `would_add` count is much larger or smaller than expected, stop and check the CSV/column before running for real — a wrong `--column` value that happens to match a header will parse successfully and produce garbage logins that will all show `not_found` on a real run (wasteful, though harmless) or, worse, silently import the wrong set of accounts.

Zero writes happen in dry-run mode — this is enforced structurally (the write loops in `lib/import-engine.zsh` are skipped entirely when `dry_run=1`), not just a flag the report happens to respect.

## The real run

Drop `--dry-run`:

```zsh
ghw import --org <org> [--team <slug>] --csv <file> --script
```

It prints one line per successful write as it happens (`org + <login> (<state>)` / `team + <login> (<state>)`), then the same before/after summary and report path as the dry run.

## How to read the report and what to do per row status

`report.csv` header: `login,phase,status,state,role,detail`. `phase` ∈ `org, team, verify`.

| `status` | What happened | Operator action |
|---|---|---|
| `added` | Write succeeded | None |
| `skipped` | Already a member — never touched | None; expected on any re-run |
| `not_found` | Login doesn't exist on GitHub (404 on the write) | Fix the source row (typo, deleted/deactivated account, or — on an EMU org — a login not yet provisioned in the enterprise) and re-run; the engine is idempotent, already-added logins will just show `skipped` |
| `failed` (phase `org`/`team`) | Write returned a non-2xx, non-404 status | Read the `detail` column (exact HTTP status + API message). Common causes: transient 5xx (just re-run), a genuine permission gap that slipped past preconditions, or a malformed login. Re-run after fixing |
| `failed` (phase `verify`) | Post-write read couldn't confirm the login is actually a member (list unreadable, or login absent from live state after a `2xx` write) | **Top-priority row** — live state diverged from what the API claimed. Manually check with `ghw members --org <org>` or the GitHub UI, then re-run if the membership genuinely isn't there |
| `would_add` | Dry-run only | Not applicable to a real run's report |

`detail` may also carry the note `"org owner auto-elevated"` on a `team`/`added` row — this is GitHub auto-promoting an existing org Owner to team maintainer regardless of the requested `--role`. It's expected GitHub semantics, not an error; the verify pass checks membership, not role, so it never becomes a `failed` row.

The `summary.txt` before→after counts (also printed to stdout) are the fastest sanity check:

```
org: 268 -> 357 (+89)
team: 3 -> 149 (+146)
```

## If it aborts mid-batch

**Just re-run the exact same command.** The engine is idempotent by construction:

- If it aborted **before any writes** (`MEMBER_LIST_READ_FAILED` from a failed pre-write member-list read, or a precondition failure), nothing happened — re-running is identical to a first attempt.
- If it aborted or completed **with errors after some writes landed** (exit 1, `completed_with_errors`), every login already added shows up as an existing member on the re-read and gets `skipped` this time — only the logins that actually failed or weren't reached get retried. There is no partial-batch cleanup step; the set-difference in the algorithm **is** the resume mechanism.

Never try to manually "finish" a partial import by hand-editing memberships — just re-run `ghw import` with the same flags against the same (or a trimmed) CSV.

## What is out of scope — do by hand

The engine will never do these, on purpose (see [README § Import engine semantics](../README.md#import-engine-semantics)):

- **Role changes** for an existing member — promoting a member to maintainer/admin, or demoting one. Use the GitHub UI or a separate, explicitly-confirmed API call. This is not a missing feature; it's the safety boundary the whole engine is built around.
- **Removals** — taking someone off an org or team. Not supported at all (`offboard` is on the [backlog](../README.md#backlog-not-built-in-v1), unbuilt).
- **Team or org creation.** The target org and (if given) team must already exist — `ORG_NOT_FOUND`/`TEAM_NOT_FOUND` refuse cleanly rather than creating anything.
- **Fixing bad source data.** A `not_found` row means go fix the CSV or the GitHub account situation; the engine does not guess or fuzzy-match logins.

## Known-good reference numbers (sanity anchor)

From the origin spec's real manual run — importing `export-INVENCO-PPNA-1784909266.csv` into `INVENCO-GROUP` / team `ai-workbench-ppna`:

- **147 of 148** source logins were net-new (1 was `Kiran1-Kumar_vnt`, a `not_found` — the account did not exist on github.com).
- Org membership: **268 → 357** (+89 net-new org members; the remaining logins in the CSV were already org members, only needing the team add).
- Team membership: **3 → 149** (+146).

If a future run against a similarly-sized CSV produces wildly different before/after deltas than this shape would suggest, treat it as a signal to double check the CSV and `--column` before trusting the result — not proof of a bug, but worth a second look.

## See also

- [`../README.md`](../README.md) — full command reference, safety model, error/refusal table, environment variables.
- [`ACCOUNTS.md`](ACCOUNTS.md) — which account (`personal`/`inv`) owns which org, and the air-gap rule.
