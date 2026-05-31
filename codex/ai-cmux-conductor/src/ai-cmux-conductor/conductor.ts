import { spawn } from "node:child_process";
import { basename } from "node:path";

export interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

export type CommandRunner = (command: string, args: string[]) => Promise<CommandResult>;

export interface ConductorContext {
  cwd: string;
  workspaceName: string;
  workspaceId: string;
  orchestratorSurfaceId: string;
  claudeSurfaceId: string;
  devinSurfaceId: string;
  reusedClaude: boolean;
  reusedDevin: boolean;
}

export type PrepareConductorResult =
  | { mode: "handoff"; message: string }
  | { mode: "error"; message: string; command: string[]; stderr: string }
  | { mode: "ready"; context: ConductorContext };

export interface PrepareConductorOptions {
  cwd: string;
  env: Record<string, string | undefined>;
  runner?: CommandRunner;
}

interface CmuxSurface {
  ref?: string;
  title?: string;
  type?: string;
  pane_ref?: string;
}

export const defaultRunner: CommandRunner = (command, args) =>
  new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
    child.on("error", (error) => resolve({ code: 127, stdout, stderr: error.message }));
  });

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function workspaceName(cwd: string): string {
  return basename(cwd.replace(/\/+$/, "")) || "workspace";
}

function displayArg(arg: string): string {
  return /^[A-Za-z0-9_/:=.,@+-]+$/.test(arg) ? arg : shellQuote(arg);
}

function cmuxCommandText(command: string[]): string {
  return command.map(displayArg).join(" ");
}

function parseTreeSurfaces(stdout: string): CmuxSurface[] {
  const parsed = JSON.parse(stdout || "{}");
  const surfaces: CmuxSurface[] = [];
  for (const window of parsed.windows || []) {
    for (const workspace of window.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          surfaces.push(surface);
        }
      }
    }
  }
  return surfaces;
}

function surfaceByTitle(surfaces: CmuxSurface[], title: string): CmuxSurface | undefined {
  return surfaces.find((surface) => surface.title === title && surface.ref);
}

function surfaceForPane(surfaces: CmuxSurface[], paneRef: string): CmuxSurface | undefined {
  return surfaces.find((surface) => surface.pane_ref === paneRef && surface.ref && surface.type !== "browser");
}

function firstRef(stdout: string, prefix: string): string | undefined {
  return stdout.match(new RegExp(`${prefix}:[A-Za-z0-9_-]+`))?.[0] || stdout.match(/[0-9A-Fa-f-]{36}/)?.[0];
}

async function runOrThrow(runner: CommandRunner, command: string, args: string[]): Promise<CommandResult> {
  const result = await runner(command, args);
  if (result.code !== 0) {
    throw new Error(`${cmuxCommandText([command, ...args])} failed: ${result.stderr || result.stdout}`);
  }
  return result;
}

async function readTree(runner: CommandRunner, workspaceId: string, windowId?: string): Promise<CmuxSurface[]> {
  const args = ["--json", "tree", "--workspace", workspaceId];
  if (windowId) args.push("--window", windowId);
  const tree = await runOrThrow(runner, "cmux", args);
  return parseTreeSurfaces(tree.stdout);
}

async function ensureAgentSurface(options: {
  runner: CommandRunner;
  workspaceId: string;
  windowId?: string;
  cwd: string;
  title: "Claude" | "Devin";
  command: "clscb" | "dey";
  surfaces: CmuxSurface[];
}): Promise<{ surfaceId: string; reused: boolean; surfaces: CmuxSurface[] }> {
  const existing = surfaceByTitle(options.surfaces, options.title);
  if (existing?.ref) return { surfaceId: existing.ref, reused: true, surfaces: options.surfaces };

  const newPane = await runOrThrow(options.runner, "cmux", [
    "new-pane",
    "--direction",
    "right",
    "--workspace",
    options.workspaceId,
    "--focus",
    "false",
  ]);
  const paneRef = firstRef(newPane.stdout, "pane");
  const refreshed = await readTree(options.runner, options.workspaceId, options.windowId);
  const created = (paneRef && surfaceForPane(refreshed, paneRef)) || surfaceByTitle(refreshed, options.title);
  if (!created?.ref) {
    throw new Error(`Unable to find cMUX surface for ${options.title} after creating ${paneRef || "a pane"}`);
  }

  await runOrThrow(options.runner, "cmux", ["rename-tab", "--workspace", options.workspaceId, "--surface", created.ref, options.title]);
  const launch = `zsh -lc ${shellQuote(`cd ${shellQuote(options.cwd)} && ${options.command}`)}\n`;
  await runOrThrow(options.runner, "cmux", ["send", "--workspace", options.workspaceId, "--surface", created.ref, launch]);
  return { surfaceId: created.ref, reused: false, surfaces: refreshed };
}

export async function prepareConductor(options: PrepareConductorOptions): Promise<PrepareConductorResult> {
  const runner = options.runner || defaultRunner;
  const cwd = options.cwd;
  const name = workspaceName(cwd);
  const workspaceId = options.env.CMUX_WORKSPACE_ID;

  if (!workspaceId) {
    const command = ["cmux", "new-workspace", "--name", name, "--cwd", cwd, "--focus", "true", "--command", "aicc"];
    const result = await runner(command[0], command.slice(1));
    if (result.code === 0) {
      return { mode: "handoff", message: `Started cMUX workspace '${name}' for ${cwd}; conductor will continue inside cMUX.` };
    }
    return {
      mode: "error",
      message: `aicc needs cMUX. Tried once to create workspace '${name}' and failed. Run manually: ${cmuxCommandText(command)}`,
      command,
      stderr: result.stderr || result.stdout,
    };
  }

  const windowId = options.env.CMUX_WINDOW_ID;
  const orchestratorSurfaceId = options.env.CMUX_SURFACE_ID || "current";
  await runOrThrow(runner, "cmux", ["rename-workspace", "--workspace", workspaceId, name]);
  let surfaces = await readTree(runner, workspaceId);
  const claude = await ensureAgentSurface({ runner, workspaceId, windowId, cwd, title: "Claude", command: "clscb", surfaces });
  surfaces = claude.surfaces;
  const devin = await ensureAgentSurface({ runner, workspaceId, windowId, cwd, title: "Devin", command: "dey", surfaces });

  return {
    mode: "ready",
    context: {
      cwd,
      workspaceName: name,
      workspaceId,
      orchestratorSurfaceId,
      claudeSurfaceId: claude.surfaceId,
      devinSurfaceId: devin.surfaceId,
      reusedClaude: claude.reused,
      reusedDevin: devin.reused,
    },
  };
}

export function buildOrchestratorPrompt(context: ConductorContext): string {
  return `You are ai-cmux-conductor, the base Codex orchestrator for this cMUX workspace.

## Workspace context
- Workspace name: ${context.workspaceName}
- Workspace ID: ${context.workspaceId}
- Working directory: ${context.cwd}
- Orchestrator surface: ${context.orchestratorSurfaceId}
- Claude surface: ${context.claudeSurfaceId} (${context.reusedClaude ? "reused existing pane" : "created new pane"})
- Devin surface: ${context.devinSurfaceId} (${context.reusedDevin ? "reused existing pane" : "created new pane"})

## Role
Stay in this base tab and coordinate the Claude and Devin panes in the same workspace. The user will mostly talk to you. When the user says "ask Claude", "send to Claude", "ask Devin", or "send to Devin", route the instruction to the matching pane.

## cMUX commands
- Read Claude: cmux read-screen --workspace ${context.workspaceId} --surface ${context.claudeSurfaceId} --scrollback --lines 160
- Read Devin: cmux read-screen --workspace ${context.workspaceId} --surface ${context.devinSurfaceId} --scrollback --lines 160
- Send Claude: cmux send --workspace ${context.workspaceId} --surface ${context.claudeSurfaceId} -- "PROMPT\\n"
- Send Devin: cmux send --workspace ${context.workspaceId} --surface ${context.devinSurfaceId} -- "PROMPT\\n"

## Operating rules
1. Periodically inspect Claude and Devin with cmux read-screen and summarize meaningful changes to the user.
2. Keep tool use scoped to this workspace ID and the stable surface IDs above.
3. If an existing Claude or Devin pane looks dead, wrong, or unrelated, report that and ask before replacing it.
4. Do not kill, close, or respawn agent panes without explicit user approval.
5. Use concise status updates: Claude, Devin, blockers, and recommended next action.`;
}

export function conductorHelpText(): string {
  return `ai-cmux-conductor / aicc — cMUX AI workspace conductor

Usage:
  aicc                         Bootstrap current cMUX workspace and open Codex orchestrator
  aicc "initial request"        Same, with an initial request for the orchestrator
  ai-cmux-conductor --help      Show this help

Behavior:
  - Outside cMUX: tries once to create a focused cMUX workspace for $PWD with command 'aicc', then exits.
  - Inside cMUX: renames workspace to the current directory, reuses/creates Claude and Devin panes, then opens Codex as the base orchestrator.
  - Claude pane command: zsh -lc 'cd <cwd> && clscb'
  - Devin pane command: zsh -lc 'cd <cwd> && dey'

No pro- prefix. The short global alias is aicc.`;
}
