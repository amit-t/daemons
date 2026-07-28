# AICO Daemon Poller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AICO's detached daemon proactively poll Claude and Devin every 60s, persist meaningful events, safely nudge Codex, and handle Claude auto-resume inside the same daemon.

**Architecture:** Keep the existing Claude auto-resume state as the durable shared state, extend it with generic agent registrations, poll snapshots, unread event inbox entries, and Codex notice throttling. The daemon discovers Claude/Devin-titled panes each tick, classifies screens, records only meaningful transitions/blockers, and sends Codex a fixed `AICO_DAEMON_NOTICE_V1` envelope instead of raw agent text.

**Tech Stack:** Bun, TypeScript, cMUX CLI, zsh wrappers.

---

### Task 1: Protocol and event inbox tests

**Files:**
- Modify: `codex/ai-cmux-orchestrator/test/ai-cmux-orchestrator-auto-resume.test.ts`
- Modify: `codex/ai-cmux-orchestrator/test/ai-cmux-orchestrator-devin-poll.test.ts`
- Modify: `codex/ai-cmux-orchestrator/test/ai-cmux-orchestrator-args.test.ts`
- Modify: `codex/ai-cmux-orchestrator/test/ai-cmux-orchestrator-cli.test.ts`

- [ ] Write failing tests for `AICO_DAEMON_NOTICE_V1`, JSONL unread event output, title discovery, and 60s default poll interval.
- [ ] Run targeted tests and confirm failures are due missing new API/behavior.

### Task 2: Extend durable state and scanner

**Files:**
- Modify: `codex/ai-cmux-orchestrator/src/ai-cmux-orchestrator/claude-auto-resume.ts`
- Modify: `codex/ai-cmux-orchestrator/src/ai-cmux-orchestrator/devin-poll.ts`
- Modify: `codex/ai-cmux-orchestrator/src/ai-cmux-orchestrator/watcher-daemon.ts`

- [ ] Add agent registrations, snapshots, inbox events, state classifier, blocker reminder throttling, and Codex notice sender.
- [ ] Keep Claude usage-limit detection feeding existing auto-resume jobs.
- [ ] Preserve existing Claude health guard and auto-resume behavior.
- [ ] Run targeted tests and fix to green.

### Task 3: CLI, prompt, docs

**Files:**
- Modify: `codex/ai-cmux-orchestrator/src/ai-cmux-orchestrator/args.ts`
- Modify: `codex/ai-cmux-orchestrator/ai-cmux-orchestrator`
- Modify: `codex/ai-cmux-orchestrator/src/ai-cmux-orchestrator/orchestrator.ts`
- Modify: `codex/ai-cmux-orchestrator/README.md`
- Modify: `README.md`

- [ ] Add `aico --events --unread` JSONL output with read-marking.
- [ ] Register Codex, Claude, and discovered Devin surfaces; Devin disabled only on explicit false.
- [ ] Update orchestrator prompt with daemon notice parsing rules.
- [ ] Document daemon poller, event inbox, protocol, and verification.

### Task 4: Verification

**Files:**
- All modified files.

- [ ] Run `bun test`.
- [ ] Run `bun run typecheck`.
- [ ] Run `zsh -n bin/aico` and `zsh -n bin/ai-cmux-orchestrator`.
- [ ] Run `bun ai-cmux-orchestrator --help`, `bun ai-cmux-orchestrator --status`, and `bun ai-cmux-orchestrator --events --unread`.
