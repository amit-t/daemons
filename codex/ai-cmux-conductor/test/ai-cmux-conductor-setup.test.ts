import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  buildOrchestratorPrompt,
  prepareConductor,
  shellQuote,
  type CommandRunner,
} from "../src/ai-cmux-conductor/conductor.ts";
import {
  DEFAULT_ENVIRONMENT_FILE,
  isDevinPanelEnabled,
  loadAiCmuxConductorEnv,
  parseEnvironmentFile,
} from "../src/ai-cmux-conductor/config.ts";

type RunnerResponse = { code?: number; stdout?: string; stderr?: string };

function runnerFor(responses: Record<string, RunnerResponse>): { runner: CommandRunner; calls: string[][] } {
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

const treeWithStaleAgentsAndUuidBase = JSON.stringify({
  windows: [
    {
      ref: "window:1",
      id: "window-uuid",
      workspaces: [
        {
          ref: "workspace:1",
          id: "workspace-uuid",
          title: "old",
          panes: [
            {
              ref: "pane:base",
              surfaces: [{ id: "base-surface-uuid", ref: "surface:base", title: "Base", type: "terminal", pane_ref: "pane:base" }],
            },
            {
              ref: "pane:stale-claude",
              surfaces: [{ id: "stale-claude-uuid", ref: "surface:old-claude", title: "Claude", type: "terminal", pane_ref: "pane:stale-claude" }],
            },
            {
              ref: "pane:stale-devin",
              surfaces: [{ id: "stale-devin-uuid", ref: "surface:old-devin", title: "Devin", type: "terminal", pane_ref: "pane:stale-devin" }],
            },
          ],
        },
      ],
    },
  ],
});


const treeWithUuidBaseOnly = JSON.stringify({
  windows: [
    {
      ref: "window:1",
      id: "window-uuid",
      workspaces: [
        {
          ref: "workspace:1",
          id: "workspace-uuid",
          title: "old",
          panes: [
            {
              ref: "pane:base",
              surfaces: [{ id: "base-surface-uuid", ref: "surface:base", title: "Base", type: "terminal", pane_ref: "pane:base" }],
            },
          ],
        },
      ],
    },
  ],
});

function treeAfterClaudePaneWithWorkspaceTitle(title: string): string {
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
            panes: [
              {
                ref: "pane:base",
                surfaces: [{ id: "base-surface-uuid", ref: "surface:base", title: "codex", type: "terminal", pane_ref: "pane:base" }],
              },
              {
                ref: "pane:claude",
                surfaces: [{ id: "claude-surface-uuid", ref: "surface:claude", title: "~/project-x", type: "terminal", pane_ref: "pane:claude" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

function treeAfterDevinPaneWithWorkspaceTitle(title: string): string {
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
            panes: [
              {
                ref: "pane:base",
                surfaces: [{ id: "base-surface-uuid", ref: "surface:base", title: "codex", type: "terminal", pane_ref: "pane:base" }],
              },
              {
                ref: "pane:claude",
                surfaces: [{ id: "claude-surface-uuid", ref: "surface:claude", title: "Claude", type: "terminal", pane_ref: "pane:claude" }],
              },
              {
                ref: "pane:devin",
                surfaces: [{ id: "devin-surface-uuid", ref: "surface:devin", title: "~/project-x", type: "terminal", pane_ref: "pane:devin" }],
              },
            ],
          },
        ],
      },
    ],
  });
}


function treeWithExistingAgentsWorkspaceTitle(title: string): string {
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
            panes: [
              {
                ref: "pane:base",
                surfaces: [{ id: "base-surface-uuid", ref: "surface:base", title: "Base", type: "terminal", pane_ref: "pane:base" }],
              },
              {
                ref: "pane:claude",
                surfaces: [{ id: "claude-surface-uuid", ref: "surface:claude", title: "Claude", type: "terminal", pane_ref: "pane:claude" }],
              },
              {
                ref: "pane:devin",
                surfaces: [{ id: "devin-surface-uuid", ref: "surface:devin", title: "Devin", type: "terminal", pane_ref: "pane:devin" }],
              },
            ],
          },
        ],
      },
    ],
  });
}

const treeAfterClaudePane = treeAfterClaudePaneWithWorkspaceTitle("old");
const treeAfterDevinPane = treeAfterDevinPaneWithWorkspaceTitle("old");
const treeAfterWorkspaceRename = treeAfterDevinPaneWithWorkspaceTitle("Project-X");

describe("shellQuote", () => {
  test("quotes single quotes safely for zsh -lc commands", () => {
    expect(shellQuote("/tmp/it's fine")).toBe("'/tmp/it'\\''s fine'");
  });
});

describe("prepareConductor", () => {
  test("outside cMUX does one workspace handoff and exits", async () => {
    const { runner, calls } = runnerFor({
      "cmux new-workspace --name Project-X --cwd /work/project-x --focus true --command aicc": { stdout: "workspace:9\n" },
    });

    const result = await prepareConductor({ cwd: "/work/project-x", env: {}, runner });

    expect(result.mode).toBe("handoff");
    expect(calls).toEqual([
      ["cmux", "new-workspace", "--name", "Project-X", "--cwd", "/work/project-x", "--focus", "true", "--command", "aicc"],
    ]);
  });

  test("outside cMUX capitalizes workspace name words from the directory basename", async () => {
    const { runner, calls } = runnerFor({
      "cmux new-workspace --name Wb-Gitlore --cwd /work/wb-gitlore --focus true --command aicc": { stdout: "workspace:9\n" },
    });

    const result = await prepareConductor({ cwd: "/work/wb-gitlore", env: {}, runner });

    expect(result.mode).toBe("handoff");
    expect(calls).toEqual([
      ["cmux", "new-workspace", "--name", "Wb-Gitlore", "--cwd", "/work/wb-gitlore", "--focus", "true", "--command", "aicc"],
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


  test("inside cMUX preserves existing Claude and Devin surfaces instead of closing or recreating them", async () => {
    const treeWithExistingAgents = treeWithExistingAgentsWorkspaceTitle("old");
    const treeAfterWorkspaceRenameWithExistingAgents = treeWithExistingAgentsWorkspaceTitle("Project-X");
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface base-surface-uuid codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithExistingAgents },
        { stdout: treeWithExistingAgents },
        { stdout: treeAfterWorkspaceRenameWithExistingAgents },
      ],
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_SURFACE_ID: "base-surface-uuid",
        CMUX_WINDOW_ID: "window-uuid",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.claudeSurfaceId).toBe("surface:claude");
    expect(result.context.devinSurfaceId).toBe("surface:devin");
    expect(result.context.reusedClaude).toBe(true);
    expect(result.context.reusedDevin).toBe(true);
    expect(calls.some((call) => call.includes("close-surface"))).toBe(false);
    expect(calls.some((call) => call.includes("new-pane") || call.includes("new-split"))).toBe(false);
    expect(calls.some((call) => call[0] === "cmux" && call[1] === "send" && call.at(-1)?.includes("clscb"))).toBe(false);
    expect(calls.some((call) => call[0] === "cmux" && call[1] === "send" && call.at(-1)?.includes("dey"))).toBe(false);
  });

  test("inside cMUX creates missing Claude right of Codex and missing Devin below Claude using UUID env IDs", async () => {
    const claudeLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && clscb'\n";
    const devinLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && dey'\n";
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface base-surface-uuid codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithUuidBaseOnly },
        { stdout: treeAfterClaudePane },
        { stdout: treeAfterDevinPane },
        { stdout: treeAfterDevinPane },
        { stdout: treeAfterWorkspaceRename },
      ],
      "cmux focus-pane --pane pane:base --workspace workspace-uuid --window window-uuid": { stdout: "" },
      "cmux new-pane --direction right --workspace workspace-uuid --focus false --window window-uuid": { stdout: "pane:claude\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude Claude": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", claudeLaunch].join(" ")]: { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:devin workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin Devin": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", devinLaunch].join(" ")]: { stdout: "" },
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        AICC_CREATE_DEVIN_PANEL: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_SURFACE_ID: "base-surface-uuid",
        CMUX_WINDOW_ID: "window-uuid",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.orchestratorSurfaceId).toBe("base-surface-uuid");
    expect(result.context.claudeSurfaceId).toBe("surface:claude");
    expect(result.context.devinSurfaceId).toBe("surface:devin");
    expect(result.context.reusedClaude).toBe(false);
    expect(result.context.reusedDevin).toBe(false);
    expect(calls).toEqual([
      ["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "base-surface-uuid", "codex"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "focus-pane", "--pane", "pane:base", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "new-pane", "--direction", "right", "--workspace", "workspace-uuid", "--focus", "false", "--window", "window-uuid"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", "Claude"],
      ["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", claudeLaunch],
      ["cmux", "new-split", "down", "--workspace", "workspace-uuid", "--surface", "surface:claude", "--focus", "false", "--window", "window-uuid"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", "Devin"],
      ["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", devinLaunch],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "rename-workspace", "--workspace", "workspace-uuid", "--window", "window-uuid", "Project-X"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
    ]);
  });

  test("inside cMUX skips Devin panel creation when the feature flag is false", async () => {
    const claudeLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && clscb'\n";
    const treeAfterClaudeWorkspaceRename = treeAfterClaudePaneWithWorkspaceTitle("Project-X");
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface base-surface-uuid codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithExistingAgentsWorkspaceTitle("old") },
        { stdout: treeWithExistingAgentsWorkspaceTitle("old") },
        { stdout: treeWithExistingAgentsWorkspaceTitle("Project-X") },
      ],
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        AICC_CREATE_DEVIN_PANEL: "false",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_SURFACE_ID: "base-surface-uuid",
        CMUX_WINDOW_ID: "window-uuid",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    if (result.mode !== "ready") throw new Error("expected ready");
    expect(result.context.devinPanelEnabled).toBe(false);
    expect(result.context.claudeSurfaceId).toBe("surface:claude");
    expect(result.context.reusedClaude).toBe(true);
    expect(result.context.devinSurfaceId).toBeUndefined();
    expect(calls).toEqual([
      ["cmux", "rename-tab", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "base-surface-uuid", "codex"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "rename-workspace", "--workspace", "workspace-uuid", "--window", "window-uuid", "Project-X"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
    ]);
  });

  test("workspace rename is verified and falls back when the first rename command does not change the title", async () => {
    const claudeLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && clscb'\n";
    const devinLaunch = "zsh -lc 'cd '\\''/work/project-x'\\'' && dey'\n";
    const { runner, calls } = strictRunnerFor({
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface base-surface-uuid codex": { stdout: "" },
      "cmux --id-format both --json tree --workspace workspace-uuid --window window-uuid": [
        { stdout: treeWithUuidBaseOnly },
        { stdout: treeAfterClaudePane },
        { stdout: treeAfterDevinPane },
        { stdout: treeAfterDevinPane },
        { stdout: treeAfterDevinPane },
        { stdout: treeAfterWorkspaceRename },
      ],
      "cmux focus-pane --pane pane:base --workspace workspace-uuid --window window-uuid": { stdout: "" },
      "cmux new-pane --direction right --workspace workspace-uuid --focus false --window window-uuid": { stdout: "pane:claude\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:claude Claude": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:claude", claudeLaunch].join(" ")]: { stdout: "" },
      "cmux new-split down --workspace workspace-uuid --surface surface:claude --focus false --window window-uuid": { stdout: "OK surface:devin workspace:1\n" },
      "cmux rename-tab --workspace workspace-uuid --window window-uuid --surface surface:devin Devin": { stdout: "" },
      [["cmux", "send", "--workspace", "workspace-uuid", "--window", "window-uuid", "--surface", "surface:devin", devinLaunch].join(" ")]: { stdout: "" },
      "cmux rename-workspace --workspace workspace-uuid --window window-uuid Project-X": { stdout: "OK workspace:1\n" },
      "cmux workspace-action --action rename --workspace workspace-uuid --window window-uuid --title Project-X": { stdout: "OK action=rename workspace=workspace:1 window=window:1\n" },
    });

    const result = await prepareConductor({
      cwd: "/work/project-x",
      env: {
        AICC_CREATE_DEVIN_PANEL: "true",
        CMUX_WORKSPACE_ID: "workspace-uuid",
        CMUX_SURFACE_ID: "base-surface-uuid",
        CMUX_WINDOW_ID: "window-uuid",
      },
      runner,
    });

    expect(result.mode).toBe("ready");
    expect(calls.slice(-5)).toEqual([
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "rename-workspace", "--workspace", "workspace-uuid", "--window", "window-uuid", "Project-X"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
      ["cmux", "workspace-action", "--action", "rename", "--workspace", "workspace-uuid", "--window", "window-uuid", "--title", "Project-X"],
      ["cmux", "--id-format", "both", "--json", "tree", "--workspace", "workspace-uuid", "--window", "window-uuid"],
    ]);
  });

});

describe("Devin panel feature flag", () => {
  test("is enabled by default and disabled only by an explicit false value", () => {
    expect(isDevinPanelEnabled({})).toBe(true);
    expect(isDevinPanelEnabled({ AICC_CREATE_DEVIN_PANEL: "false" })).toBe(false);
    expect(isDevinPanelEnabled({ AICC_CREATE_DEVIN_PANEL: "true" })).toBe(true);
  });

  test("parses environment.env style assignments", () => {
    expect(
      parseEnvironmentFile(`
        # comment
        AICC_CREATE_DEVIN_PANEL='true'
        export OTHER_FLAG="quoted value"
      `),
    ).toEqual({
      AICC_CREATE_DEVIN_PANEL: "true",
      OTHER_FLAG: "quoted value",
    });
  });

  test("tracks the repository environment.env file with Devin enabled by default", () => {
    const fileEnv = loadAiCmuxConductorEnv({}, DEFAULT_ENVIRONMENT_FILE);

    expect(readFileSync(DEFAULT_ENVIRONMENT_FILE, "utf8")).toContain("AICC_CREATE_DEVIN_PANEL=true");
    expect(fileEnv.AICC_CREATE_DEVIN_PANEL).toBe("true");
    expect(isDevinPanelEnabled(fileEnv)).toBe(true);
  });

  test("process environment overrides the repository environment.env file", () => {
    const env = loadAiCmuxConductorEnv({ AICC_CREATE_DEVIN_PANEL: "true" }, DEFAULT_ENVIRONMENT_FILE);

    expect(isDevinPanelEnabled(env)).toBe(true);
  });
});

describe("buildOrchestratorPrompt", () => {
  test("includes stable cMUX IDs and routing instructions", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "project-x",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:1",
      devinPanelEnabled: true,
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

  test("tells the orchestrator to open Devin below Claude with dey before passing Devin prompts", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "project-x",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:1",
      devinPanelEnabled: true,
      claudeSurfaceId: "surface:2",
      devinSurfaceId: "surface:4",
      reusedClaude: true,
      reusedDevin: false,
    });

    expect(prompt).toContain('When the user says "ask Devin"');
    expect(prompt).toContain("open Devin in interactive yolo mode below Claude");
    expect(prompt).toContain("cmux new-split down --workspace workspace:1 --surface surface:2 --focus true");
    expect(prompt).toContain("cmux rename-tab --workspace workspace:1 --surface NEW_DEVIN_SURFACE Devin");
    expect(prompt).toContain("zsh -lc 'cd '\\''/work/project-x'\\'' && dey'");
    expect(prompt).toContain("send the pending prompt to that Devin surface");
  });

  test("omits Devin routing instructions when the Devin panel is disabled", () => {
    const prompt = buildOrchestratorPrompt({
      cwd: "/work/project-x",
      workspaceName: "project-x",
      workspaceId: "workspace:1",
      orchestratorSurfaceId: "surface:1",
      devinPanelEnabled: false,
      claudeSurfaceId: "surface:2",
      reusedClaude: false,
      reusedDevin: false,
    });

    expect(prompt).toContain("Devin panel: disabled");
    expect(prompt).toContain("Claude surface: surface:2");
    expect(prompt).not.toContain("Read Devin:");
    expect(prompt).not.toContain("Send Devin:");
    expect(prompt).not.toContain("ask Devin");
  });
});
