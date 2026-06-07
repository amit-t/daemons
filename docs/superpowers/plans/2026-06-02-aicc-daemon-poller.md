# AICC Daemon Poller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AICC's detached daemon proactively poll Claude and Devin every 60s, persist meaningful events, safely nudge Codex, and handle Claude auto-resume inside the same daemon.

**Architecture:** Keep the existing Claude auto-resume state as the durable shared state, extend it with generic agent registrations, poll snapshots, unread event inbox entries, and Codex notice throttling. The daemon discovers Claude/Devin-titled panes each tick, classifies screens, records only meaningful transitions/blockers, and sends Codex a fixed `AICC_DAEMON_NOTICE_V1` envelope instead of raw agent text.

**Tech Stack:** Bun, TypeScript, cMUX CLI, zsh wrappers.

---

### Task 1: Protocol and event inbox tests

**Files:**
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-auto-resume.test.ts`
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-devin-poll.test.ts`
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-args.test.ts`
- Modify: `codex/ai-cmux-conductor/test/ai-cmux-conductor-cli.test.ts`

- [ ] Write failing tests for `AICC_DAEMON_NOTICE_V1`, JSONL unread event output, title discovery, and 60s default poll interval.
- [ ] Run targeted tests and confirm failures are due missing new API/behavior.

### Task 2: Extend durable state and scanner

**Files:**
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/claude-auto-resume.ts`
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/devin-poll.ts`
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/watcher-daemon.ts`

- [ ] Add agent registrations, snapshots, inbox events, state classifier, blocker reminder throttling, and Codex notice sender.
- [ ] Keep Claude usage-limit detection feeding existing auto-resume jobs.
- [ ] Preserve existing Claude health guard and auto-resume behavior.
- [ ] Run targeted tests and fix to green.

### Task 3: CLI, prompt, docs

**Files:**
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/args.ts`
- Modify: `codex/ai-cmux-conductor/ai-cmux-conductor`
- Modify: `codex/ai-cmux-conductor/src/ai-cmux-conductor/conductor.ts`
- Modify: `codex/ai-cmux-conductor/README.md`
- Modify: `README.md`

- [ ] Add `aicc --events --unread` JSONL output with read-marking.
- [ ] Register Codex, Claude, and discovered Devin surfaces; Devin disabled only on explicit false.
- [ ] Update orchestrator prompt with daemon notice parsing rules.
- [ ] Document daemon poller, event inbox, protocol, and verification.

### Task 4: Verification

**Files:**
- All modified files.

- [ ] Run `bun test`.
- [ ] Run `bun run typecheck`.
- [ ] Run `zsh -n bin/aicc` and `zsh -n bin/ai-cmux-conductor`.
- [ ] Run `bun ai-cmux-conductor --help`, `bun ai-cmux-conductor --status`, and `bun ai-cmux-conductor --events --unread`.
