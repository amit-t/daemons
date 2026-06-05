import { describe, expect, test } from "bun:test";
import {
  buildResetStatusText,
  isExplicitResetRequest,
  resetAiCmuxWorkspace,
  type AiCmuxResetResult,
} from "../src/ai-cmux-conductor/reset.ts";
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
      if (!queue?.length) return { code: 99, stdout: "", stderr: `unexpected call: ${key}` };
      const response = queue.shift()!;
      return { code: response.code ?? 0, stdout: response.stdout ?? "", stderr: response.stderr ?? "" };
    },
  };
}

function workspaceTree(surfaces: Array<Record<string, unknown>>): string {
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
            panes: surfaces.map((surface) => ({
              ref: surface.pane_ref,
              surfaces: [{ type: "terminal", ...surface }],
            })),
          },
        ],
      },
    ],
  });
}

const treeWithAgents = workspaceTree([
  { id: "codex-uuid", ref: "surface:codex", title: "codex", pane_ref: "pane:codex" },
  { id: "claude-uuid", ref: "surface:claude", title: "Claude", pane_ref: "pane:claude" },
  { id: "devin-uuid", ref: "surface:devin", title: "Devin", pane_ref: "pane:devin" },
]);

const treeWithAllOptionalPanels = workspaceTree([
  { id: "codex-uuid", ref: "surface:codex", title: "codex", pane_ref: "pane:codex" },
  { id: "claude-uuid", ref: "surface:claude", title: "Claude", pane_ref: "pane:claude" },
  { id: "codex-panel-uuid", ref: "surface:codex-panel", title: "Codex", pane_ref: "pane:codex-panel" },
  { id: "devin-uuid", ref: "surface:devin", title: "Devin", pane_ref: "pane:devin" },
]);

const treeAfterNewTerminal = workspaceTree([
  { id: "codex-uuid", ref: "surface:codex", title: "codex", pane_ref: "pane:codex" },
  { id: "terminal-uuid", ref: "surface:terminal", title: "~/project-x", pane_ref: "pane:codex" },
  { id: "claude-uuid", ref: "surface:claude", title: "Claude", pane_ref: "pane:claude" },
  { id: "devin-uuid", ref: "surface:devin", title: "Devin", pane_ref: "pane:devin" },
]);

const treeAfterNewTerminalWithAllOptionalPanels = workspaceTree([
  { id: "codex-uuid", ref: "surface:codex", title: "codex", pane_ref: "pane:codex" },
  { id: "terminal-uuid", ref: "surface:terminal", title: "~/project-x", pane_ref: "pane:codex" },
  { id: "claude-uuid", ref: "surface:claude", title: "Claude", pane_ref: "pane:claude" },
  { id: "codex-panel-uuid", ref: "surface:codex-panel", title: "Codex", pane_ref: "pane:codex-panel" },
  { id: "devin-uuid", ref: "surface:devin", title: "Devin", pane_ref: "pane:devin" },
]);

describe("AICC reset request detection", () => {
  test("matches only the exact bare Reset request", () => {
    expect(isExplicitResetRequest("Reset")).toBe(true);
    expect(isExplicitResetRequest(" reset")).toBe(false);
    expect(isExplicitResetRequest("Reset now")).toBe(false);
    expect(isExplicitResetRequest("reset")).toBe(false);
  });
});

describe("resetAiCmuxWorkspace", () => {
  test("pushes back and does not close anything when Claude is actively working", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithAgents },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 220": {
        stdout: "Claude Code\n✻ Thinking…\nRunning tool: Edit\n",
      },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 220": {
        stdout: "Task complete. Ready for review.\n",
      },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        AICC_CREATE_DEVIN_PANEL: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result.mode).toBe("blocked");
    expect(buildResetStatusText(result)).toContain("I cannot reset");
    expect(buildResetStatusText(result)).toContain("Claude appears active");
    expect(calls.some((call) => call.includes("close-surface"))).toBe(false);
    expect(calls.some((call) => call.includes("new-surface"))).toBe(false);
  });

  test("pushes back and does not close anything when Devin has unresolved work", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithAgents },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 220": {
        stdout: "Claude Code\n> Ready for your next task\n",
      },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 220": {
        stdout: "Waiting for your approval before applying changes.\n",
      },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        AICC_CREATE_DEVIN_PANEL: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result.mode).toBe("blocked");
    expect(buildResetStatusText(result)).toContain("Devin appears active");
    expect(calls.some((call) => call.includes("close-surface"))).toBe(false);
    expect(calls.some((call) => call.includes("new-surface"))).toBe(false);
  });

  test("creates one fresh terminal surface and closes idle AICC AI surfaces", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithAgents },
        { stdout: treeAfterNewTerminal },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 220": {
        stdout: "Claude Code\n> Ready for your next task\n",
      },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:devin --scrollback --lines 220": {
        stdout: "Task complete. Ready for review.\n",
      },
      "cmux new-surface --workspace workspace-uuid --window window-uuid --pane pane:codex --type terminal --focus true": {
        stdout: "surface:terminal\n",
      },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:terminal terminal": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:claude": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:devin": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:codex": { stdout: "" },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        AICC_CREATE_DEVIN_PANEL: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result).toEqual({
      mode: "reset",
      workspaceId: "workspace-uuid",
      terminalSurfaceId: "surface:terminal",
      closedSurfaceIds: ["surface:claude", "surface:devin", "surface:codex"],
    } satisfies AiCmuxResetResult);
    expect(calls.slice(-4)).toEqual([
      ["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:terminal", "terminal"],
      ["cmux", "close-surface", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude"],
      ["cmux", "close-surface", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin"],
      ["cmux", "close-surface", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex"],
    ]);
    expect(buildResetStatusText(result)).toContain("AICC reset complete");
  });

  test("leaves existing Devin panes untouched when the Devin panel is disabled", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithAgents },
        { stdout: treeAfterNewTerminal },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:claude --scrollback --lines 220": {
        stdout: "Claude Code\n> Ready for your next task\n",
      },
      "cmux new-surface --workspace workspace-uuid --window window-uuid --pane pane:codex --type terminal --focus true": {
        stdout: "surface:terminal\n",
      },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:terminal terminal": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:claude": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:codex": { stdout: "" },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result).toEqual({
      mode: "reset",
      workspaceId: "workspace-uuid",
      terminalSurfaceId: "surface:terminal",
      closedSurfaceIds: ["surface:claude", "surface:codex"],
    } satisfies AiCmuxResetResult);
    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
  });

  test("pushes back and does not close anything when the enabled Codex panel is active", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": { stdout: treeWithAllOptionalPanels },
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:codex-panel --scrollback --lines 220": {
        stdout: "Codex\n✻ Thinking…\nRunning tool: Edit\n",
      },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        AICC_CREATE_CLAUDE_PANEL: "false",
        AICC_CREATE_CODEX_PANEL: "true",
        AICC_CREATE_DEVIN_PANEL: "false",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result.mode).toBe("blocked");
    expect(buildResetStatusText(result)).toContain("Codex appears active");
    expect(calls.some((call) => call.includes("close-surface"))).toBe(false);
    expect(calls.some((call) => call.includes("surface:claude"))).toBe(false);
    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
  });

  test("resets enabled Codex panel and base Codex while leaving disabled Claude and Devin panes untouched", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithAllOptionalPanels },
        { stdout: treeAfterNewTerminalWithAllOptionalPanels },
      ],
      "cmux read-screen --workspace workspace-uuid --window window-uuid --surface surface:codex-panel --scrollback --lines 220": {
        stdout: "Codex\n> Ready for your next prompt\n",
      },
      "cmux new-surface --workspace workspace-uuid --window window-uuid --pane pane:codex --type terminal --focus true": {
        stdout: "surface:terminal\n",
      },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:terminal terminal": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:codex-panel": { stdout: "" },
      "cmux close-surface --workspace workspace-uuid --window window-uuid --surface surface:codex": { stdout: "" },
    });

    const result = await resetAiCmuxWorkspace({
      env: {
        AICC_CREATE_CLAUDE_PANEL: "false",
        AICC_CREATE_CODEX_PANEL: "true",
        AICC_CREATE_DEVIN_PANEL: "false",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:codex",
      },
      runner,
    });

    expect(result).toEqual({
      mode: "reset",
      workspaceId: "workspace-uuid",
      terminalSurfaceId: "surface:terminal",
      closedSurfaceIds: ["surface:codex-panel", "surface:codex"],
    } satisfies AiCmuxResetResult);
    expect(calls.some((call) => call.includes("surface:claude"))).toBe(false);
    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
  });

  test("fails safely outside cMUX", async () => {
    const result = await resetAiCmuxWorkspace({ env: {}, runner: async () => ({ code: 0, stdout: "", stderr: "" }) });

    expect(result.mode).toBe("error");
    expect(buildResetStatusText(result)).toContain("AICC reset requires cMUX");
  });
});
