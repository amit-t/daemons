import { describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FileClaudeAutoResumeStore,
  createEmptyClaudeAutoResumeState,
  detectClaudeUsageLimit,
  processDueClaudeAutoResumeJobs,
  scanClaudeSurfacesOnce,
  scheduleClaudeAutoResumeJob,
  type ClaudeAutoResumeState,
} from "../src/ai-cmux-conductor/claude-auto-resume.ts";
import type { CommandRunner } from "../src/ai-cmux-conductor/conductor.ts";

type RunnerResponse = { code?: number; stdout?: string; stderr?: string };

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function treeWithClaude(surfaceRef: string, title = "Claude"): string {
  return JSON.stringify({
    windows: [
      {
        ref: "window:1",
        id: "window-uuid",
        workspaces: [
          {
            ref: "workspace:1",
            id: "workspace-uuid",
            title: "Project-X",
            panes: [
              {
                ref: "pane:claude",
                surfaces: [{ id: `${surfaceRef}-uuid`, ref: surfaceRef, title, type: "terminal", pane_ref: "pane:claude" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

function commandKey(args: string[]): string {
  return args.join(" ");
}

function strictRunnerFor(responses: Record<string, RunnerResponse | RunnerResponse[]>): { runner: CommandRunner; calls: string[][] } {
  const calls: string[][] = [];
  const queues = new Map(
    Object.entries(responses).map(([key, value]) => [key, Array.isArray(value) ? value.slice() : [value]]),
  );
  return {
    calls,
    runner: async (cmd, args) => {
      const call = [cmd, ...args];
      calls.push(call);
      const key = call.join(" ");
      const queue = queues.get(key);
      if (!queue?.length) {
        return { code: 99, stdout: "", stderr: `unexpected call: ${key}` };
      }
      const response = queue.shift()!;
      return { code: response.code ?? 0, stdout: response.stdout ?? "", stderr: response.stderr ?? "" };
    },
  };
}

describe("Claude usage-limit detection", () => {
  test("parses resets 10:50pm (Asia/Calcutta) and schedules continue one minute later", () => {
    const now = new Date("2026-06-02T15:00:00.000Z");
    const detection = detectClaudeUsageLimit(
      "You've hit your session limit · resets 10:50pm (Asia/Calcutta)",
      now,
      "Asia/Kolkata",
    );

    expect(detection).toBeDefined();
    expect(detection?.timeZone).toBe("Asia/Kolkata");
    expect(detection?.resetAt).toBe("2026-06-02T17:20:00.000Z");
    expect(detection?.sendAt).toBe("2026-06-02T17:21:00.000Z");
    expect(detection?.sourceExcerpt).toContain("session limit");
  });

  test("parses uppercase and lowercase AM/PM reset times", () => {
    const now = new Date("2026-06-02T00:00:00.000Z");

    expect(detectClaudeUsageLimit("usage limit resets 7:05 AM", now, "Asia/Kolkata")?.resetAt).toBe(
      "2026-06-02T01:35:00.000Z",
    );
    expect(detectClaudeUsageLimit("session limit resets 7:05 pm", now, "Asia/Kolkata")?.resetAt).toBe(
      "2026-06-02T13:35:00.000Z",
    );
  });

  test("schedules tomorrow when same-day reset time has already passed", () => {
    const now = new Date("2026-06-02T18:00:00.000Z");

    const detection = detectClaudeUsageLimit("You've hit your session limit · resets 10:50pm (Asia/Kolkata)", now);

    expect(detection?.resetAt).toBe("2026-06-03T17:20:00.000Z");
    expect(detection?.sendAt).toBe("2026-06-03T17:21:00.000Z");
  });

  test("normalizes Asia/Calcutta to Asia/Kolkata", () => {
    const detection = detectClaudeUsageLimit("usage limit resets 10:50 PM (Asia/Calcutta)", new Date("2026-06-02T12:00:00.000Z"));

    expect(detection?.timeZone).toBe("Asia/Kolkata");
  });
});

describe("Claude auto-resume scheduler", () => {

  test("file store persists scheduled jobs across daemon restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "aicc-auto-resume-"));
    try {
      const store = new FileClaudeAutoResumeStore(join(dir, "state.json"));
      const state = createEmptyClaudeAutoResumeState();
      const registration = {
        workspaceId: "workspace-uuid",
        windowId: "window-uuid",
        surfaceId: "surface:claude",
        agentIdentity: "Claude",
        workspaceName: "Project-X",
        updatedAt: "2026-06-02T15:00:00.000Z",
      };
      const detection = detectClaudeUsageLimit(
        "You've hit your session limit · resets 10:50pm (Asia/Calcutta)",
        new Date("2026-06-02T15:00:00.000Z"),
      );
      if (!detection) throw new Error("expected detection");

      scheduleClaudeAutoResumeJob(state, registration, detection, new Date("2026-06-02T15:00:00.000Z"));
      await store.save(state);

      const reloaded = await store.load();

      expect(reloaded.jobs).toHaveLength(1);
      expect(reloaded.jobs[0].workspaceId).toBe("workspace-uuid");
      expect(reloaded.jobs[0].sendAt).toBe("2026-06-02T17:21:00.000Z");
      expect(reloaded.jobs[0].status).toBe("pending");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("deduplicates duplicate limit messages by workspace, agent identity, and reset time", () => {
    const state = createEmptyClaudeAutoResumeState();
    const registration = {
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      surfaceId: "surface:claude",
      agentIdentity: "Claude",
      workspaceName: "Project-X",
      updatedAt: "2026-06-02T15:00:00.000Z",
    };
    const detection = detectClaudeUsageLimit(
      "You've hit your session limit · resets 10:50pm (Asia/Calcutta)",
      new Date("2026-06-02T15:00:00.000Z"),
    );
    if (!detection) throw new Error("expected detection");

    const first = scheduleClaudeAutoResumeJob(state, registration, detection, new Date("2026-06-02T15:00:00.000Z"));
    const second = scheduleClaudeAutoResumeJob(state, registration, detection, new Date("2026-06-02T15:01:00.000Z"));

    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(state.jobs).toHaveLength(1);
    expect(state.jobs[0].message).toBe("continue\n");
  });

  test("re-resolves stale Claude surface before sending continue", async () => {
    const state: ClaudeAutoResumeState = {
      ...createEmptyClaudeAutoResumeState(),
      jobs: [
        {
          id: "job-1",
          workspaceId: "workspace-uuid",
          windowId: "window-uuid",
          agentIdentity: "Claude",
          surfaceId: "surface:stale",
          resetAt: "2026-06-02T17:20:00.000Z",
          sendAt: "2026-06-02T17:21:00.000Z",
          message: "continue\n",
          sourceExcerpt: "session limit resets 10:50pm",
          status: "pending",
          attempts: 0,
          createdAt: "2026-06-02T15:00:00.000Z",
          updatedAt: "2026-06-02T15:00:00.000Z",
        },
      ],
    };
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithClaude("surface:new-claude") },
      [commandKey(["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:new-claude", "--", "continue\n"])]: { stdout: "sent" },
    });

    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:21:00.000Z"));

    expect(state.jobs[0].status).toBe("sent");
    expect(state.jobs[0].surfaceId).toBe("surface:new-claude");
    expect(calls.at(-1)).toEqual(["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:new-claude", "--", "continue\n"]);
  });

  test("sends overdue pending job after daemon restart when within grace window", async () => {
    const state = createEmptyClaudeAutoResumeState();
    state.jobs.push({
      id: "job-1",
      workspaceId: "workspace-uuid",
      agentIdentity: "Claude",
      surfaceId: "surface:claude",
      resetAt: "2026-06-02T17:20:00.000Z",
      sendAt: "2026-06-02T17:21:00.000Z",
      message: "continue\n",
      sourceExcerpt: "usage limit resets 10:50pm",
      status: "pending",
      attempts: 0,
      createdAt: "2026-06-02T15:00:00.000Z",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const { runner } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid": { stdout: treeWithClaude("surface:claude") },
      [commandKey(["cmux", "send", "--workspace", "workspace-uuid", "--surface", "surface:claude", "--", "continue\n"])]: { stdout: "sent" },
    });

    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:30:00.000Z"));

    expect(state.jobs[0].status).toBe("sent");
    expect(state.jobs[0].sentAt).toBe("2026-06-02T17:30:00.000Z");
  });


  test("marks overdue pending job stale after restart when beyond grace window", async () => {
    const state = createEmptyClaudeAutoResumeState();
    state.jobs.push({
      id: "job-stale",
      workspaceId: "workspace-uuid",
      agentIdentity: "Claude",
      surfaceId: "surface:claude",
      resetAt: "2026-06-02T17:20:00.000Z",
      sendAt: "2026-06-02T17:21:00.000Z",
      message: "continue\n",
      sourceExcerpt: "usage limit resets 10:50pm",
      status: "pending",
      attempts: 0,
      createdAt: "2026-06-02T15:00:00.000Z",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const { runner, calls } = strictRunnerFor({});

    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:52:00.000Z"));

    expect(state.jobs[0].status).toBe("stale");
    expect(state.jobs[0].lastError).toContain("30 minute grace window");
    expect(calls).toEqual([]);
  });

  test("failed send retries three times over two minutes and records final error", async () => {
    const state = createEmptyClaudeAutoResumeState();
    state.jobs.push({
      id: "job-1",
      workspaceId: "workspace-uuid",
      agentIdentity: "Claude",
      surfaceId: "surface:claude",
      resetAt: "2026-06-02T17:20:00.000Z",
      sendAt: "2026-06-02T17:21:00.000Z",
      message: "continue\n",
      sourceExcerpt: "usage limit resets 10:50pm",
      status: "pending",
      attempts: 0,
      createdAt: "2026-06-02T15:00:00.000Z",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const { runner } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid": [
        { stdout: treeWithClaude("surface:claude") },
        { stdout: treeWithClaude("surface:claude") },
        { stdout: treeWithClaude("surface:claude") },
      ],
      [commandKey(["cmux", "send", "--workspace", "workspace-uuid", "--surface", "surface:claude", "--", "continue\n"])]: [
        { code: 1, stderr: "pane busy" },
        { code: 1, stderr: "pane still busy" },
        { code: 1, stderr: "pane gone" },
      ],
    });

    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:21:00.000Z"));
    expect(state.jobs[0].status).toBe("pending");
    expect(state.jobs[0].attempts).toBe(1);
    expect(state.jobs[0].nextAttemptAt).toBe("2026-06-02T17:22:00.000Z");

    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:22:00.000Z"));
    await processDueClaudeAutoResumeJobs(state, runner, new Date("2026-06-02T17:23:00.000Z"));

    expect(state.jobs[0].status).toBe("failed");
    expect(state.jobs[0].attempts).toBe(3);
    expect(state.jobs[0].lastError).toBe("cmux send failed: pane gone");
  });
});

describe("Claude auto-resume fake cMUX integration", () => {
  test("detects limit screen, creates durable job, and sends continue at reset plus sixty seconds", async () => {
    const now = new Date("2026-06-02T15:00:00.000Z");
    const state = createEmptyClaudeAutoResumeState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      surfaceId: "surface:claude",
      agentIdentity: "Claude",
      updatedAt: iso(now.getTime()),
    });
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithClaude("surface:claude") },
        { stdout: treeWithClaude("surface:claude") },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 160": {
        stdout: "You've hit your session limit · resets 10:50pm (Asia/Calcutta)\n",
      },
      [commandKey(["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", "--", "continue\n"])]: { stdout: "sent" },
    });

    await scanClaudeSurfacesOnce(state, runner, now);
    expect(state.jobs).toHaveLength(1);
    expect(state.jobs[0].sendAt).toBe("2026-06-02T17:21:00.000Z");

    await processDueClaudeAutoResumeJobs(state, runner, new Date(state.jobs[0].sendAt));

    expect(state.jobs[0].status).toBe("sent");
    expect(calls.at(-1)).toEqual(["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", "--", "continue\n"]);
  });
});
