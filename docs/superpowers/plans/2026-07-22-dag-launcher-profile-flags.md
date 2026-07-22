# DAG Launcher Profile Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dag --co`, `dag --cf`, `dag --deo`, and `dag --def` launcher-profile selectors while preserving every existing DAG selector.

**Architecture:** Keep launcher selection inside the existing pre-command parser in `bin/dag`. Track whether the last selector came from `--agent` so canonical-agent validation stays narrow, then resolve direct profiles through four dedicated environment overrides. Prompt assembly and agent execution remain unchanged.

**Tech Stack:** zsh, existing DAG test harness, Markdown documentation, Git

---

### Task 1: Add failing CLI contract tests

**Files:**
- Modify: `claude/devin-acu-governor/test/dag-cli.test.zsh:55-64,274-319`

- [ ] **Step 1: Extend prompt-parity coverage**

Change the global-memory selector loop to:

```zsh
for agent_args in "" "--claude" "--codex" "--devin" "--co" "--cf" "--deo" "--def"; do
```

This proves every new launcher profile receives the same assembled DAG prompt and global instructions.

- [ ] **Step 2: Add launcher-resolution assertions**

After the existing `--devin` assertion, add:

```zsh
for profile in co cf deo def; do
  out=$(run_dag_launcher "--${profile}" status); rc=$?
  assert_exit "profile ${profile} rc" 0 $rc
  assert_eq "profile ${profile} launcher" "$profile" "$out"
done
```

- [ ] **Step 3: Add environment-override assertions**

After existing launcher override coverage, add:

```zsh
out=$(DAG_LAUNCHER_CO="my-co" run_dag_launcher --co status)
assert_eq "co launcher override" "my-co" "$out"
out=$(DAG_LAUNCHER_CF="my-cf" run_dag_launcher --cf status)
assert_eq "cf launcher override" "my-cf" "$out"
out=$(DAG_LAUNCHER_DEO="my-deo" run_dag_launcher --deo status)
assert_eq "deo launcher override" "my-deo" "$out"
out=$(DAG_LAUNCHER_DEF="my-def" run_dag_launcher --def status)
assert_eq "def launcher override" "my-def" "$out"
```

- [ ] **Step 4: Add validation, prompt-leak, and help assertions**

Add these assertions near existing invalid-agent and help coverage:

```zsh
out=$(run_dag_launcher --agent co status 2>&1); rc=$?
assert_exit "profile rejected as canonical agent rc" 2 $rc
assert_contains "profile rejected as canonical agent message" "$out" "claude, codex, devin"

for profile in co cf deo def; do
  out=$(PATH="${tmpdir}/bin:$PATH" DAG_PRINT_PROMPT=1 DEVIN_COG_KEY=k DEVIN_SERVICE_KEY=ws zsh "$dag" "--${profile}" status); rc=$?
  assert_exit "profile prompt rc ${profile}" 0 $rc
  assert_contains "profile prompt playbook ${profile}" "$out" "# Playbook: status"
  if [[ "$out" == *"--${profile}"* ]]; then _fail "--${profile} leaked into prompt"; else _ok; fi
done

out=$(run_dag help)
assert_contains "usage profile flags" "$out" "--co|--cf|--deo|--def"
assert_contains "usage profile launcher config" "$out" "DAG_LAUNCHER_CO"
```

- [ ] **Step 5: Run focused test and verify RED**

Run:

```zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
```

Expected: non-zero exit with failures showing the new flags are unknown, launcher output is missing, overrides do not resolve, and help lacks the new profile text. Existing assertions remain green.

### Task 2: Implement launcher-profile parsing and resolution

**Files:**
- Modify: `claude/devin-acu-governor/bin/dag:31-98,226-270`
- Test: `claude/devin-acu-governor/test/dag-cli.test.zsh`

- [ ] **Step 1: Document new selectors in CLI usage**

Update the usage preamble to include:

```text
  dag [--agent claude|codex|devin] [--co|--cf|--deo|--def] <command ...>
                              Pick the parent agent or model-pinned launcher profile
                              that runs the playbook session. Agent shorthands:
                              --claude/--codex/--devin. Profile flags:
                              --co/--cf/--deo/--def. Selectors go before the command.
```

Add examples for `dag --co status`, `dag --cf status`, `dag --deo status`, and `dag --def status`. Add configuration lines for `DAG_LAUNCHER_CO`, `DAG_LAUNCHER_CF`, `DAG_LAUNCHER_DEO`, and `DAG_LAUNCHER_DEF` with matching defaults.

- [ ] **Step 2: Extend launcher resolution**

Extend `dag_resolve_launcher` with exact mappings:

```zsh
    co)     print -r -- "${DAG_LAUNCHER_CO:-co}" ;;
    cf)     print -r -- "${DAG_LAUNCHER_CF:-cf}" ;;
    deo)    print -r -- "${DAG_LAUNCHER_DEO:-deo}" ;;
    def)    print -r -- "${DAG_LAUNCHER_DEF:-def}" ;;
```

- [ ] **Step 3: Parse profile flags without widening `--agent`**

Initialize selector source beside `agent`:

```zsh
  local agent="" selector_source=""
```

Set `selector_source="agent"` for `--agent` and `--agent=*`. Set `selector_source="shorthand"` for existing agent shorthands and the new profile shorthands. Add this parser arm:

```zsh
      --co|--cf|--deo|--def)
        agent="${1#--}"
        selector_source="shorthand"
        shift
        ;;
```

Replace post-parse validation with:

```zsh
  if [[ "$selector_source" == "agent" && -n "$agent" && "$agent" != (claude|codex|devin) ]]; then
    print -ru2 -- "dag: --agent expects one of claude, codex, devin (got: ${agent})"
    exit 2
  fi
  if [[ -n "$agent" && "$agent" != (claude|codex|devin|co|cf|deo|def) ]]; then
    print -ru2 -- "dag: unknown launcher selector: ${agent}"
    exit 2
  fi
```

The last selector still wins because both value and source are replaced together.

- [ ] **Step 4: Run focused test and verify GREEN**

Run:

```zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
```

Expected: `pass=<count> fail=0` and exit `0`.

- [ ] **Step 5: Parse-check implementation**

Run:

```zsh
zsh -n claude/devin-acu-governor/bin/dag
```

Expected: no output and exit `0`.

### Task 3: Document behavior and verify repository

**Files:**
- Modify: `claude/devin-acu-governor/README.md:5-10,475-490,573-585`
- Modify: `README.md:27`

- [ ] **Step 1: Update daemon README runtime and usage documentation**

Document the four exact mappings, before-command placement, unchanged canonical `--agent` values, and examples:

```zsh
dag --co status
dag --cf status
dag --deo status
dag --def status
```

Add configuration rows for the four `DAG_LAUNCHER_*` profile overrides.

- [ ] **Step 2: Update root daemon summary**

Expand the DAG entry in root `README.md` to name `--co`, `--cf`, `--deo`, and `--def` and their exact launcher commands while retaining existing selector documentation.

- [ ] **Step 3: Run full verification**

Run:

```zsh
zsh claude/devin-acu-governor/test/run.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/lib/*.zsh
git diff --check
```

Expected: every test file reports `fail=0`, runner prints `all test files passed`, both syntax commands exit `0`, and `git diff --check` prints nothing.

- [ ] **Step 4: Inspect final diff and commit scoped work**

Run:

```zsh
git status --short
git diff -- claude/devin-acu-governor/bin/dag claude/devin-acu-governor/test/dag-cli.test.zsh claude/devin-acu-governor/README.md README.md docs/superpowers/plans/2026-07-22-dag-launcher-profile-flags.md
git add -- claude/devin-acu-governor/bin/dag claude/devin-acu-governor/test/dag-cli.test.zsh claude/devin-acu-governor/README.md README.md docs/superpowers/plans/2026-07-22-dag-launcher-profile-flags.md
git commit -m "feat(dag): support model-pinned launcher flags"
```

Expected: only intentional files are staged; commit succeeds.

- [ ] **Step 5: Push and verify synchronization**

Run:

```zsh
git push origin HEAD
git status --short --branch
```

Expected: push succeeds and branch reports synchronized with its upstream with no working-tree changes.
