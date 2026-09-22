# DAG Defu Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `defu` as a configurable DAG launcher profile, exposed through `dag --defu` and `dag--defu`, for every agent-driven DAG command.

**Architecture:** Extend DAG’s shared pre-command launcher selection so one profile automatically covers every agent-driven command without changing command routing or prompt assembly. Resolve the profile to `${DAG_LAUNCHER_DEFU:-DEFU_YOLO=1 defu}`, apply the Devin-family `--` separator, and leave local-only commands on their existing early-return paths.

**Tech Stack:** zsh, repository test harness, Markdown

---

## File Structure

- `claude/devin-acu-governor/test/dag-cli.test.zsh`: selector, launcher, prompt, local-command, help, and wrapper regression coverage.
- `claude/devin-acu-governor/bin/dag`: global selector parsing, validation, launcher resolution, separator classification, help, examples, and configuration output.
- `aliases.zsh`: global `dag--defu` forwarding wrapper.
- `claude/devin-acu-governor/README.md`: complete Defu profile behavior and configuration reference.
- `README.md`: repository catalog entry for the new profile and wrapper.

### Task 1: Add Failing Defu CLI and Wrapper Tests

**Files:**
- Modify: `claude/devin-acu-governor/test/dag-cli.test.zsh:58,465-538`

- [ ] **Step 1: Extend prompt parity coverage**

Replace:

```zsh
for agent_args in "" "--claude" "--codex" "--devin" "--co" "--cf" "--deo" "--def" "--des" "--del" "--det" "--dey"; do
```

with:

```zsh
for agent_args in "" "--claude" "--codex" "--devin" "--co" "--cf" "--deo" "--def" "--des" "--del" "--det" "--dey" "--defu"; do
```

- [ ] **Step 2: Add launcher, override, default-classification, local-command, prompt, help, and wrapper assertions**

Insert after the existing `deo def des del det dey` launcher loop:

```zsh
out=$(run_dag_launcher --defu status); rc=$?
assert_exit "profile defu rc" 0 $rc
assert_eq "profile defu launcher" "DEFU_YOLO=1 defu --" "$out"
```

Insert after the existing `DAG_LAUNCHER_DEY` override assertion:

```zsh
out=$(DAG_LAUNCHER_DEFU="my-defu --mode" run_dag_launcher --defu status)
assert_eq "defu launcher override" "my-defu --mode --" "$out"
```

Insert after the existing default `deo` classification assertion:

```zsh
out=$(DAG_LAUNCHER="DEFU_YOLO=1 defu" run_dag_launcher status)
assert_eq "defu-like default launcher gets --" "DEFU_YOLO=1 defu --" "$out"
```

Insert after the canonical Devin single-separator assertion:

```zsh
out=$(run_dag --defu setup-extract); rc=$?
assert_exit "defu local setup-extract rc" 0 $rc
assert_contains "defu local setup-extract stays local" "$out" "security add-generic-password"
```

Replace:

```zsh
for profile in co cf deo def des del det; do
```

with:

```zsh
for profile in co cf deo def des del det defu; do
```

Insert with the existing help assertions:

```zsh
assert_contains "usage defu profile flag" "$out" "--defu"
assert_contains "usage defu launcher config" "$out" "DAG_LAUNCHER_DEFU"
```

Insert before `report`:

```zsh
source "${script_dir}/../../../aliases.zsh"
dag() { print -r -- "${(j:|:)@}" }
out=$(dag--defu status --group "Platform Eng"); rc=$?
assert_exit "dag--defu wrapper rc" 0 $rc
assert_eq "dag--defu wrapper forwarding" "--defu|status|--group|Platform Eng" "$out"
```

- [ ] **Step 3: Run the focused test and observe the expected failure**

Run:

```zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
```

Expected: non-zero with Defu assertions failing because `--defu` and `dag--defu` do not exist. Existing assertions before the new coverage remain green.

### Task 2: Implement the Shared Defu Launcher Profile

**Files:**
- Modify: `claude/devin-acu-governor/bin/dag:31-39,131-169,306-336,344-383`
- Modify: `aliases.zsh:63-70`
- Test: `claude/devin-acu-governor/test/dag-cli.test.zsh`

- [ ] **Step 1: Extend DAG usage and examples**

Change the usage selector list to:

```text
  dag [--agent claude|codex|devin] [--co|--cf|--deo|--def|--des|--del|--det|--dey|--defu] <command ...>
```

Change the profile description to:

```text
                              --co/--cf (Claude Opus/Fable), --deo/--def (Devin
                              Opus/Fable), --des/--del/--det (Devin GPT-5.6
                              Sol/Luna/Terra), --dey (Devin default model),
                              --defu (cheapest enabled Fusion pair via DEFU_YOLO=1 defu).
```

Add this example after `dag --dey set-limits-new`:

```text
  dag --defu status
```

Add this configuration line after `DAG_LAUNCHER_DEY`:

```text
  DAG_LAUNCHER_DEFU          launcher for --defu (default: DEFU_YOLO=1 defu; cheapest enabled Fusion pair)
```

- [ ] **Step 2: Add resolver and separator support**

Add this resolver branch after `dey`:

```zsh
    defu)   print -r -- "${DAG_LAUNCHER_DEFU:-DEFU_YOLO=1 defu}" ;;
```

Change explicit Devin-family classification to:

```zsh
    devin|deo|def|des|del|det|dey|defu) return 0 ;;
```

Change default-launcher command-text detection to:

```zsh
      [[ "$l" == (deo|def|des|del|det|dey|defu|devin|devinc)* || "$l" == *devin* ]] && return 0
```

- [ ] **Step 3: Add selector parsing and validation**

Change the profile selector branch to:

```zsh
      --co|--cf|--deo|--def|--des|--del|--det|--dey|--defu)
```

Change known-selector validation to:

```zsh
  if [[ -n "$agent" && "$agent" != (claude|codex|devin|co|cf|deo|def|des|del|det|dey|defu) ]]; then
```

Keep canonical `--agent` validation unchanged.

- [ ] **Step 4: Add the global forwarding wrapper**

Add after `dag--devin`:

```zsh
dag--defu()   { dag --defu "$@" }
```

- [ ] **Step 5: Parse-check changed zsh files**

Run:

```zsh
zsh -n aliases.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/test/dag-cli.test.zsh
```

Expected: all commands exit `0` with no output.

- [ ] **Step 6: Run the focused test and observe green**

Run:

```zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
```

Expected: exit `0`, `0 failed`.

### Task 3: Document Defu Across Both README Surfaces

**Files:**
- Modify: `claude/devin-acu-governor/README.md:5-25,702-715`
- Modify: `README.md:28`

- [ ] **Step 1: Update daemon runtime behavior**

In `claude/devin-acu-governor/README.md`, extend the parent-agent wrapper list to include `dag--defu`, and extend the Devin-family separator list to include `--defu`.

Extend the launcher-profile paragraph with this sentence:

```markdown
`--defu` launches the cheapest enabled Devin Fusion pair through `DEFU_YOLO=1 defu`; Defu owns dynamic pair selection plus its precision, boil-the-ocean, and caveman prompt, while DAG supplies the unchanged command playbook after `--`.
```

Add this launcher example:

```zsh
dag --defu status
```

- [ ] **Step 2: Add configuration reference**

Add this row after `DAG_LAUNCHER_DEY`:

```markdown
| `DAG_LAUNCHER_DEFU` | `DEFU_YOLO=1 defu` | Cheapest-enabled-Fusion Devin launcher used by `--defu`; DAG appends `--` before its assembled prompt |
```

- [ ] **Step 3: Update repository catalog**

In the root `README.md` DAG catalog entry, add `--defu` → `DEFU_YOLO=1 defu` (cheapest enabled Fusion pair) to the launcher-profile list and state that `dag--defu` is the global wrapper.

- [ ] **Step 4: Check documentation diff**

Run:

```zsh
git diff --check
```

Expected: exit `0` with no output.

### Task 4: Full Verification and Scoped Commit

**Files:**
- Verify all modified files and both planning artifacts.

- [ ] **Step 1: Run complete required verification**

Run:

```zsh
zsh -n aliases.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/test/dag-cli.test.zsh
zsh claude/devin-acu-governor/test/dag-cli.test.zsh
zsh claude/devin-acu-governor/test/run.zsh
git diff --check
```

Expected: every command exits `0`; focused and full suites report `0` failures.

- [ ] **Step 2: Inspect the complete scoped diff**

Run:

```zsh
git status --short
git diff -- aliases.zsh README.md claude/devin-acu-governor/bin/dag claude/devin-acu-governor/test/dag-cli.test.zsh claude/devin-acu-governor/README.md docs/superpowers/plans/2026-09-22-dag-defu-launcher.md
```

Expected: only the six listed implementation, test, documentation, and plan files differ from the committed design baseline; no secrets, generated credentials, or unrelated changes.

- [ ] **Step 3: Commit the scoped implementation**

```zsh
git add aliases.zsh README.md claude/devin-acu-governor/bin/dag claude/devin-acu-governor/test/dag-cli.test.zsh claude/devin-acu-governor/README.md docs/superpowers/plans/2026-09-22-dag-defu-launcher.md
git commit -m "feat(dag): add defu launcher profile"
```

- [ ] **Step 4: Push the feature branch**

```zsh
git push -u origin HEAD
```

Expected: branch `feat/dag-defu-launcher` tracks `origin/feat/dag-defu-launcher`.
