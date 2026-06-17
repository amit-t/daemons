# AICC Default Kid-Panel Goal Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AICC base orchestrators attempt kid-panel decomposition for ordinary tasks and require every delegated kid-panel assignment to be marked as a goal.

**Architecture:** This is a prompt-contract change in `buildOrchestratorPrompt`; no runtime dispatcher is added. Tests assert the generated prompt includes default orchestration and goal-marking rules only when managed kid panels are enabled. README files document the new default behavior.

**Tech Stack:** TypeScript, Bun test runner, zsh wrapper syntax checks.

---

### Task 1: Prompt contract test

**Files:**
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-panels.test.ts`

- [ ] **Step 1: Write the failing test**

Add this test in `describe("buildOrchestratorPrompt panel routing", ...)` after the explicit kid-pane routing test:

```ts
test("tells the orchestrator to decompose ordinary tasks across enabled kid panels and require goal marking", () => {
  const prompt = buildOrchestratorPrompt({
    cwd: "/repo",
    workspaceId: "workspace:1",
    workspaceName: "Repo",
    orchestratorSurfaceId: "surface:base",
    claudeSurfaceId: "surface:claude",
    codexPanelSurfaceId: "surface:codex-panel",
    devinSurfaceId: "surface:devin",
    claudePanelEnabled: true,
    codexPanelEnabled: true,
    devinPanelEnabled: true,
    reusedClaude: false,
    reusedCodexPanel: false,
    reusedDevin: false,
  });

  expect(prompt).toContain("Default orchestration for ordinary tasks");
  expect(prompt).toContain("For every non-trivial Amit task, first attempt to decompose it into independent chunks for enabled kid panels");
  expect(prompt).toContain("mark that assigned work as a goal before doing it");
  expect(prompt).toContain("Goal instruction: tell the kid agent to create or mark a goal for its assignment before it starts work");
  expect(prompt).toContain("base orchestrator owns decomposition, routing, progress checks, integration, and final response");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```zsh
cd codex/ai-cmux-conductor && bun test test/ai-cmux-conductor-panels.test.ts --test-name-pattern "decompose ordinary tasks"
```

Expected: FAIL because prompt does not contain `Default orchestration for ordinary tasks`.

### Task 2: Prompt implementation

**Files:**
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/conductor.ts`

- [ ] **Step 1: Implement minimal prompt text**

In `buildOrchestratorPrompt`, add a `defaultOrchestrationRules` string near `kidRoutingRules`. When enabled kid panels exist, include explicit rules for default decomposition, delegation, goal marking, skip cases, and base orchestrator synthesis. When no kid panels are enabled, omit this section.

- [ ] **Step 2: Run focused test to verify it passes**

Run:

```zsh
cd codex/ai-cmux-conductor && bun test test/ai-cmux-conductor-panels.test.ts --test-name-pattern "decompose ordinary tasks"
```

Expected: PASS.

### Task 3: Disabled-panels regression

**Files:**
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-panels.test.ts`

- [ ] **Step 1: Extend existing disabled-panels test**

In `omits kid-pane routing and background sections when no side agents are enabled`, add:

```ts
expect(prompt).not.toContain("Default orchestration for ordinary tasks");
expect(prompt).not.toContain("mark that assigned work as a goal before doing it");
```

- [ ] **Step 2: Run focused panel tests**

Run:

```zsh
cd codex/ai-cmux-conductor && bun test test/ai-cmux-conductor-panels.test.ts
```

Expected: all panel tests pass.

### Task 4: Documentation

**Files:**
- Modify: `codex/ai-cmux-conductor/README.md`
- Modify: `README.md`

- [ ] **Step 1: Update daemon README**

Document that ordinary non-trivial tasks default to decomposition across enabled kid panels and that delegated prompts must include goal marking.

- [ ] **Step 2: Update root README**

Update the AICC repository summary to mention default kid-panel orchestration and goal-marking assignments.

### Task 5: Verification and commit

**Files:**
- Verify all touched files.

- [ ] **Step 1: Run full tests**

```zsh
cd codex/ai-cmux-conductor && bun test
```

Expected: 0 failures.

- [ ] **Step 2: Run typecheck**

```zsh
cd codex/ai-cmux-conductor && bun run typecheck
```

Expected: exit 0.

- [ ] **Step 3: Run zsh parse checks**

```zsh
zsh -n aliases.zsh
zsh -n codex/ai-cmux-conductor/bin/aicc
zsh -n codex/ai-cmux-conductor/bin/ai-cmux-conductor
```

Expected: exit 0 for each command.

- [ ] **Step 4: Commit and push**

```zsh
git status --short
git add README.md docs/superpowers/specs/2026-06-17-aicc-default-kid-goals-design.md docs/superpowers/plans/2026-06-17-aicc-default-kid-goals.md codex/ai-cmux-conductor/README.md codex/ai-cmux-conductor/src/ai-cmux-conductor/conductor.ts codex/ai-cmux-conductor/test/ai-cmux-conductor-panels.test.ts
git commit -m "feat(aicc): default kid-panel goal orchestration"
git push -u origin HEAD
```
