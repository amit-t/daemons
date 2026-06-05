import { defaultRunner, type CommandResult, type CommandRunner } from "./conductor.ts";
import { isClaudePanelEnabled, isCodexPanelEnabled, isDevinPanelEnabled } from "./config.ts";

export type AiCmuxResetAgent = "Claude" | "Codex" | "Devin";

export interface AiCmuxResetBlocker {
  agent: AiCmuxResetAgent;
  surfaceId: string;
  reason: string;
}

export type AiCmuxResetResult =
  | {
      mode: "reset";
      workspaceId: string;
      terminalSurfaceId: string;
      closedSurfaceIds: string[];
    }
  | {
      mode: "blocked";
      workspaceId: string;
      blockers: AiCmuxResetBlocker[];
    }
  | {
      mode: "error";
      message: string;
      workspaceId?: string;
    };

export interface AiCmuxResetOptions {
  env: Record<string, string | undefined>;
  runner?: CommandRunner;
  beforeClose?: () => Promise<void>;
}

interface CmuxSurface {
  id?: string;
  ref?: string;
  title?: string;
  type?: string;
  pane_id?: string;
  pane_ref?: string;
}

interface AgentSurface {
  agent: AiCmuxResetAgent;
  surface: CmuxSurface;
  surfaceId: string;
}

interface AgentReadiness {
  safe: boolean;
  reason: string;
}

export function isExplicitResetRequest(prompt: string): boolean {
  return prompt === "Reset";
}

export async function resetAiCmuxWorkspace(options: AiCmuxResetOptions): Promise<AiCmuxResetResult> {
  const runner = options.runner || defaultRunner;
  const workspaceId = options.env.CMUX_WORKSPACE_ID;
  const windowId = options.env.CMUX_WINDOW_ID;
  const currentSurfaceId = options.env.CMUX_SURFACE_ID;
  if (!workspaceId) return { mode: "error", message: "AICC reset requires cMUX; CMUX_WORKSPACE_ID is not set." };

  let surfaces: CmuxSurface[];
  try {
    surfaces = await readCmuxTreeSurfaces(runner, workspaceId, windowId);
  } catch (error) {
    return { mode: "error", workspaceId, message: `AICC reset could not inspect cMUX workspace: ${errorMessage(error)}` };
  }

  const agentSurfaces = discoverAgentSurfaces(surfaces, {
    includeClaude: isClaudePanelEnabled(options.env),
    includeCodexPanel: isCodexPanelEnabled(options.env),
    includeDevin: isDevinPanelEnabled(options.env),
  });
  const blockers: AiCmuxResetBlocker[] = [];
  for (const agentSurface of agentSurfaces) {
    try {
      const screen = await readSurfaceScreen(runner, workspaceId, windowId, agentSurface.surfaceId);
      const readiness = classifyAgentReadiness(agentSurface.agent, screen);
      if (!readiness.safe) {
        blockers.push({
          agent: agentSurface.agent,
          surfaceId: agentSurface.surfaceId,
          reason: readiness.reason,
        });
      }
    } catch (error) {
      blockers.push({
        agent: agentSurface.agent,
        surfaceId: agentSurface.surfaceId,
        reason: `could not inspect screen: ${errorMessage(error)}`,
      });
    }
  }

  if (blockers.length) return { mode: "blocked", workspaceId, blockers };

  const codexSurface = resolveCodexSurface(surfaces, currentSurfaceId);
  const codexSurfaceId = codexSurface && surfaceId(codexSurface);
  const codexPaneRef = codexSurface?.pane_ref || codexSurface?.pane_id;
  if (!codexSurface || !codexSurfaceId || !codexPaneRef) {
    return {
      mode: "error",
      workspaceId,
      message: `AICC reset could not find the Codex surface/pane (${currentSurfaceId || "current surface unknown"}).`,
    };
  }

  const terminal = await createBasicTerminalSurface(
    runner,
    workspaceId,
    windowId,
    codexPaneRef,
    new Set(surfaces.map((surface) => surfaceId(surface)).filter((id): id is string => Boolean(id))),
  );
  if (terminal.mode === "error") return { ...terminal, workspaceId };

  if (options.beforeClose) await options.beforeClose();

  const targetIds = uniqueSurfaceIds([...agentSurfaces.map((agentSurface) => agentSurface.surfaceId), codexSurfaceId]).filter(
    (targetId) => targetId !== terminal.terminalSurfaceId,
  );
  const closedSurfaceIds: string[] = [];
  for (const targetId of targetIds) {
    const result = await runner("cmux", ["close-surface", "--workspace", workspaceId, ...windowArgs(windowId), "--surface", targetId]);
    if (result.code !== 0) {
      return {
        mode: "error",
        workspaceId,
        message: `AICC reset could not close ${targetId}: ${exactFailure("cmux close-surface", result)}`,
      };
    }
    closedSurfaceIds.push(targetId);
  }

  return {
    mode: "reset",
    workspaceId,
    terminalSurfaceId: terminal.terminalSurfaceId,
    closedSurfaceIds,
  };
}

async function createBasicTerminalSurface(
  runner: CommandRunner,
  workspaceId: string,
  windowId: string | undefined,
  paneRef: string,
  previousSurfaceIds: Set<string>,
): Promise<{ mode: "ok"; terminalSurfaceId: string } | { mode: "error"; message: string }> {
  const create = await runner("cmux", [
    "new-surface",
    "--workspace",
    workspaceId,
    ...windowArgs(windowId),
    "--pane",
    paneRef,
    "--type",
    "terminal",
    "--focus",
    "true",
  ]);
  if (create.code !== 0) {
    return { mode: "error", message: `AICC reset could not create a basic terminal: ${exactFailure("cmux new-surface", create)}` };
  }

  const createdRef = firstCmuxRef(create.stdout, "surface");
  const surfaces = await readCmuxTreeSurfaces(runner, workspaceId, windowId);
  const createdSurface =
    (createdRef && surfaces.find((surface) => surfaceId(surface) === createdRef)) ||
    surfaces.find((surface) => {
      const id = surfaceId(surface);
      return (surface.pane_ref === paneRef || surface.pane_id === paneRef) && Boolean(id) && !previousSurfaceIds.has(id!);
    });
  const terminalSurfaceId = createdSurface && surfaceId(createdSurface);
  if (!terminalSurfaceId) return { mode: "error", message: `AICC reset could not find the new terminal surface in pane ${paneRef}.` };

  const rename = await runner("cmux", ["rename-tab", "--workspace", workspaceId, ...windowArgs(windowId), "--surface", terminalSurfaceId, "terminal"]);
  if (rename.code !== 0) {
    return { mode: "error", message: `AICC reset could not rename the basic terminal: ${exactFailure("cmux rename-tab", rename)}` };
  }

  return { mode: "ok", terminalSurfaceId };
}

function classifyAgentReadiness(agent: AiCmuxResetAgent, screenText: string): AgentReadiness {
  const lines = screenText.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const recentLines = lines.slice(-80);
  const recentText = recentLines.join("\n");

  if (!recentLines.length) return { safe: true, reason: `${agent} screen is empty` };

  const unresolved = [...recentLines].reverse().find((line) => unresolvedWorkPattern.test(line));
  if (unresolved) return { safe: false, reason: compactReason(unresolved) };

  const terminal = [...recentLines].reverse().find((line) => idlePattern.test(line) || completedPattern.test(line) || shellPromptPattern.test(line));
  if (terminal) return { safe: true, reason: compactReason(terminal) };

  const active = [...recentLines].reverse().find((line) => activeWorkPattern.test(line));
  if (active) return { safe: false, reason: compactReason(active) };

  if (agentUiPattern(agent).test(recentText)) return { safe: false, reason: `${agent} state is unclear; no idle or completed marker found` };
  return { safe: true, reason: `${agent} UI is not visible` };
}

const unresolvedWorkPattern =
  /\b(waiting for|awaiting|needs?|requires?|blocked|stuck|cannot proceed|can't proceed|approval|confirmation|permission|credential|token|unauthorized|forbidden|error|failed|failure|exception)\b/i;
const idlePattern = /\b(ready for (?:your )?(?:next )?(?:task|prompt)|what can i help|how can i help|start a new task|no pending work)\b|^>\s*$/i;
const completedPattern = /\b(task complete|ready for review|completed|complete|finished|done)\b/i;
const activeWorkPattern =
  /\b(thinking|working|running|executing|processing|applying|editing|writing|analyzing|planning|searching|reading|installing|building|testing|in progress|esc to interrupt|interrupt)\b|[✻✽✶✢]\s*\w+/i;
const shellPromptPattern = /(?:^|[/~\w.-])\s[%$#]\s*$/;

function agentUiPattern(agent: AiCmuxResetAgent): RegExp {
  if (agent === "Claude") return /\b(Claude Code|Welcome to Claude|Opus|Sonnet|Haiku|Claude)\b/i;
  if (agent === "Codex") return /\b(Codex|codex|OpenAI|GPT)\b/i;
  return /\b(Devin|devin)\b/i;
}

function compactReason(value: string): string {
  return value.replace(/\s+/g, " ").trim().slice(0, 180);
}

async function readCmuxTreeSurfaces(runner: CommandRunner, workspaceId: string, windowId?: string): Promise<CmuxSurface[]> {
  const result = await runner("cmux", ["--id-format", "both", "--json", "tree", "--workspace", workspaceId, ...windowArgs(windowId)]);
  if (result.code !== 0) throw new Error(exactFailure("cmux tree", result));
  return parseTreeSurfaces(result.stdout);
}

async function readSurfaceScreen(runner: CommandRunner, workspaceId: string, windowId: string | undefined, surfaceIdValue: string): Promise<string> {
  const result = await runner("cmux", [
    "read-screen",
    "--workspace",
    workspaceId,
    ...windowArgs(windowId),
    "--surface",
    surfaceIdValue,
    "--scrollback",
    "--lines",
    "220",
  ]);
  if (result.code !== 0) throw new Error(exactFailure("cmux read-screen", result));
  return result.stdout;
}

function parseTreeSurfaces(stdout: string): CmuxSurface[] {
  const parsed = JSON.parse(stdout || "{}");
  const surfaces: CmuxSurface[] = [];
  for (const window of parsed.windows || []) {
    for (const workspace of window.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) surfaces.push(surface);
      }
    }
  }
  return surfaces;
}

function discoverAgentSurfaces(
  surfaces: CmuxSurface[],
  options: { includeClaude: boolean; includeCodexPanel: boolean; includeDevin: boolean },
): AgentSurface[] {
  return surfaces
    .map((surface): AgentSurface | undefined => {
      const id = surfaceId(surface);
      if (!id || surface.type === "browser") return undefined;
      if (options.includeClaude && /\bClaude\b/i.test(surface.title || "")) return { agent: "Claude", surface, surfaceId: id };
      if (options.includeCodexPanel && surface.title === "Codex") return { agent: "Codex", surface, surfaceId: id };
      if (options.includeDevin && /\bDevin\b/i.test(surface.title || "")) return { agent: "Devin", surface, surfaceId: id };
      return undefined;
    })
    .filter((surface): surface is AgentSurface => Boolean(surface));
}

function resolveCodexSurface(surfaces: CmuxSurface[], preferredId?: string): CmuxSurface | undefined {
  const preferred = preferredId ? surfaces.find((surface) => surface.id === preferredId || surface.ref === preferredId) : undefined;
  if (preferred && preferred.type !== "browser") return preferred;
  return surfaces.find((surface) => surface.type !== "browser" && surface.title === "codex");
}

function uniqueSurfaceIds(ids: string[]): string[] {
  return Array.from(new Set(ids));
}

function firstCmuxRef(stdout: string, prefix: string): string | undefined {
  return stdout.match(new RegExp(`${prefix}:[A-Za-z0-9_-]+`))?.[0] || stdout.match(/[0-9A-Fa-f-]{36}/)?.[0];
}

function surfaceId(surface: CmuxSurface): string | undefined {
  return surface.ref || surface.id;
}

function windowArgs(windowId?: string): string[] {
  return windowId ? ["--window", windowId] : [];
}

function exactFailure(command: string, result: CommandResult): string {
  const output = (result.stderr || result.stdout).trim();
  return `${command} failed${output ? `: ${output}` : ` with exit ${result.code}`}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function buildResetStatusText(result: AiCmuxResetResult): string {
  if (result.mode === "reset") {
    return `AICC reset complete: opened basic terminal ${result.terminalSurfaceId}; closed ${result.closedSurfaceIds.join(", ")}.`;
  }
  if (result.mode === "blocked") {
    return `I cannot reset: ${result.blockers
      .map((blocker) => `${blocker.agent} appears active on ${blocker.surfaceId} (${blocker.reason})`)
      .join("; ")}.`;
  }
  return result.message;
}
