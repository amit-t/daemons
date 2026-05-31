import { describe, expect, test } from "bun:test";
import {
  buildOrchestratorPrompt,
  prepareConductor,
  shellQuote,
  type CommandRunner,
} from "../src/ai-cmux-conductor/conductor.ts";

function runnerFor(responses: Record<string, { code?: number; stdout?: string; stderr?: string }>): { runner: CommandRunner; calls: string[][] } {
  const calls: string[][] = [];
  return {
    calls,
    runner: async (cmd, args) => {
      const call = [cmd, ...args];
      calls.push(call);
      const key = call.join(" ");
      const response = responses[key] || { code: 0, stdout: "" };
      return { code: response.code ?? 0, stdout: response.stdout ?? "", stderr: response.stderr ?? "" };
    },
  };
}

const treeWithClaudeOnly = JSON.stringify({
  windows: [
    {
      workspaces: [
        {
          ref: "workspace:1",
          title: "old",
          panes: [
            {
              ref: "pane:1",
              surfaces: [
                { ref: "surface:1", title: "Base", type: "terminal", pane_ref: "pane:1" },
                { ref: "surface:2", title: "Claude", type: "terminal", pane_ref: "pane:1" },
              ],
            },
          ],
        },
      ],
    },
  ],
});

const treeWithBoth = JSON.stringify({
  windows: [
    {
      workspaces: [
        {
          ref: "workspace:1",
          title: "project-x",
          panes: [
            {
              ref: "pane:1",
              surfaces: [
                { ref: "surface:2", title: "Claude", type: "terminal", pane_ref: "pane:1" },
                { ref: "surface:4", title: "Devin", type: "terminal", pane_ref: "pane:3" },
              ],
            },
          ],
        },
      ],
    },
  ],
});

describe("shellQuote", () => {
  test("quotes single quotes safely for zsh -lc commands", () => {
    expect(shellQuote("/tmp/it's fine")).toBe("'/tmp/it'\\''s fine'");
  });
});

describe("prepareConductor", () => {
  test("outside cMUX does one workspace handoff and exits", async () => {
    const { runner, calls } = runnerFor({
      "cmux new-workspace --name project-x --cwd /work/project-x --focus true --command aicc": { stdout: "workspace:9\n" },
    });

    const result = await prepareConductor({ cwd: "/work/project-x", env: {}, runner });

    expect(result.mode).toBe("handoff");
    expect(calls).toEqual([
      ["cmux", "new-workspace", "--name", "project-x", "--cwd", "/work/project-x", "--focus", "true", "--command", "aicc"],
    ]);
  });

  test("outside cMUX failure returns a copyable manual command", async () => {
    const { runner } = runnerFor({
      "cmux new-workspace --name Space App --cwd /work/Space App --focus true --command aicc": { code: 1, stderr: "no cmux" },
    });

    const result = await prepareConductor({ cwd: "/work/Space App", env: {}, runner });

    expect(result.mode).toBe("error");
    if (result.mode !== "error") throw new Error("expected error");
    expect(result.message).toContain("cmux new-workspace --name 'Space App' --cwd '/work/Space App' --focus true --command aicc");
    expect(result.stderr).toBe("no cmux");
  });

  test("inside cMUX reuses Claude and creates missing Devin", async () => {
    const { runner, calls } = runnerFor({
      "cmux rename-workspace --workspace workspace:1 project-x": { stdout: "" },
      "cmux --json tree --workspace workspace:1": { stdout: treeWithClaudeOnly },
      "cmux new-pane --direction right --workspace workspace:1 --focus false": { stdout: "pane:3\n" },
      "cmux --json tree --workspace workspace:1 --window window:1": { stdout: treeWithBoth },
      "cmux rename-tab --workspace workspace:1 --surface surface:4 Devin": { stdout: "" },
      "cmux send --workspace workspace:1 --surface surface:4 zsh -lc 'cd '\''/work/project-x'\'' && dey'\n": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: { CMUX_WORKSPACE_ID: "workspace:1", CMUX_SURFACE_ID: "surface:1", CMUX_WINDOW_ID: "window:1" },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.workspaceId).toBe("workspace:1");
    expect(result.context.orchestratorSurfaceId).toBe("surface:1");
    expect(result.context.claudeSurfaceId).toBe("surface:2");
    expect(result.context.devinSurfaceId).toBe("surface:4");
    expect(calls.some((call) => call.join(" ") === "cmux new-pane --direction right --workspace workspace:1 --focus false")).toBe(true);
  });
});

describe("buildOrchestratorPrompt", () => {
  test("includes stable cMUX IDs and routing instructions", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "project-x",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:1",
      claudeSurfaceId: "surface:2",
      devinSurfaceId: "surface:4",
      reusedClaude: true,
      reusedDevin: false,
    });

    expect(prompt).toContain("workspace:1");
    expect(prompt).toContain("/work/project-x");
    expect(prompt).toContain("Claude surface: surface:2");
    expect(prompt).toContain("Devin surface: surface:4");
    expect(prompt).toContain("cmux read-screen");
    expect(prompt).toContain("cmux send");
    expect(prompt).toContain("ask before replacing");
  });
});
