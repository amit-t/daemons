import { describe, expect, test } from "bun:test";
import {
  buildAiccDaemonNotice,
  createEmptyDevinPollState,
  detectDevinInputRequest,
  formatDevinPollSitrep,
  formatUnreadDevinPollEventsJsonl,
  registerDevinPollFromConductorContext,
  scanDevinSurfacesOnce,
  type DevinPollState,
} from "../src/ai-cmux-conductor/devin-poll.ts";
import type { CommandRunner } from "../src/ai-cmux-conductor/conductor.ts";

type RunnerResponse = { code?: number; stdout?: string; stderr?: string };

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

function treeWithCodexAndDevin(): string {
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
                ref: "pane:codex",
                surfaces: [{ id: "surface:codex-uuid", ref: "surface:codex", title: "codex", type: "terminal", pane_ref: "pane:codex" }],
              },
              {
                ref: "pane:devin",
                surfaces: [{ id: "surface:devin-uuid", ref: "surface:devin", title: "kid-devin", type: "terminal", pane_ref: "pane:devin" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

function treeWithCodexClaudeAndDevin(): string {
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
                ref: "pane:codex",
                surfaces: [{ id: "surface:codex-uuid", ref: "surface:codex", title: "codex", type: "terminal", pane_ref: "pane:codex" }],
              },
              {
                ref: "pane:claude",
                surfaces: [{ id: "surface:claude-uuid", ref: "surface:claude", title: "kid-claude", type: "terminal", pane_ref: "pane:claude" }],
              },
              {
                ref: "pane:devin",
                surfaces: [{ id: "surface:devin-uuid", ref: "surface:devin", title: "kid-devin", type: "terminal", pane_ref: "pane:devin" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

function treeWithCodexClaudeCodexPanelAndDevin(): string {
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
                ref: "pane:codex",
                surfaces: [{ id: "surface:codex-uuid", ref: "surface:codex", title: "codex", type: "terminal", pane_ref: "pane:codex" }],
              },
              {
                ref: "pane:claude",
                surfaces: [{ id: "surface:claude-uuid", ref: "surface:claude", title: "kid-claude", type: "terminal", pane_ref: "pane:claude" }],
              },
              {
                ref: "pane:codex-panel",
                surfaces: [{ id: "surface:codex-panel-uuid", ref: "surface:codex-panel", title: "kid-codex", type: "terminal", pane_ref: "pane:codex-panel" }],
              },
              {
                ref: "pane:devin",
                surfaces: [{ id: "surface:devin-uuid", ref: "surface:devin", title: "kid-devin", type: "terminal", pane_ref: "pane:devin" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

describe("Devin input polling", () => {
  test("detects Devin screens that are waiting for user input after preparing a plan", () => {
    const detection = detectDevinInputRequest(`
Devin created a plan for the handoff.
Planner ready.
Waiting for your input before continuing.
`);

    expect(detection).toBeDefined();
    expect(detection?.reason).toContain("Waiting for your input");
    expect(detection?.excerpt).toContain("Planner ready");
  });

  test("registers Devin and Codex surfaces from conductor context", async () => {
    const saved: DevinPollState[] = [];
    const store = {
      load: async () => createEmptyDevinPollState(),
      save: async (state: DevinPollState) => {
        saved.push(state);
      },
    };

    await registerDevinPollFromConductorContext(
      {
        cwd: "/work/project-x",
        workspaceName: "Project-X",
        workspaceId: "workspace-uuid",
        orchestratorSurfaceId: "surface:codex",
        claudePanelEnabled: true,
        claudeSurfaceId: "surface:claude",
        codexPanelEnabled: true,
        codexPanelSurfaceId: "surface:codex-panel",
        devinPanelEnabled: true,
        devinSurfaceId: "surface:devin",
        reusedClaude: true,
        reusedCodexPanel: true,
        reusedDevin: true,
      },
      "window-uuid",
      store,
    );

    expect(saved).toHaveLength(1);
    expect(saved[0].registrations[0]).toMatchObject({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      orchestratorSurfaceId: "surface:codex",
      claudePanelEnabled: true,
      devinPanelEnabled: true,
      devinSurfaceId: "surface:devin",
      codexPanelEnabled: true,
      codexPanelSurfaceId: "surface:codex-panel",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
    });
  });

  test("does not poll existing Devin panes when Devin panel is disabled", async () => {
    const saved: DevinPollState[] = [];
    const store = {
      load: async () => createEmptyDevinPollState(),
      save: async (state: DevinPollState) => {
        saved.push(state);
      },
    };

    await registerDevinPollFromConductorContext(
      {
        cwd: "/work/project-x",
        workspaceName: "Project-X",
        workspaceId: "workspace-uuid",
        orchestratorSurfaceId: "surface:codex",
        claudePanelEnabled: true,
        claudeSurfaceId: "surface:claude",
        codexPanelEnabled: false,
        codexPanelSurfaceId: undefined,
        devinPanelEnabled: false,
        devinSurfaceId: undefined,
        reusedClaude: true,
        reusedCodexPanel: false,
        reusedDevin: false,
      },
      "window-uuid",
      store,
    );

    expect(saved[0].registrations[0]).toMatchObject({
      devinPanelEnabled: false,
      devinSurfaceId: "",
    });

    const state = saved[0];
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithCodexClaudeAndDevin() },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 200": { stdout: "Claude is idle." },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));

    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
    expect(state.events.filter((event) => event.type === "aicc_event" && event.agent === "Devin")).toHaveLength(0);
  });

  test("does not poll existing Claude or Codex panes when those panels are disabled", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      claudePanelEnabled: false,
      claudeSurfaceId: "surface:claude",
      codexPanelEnabled: false,
      codexPanelSurfaceId: "surface:codex-panel",
      devinPanelEnabled: false,
      devinSurfaceId: "surface:devin",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithCodexClaudeCodexPanelAndDevin() },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));

    expect(calls.some((call) => call.includes("read-screen"))).toBe(false);
    expect(state.events.filter((event) => event.type === "aicc_event")).toHaveLength(0);
  });

  test("polls the enabled Codex panel and nudges the base orchestrator without raw screen injection", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      claudePanelEnabled: false,
      codexPanelEnabled: true,
      codexPanelSurfaceId: "surface:codex-panel",
      devinPanelEnabled: false,
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const waitingScreen = `
Codex prepared a plan.
Waiting for your input before continuing.
`;
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithCodexClaudeCodexPanelAndDevin() },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:codex-panel --scrollback --lines 200": { stdout: waitingScreen },
      [commandKey([
        "cmux",
        "send",
        "--workspace",
        "workspace-uuid",
        "--window",
        "window-uuid",
        "--surface",
        "surface:codex",
        "--",
        buildAiccDaemonNotice({
          workspaceId: "workspace-uuid",
          noticeId: "notice-workspace-uuid-2026-06-02T15:05:00.000Z",
          createdAt: "2026-06-02T15:05:00.000Z",
        }),
      ])]: { stdout: "sent" },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));
    const jsonl = formatUnreadDevinPollEventsJsonl(state);
    const parsed = JSON.parse(jsonl.trim());

    expect(calls.filter((call) => call[1] === "send")).toHaveLength(1);
    expect(parsed.agent).toBe("Codex");
    expect(parsed.state).toBe("needs_input");
    expect(parsed.summary).toContain("Codex needs user input");
    expect(jsonl).not.toContain("Codex prepared a plan");
  });

  test("treats legacy Devin registrations without explicit opt-in as disabled", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      claudeSurfaceId: "surface:claude",
      devinSurfaceId: "surface:devin",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithCodexClaudeAndDevin() },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 200": { stdout: "Claude is idle." },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));

    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
    expect(state.events.filter((event) => event.type === "aicc_event" && event.agent === "Devin")).toHaveLength(0);
  });

  test("polls Devin and nudges Codex with a fixed daemon envelope when Devin waits for input", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      devinPanelEnabled: true,
      devinSurfaceId: "surface:devin",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const waitingScreen = `
Plan prepared from the handoff.
Waiting for your input before I continue.
> Type your answer
`;
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithCodexAndDevin() },
        { stdout: treeWithCodexAndDevin() },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 200": [
        { stdout: waitingScreen },
        { stdout: waitingScreen },
      ],
      [commandKey([
        "cmux",
        "send",
        "--workspace",
        "workspace-uuid",
        "--window",
        "window-uuid",
        "--surface",
        "surface:codex",
        "--",
        buildAiccDaemonNotice({
          workspaceId: "workspace-uuid",
          noticeId: "notice-workspace-uuid-2026-06-02T15:05:00.000Z",
          createdAt: "2026-06-02T15:05:00.000Z",
        }),
      ])]: { stdout: "sent" },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));
    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:06:00.000Z"));

    expect(calls.filter((call) => call[1] === "send")).toHaveLength(1);
    expect(calls.find((call) => call[1] === "send")?.at(-1)).toContain("<<<AICC_DAEMON_NOTICE_V1");
    expect(calls.find((call) => call[1] === "send")?.at(-1)).not.toContain("Plan prepared from the handoff");
    expect(state.registrations[0].lastInputRequestFingerprint).toBeTruthy();
    expect(formatDevinPollSitrep(state)).toContain("Unread AICC events: 1");
  });

  test("formats unread event inbox as safe JSONL and marks events displayed", async () => {
    const state = createEmptyDevinPollState();
    state.events.push({
      id: "evt-1",
      type: "aicc_event",
      at: "2026-06-02T15:05:00.000Z",
      message: "Devin needs user input.",
      workspaceId: "workspace-uuid",
      devinSurfaceId: "surface:devin",
      orchestratorSurfaceId: "surface:codex",
      agent: "Devin",
      state: "needs_input",
      severity: "action_required",
      summary: "Devin needs user input.",
      excerptHash: "sha256:abc123",
    });

    const jsonl = formatUnreadDevinPollEventsJsonl(state, { markRead: true, now: new Date("2026-06-02T15:06:00.000Z") });
    const parsed = JSON.parse(jsonl.trim());

    expect(parsed).toMatchObject({
      type: "aicc_event",
      version: 1,
      id: "evt-1",
      agent: "Devin",
      state: "needs_input",
      severity: "action_required",
      summary: "Devin needs user input.",
      excerpt_hash: "sha256:abc123",
    });
    expect(jsonl).not.toContain("Plan prepared");
    expect(state.events[0].readAt).toBe("2026-06-02T15:06:00.000Z");
  });

  test("polls discovered Claude panes into the same event inbox without raw screen injection", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      claudeSurfaceId: "surface:claude",
      devinPanelEnabled: true,
      devinSurfaceId: "surface:devin",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const claudeLimitScreen = "You've hit your session limit · resets 10:50pm (Asia/Calcutta)";
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithCodexClaudeAndDevin() },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 200": { stdout: claudeLimitScreen },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 200": { stdout: "Devin is working." },
      [commandKey([
        "cmux",
        "send",
        "--workspace",
        "workspace-uuid",
        "--window",
        "window-uuid",
        "--surface",
        "surface:codex",
        "--",
        buildAiccDaemonNotice({
          workspaceId: "workspace-uuid",
          noticeId: "notice-workspace-uuid-2026-06-02T15:05:00.000Z",
          createdAt: "2026-06-02T15:05:00.000Z",
        }),
      ])]: { stdout: "sent" },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));
    const jsonl = formatUnreadDevinPollEventsJsonl(state);
    const parsed = JSON.parse(jsonl.trim());

    expect(calls.filter((call) => call[1] === "send")).toHaveLength(1);
    expect(parsed.agent).toBe("Claude");
    expect(parsed.state).toBe("usage_limited");
    expect(parsed.summary).toContain("Claude usage-limited");
    expect(jsonl).not.toContain("You've hit your session limit");
  });

  test("repeats unresolved blocker notices every ten minutes but not every poll", async () => {
    const state = createEmptyDevinPollState();
    state.registrations.push({
      workspaceId: "workspace-uuid",
      windowId: "window-uuid",
      workspaceName: "Project-X",
      cwd: "/work/project-x",
      orchestratorSurfaceId: "surface:codex",
      devinPanelEnabled: true,
      devinSurfaceId: "surface:devin",
      updatedAt: "2026-06-02T15:00:00.000Z",
    });
    const blockedScreen = "BLOCKED: Need Amit to provide the API key before I can continue.";
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithCodexAndDevin() },
        { stdout: treeWithCodexAndDevin() },
        { stdout: treeWithCodexAndDevin() },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 200": [
        { stdout: blockedScreen },
        { stdout: blockedScreen },
        { stdout: blockedScreen },
      ],
      [commandKey([
        "cmux",
        "send",
        "--workspace",
        "workspace-uuid",
        "--window",
        "window-uuid",
        "--surface",
        "surface:codex",
        "--",
        buildAiccDaemonNotice({
          workspaceId: "workspace-uuid",
          noticeId: "notice-workspace-uuid-2026-06-02T15:00:00.000Z",
          createdAt: "2026-06-02T15:00:00.000Z",
        }),
      ])]: { stdout: "sent" },
      [commandKey([
        "cmux",
        "send",
        "--workspace",
        "workspace-uuid",
        "--window",
        "window-uuid",
        "--surface",
        "surface:codex",
        "--",
        buildAiccDaemonNotice({
          workspaceId: "workspace-uuid",
          noticeId: "notice-workspace-uuid-2026-06-02T15:10:00.000Z",
          createdAt: "2026-06-02T15:10:00.000Z",
        }),
      ])]: { stdout: "sent" },
    });

    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:00:00.000Z"));
    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:05:00.000Z"));
    await scanDevinSurfacesOnce(state, runner, new Date("2026-06-02T15:10:00.000Z"));

    expect(calls.filter((call) => call[1] === "send")).toHaveLength(2);
    expect(state.events.filter((event) => event.type === "aicc_event" && event.state === "blocked")).toHaveLength(2);
  });
});
