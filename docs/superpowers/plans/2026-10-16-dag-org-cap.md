# `dag org-cap` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** New DAG mode `dag org-cap <org> [+acus|acus]` that changes one organization's Local Agent cap and always asks the operator to pick the funding source: `ZERO-SUM` (donor orgs pay), `POOL HEADROOM` (ceiling slack pays, Σ grows), or `MIXED` (donors first, slack remainder).

**Architecture:** Same pattern as every dag playbook command: `bin/dag` validates args and assembles `playbooks/_common.md` + `playbooks/org-cap.md` + run-context lines into an agent prompt. All numbers come from `lib/org-rebalance.jq` (hard rule 1), extended with a `slack_only` flag and an auto-need mode. Writes stay behind `CONFIRM DAG WRITE`.

**Tech Stack:** zsh (`#!/usr/bin/env zsh`, `zsh -n` to parse-check), jq, existing test harness (`test/harness.zsh`, run via `zsh test/run.zsh`).

**Spec:** User request (this plan's header) + existing contract in `claude/devin-acu-governor/playbooks/_common.md`. Repo root: `/Users/amittiwari/Projects/Tools-Utilities/daemons`. Daemon dir: `claude/devin-acu-governor` (all paths below relative to it unless rooted).

## Global Constraints

- Org ceiling: Σ every org's `local_agent` + `cloud_agent` caps ≤ `DAG_MONTHLY_ACU_POOL` (24000). POOL HEADROOM/MIXED fund only from `ceiling − sum_before`, never past the ceiling. While the layer is over the ceiling, only shrinking writes are allowed.
- Headroom clamps (hard rule 11): defaults 250, explicit-request range 250–500, above 500 never — jq clamps to [0,500].
- Hard rule 1: every displayed/written number comes from jq output; playbook shows exact jq command + full JSON.
- Hard rule 2: `CONFIRM DAG WRITE` before any PATCH. Funding-mode keyword is NOT write authorization.
- PATCH bodies carry only `{"local_agent":{"cycle_acu_limit":N}}` (cloud gate preserved). Never clear an org cap. Cuts before raises. GET-verify every write.
- Backward compatibility: all existing tests stay green; `lib/org-rebalance.jq` defaults (`slack_only` false, numeric needs) must not change existing outputs.
- zsh only; validate scripts with `zsh -n`; no shellcheck.
- Each task ends in its own commit (caveman-commit style: `feat(dag): ...` / `test(dag): ...` / `docs(dag): ...`).

## Review Focus

1. Uncapped target org + `+N` delta: no base cap to add to — CLI accepts it (can't know cap), playbook must stop and ask for an absolute amount. Test pinned in Task 2 (playbook text) — the playbook step must say it explicitly.
2. Layer already over ceiling + raise request: raise must be refused (point at `dag slg`); only the shrink path may run. Pinned by jq warning test (Task 1, existing warning retained) + playbook step text (Task 2).
3. Shrink below current consumption: members insta-blocked at the gate — playbook must warn loudly in the shrink preview. Pinned in Task 2 playbook text.
4. `dag org cap` two-word form colliding with future `dag org <other>`: unknown subword must exit 2 with a clear message, not fall through to the playbook. Test pinned in Task 3.
5. Auto-need when the cap already covers projected + headroom: need must come out 0 (report "nothing to raise", stop) — not negative, not a donor drain. Test pinned in Task 1.

---

### Task 1: `lib/org-rebalance.jq` — `slack_only` + auto-need

**Files:**
- Modify: `claude/devin-acu-governor/lib/org-rebalance.jq`
- Test: `claude/devin-acu-governor/test/org-rebalance.test.zsh`

**Interfaces:**
- Consumes: existing input shape (header comment in the file).
- Produces (new inputs, all optional, defaults = old behavior):
  - `"slack_only": <bool=false>` — donors give nothing (treat every donor surplus as 0); funding comes only from ceiling slack. Implies slack use regardless of `use_slack`. Echoed in output as top-level `slack_only`.
  - `"target_headroom": <n=250>` — clamped `[0,500]` like `min_donor_headroom`; used only by auto-need.
  - `needs[]` entries may carry `"need": "auto"` → resolved per org as `need = max(0, ceil(projected) + target_headroom − cap_before)` (org's `projected` = `consumed + run_rate × days_left`, already computed; `cap_before` = that org's `local_cap`). Numeric needs unchanged. Auto entry for an org_id not in `orgs`, or for an uncapped org (`local_cap` null): drop the entry (existing uncapped warning still fires).
- Update the file's header comment for all three.

- [ ] **Step 1: Write failing tests** — append to `test/org-rebalance.test.zsh` before `report`:

```zsh
# H. slack_only: donors untouched, funding purely from ceiling slack.
#    Σ before 1450, ceiling 2000 -> slack 550; need 500 fully slack-funded.
out=$(run_jq '{"ceiling":2000,"slack_only":true,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "H slack_only echoed" true "$(field "$out" '.slack_only')"
assert_eq "H no donors" '[]' "$(field "$out" '.donors')"
assert_eq "H from_slack" 500 "$(field "$out" '.recipients[0].from_slack')"
assert_eq "H from_donors" 0 "$(field "$out" '.recipients[0].from_donors')"
assert_eq "H cap_after" 1500 "$(field "$out" '.recipients[0].cap_after')"
assert_eq "H sum_after" 1950 "$(field "$out" '.sum_after')"
assert_eq "H zero_sum" false "$(field "$out" '.zero_sum')"
assert_eq "H one write" 1 "$(field "$out" '.writes | length')"

# I. slack_only never passes the ceiling: slack 50 < need 500 -> 450 unfunded.
out=$(run_jq '{"ceiling":1500,"slack_only":true,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "I from_slack" 50 "$(field "$out" '.recipients[0].from_slack')"
assert_eq "I unfunded" 450 "$(field "$out" '.recipients[0].unfunded')"
assert_eq "I sum_after = ceiling" 1500 "$(field "$out" '.sum_after')"

# J. auto-need: projected 1000 (consumed 1000, no run_rate), cap 900,
#    target_headroom default 250 -> need = 1000 + 250 - 900 = 350.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":900,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "J auto need" 350 "$(field "$out" '.recipients[0].need')"
assert_eq "J cap_after" 1250 "$(field "$out" '.recipients[0].cap_after')"

# K. auto-need already satisfied: cap 2000 >= projected 1000 + 250 -> need 0, no recipient row, no writes.
out=$(run_jq '{"ceiling":24000,
  "orgs":[{"org_id":"r","name":"R","local_cap":2000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "K no recipients" '[]' "$(field "$out" '.recipients')"
assert_eq "K no writes" '[]' "$(field "$out" '.writes')"

# L. target_headroom clamps at 500 (hard rule 11): 900 -> 500; need = 1000+500-900 = 600.
out=$(run_jq '{"ceiling":24000,"target_headroom":900,
  "orgs":[{"org_id":"r","name":"R","local_cap":900,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "L clamped need" 600 "$(field "$out" '.recipients[0].need')"

# M. auto-need with run_rate: projected = 100 + 10*5 = 150, cap 100 -> need 150+250-100 = 300.
out=$(run_jq '{"ceiling":24000,"days_left":5,
  "orgs":[{"org_id":"r","name":"R","local_cap":100,"local_consumed":100,"run_rate":10},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "M forecast need" 300 "$(field "$out" '.recipients[0].need')"
```

- [ ] **Step 2: Run to verify failure** — `zsh claude/devin-acu-governor/test/org-rebalance.test.zsh`; expected: FAIL lines for H–M (jq errors on `"auto"` arithmetic / missing `slack_only`), existing A–G pass.
- [ ] **Step 3: Implement in `lib/org-rebalance.jq`**. Notes: move `$needs` resolution after `$orgs` so auto entries can read `projected`/`cap_before`; a need of 0 (auto resolved) must not create a recipient row (filter `need > 0` after resolution); in the greedy reduce, when `slack_only` is true skip donor draining entirely and set `$from_slack = min(slack, want)`; `$givers` then comes out empty; add `slack_only` to the output object; update the header comment.
- [ ] **Step 4: Run to verify pass** — `zsh claude/devin-acu-governor/test/org-rebalance.test.zsh`; expected `fail=0`. Also run `zsh claude/devin-acu-governor/test/run.zsh` to prove no regression.
- [ ] **Step 5: Commit** — `feat(dag): org-rebalance slack_only + auto-need for org-cap`

### Task 2: Playbook `org-cap.md` + policy docs

**Files:**
- Create: `claude/devin-acu-governor/playbooks/org-cap.md`
- Modify: `claude/devin-acu-governor/playbooks/_common.md` (the "Zero-sum org moves" bullet in "Org gate policy")
- Modify: `claude/devin-acu-governor/playbooks/all-commands.md` ("Existing command routing" list)

**Interfaces:**
- Consumes: Task 1 jq inputs (`slack_only`, `target_headroom`, `need: "auto"`), run-context lines produced by Task 3 (`org selector`, `requested amount`, `amount semantics`).
- Produces: playbook text containing the literal strings Task 3's CLI tests assert: `# Playbook: org-cap`, `ZERO-SUM`, `POOL HEADROOM`, `MIXED`.

- [ ] **Step 1: Write `playbooks/org-cap.md`.** Title line: `# Playbook: org-cap (change one org's Local Agent cap — funding mode always asked)`. Required content, in playbook step style matching `boost-org.md`/`slg.md`:
  1. **Resolve the org** — identical rule to `boost-org.md` step 1 (exact org_id, else exact case-insensitive name; ambiguous/missing → list orgs and stop).
  2. **Cycle + layer reads** — cycle dates + `days_left` (hard rule 9); for every org: ACU-limits GET, per-org Local Agent consumption (`cascade + terminal`), last-7-day `run_rate`; report Σ local + cloud vs ceiling and uncapped orgs.
  3. **Interpret the amount** (from Run context): `+N` → need N above current cap; absolute `N` → shrink / raise / no-op against `cap_before`; omitted → auto-need (`"need": "auto"`, `target_headroom` 250 default, 250–500 only on explicit in-session request, above 500 never — hard rule 11). Uncapped target: `+N` invalid → stop and ask for an absolute amount; absolute/omitted → model the target as `local_cap: 0` in the jq input and state in the preview that the first explicit cap counts as Σ growth and must be funded.
  4. **Shrink path** (absolute N < cap_before): no funding question; warn loudly when `N < ceil(local_consumed)` (members insta-blocked); preview (endpoint, old → new, body) → `CONFIRM DAG WRITE` → PATCH local key only → GET-verify → ledger `orgs` update → report. Shrinks are always allowed, even over the ceiling.
  5. **Raise guard:** if the layer is over the ceiling, refuse every raise mode and point at `dag slg`; only the shrink path may run.
  6. **Plan all three modes** with `org_rebalance_jq`, same input, target as the only `needs` entry: ZERO-SUM (`use_slack:false`), MIXED (`use_slack:true`), POOL HEADROOM (`slack_only:true`). Show each exact jq command + full JSON (hard rule 1).
  7. **Funding menu — always asked:** one comparison table (per mode: funded from donors, from slack, unfunded, Σ before → after vs ceiling, donor cuts count) then ask for exactly one keyword — `ZERO-SUM`, `POOL HEADROOM`, `MIXED`, or `CANCEL` — and stop for the reply. The keyword picks a plan; it never authorizes writes.
  8. **Preview the chosen plan:** recipient row (`cap_before → cap_after`, need, from_donors, from_slack, unfunded), donor table (`cap_before → cap_after`, given, floor), `sum_before → sum_after` vs ceiling, `warnings[]` verbatim, flag when the org's Σ member user-caps exceed the proposed org cap, UI instruction (hard rule 10). Stop; write only after `CONFIRM DAG WRITE` (hard rule 2).
  9. **PATCH + verify:** donor cuts before the raise; bodies carry only `local_agent`; GET-verify each; stop-on-first-failure with applied/failed/unattempted rows (hard rules 4, 8).
  10. **Ledger** `orgs` entries refresh; **report** incl. pointer to `dag slg` (whole-layer replan) and `dag set limit global <acus> [org]` (no-planning deterministic write).
- [ ] **Step 2: Update `_common.md`.** In the "Zero-sum org moves" bullet, after the `dag set limit global` sentence, add: `dag org-cap <org> [+acus|acus]` is the explicit single-org change flow — zero-sum by default, allowed to fund from pool headroom (`ceiling − Σ caps`) only through its explicit `POOL HEADROOM`/`MIXED` keyword choice, never past the ceiling, raise modes refused while the layer is over the ceiling. Keep the existing "never offer raise-to-Σ-member-caps / never clear" sentence intact.
- [ ] **Step 3: Update `all-commands.md`** routing list with one line: Use `dag org-cap <org_id|org_name> [+acus|acus]` to change one org's Local Agent cap with a funding-mode choice (`ZERO-SUM` donor orgs / `POOL HEADROOM` ceiling slack / `MIXED`), `CONFIRM DAG WRITE` gated.
- [ ] **Step 4: Verify** — `zsh claude/devin-acu-governor/test/run.zsh` still `all test files passed` (docs only; guards against accidental breakage).
- [ ] **Step 5: Commit** — `docs(dag): org-cap playbook + org-gate policy update`

### Task 3: `bin/dag` command wiring + CLI tests

**Files:**
- Modify: `claude/devin-acu-governor/bin/dag` (usage text, command dispatch, all-commands playbook loop)
- Test: `claude/devin-acu-governor/test/dag-cli.test.zsh`

**Interfaces:**
- Consumes: `playbooks/org-cap.md` (Task 2 — `dag_build_prompt` cats it).
- Produces: commands `dag org-cap <org> [amount]` and `dag org cap <org> [amount]`; run-context lines (exact strings): `requested shell command: ...`, `org selector: <selector>`, `requested amount: ...` (one of `+N ACUs above the current cap`, `set cap to N ACUs (absolute)`, `none — recommend via auto-need (projected + target headroom)`), `funding modes: always ask the user to choose ZERO-SUM, POOL HEADROOM, or MIXED before any preview; the choice is planning input only, never write authorization`, `amount is planning input only; every write still requires CONFIRM DAG WRITE`.

- [ ] **Step 1: Write failing tests** — append to `test/dag-cli.test.zsh` before `report` (match file's existing style):

```zsh
# org-cap: new org-gate change mode with funding choice.
out=$(run_dag org-cap "Platform Eng"); rc=$?
assert_exit "org-cap rc" 0 $rc
assert_contains "org-cap playbook" "$out" "# Playbook: org-cap"
assert_contains "org-cap selector" "$out" "org selector: Platform Eng"
assert_contains "org-cap recommend" "$out" "recommend via auto-need"
assert_contains "org-cap funding modes" "$out" "ZERO-SUM, POOL HEADROOM, or MIXED"
out=$(run_dag org cap "Platform Eng" +300); rc=$?
assert_exit "org cap two-word rc" 0 $rc
assert_contains "org cap delta" "$out" "+300 ACUs above the current cap"
out=$(run_dag org-cap "Platform Eng" 1200); rc=$?
assert_exit "org-cap absolute rc" 0 $rc
assert_contains "org-cap absolute" "$out" "set cap to 1200 ACUs (absolute)"
out=$(run_dag org-cap 2>&1); rc=$?; assert_exit "org-cap no org" 2 $rc
out=$(run_dag org-cap a@b.co 2>&1); rc=$?; assert_exit "org-cap email rejected" 2 $rc
out=$(run_dag org-cap "Platform Eng" xx 2>&1); rc=$?; assert_exit "org-cap bad amount" 2 $rc
out=$(run_dag org-cap "Platform Eng" +0 2>&1); rc=$?; assert_exit "org-cap zero delta" 2 $rc
out=$(run_dag org frobnicate 2>&1); rc=$?; assert_exit "org unknown subword" 2 $rc
out=$(run_dag 2>&1)
assert_contains "usage org-cap" "$out" "dag org-cap <org_id|org_name> [+acus|acus]"
out=$(run_dag all commands 2>&1)
assert_contains "all-commands includes org-cap" "$out" "# Playbook: org-cap"
```

- [ ] **Step 2: Run to verify failure** — `zsh claude/devin-acu-governor/test/dag-cli.test.zsh`; expected FAILs on the new asserts only.
- [ ] **Step 3: Implement in `bin/dag`.**
  - Helper `dag_org_cap_context() { # $1=invoked label, rest=args }` modeled on `dag_boost_org_context`: amount = last arg when it matches `(+|)<0->` (zsh: `[[ "$last" == (+|)<0-> ]]`), remaining words = selector; selector required, must not start with `-` or look like an email (`*@*.*`); then reject value 0 (`+0` and `0`) with exit 2 and the message that a zero cap is a block — direct the user to `dag set limit global 0 <org>`; sets `_dag_org_cap_context` lines per the Interfaces block.
  - Dispatch: `org-cap)` case; `org)` case requiring `"${1:-}" == "cap"` (else error `dag: unknown org command (expected: dag org cap <org_id|org_name> [+acus|acus])`, exit 2), then shift and share the helper. Both set `cmd="org-cap"`.
  - Usage block after the `dag slg` entry: `dag org-cap <org_id|org_name> [+acus|acus]` + two description lines (change one org's Local Agent cap; always asks funding mode ZERO-SUM / POOL HEADROOM / MIXED; `+N` raises by N, bare N sets absolute, omitted recommends) + alias line `dag org cap <org> [amount]`. Add one Examples line: `dag org-cap "Platform Eng" +300`.
  - `all-commands` playbook loop (line ~333): add `org-cap` to the list.
- [ ] **Step 4: Parse-check + run tests** — `zsh -n claude/devin-acu-governor/bin/dag` then `zsh claude/devin-acu-governor/test/run.zsh`; expected `all test files passed`.
- [ ] **Step 5: Commit** — `feat(dag): org-cap command — single-org gate change with funding choice`

### Task 4: README + final verification

**Files:**
- Modify: `claude/devin-acu-governor/README.md`

**Interfaces:**
- Consumes: final command surface from Task 3.

- [ ] **Step 1: Update README.** (a) Command table: add row `dag org-cap <org_id|org_name> [+acus|acus]` / `dag org cap <org> [amount]` — ✅ org limit + ledger — change one org's Local Agent cap via `lib/org-rebalance.jq`; always asks funding mode (`ZERO-SUM` donor orgs, zero-sum / `POOL HEADROOM` ceiling slack, Σ grows ≤ `DAG_MONTHLY_ACU_POOL` / `MIXED` donors then slack); `+N` delta, bare `N` absolute, omitted = projected + 250 recommendation; raises refused while the layer is over the ceiling; shrinks always allowed; `CONFIRM DAG WRITE` + live-GET verify. (b) "Org ceiling — zero-sum org gates" policy table: add row `Explicit single-org change | dag org-cap — zero-sum by default; pool-headroom growth only via its explicit keyword choice, ceiling-clamped.` (c) Check root `README.md` — update only if it enumerates dag commands.
- [ ] **Step 2: Full verification** — `zsh -n claude/devin-acu-governor/bin/dag && zsh claude/devin-acu-governor/test/run.zsh`; expected: `all test files passed`.
- [ ] **Step 3: Commit + push** — `docs(dag): README for org-cap mode`; then `git push` (AGENTS.md completion rule; branch `main`, personal identity `amit-t` matches remote).
