import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  buildOrchestratorPrompt,
  prepareConductor,
  type CommandRunner,
} from "../src/ai-cmux-conductor/conductor.ts";
import {
  CODEX_PANEL_FEATURE_FLAG,
  CLAUDE_PANEL_FEATURE_FLAG,
  DEFAULT_ENVIRONMENT_FILE,
  DEVIN_PANEL_FEATURE_FLAG,
  isClaudePanelEnabled,
  isCodexPanelEnabled,
  isDevinPanelEnabled,
  loadAiCmuxConductorEnv,
} from "../src/ai-cmux-conductor/config.ts";

type RunnerResponse = { code?: number; stdout?: string; stderr?: string };

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
      if (!queue?.length && cmd === "cmux" && args[0] === "send") return { code: 0, stdout: "", stderr: "" };
      if (!queue?.length) return { code: 99, stdout: "", stderr: `unexpected call: ${key}` };
      const response = queue.shift()!;
      return { code: response.code ?? 0, stdout: response.stdout ?? "", stderr: response.stderr ?? "" };
    },
  };
}

function workspaceTree(title: string, surfaces: Array<Record<string, unknown>>): string {
  return JSON.stringify({
    windows: [
      {
        ref: "window:1",
        id: "window-uuid",
        workspaces: [
          {
            ref: "workspace:1",
            id: "workspace-uuid",
            title,
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

const baseSurface = { id: "base-surface-uuid", ref: "surface:base", title: "codex", pane_ref: "pane:base" };
const claudeSurface = { id: "claude-surface-uuid", ref: "surface:claude", title: "Claude", pane_ref: "pane:claude" };
const codexPanelSurface = { id: "codex-panel-surface-uuid", ref: "surface:codex-panel", title: "Codex", pane_ref: "pane:codex-panel" };
const devinSurface = { id: "devin-surface-uuid", ref: "surface:devin", title: "Devin", pane_ref: "pane:devin" };

describe("AICC managed panel feature flags", () => {
  test("enables Claude and Codex panels by default while Devin remains opt-in", () => {
    expect(isClaudePanelEnabled({})).toBe(true);
    expect(isCodexPanelEnabled({})).toBe(true);
    expect(isDevinPanelEnabled({})).toBe(false);

    expect(isClaudePanelEnabled({ [CLAUDE_PANEL_FEATURE_FLAG]: "false" })).toBe(false);
    expect(isCodexPanelEnabled({ [CODEX_PANEL_FEATURE_FLAG]: "0" })).toBe(false);
    expect(isDevinPanelEnabled({ [DEVIN_PANEL_FEATURE_FLAG]: "yes" })).toBe(true);

    const env = loadAiCmuxConductorEnv({}, DEFAULT_ENVIRONMENT_FILE);
    expect(readFileSync(DEFAULT_ENVIRONMENT_FILE, "utf8")).toContain(`${CLAUDE_PANEL_FEATURE_FLAG}=true`);
    expect(readFileSync(DEFAULT_ENVIRONMENT_FILE, "utf8")).toContain(`${CODEX_PANEL_FEATURE_FLAG}=true`);
    expect(readFileSync(DEFAULT_ENVIRONMENT_FILE, "utf8")).toContain(`${DEVIN_PANEL_FEATURE_FLAG}=false`);
    expect(isClaudePanelEnabled(env)).toBe(true);
    expect(isCodexPanelEnabled(env)).toBe(true);
    expect(isDevinPanelEnabled(env)).toBe(false);
  });
});

describe("prepareConductor optional managed panel stack", () => {
  test("by default creates Claude right of the orchestrator and a Codex panel below Claude, while leaving Devin unmanaged", async () => {
    const claudeLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && clscb'\n";
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:base codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: workspaceTree("old", [baseSurface, devinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, devinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("Project-X", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
      ],
      "cmux focus-pane --pane pane:base --workspace workspace-uuid --window window-uuid": { stdout: "" },
      "cmux new-pane --direction right --workspace workspace-uuid --focus false --window window-uuid": { stdout: "pane:claude\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude Claude": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", claudeLaunch].join(" ")]: { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:codex-panel workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel Codex": { stdout: "" },
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:base",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.claudePanelEnabled).toBe(true);
    expect(result.context.codexPanelEnabled).toBe(true);
    expect(result.context.devinPanelEnabled).toBe(false);
    expect(result.context.claudeSurfaceId).toBe("surface:claude");
    expect(result.context.codexPanelSurfaceId).toBe("surface:codex-panel");
    expect(result.context.devinSurfaceId).toBeUndefined();
    expect(calls).toContainEqual(["cmux", "new-split", "down", "--workspace", "workspace-uuid", "--surface", "surface:claude", "--focus", "false", "--window", "window-uuid"]);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex-panel", "Codex"]);
    expect(calls.find((call) => call[1] === "send" && call.includes("surface:codex-panel"))?.at(-1)).toContain("cxscb --disable apps -c");
    expect(calls.some((call) => call.includes("surface:devin"))).toBe(false);
  });

  test("when all three panels are enabled, stacks Claude, Codex, then Devin from top to bottom", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:base codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: workspaceTree("old", [baseSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("Project-X", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
      ],
      "cmux focus-pane --pane pane:base --workspace workspace-uuid --window window-uuid": { stdout: "" },
      "cmux new-pane --direction right --workspace workspace-uuid --focus false --window window-uuid": { stdout: "pane:claude\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude Claude": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:codex-panel workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel Codex": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:codex-panel --focus false --window window-uuid": { stdout: "OK surface:devin workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin Devin": { stdout: "" },
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        [DEVIN_PANEL_FEATURE_FLAG]: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:base",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.claudeSurfaceId).toBe("surface:claude");
    expect(result.context.codexPanelSurfaceId).toBe("surface:codex-panel");
    expect(result.context.devinSurfaceId).toBe("surface:devin");
    expect(calls.filter((call) => call[1] === "new-split")).toEqual([
      ["cmux", "new-split", "down", "--workspace", "workspace-uuid", "--surface", "surface:claude", "--focus", "false", "--window", "window-uuid"],
      ["cmux", "new-split", "down", "--workspace", "workspace-uuid", "--surface", "surface:codex-panel", "--focus", "false", "--window", "window-uuid"],
    ]);
  });

  test("when all managed panels are disabled, creates no side panes and ignores existing agent panes", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:base codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("Project-X", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
      ],
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        [CLAUDE_PANEL_FEATURE_FLAG]: "false",
        [CODEX_PANEL_FEATURE_FLAG]: "false",
        [DEVIN_PANEL_FEATURE_FLAG]: "false",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_WINDOW_ID: "window-uuid",
        CMUX_SURFACE_ID: "surface:base",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.claudePanelEnabled).toBe(false);
    expect(result.context.codexPanelEnabled).toBe(false);
    expect(result.context.devinPanelEnabled).toBe(false);
    expect(result.context.claudeSurfaceId).toBeUndefined();
    expect(result.context.codexPanelSurfaceId).toBeUndefined();
    expect(result.context.devinSurfaceId).toBeUndefined();
    expect(calls.some((call) => call.includes("new-pane") || call.includes("new-split"))).toBe(false);
    expect(calls.some((call) => call[1] === "send")).toBe(false);
  });
});

describe("buildOrchestratorPrompt panel routing", () => {
  test("includes Codex panel routing when the Codex panel is enabled", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "Project-X",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:base",
      claudePanelEnabled: true,
      claudeSurfaceId: "surface:claude",
      codexPanelEnabled: true,
      codexPanelSurfaceId: "surface:codex-panel",
      devinPanelEnabled: false,
      reusedClaude: true,
      reusedCodexPanel: false,
      reusedDevin: false,
    });

    expect(prompt).toContain("Codex panel surface: surface:codex-panel");
    expect(prompt).toContain('"ask Codex"');
    expect(prompt).toContain("Read Codex:");
    expect(prompt).toContain("Send Codex:");
    expect(prompt).toContain("Codex below Claude");
    expect(prompt).toContain("cxscb --disable apps -c");
    expect(prompt).not.toContain("Read Devin:");
  });
});
