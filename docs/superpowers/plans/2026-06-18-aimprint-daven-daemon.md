# AiMPrint Daven Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build AiMPrint, a visible, interactive Daven-powered daemon that reports current-quarter Devin and Windsurf attribution metrics across `Invenco-Cloud-Systems-ICS`, writing a polished browser-renderable Markdown report plus a JSON sidecar for future local-dashboard ingestion.

**Architecture:** This daemon is an AI-agent launcher, not a deterministic scanner. The CLI command starts a Daven agent in YOLO/interactive mode so Amit can watch it work. The daemon supplies Daven with a focused playbook, repo-local GitHub helper scripts, report templates, analytics rules, and strict read-only GitHub guardrails. Daven calls the scripts, inspects outputs, runs attribution analytics, and writes Markdown + JSON artifacts.

**Tech Stack:** zsh wrapper, Daven CLI/runtime, GitHub CLI (`gh`), zsh helper scripts, jq/Python helper scripts for repeatable read-only data extraction, Markdown report template, JSON schema, daemon-specific README, root README/aliases integration.

---

## 1. Non-negotiable steering

Amit clarified that daemon means AI agent in this repository.

Required behavior:

- The daemon must be invoked through a CLI command.
- The command must launch a visible interactive Daven session, not run as hidden background automation.
- Daven runs in YOLO permissions mode.
- Daven does the orchestration: calls helper scripts, reads outputs, runs analytics, writes summary/report files.
- Helper scripts exist to make Daven faster and consistent; they do not replace the agent.
- The handoff document is for a Claude agent to build, but the built daemon invokes Daven.
- Amit must be able to watch Daven work through the analysis.
- The daemon name is **AiMPrint**; it reports AI imprints in GitHub work, not human performance.
- Name genesis: **AiMPrint** means AI + imprint — the durable marks left by Devin and Windsurf in commit metadata, PR-linked work, and generated/co-author trailers.

Forbidden implementation shape:

- Fully deterministic CLI that directly scans GitHub and emits reports without an AI agent.
- Background-only job where no Daven panel/session is visible.
- Claude/Codex metrics in the primary report.
- Human productivity ranking or human attribution scorecards.
- GitHub write operations.

---

## 2. Product requirements

### Report scope

- Default org: `Invenco-Cloud-Systems-ICS`.
- Default GitHub account: VNT account `amit-tiwari_vnt`.
- Default window: current calendar quarter to today, not rolling 90 days.
  - On 2026-06-18, default is `2026-Q2`, starting `2026-04-01`.
- Supported overrides:
  - `--quarter "Q1 2026"`
  - `--quarter "Q2 2026"`
  - `--quarter "Q4 2025"`
  - `--start-date YYYY-MM-DD --end-date YYYY-MM-DD`
- Default branch only for commit scanning.
- All non-archived repositories in org by default.
- Config can override org/account, but implementation must require explicit opt-in flags for non-default org/account.

### Agents counted

Primary metrics include only:

- Devin.
- Windsurf.

Primary metrics exclude:

- Claude.
- Codex.
- Generic AI keywords without strong bot/email/trailer evidence.

### Output artifacts

Every successful run writes both:

```text
reports/aimprint/<label>/aimprint-<label>.md
reports/aimprint/<label>/aimprint-<label>.json
```

Example for default on 2026-06-18:

```text
reports/aimprint/2026-Q2/aimprint-2026-Q2.md
reports/aimprint/2026-Q2/aimprint-2026-Q2.json
```

Markdown is the human-facing artifact and must render cleanly in browser/GitHub preview. JSON is the dashboard-ready sidecar for future local UI.

---

## 3. Daemon user experience

Canonical command:

```zsh
aimprint
```

Short alias:

```zsh
ap
```

Expected default flow:

1. zsh wrapper resolves daemon directory.
2. Wrapper launches Daven in interactive YOLO mode from `codex/aimprint/`.
3. Wrapper passes a generated run context into Daven:
   - org = `Invenco-Cloud-Systems-ICS`;
   - account = `amit-tiwari_vnt`;
   - window = current quarter to now;
   - output Markdown/JSON paths;
   - hard read-only guard;
   - helper scripts list and exact commands.
4. Daven reads daemon README/playbook.
5. Daven runs helper scripts.
6. Daven validates outputs.
7. Daven writes Markdown report and JSON sidecar.
8. Daven reports artifact paths and summary in the visible session.

Override examples:

```zsh
aimprint --quarter "Q2 2026"
aimprint --quarter "Q4 2025"
aimprint --start-date 2026-04-01 --end-date 2026-06-18
aimprint --out-dir /tmp/aimprint
```

Daven launch command placeholder:

```zsh
daven --yolo --interactive --cwd "$daemon_dir" --prompt-file "$run_context"
```

Implementation must inspect local Daven invocation conventions before finalizing. If Daven binary or flags differ, implement a small adapter in the wrapper and document actual command in `codex/aimprint/README.md`.

---

## 4. Repository placement

Create new daemon:

```text
codex/aimprint/
```

Rationale: repo instructions say Codex-related daemons live under `codex/<daemon-name>/`; this daemon is launched from this tools repo and uses AI-agent orchestration. Runtime is Daven, but daemon family remains local CLI daemon under existing `codex/` pattern unless Amit later creates a separate `daven/` family.

Files to create:

```text
codex/aimprint/
  README.md
  aimprint
  environment.env
  playbooks/
    _common.md
    run-attribution-report.md
  scripts/
    github-auth-check.zsh
    github-list-repos.zsh
    github-scan-commits.zsh
    github-search-pr-comments.zsh
    classify-ai-signals.py
    build-report-json.py
    render-markdown-report.py
    verify-report-artifacts.py
  templates/
    report.md.tmpl
  schema/
    report.schema.json
  test/
    run.zsh
    fixtures/
      commits.jsonl
      repos.json
      expected-report.json
```

Files to modify:

```text
README.md
aliases.zsh
```

No generic shared runtime folders.

---

## 5. Daven playbook contract

### `playbooks/_common.md`

Must include:

- You are Daven, running inside `codex/aimprint`.
- Read-only GitHub guard is top-level and non-negotiable.
- Use VNT account only: `gh auth token -u amit-tiwari_vnt`.
- Do not print tokens.
- Do not run GitHub write operations.
- Allowed GitHub operations:
  - `gh auth status`
  - `gh auth token -u amit-tiwari_vnt`
  - `gh repo list`
  - `gh api -X GET ...`
  - `gh search prs ...`
- Forbidden GitHub operations:
  - `git push`
  - `gh pr create/edit/comment/merge/close/reopen`
  - `gh issue create/edit/comment/close/reopen`
  - `gh api -X POST|PATCH|PUT|DELETE`
  - repository settings, branch, label, issue, PR, release, workflow writes.
- Count only Devin and Windsurf in primary metrics.
- Ignore Claude/Codex primary metrics even if found.
- Human attribution is out of scope.
- Always produce both Markdown and JSON artifacts.

### `playbooks/run-attribution-report.md`

Daven must follow this flow:

1. Read run context generated by wrapper.
2. Run `scripts/github-auth-check.zsh`.
3. Run `scripts/github-list-repos.zsh`.
4. Run `scripts/github-scan-commits.zsh`.
5. Optionally run `scripts/github-search-pr-comments.zsh` when report asks for PR/comment ranking.
6. Run `scripts/classify-ai-signals.py`.
7. Review classification summary manually.
8. Run `scripts/build-report-json.py`.
9. Run `scripts/render-markdown-report.py`.
10. Run `scripts/verify-report-artifacts.py`.
11. Open/read top of Markdown file and validate executive summary looks coherent.
12. Report final paths, core metrics, and any incomplete repos/errors.

The playbook must tell Daven not to improvise new API calls until helper scripts prove insufficient. If helper scripts fail, Daven should inspect and fix local helper scripts, not bypass guardrails.

---

## 6. Helper script contracts

All scripts use zsh unless Python is clearly better for JSON/Markdown transforms. zsh scripts use `#!/usr/bin/env zsh`, are checked with `zsh -n`, and never use shellcheck.

### `scripts/github-auth-check.zsh`

Inputs:

```zsh
--org Invenco-Cloud-Systems-ICS
--account amit-tiwari_vnt
--out .run/auth.json
```

Behavior:

- Gets token with `gh auth token -u amit-tiwari_vnt` without printing token.
- Calls `gh api -X GET orgs/Invenco-Cloud-Systems-ICS`.
- Writes sanitized JSON:

```json
{
  "ok": true,
  "org": "Invenco-Cloud-Systems-ICS",
  "account": "amit-tiwari_vnt",
  "owned_private_repos": 294,
  "public_repos": 0
}
```

### `scripts/github-list-repos.zsh`

Command shape:

```zsh
GH_TOKEN=$(gh auth token -u amit-tiwari_vnt) gh repo list Invenco-Cloud-Systems-ICS --limit 1000 --json name,nameWithOwner,pushedAt,updatedAt,isArchived,isPrivate,defaultBranchRef
```

Output: raw repo list plus normalized fields.

### `scripts/github-scan-commits.zsh`

Inputs:

```zsh
--org Invenco-Cloud-Systems-ICS
--account amit-tiwari_vnt
--repos .run/repos.json
--start 2026-04-01T00:00:00.000Z
--end 2026-06-18T23:59:59.999Z
--out .run/commits.jsonl
--errors .run/errors.jsonl
```

Behavior:

- Iterates non-archived repos with default branch.
- Calls only:

```zsh
gh api -X GET "repos/$org/$repo/commits" -f sha="$branch" -f since="$start" -f until="$end" -f per_page=100 --paginate
```

- Writes one normalized commit JSON object per line.
- Records repo-level errors and continues.

### `scripts/github-search-pr-comments.zsh`

Optional helper for top-commented repos/PRs. It uses `gh search prs --owner ... --updated >=YYYY-MM-DD --comments >0 --sort comments --order desc` and records GitHub search cap metadata.

### `scripts/classify-ai-signals.py`

Rules:

- Strong Devin:
  - `devin-ai-integration[bot]`
  - `158243242+devin-ai-integration[bot]@users.noreply.github.com`
  - `Generated with [Devin](https://devin.ai)`
- Strong Windsurf:
  - `windsurf-bot[bot]`
  - `189301087+windsurf-bot[bot]@users.noreply.github.com`
- Weak-only signals excluded from primary metrics:
  - `Windsurf`, `Cascade`, and `.windsurf` mentions without bot/email evidence.
- Claude/Codex ignored in primary metrics.

### `scripts/build-report-json.py`

Writes schema version `aimprint.v1` and dashboard-ready summary/repo/PR/error fields.

### `scripts/render-markdown-report.py`

Writes browser-renderable Markdown with all report sections listed below.

### `scripts/verify-report-artifacts.py`

Checks:

- Markdown exists.
- JSON exists.
- JSON parses.
- JSON schema version correct.
- Markdown title matches JSON window label.
- Markdown links to JSON sidecar.
- Markdown includes Devin and Windsurf tables.
- Markdown does not include token-looking strings.
- Summary totals in Markdown match JSON summary.

---

## 7. Detection rules

Primary metric includes strong evidence only.

### Devin strong evidence

- Commit author login equals `devin-ai-integration[bot]`.
- Commit committer login equals `devin-ai-integration[bot]`.
- Commit message contains `158243242+devin-ai-integration[bot]@users.noreply.github.com`.
- Commit message contains `Generated with [Devin](https://devin.ai)`.

### Windsurf strong evidence

- Commit author login equals `windsurf-bot[bot]`.
- Commit committer login equals `windsurf-bot[bot]`.
- Commit message contains `189301087+windsurf-bot[bot]@users.noreply.github.com`.

### Excluded weak evidence

Weak evidence can appear in JSON diagnostics but not primary metric:

- `Windsurf` keyword only.
- `Cascade` keyword only.
- `.windsurf` path mention only.
- Windsurf-family text without bot/email evidence.

### Ignored primary agents

- Claude.
- Codex.

---

## 8. Markdown report contract

Every report includes:

1. `# AiMPrint Report — <label>`.
2. Metadata table: org, window, generated at, GitHub account, read-only mode, primary agents.
3. Executive summary paragraph.
4. KPI summary table.
5. Agent split table.
6. Top repos by AI commit count.
7. Top repos by AI commit share with minimum 10 commits scanned.
8. PR-linked vs direct/unknown delivery table.
9. Detection rules.
10. Limitations.
11. Link to JSON sidecar.
12. Errors appendix.

Style:

- Browser-renderable Markdown.
- Tables copy cleanly.
- Percentages with two decimals.
- Escape `|` in cells.
- No tokens.

Example skeleton:

```markdown
# AiMPrint Report — 2026-Q2

| Field | Value |
|---|---|
| Org | `Invenco-Cloud-Systems-ICS` |
| Window | `2026-04-01T00:00:00.000Z` → `2026-06-18T23:59:59.999Z` |
| GitHub account | `amit-tiwari_vnt` |
| Primary agents | Devin, Windsurf |
| GitHub mode | Read-only GET/list/search |

## Executive summary

Strong AI signal was found in **1,059 of 3,625** default-branch commits (**29.21%**) across scanned repos. Primary signal is commit-level Devin or Windsurf bot identity/trailers; Claude and Codex are intentionally excluded.

## KPI summary

| Metric | Value |
|---|---:|
| Repos listed | 294 |
| Repos scanned | 160 |
| Commits scanned | 3,625 |
| Strong AI commits | 1,059 |
| AI commit share | 29.21% |
| PRs with AI commits | 123 |
| Direct/unknown AI commits | 456 |

## JSON sidecar

Machine-readable data: [`aimprint-2026-Q2.json`](./aimprint-2026-Q2.json)
```

---

## 9. JSON sidecar contract

JSON must be stable for future local dashboard.

Top-level shape:

```json
{
  "schemaVersion": "aimprint.v1",
  "org": "Invenco-Cloud-Systems-ICS",
  "generatedAt": "2026-06-18T00:00:00.000Z",
  "githubAccount": "amit-tiwari_vnt",
  "readOnly": true,
  "window": {
    "label": "2026-Q2",
    "startIso": "2026-04-01T00:00:00.000Z",
    "endIso": "2026-06-18T23:59:59.999Z",
    "quarter": "Q2 2026"
  },
  "agents": {
    "primary": ["devin", "windsurf"],
    "ignoredInPrimary": ["claude", "codex"]
  },
  "summary": {
    "reposListed": 294,
    "reposScanned": 160,
    "reposWithErrors": 0,
    "commitsScanned": 3625,
    "strongAiCommits": 1059,
    "devinCommits": 1008,
    "windsurfCommits": 51,
    "aiCommitShare": 0.2921,
    "devinCommitShare": 0.2781,
    "windsurfCommitShare": 0.0141,
    "prsWithAiCommits": 123,
    "prLinkedAiCommits": 603,
    "directOrUnknownAiCommits": 456
  },
  "repoMetrics": [],
  "prMetrics": [],
  "errors": [],
  "detectionRules": {}
}
```

Do not include raw commit messages by default. Future `--include-samples` may add examples.

---

## 10. Implementation tasks

### Task 1: Discover Daven invocation and existing daemon patterns

**Files:**
- Read: `AGENTS.md`
- Read: `README.md`
- Read: `aliases.zsh`
- Read: `claude/devin-acu-governor/README.md`
- Read: `codex/ai-cmux-conductor/README.md`

- [ ] Inspect existing wrappers and README patterns.
- [ ] Locate Daven binary/CLI invocation pattern on Amit's machine.
- [ ] Record actual Daven launch command in implementation notes.
- [ ] Confirm whether daemon belongs under `codex/aimprint/` or a new family; default to `codex/` unless Amit says otherwise.

Verification:

```zsh
cd /Users/amittiwari/Projects/Tools-Utilities/daemons
zsh -n aliases.zsh
```

Expected: existing aliases parse.

### Task 2: Scaffold daemon directory and wrapper

**Files:**
- Create: `codex/aimprint/README.md`
- Create: `codex/aimprint/aimprint`
- Create: `codex/aimprint/environment.env`
- Create: `codex/aimprint/playbooks/_common.md`
- Create: `codex/aimprint/playbooks/run-attribution-report.md`

- [ ] Create directories.
- [ ] Create zsh wrapper with `script_path=${0:A}` captured before functions.
- [ ] Parse CLI args for quarter/date/out-dir.
- [ ] Generate `.run/context.md` or temp context file for Daven.
- [ ] Launch Daven in visible YOLO interactive mode with the context.
- [ ] Add README guardrails and usage.

Wrapper must parse-check:

```zsh
zsh -n codex/aimprint/aimprint
```

Expected: exit 0.

### Task 3: Implement date/window helper in wrapper or script

**Files:**
- Modify: `codex/aimprint/aimprint`
- Optional create: `codex/aimprint/scripts/resolve-window.zsh`
- Test: `codex/aimprint/test/run.zsh`

- [ ] Default no args to current quarter.
- [ ] Support `--quarter "Q2 2026"`.
- [ ] Support `--start-date` + `--end-date`.
- [ ] Reject mixed quarter and date args.
- [ ] Reject malformed quarter/date.
- [ ] Write resolved window into run context.

Verification examples:

```zsh
codex/aimprint/aimprint --dry-run-context --now 2026-06-18T10:20:30Z | grep '2026-Q2'
codex/aimprint/aimprint --dry-run-context --quarter 'Q4 2025' | grep '2025-Q4'
```

Expected: context output contains correct windows and does not launch Daven in dry-run mode.

### Task 4: Build read-only GitHub helper scripts

**Files:**
- Create: `scripts/github-auth-check.zsh`
- Create: `scripts/github-list-repos.zsh`
- Create: `scripts/github-scan-commits.zsh`
- Create: `scripts/github-search-pr-comments.zsh`

Each script must:

- Use zsh.
- Use `gh auth token -u amit-tiwari_vnt`.
- Never print token.
- Use only GET/list/search.
- Write output files under `.run/` or configured run dir.
- Continue through repo-level errors where possible.

Parse verification:

```zsh
zsh -n codex/aimprint/scripts/*.zsh
```

Functional smoke with no writes:

```zsh
codex/aimprint/scripts/github-auth-check.zsh --org Invenco-Cloud-Systems-ICS --account amit-tiwari_vnt --out /tmp/aip-auth.json
jq '.ok, .org, .account' /tmp/aip-auth.json
```

Expected: `true`, org name, account name.

### Task 5: Build analytics helper scripts

**Files:**
- Create: `scripts/classify-ai-signals.py`
- Create: `scripts/build-report-json.py`
- Create: `scripts/render-markdown-report.py`
- Create: `scripts/verify-report-artifacts.py`
- Create: `schema/report.schema.json`
- Create: `templates/report.md.tmpl`

- [ ] `classify-ai-signals.py` reads commits JSONL and writes classified commits JSONL + summary.
- [ ] `build-report-json.py` writes `schemaVersion: aimprint.v1` JSON.
- [ ] `render-markdown-report.py` writes browser-renderable Markdown.
- [ ] `verify-report-artifacts.py` validates consistency and no secrets.
- [ ] `report.schema.json` documents JSON sidecar schema.
- [ ] `report.md.tmpl` contains all required sections.

Verification:

```zsh
python3 codex/aimprint/scripts/classify-ai-signals.py --commits codex/aimprint/test/fixtures/commits.jsonl --out /tmp/aip-classified.jsonl --summary /tmp/aip-summary.json
python3 codex/aimprint/scripts/build-report-json.py --classified /tmp/aip-classified.jsonl --repos codex/aimprint/test/fixtures/repos.json --errors /tmp/empty-errors.jsonl --window codex/aimprint/test/fixtures/window.json --out /tmp/aip-report.json
python3 codex/aimprint/scripts/render-markdown-report.py --json /tmp/aip-report.json --template codex/aimprint/templates/report.md.tmpl --out /tmp/aip-report.md
python3 codex/aimprint/scripts/verify-report-artifacts.py --markdown /tmp/aip-report.md --json /tmp/aip-report.json
```

Expected: all exit 0.

### Task 6: Write Daven playbooks

**Files:**
- Modify: `playbooks/_common.md`
- Modify: `playbooks/run-attribution-report.md`

Playbook acceptance:

- Lists exact helper script order.
- Tells Daven to inspect outputs before rendering.
- Tells Daven to fix helper script issues locally if needed.
- Tells Daven not to run ad hoc GitHub write operations.
- Tells Daven to produce final Markdown and JSON paths.
- Tells Daven to summarize metrics in final response.

Verification:

```zsh
grep -R "gh api -X POST\\|gh api -X PATCH\\|gh api -X PUT\\|gh api -X DELETE" codex/aimprint/playbooks && exit 1 || true
grep -R "devin-ai-integration\\|windsurf-bot" codex/aimprint/playbooks
```

Expected: no forbidden write verbs; detection signals present.

### Task 7: Build daemon test harness

**Files:**
- Create: `codex/aimprint/test/run.zsh`
- Create fixtures under `test/fixtures/`

Test harness must check:

- zsh parse for wrapper and helper scripts.
- date/window dry-run outputs.
- classifier fixture outputs.
- JSON report schema fields.
- Markdown report title, KPI table, JSON sidecar link.
- no token-like strings in generated artifacts.
- no forbidden GitHub write verbs in scripts/playbooks.

Command:

```zsh
zsh codex/aimprint/test/run.zsh
```

Expected: all assertions pass.

### Task 8: Documentation and aliases

**Files:**
- Modify: `README.md`
- Modify: `aliases.zsh`
- Modify: `codex/aimprint/README.md`

Root README entry:

```markdown
- [`codex/aimprint`](./codex/aimprint) — `aimprint`/`aip`, a visible Daven-powered read-only Invenco ICS GitHub AI attribution daemon that launches Daven in interactive YOLO mode, defaults to the current calendar quarter, uses the VNT GitHub account, calls repo-local GitHub helper scripts, and writes a browser-renderable Markdown report plus JSON sidecar for Devin and Windsurf metrics.
```

Aliases:

```zsh
alias aimprint='/Users/amittiwari/Projects/Tools-Utilities/daemons/codex/aimprint/aimprint'
alias aip='aimprint'
```

Verification:

```zsh
zsh -n aliases.zsh
```

Expected: exit 0.

### Task 9: Live smoke test with visible Daven

Run:

```zsh
aimprint --quarter "Q2 2026"
```

Expected:

- visible Daven session opens/runs;
- Daven reads context/playbook;
- Daven runs helper scripts;
- no GitHub write operations;
- Markdown file exists;
- JSON sidecar exists;
- Markdown renders cleanly in browser/GitHub preview;
- JSON parses with `jq`;
- primary metrics include only Devin and Windsurf.

Validate outputs:

```zsh
jq '.schemaVersion, .org, .agents.primary, .summary.strongAiCommits' reports/aimprint/2026-Q2/aimprint-2026-Q2.json
python3 - <<'PY'
from pathlib import Path
p = Path('reports/aimprint/2026-Q2/aimprint-2026-Q2.md')
text = p.read_text()
assert text.startswith('# AiMPrint Report')
assert '| Metric | Value |' in text
assert 'aimprint-2026-Q2.json' in text
agent_split = text.split('## Agent split')[1].split('##')[0]
assert 'Claude' not in agent_split
assert 'Codex' not in agent_split
print(p)
PY
```

Expected: all assertions pass.

### Task 10: Final verification, commit, push

Run:

```zsh
cd /Users/amittiwari/Projects/Tools-Utilities/daemons
zsh codex/aimprint/test/run.zsh
zsh -n aliases.zsh
git status --short
git diff --stat
```

Audit:

- no tokens;
- no unrelated files;
- no accidental generated report artifacts committed unless README explicitly documents committed sample fixtures;
- wrapper and scripts parse;
- Daven visible smoke passed.

Commit:

```zsh
git add codex/aimprint README.md aliases.zsh
git commit -m "feat: add ICS AI attribution Daven daemon"
git push -u origin HEAD
```

If push fails, report exact output and do not claim completion.

---

## 11. Future local dashboard integration

The daemon v1 must not build the dashboard. It prepares the dashboard data contract.

Future dashboard should:

- read `reports/aimprint/*/*.json`;
- show current quarter AI commit share;
- show Devin vs Windsurf split;
- show top repos by AI commit count;
- show top repos by AI commit share with minimum commit threshold;
- show PR-linked vs direct/unknown delivery;
- show quarter-over-quarter trend;
- link back to Markdown reports.

The future UI should not rescan GitHub in v1. Daven daemon owns collection/report generation.

---

## 12. Known risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Daven CLI flags differ from placeholder | Wrapper launch fails | Task 1 requires discovering actual local Daven command before implementation |
| Helper scripts become de facto daemon | Violates Amit steering | Wrapper must launch Daven; scripts are called by Daven from playbook |
| GitHub search caps at 1,000 results | PR comment rankings incomplete | Use commit pagination as primary metric; mark PR comment data as capped |
| Direct pushes by Devin lack human owner | Human attribution impossible | Human attribution explicitly out of scope |
| Claude/Codex appear in AI tooling repos | Primary metric pollution | Classifier ignores Claude/Codex primary signals |
| Windsurf naming evidence varies | Under-count Flow work | Treat Windsurf bot and Windsurf aliases as one `windsurf` metric |
| Markdown report too large | Browser preview slow | Keep raw commits out of Markdown; structured detail goes in JSON |
| Token accidentally printed | Secret leak | Scripts never echo token; verifier scans artifacts for token-like strings |
| GitHub write command accidentally added | Safety breach | Tests grep scripts/playbooks for forbidden verbs |

---

## 13. Acceptance checklist

- [ ] CLI command launches visible Daven in YOLO interactive mode.
- [ ] Daven has playbooks and helper scripts tailored to this report.
- [ ] Default run uses current calendar quarter to today.
- [ ] Quarter override works.
- [ ] Start/end date override works.
- [ ] Default org is `Invenco-Cloud-Systems-ICS`.
- [ ] Default account is `amit-tiwari_vnt`.
- [ ] GitHub operations are read-only.
- [ ] Primary metrics include only Devin and Windsurf.
- [ ] Claude/Codex excluded from primary metrics.
- [ ] Human attribution/ranking absent.
- [ ] Markdown report written by each successful run.
- [ ] Markdown renders in browser/GitHub preview.
- [ ] JSON sidecar written by each successful run.
- [ ] JSON sidecar uses `schemaVersion: aimprint.v1`.
- [ ] Helper scripts make Daven faster and consistent.
- [ ] README documents guardrails, command use, Daven launch, scripts, Markdown, JSON, metrics, verification.
- [ ] Root README and aliases updated.
- [ ] zsh parse checks pass.
- [ ] daemon test harness passes.
- [ ] visible Daven smoke test passes.
- [ ] Commit and push complete after verification.
