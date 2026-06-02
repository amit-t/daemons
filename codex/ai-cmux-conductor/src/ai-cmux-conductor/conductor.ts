import { spawn } from "node:child_process";
import { basename } from "node:path";
import { DEVIN_PANEL_FEATURE_FLAG, isDevinPanelEnabled } from "./config.ts";

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
  devinPanelEnabled: boolean;
  devinSurfaceId?: string;
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
  id?: string;
  ref?: string;
  title?: string;
  type?: string;
  pane_id?: string;
  pane_ref?: string;
}

interface CmuxWorkspace {
  id?: string;
  ref?: string;
  title?: string;
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
  const name = basename(cwd.replace(/\/+$/, "")) || "workspace";
  return name.replace(/[\p{L}\p{N}]+/gu, (word) => {
    const [first = "", ...rest] = Array.from(word);
    return `${first.toLocaleUpperCase()}${rest.join("").toLocaleLowerCase()}`;
  });
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

function parseTreeWorkspaces(stdout: string): CmuxWorkspace[] {
  const parsed = JSON.parse(stdout || "{}");
  const workspaces: CmuxWorkspace[] = [];
  for (const window of parsed.windows || []) {
    for (const workspace of window.workspaces || []) {
      workspaces.push(workspace);
    }
  }
  return workspaces;
}

function surfaceByTitle(surfaces: CmuxSurface[], title: string): CmuxSurface | undefined {
  return surfaces.find((surface) => surface.title === title && surface.ref);
}

function surfaceByAgentTitle(surfaces: CmuxSurface[], title: "Claude" | "Devin"): CmuxSurface | undefined {
  const agentPattern = new RegExp(`\\b${title}\\b`, "i");
  return surfaces.find((surface) => surface.type !== "browser" && surfaceId(surface) && agentPattern.test(surface.title || ""));
}

function surfaceForPane(surfaces: CmuxSurface[], paneRef: string): CmuxSurface | undefined {
  return surfaces.find((surface) => (surface.pane_ref === paneRef || surface.pane_id === paneRef) && (surface.ref || surface.id) && surface.type !== "browser");
}

function surfaceByIdOrRef(surfaces: CmuxSurface[], idOrRef?: string): CmuxSurface | undefined {
  return surfaces.find((surface) => surface.ref === idOrRef || surface.id === idOrRef);
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
  const args = ["--id-format", "both", "--json", "tree", "--workspace", workspaceId];
  if (windowId) args.push("--window", windowId);
  const tree = await runOrThrow(runner, "cmux", args);
  return parseTreeSurfaces(tree.stdout);
}

async function readWorkspaces(runner: CommandRunner, workspaceId: string, windowId?: string): Promise<CmuxWorkspace[]> {
  const args = ["--id-format", "both", "--json", "tree", "--workspace", workspaceId];
  if (windowId) args.push("--window", windowId);
  const tree = await runOrThrow(runner, "cmux", args);
  return parseTreeWorkspaces(tree.stdout);
}

function windowArgs(windowId?: string): string[] {
  return windowId ? ["--window", windowId] : [];
}

function workspaceByIdOrRef(workspaces: CmuxWorkspace[], idOrRef: string): CmuxWorkspace | undefined {
  return workspaces.find((workspace) => workspace.id === idOrRef || workspace.ref === idOrRef) || (workspaces.length === 1 ? workspaces[0] : undefined);
}

async function workspaceHasTitle(runner: CommandRunner, workspaceId: string, windowId: string | undefined, title: string): Promise<boolean> {
  const workspaces = await readWorkspaces(runner, workspaceId, windowId);
  return workspaceByIdOrRef(workspaces, workspaceId)?.title === title;
}

async function renameWorkspace(runner: CommandRunner, workspaceId: string, windowId: string | undefined, title: string): Promise<void> {
  const initialWorkspaces = await readWorkspaces(runner, workspaceId, windowId);
  const initialWorkspace = workspaceByIdOrRef(initialWorkspaces, workspaceId);
  const targets = Array.from(new Set([workspaceId, initialWorkspace?.ref, initialWorkspace?.id].filter((target): target is string => Boolean(target))));
  const errors: string[] = [];

  for (const target of targets) {
    const attempts = [
      ["rename-workspace", "--workspace", target, ...windowArgs(windowId), title],
      ["workspace-action", "--action", "rename", "--workspace", target, ...windowArgs(windowId), "--title", title],
    ];

    for (const args of attempts) {
      const result = await runner("cmux", args);
      if (result.code !== 0) {
        errors.push(`${cmuxCommandText(["cmux", ...args])}: ${result.stderr || result.stdout}`);
        continue;
      }
      if (await workspaceHasTitle(runner, workspaceId, windowId, title)) return;
      errors.push(`${cmuxCommandText(["cmux", ...args])}: title did not change`);
    }
  }

  const observed = workspaceByIdOrRef(await readWorkspaces(runner, workspaceId, windowId), workspaceId)?.title || "unknown";
  throw new Error(`Unable to rename cMUX workspace to ${shellQuote(title)}; observed title is ${shellQuote(observed)}. ${errors.join("; ")}`);
}

function surfaceId(surface: CmuxSurface): string | undefined {
  return surface.ref || surface.id;
}

async function createAgentSurface(options: {
  runner: CommandRunner;
  workspaceId: string;
  windowId?: string;
  cwd: string;
  title: "Claude" | "Devin";
  command: "clscb" | "dey";
  direction: "right" | "down";
  splitFromSurfaceRef?: string;
  focusPaneRef?: string;
  surfaces: CmuxSurface[];
}): Promise<{ surfaceId: string; reused: boolean; surfaces: CmuxSurface[] }> {
  const existing = surfaceByAgentTitle(options.surfaces, options.title);
  const existingId = existing && surfaceId(existing);
  if (existingId) {
    return { surfaceId: existingId, reused: true, surfaces: options.surfaces };
  }

  if (options.splitFromSurfaceRef) {
    const split = await runOrThrow(options.runner, "cmux", [
      "new-split",
      options.direction,
      "--workspace",
      options.workspaceId,
      "--surface",
      options.splitFromSurfaceRef,
      "--focus",
      "false",
      ...windowArgs(options.windowId),
    ]);
    const paneRef = firstRef(split.stdout, "pane");
    const newSurfaceRef = firstRef(split.stdout, "surface");
    const refreshed = await readTree(options.runner, options.workspaceId, options.windowId);
    const created =
      (newSurfaceRef && surfaceByIdOrRef(refreshed, newSurfaceRef)) ||
      (paneRef && surfaceForPane(refreshed, paneRef)) ||
      surfaceByTitle(refreshed, options.title);
    const createdId = created && surfaceId(created);
    if (!createdId) {
      throw new Error(`Unable to find cMUX surface for ${options.title} after creating ${newSurfaceRef || paneRef || "a pane"}`);
    }
    await runOrThrow(options.runner, "cmux", ["rename-tab", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdId, options.title]);
    const launch = `zsh -lc ${shellQuote(`cd ${shellQuote(options.cwd)} && ${options.command}`)}\n`;
    await runOrThrow(options.runner, "cmux", ["send", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdId, launch]);
    return { surfaceId: createdId, reused: false, surfaces: refreshed };
  }

  if (options.focusPaneRef) {
    await runOrThrow(options.runner, "cmux", [
      "focus-pane",
      "--pane",
      options.focusPaneRef,
      "--workspace",
      options.workspaceId,
      ...windowArgs(options.windowId),
    ]);
  }

  const newPane = await runOrThrow(options.runner, "cmux", [
    "new-pane",
    "--direction",
    options.direction,
    "--workspace",
    options.workspaceId,
    "--focus",
    "false",
    ...windowArgs(options.windowId),
  ]);
  const paneRef = firstRef(newPane.stdout, "pane");
  const newSurfaceRef = firstRef(newPane.stdout, "surface");
  const refreshed = await readTree(options.runner, options.workspaceId, options.windowId);
  const created =
    (newSurfaceRef && surfaceByIdOrRef(refreshed, newSurfaceRef)) ||
    (paneRef && surfaceForPane(refreshed, paneRef)) ||
    surfaceByTitle(refreshed, options.title);
  const createdId = created && surfaceId(created);
  if (!createdId) {
    throw new Error(`Unable to find cMUX surface for ${options.title} after creating ${newSurfaceRef || paneRef || "a pane"}`);
  }
  await runOrThrow(options.runner, "cmux", ["rename-tab", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdId, options.title]);
  const launch = `zsh -lc ${shellQuote(`cd ${shellQuote(options.cwd)} && ${options.command}`)}\n`;
  await runOrThrow(options.runner, "cmux", ["send", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdId, launch]);
  return { surfaceId: createdId, reused: false, surfaces: refreshed };
}

export async function prepareConductor(options: PrepareConductorOptions): Promise<PrepareConductorResult> {
  const runner = options.runner || defaultRunner;
  const cwd = options.cwd;
  const name = workspaceName(cwd);
  const workspaceId = options.env.CMUX_WORKSPACE_ID;
  const devinPanelEnabled = isDevinPanelEnabled(options.env);

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
  await runOrThrow(runner, "cmux", ["rename-tab", "--workspace", workspaceId, ...windowArgs(windowId), "--surface", orchestratorSurfaceId, "codex"]);
  let surfaces = await readTree(runner, workspaceId, windowId);
  const orchestratorSurface = surfaceByIdOrRef(surfaces, orchestratorSurfaceId);
  const claude = await createAgentSurface({
    runner,
    workspaceId,
    windowId,
    cwd,
    title: "Claude",
    command: "clscb",
    direction: "right",
    focusPaneRef: orchestratorSurface?.pane_ref || orchestratorSurface?.pane_id,
    surfaces,
  });
  surfaces = claude.surfaces;
  const claudeSurface = surfaceByIdOrRef(surfaces, claude.surfaceId);
  const claudeSurfaceRef = claudeSurface && surfaceId(claudeSurface);
  if (!claudeSurfaceRef) {
    throw new Error(`Unable to find cMUX surface for Claude after creating ${claude.surfaceId}`);
  }
  let devin: { surfaceId?: string; reused: boolean } = { reused: false };
  if (devinPanelEnabled) {
    devin = await createAgentSurface({
      runner,
      workspaceId,
      windowId,
      cwd,
      title: "Devin",
      command: "dey",
      direction: "down",
      splitFromSurfaceRef: claudeSurfaceRef,
      surfaces,
    });
  }
  await renameWorkspace(runner, workspaceId, windowId, name);

  return {
    mode: "ready",
    context: {
      cwd,
      workspaceName: name,
      workspaceId,
      orchestratorSurfaceId,
      claudeSurfaceId: claude.surfaceId,
      devinPanelEnabled,
      devinSurfaceId: devin.surfaceId,
      reusedClaude: claude.reused,
      reusedDevin: devin.reused,
    },
  };
}

export function buildOrchestratorPrompt(context: ConductorContext): string {
  const devinEnabled = context.devinPanelEnabled && context.devinSurfaceId;
  const devinContext = devinEnabled
    ? `- Devin surface: ${context.devinSurfaceId} (${context.reusedDevin ? "reused existing pane" : "created new pane"})`
    : `- Devin panel: disabled (${DEVIN_PANEL_FEATURE_FLAG}=false)`;
  const devinRole = devinEnabled
    ? ` When the user says "ask Claude", "send to Claude", "ask Devin", or "send to Devin", route the instruction to the matching pane.`
    : ` When the user says "ask Claude" or "send to Claude", route the instruction to Claude. Devin routing is disabled by ${DEVIN_PANEL_FEATURE_FLAG}.`;
  const devinLaunchCommand = `zsh -lc ${shellQuote(`cd ${shellQuote(context.cwd)} && dey`)}`;
  const devinCommands = devinEnabled
    ? `- Read Devin: cmux read-screen --workspace ${context.workspaceId} --surface ${context.devinSurfaceId} --scrollback --lines 160
- Send Devin: cmux send --workspace ${context.workspaceId} --surface ${context.devinSurfaceId} -- "PROMPT\\n"
- Open/repair Devin below Claude when needed:
  1. cmux new-split down --workspace ${context.workspaceId} --surface ${context.claudeSurfaceId} --focus true
  2. cmux rename-tab --workspace ${context.workspaceId} --surface NEW_DEVIN_SURFACE Devin
  3. cmux send --workspace ${context.workspaceId} --surface NEW_DEVIN_SURFACE -- "${devinLaunchCommand}\\n"
  4. Wait for the Devin CLI UI, then send the pending prompt to that Devin surface.`
    : "";
  const agents = devinEnabled ? "Claude and Devin" : "Claude";
  const agentPaneNoun = devinEnabled ? "panes" : "pane";
  const managedAgent = devinEnabled ? "Claude or Devin" : "Claude";
  const operatingRules = devinEnabled
    ? `1. Periodically inspect ${agents} with cmux read-screen and summarize meaningful changes to the user.
2. Keep tool use scoped to this workspace ID and the stable surface IDs above.
3. When the user says "ask Devin" or "send to Devin", always use the Devin pane. If it is missing, closed, dead, or not running Devin, open Devin in interactive yolo mode below Claude with the commands above, then send the pending prompt to that Devin surface.
4. If an existing ${managedAgent} pane looks dead, wrong, or unrelated outside an explicit Devin-routing request, report that and ask before replacing it.
5. Do not kill, close, or respawn Claude, Codex, or unrelated user terminal panes without explicit user approval.
6. Treat the user's explicit request to ask Devin as approval to open/repair only the Devin pane with \`dey\`.
7. Claude auto-resume runs in the AICC daemon. For sitrep, run: aicc --status.
8. Use concise status updates: ${agents}, blockers, and recommended next action.`
    : `1. Periodically inspect ${agents} with cmux read-screen and summarize meaningful changes to the user.
2. Keep tool use scoped to this workspace ID and the stable surface IDs above.
3. If an existing ${managedAgent} pane looks dead, wrong, or unrelated, report that and ask before replacing it.
4. Do not kill, close, or respawn Claude, Codex, or unrelated user terminal panes without explicit user approval.
5. Claude auto-resume runs in the AICC daemon. For sitrep, run: aicc --status.
6. Use concise status updates: ${agents}, blockers, and recommended next action.`;

  return `You are ai-cmux-conductor, the base Codex orchestrator for this cMUX workspace.

## Workspace context
- Workspace name: ${context.workspaceName}
- Workspace ID: ${context.workspaceId}
- Working directory: ${context.cwd}
- Orchestrator surface: ${context.orchestratorSurfaceId}
- Claude surface: ${context.claudeSurfaceId} (${context.reusedClaude ? "reused existing pane" : "created new pane"})
${devinContext}

## Role
Stay in this base tab and coordinate the ${agents} ${agentPaneNoun} in the same workspace. The user will mostly talk to you.${devinRole}

## cMUX commands
- Read Claude: cmux read-screen --workspace ${context.workspaceId} --surface ${context.claudeSurfaceId} --scrollback --lines 160
- Send Claude: cmux send --workspace ${context.workspaceId} --surface ${context.claudeSurfaceId} -- "PROMPT\\n"
${devinCommands}

## Operating rules
${operatingRules}`;
}

export function conductorHelpText(): string {
  return `ai-cmux-conductor / aicc — cMUX AI workspace conductor

Usage:
  aicc                         Bootstrap current cMUX workspace and open Codex orchestrator
  aicc "initial request"        Same, with an initial request for the orchestrator
  ai-cmux-conductor --help      Show this help
  aicc --status                 Show Claude auto-resume daemon sitrep
  aicc --daemon                 Run Claude auto-resume watcher loop
  aicc --stop-daemon            Stop Claude auto-resume watcher loop

Behavior:
  - Outside cMUX: tries once to create a focused cMUX workspace for $PWD with command 'aicc', then exits.
  - Inside cMUX: renames the current tab to codex, reuses existing Claude/Devin panes when present, creates missing panes, verifies the workspace is named after the title-cased current directory, then opens Codex as the base orchestrator.
  - Devin panel feature flag: ${DEVIN_PANEL_FEATURE_FLAG}=true by default in environment.env. Set it to false to skip Devin.
  - Codex orchestrator command: cxscb
  - Claude pane command: zsh -lc 'cd <cwd> && clscb'
  - Devin pane command when enabled: zsh -lc 'cd <cwd> && dey'
  - Claude auto-resume: registers Claude panes, watches read-screen --scrollback, persists reset schedules, and sends continue after reset + 60 seconds.
  - Existing Claude/Devin panes are preserved; AICC does not close or respawn them during bootstrap.

No pro- prefix. The short global alias is aicc.`;
}
