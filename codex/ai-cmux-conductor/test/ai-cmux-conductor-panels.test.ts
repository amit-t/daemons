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
const claudeSurface = { id: "claude-surface-uuid", ref: "surface:claude", title: "kid-claude", pane_ref: "pane:claude" };
const codexPanelSurface = { id: "codex-panel-surface-uuid", ref: "surface:codex-panel", title: "kid-codex", pane_ref: "pane:codex-panel" };
const devinSurface = { id: "devin-surface-uuid", ref: "surface:devin", title: "kid-devin", pane_ref: "pane:devin" };
const legacyClaudeSurface = { ...claudeSurface, title: "Claude" };
const legacyCodexPanelSurface = { ...codexPanelSurface, title: "Codex" };
const legacyDevinSurface = { ...devinSurface, title: "Devin" };

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
  test("names newly-created managed side panels with kid-prefixed titles", async () => {
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
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude kid-claude": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:codex-panel workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel kid-codex": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:codex-panel --focus false --window window-uuid": { stdout: "OK surface:devin workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin kid-devin": { stdout: "" },
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
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", "kid-claude"]);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex-panel", "kid-codex"]);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", "kid-devin"]);
    expect(calls).not.toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex-panel", "Codex"]);
  });

  test("reuses legacy managed side panels and retitles them to kid-prefixed names", async () => {
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:base codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: workspaceTree("old", [baseSurface, legacyClaudeSurface, legacyCodexPanelSurface, legacyDevinSurface]) },
        { stdout: workspaceTree("old", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
        { stdout: workspaceTree("Project-X", [baseSurface, claudeSurface, codexPanelSurface, devinSurface]) },
      ],
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude kid-claude": { stdout: "" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel kid-codex": { stdout: "" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin kid-devin": { stdout: "" },
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
    expect(result.context.reusedClaude).toBe(true);
    expect(result.context.reusedCodexPanel).toBe(true);
    expect(result.context.reusedDevin).toBe(true);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", "kid-claude"]);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex-panel", "kid-codex"]);
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", "kid-devin"]);
    expect(calls.some((call) => call.includes("new-pane") || call.includes("new-split"))).toBe(false);
  });

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
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude kid-claude": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", claudeLaunch].join(" ")]: { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:codex-panel workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel kid-codex": { stdout: "" },
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
    expect(calls).toContainEqual(["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:codex-panel", "kid-codex"]);
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
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude kid-claude": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:codex-panel workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:codex-panel kid-codex": { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:codex-panel --focus false --window window-uuid": { stdout: "OK surface:devin workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin kid-devin": { stdout: "" },
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
    expect(prompt).toContain("Codex (kid-codex) below kid-claude");
    expect(prompt).toContain("send the refined pending prompt to that Codex surface");
    expect(prompt).toContain("cxscb --disable apps -c");
    expect(prompt).not.toContain("Read Devin:");
  });

  test("mandates refined structured prompts for kid-pane requests and forbids background subagents", () => {
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

    // Recognizes the user's "tell kid claude / kid codex" phrasing as routing triggers.
    expect(prompt).toContain('"tell Claude"');
    expect(prompt).toContain('"tell kid-claude"');
    expect(prompt).toContain('"tell Codex"');
    expect(prompt).toContain('"tell kid-codex"');

    // Non-negotiable: route into the spawned kid pane with a refined self-contained prompt, no background work.
    expect(prompt).toContain("## Kid-pane routing (non-negotiable)");
    expect(prompt).toContain("Claude → kid-claude, Codex → kid-codex");
    expect(prompt).toContain("## Kid-pane prompt refinement (non-negotiable)");
    expect(prompt).toContain("Do NOT copy Amit's raw wording straight through");
    expect(prompt).toContain("Build a structured prompt before cmux send");
    expect(prompt).toContain("Original ask");
    expect(prompt).toContain("Objective");
    expect(prompt).toContain("Acceptance criteria");
    expect(prompt).toContain("Verification");
    expect(prompt).toContain("Agent-specific command profile");
    expect(prompt).toContain("Claude/kid-claude runs clscb");
    expect(prompt).toContain("Codex/kid-codex runs cxscb --disable apps -c 'mcp_servers={}'");
    expect(prompt).not.toContain("verbatim");
    expect(prompt).not.toContain("literal instruction");
    expect(prompt).toContain("watch the agent work through it");
    expect(prompt).toContain("Do NOT spawn a background subagent");
    expect(prompt).toContain("never spawn a background subagent for it");

    // Background work allowed only when no kid pane is addressed.
    expect(prompt).toContain("## Background work");
    expect(prompt).toContain("ONLY when the user has NOT addressed a kid pane");
  });

  test("omits kid-pane routing and background sections when no side agents are enabled", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "Project-X",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:base",
      claudePanelEnabled: false,
      codexPanelEnabled: false,
      devinPanelEnabled: false,
      reusedClaude: false,
      reusedCodexPanel: false,
      reusedDevin: false,
    });

    expect(prompt).not.toContain("## Kid-pane routing (non-negotiable)");
    expect(prompt).not.toContain("## Background work");
    expect(prompt).toContain("No managed side-agent routing panes are enabled.");
  });
});
