import { spawn } from "node:child_process";
import { shellQuote } from "./conductor.ts";

export type OrchestratorAgentName = "claude" | "codex" | "devin";

export const ORCHESTRATOR_AGENT_NAMES: readonly OrchestratorAgentName[] = ["claude", "codex", "devin"];

export const DEFAULT_ORCHESTRATOR_AGENT: OrchestratorAgentName = "codex";

export const CODEX_ORCHESTRATOR_COMMAND = "cxscb";
export const CODEX_ORCHESTRATOR_FLAGS = "--disable apps -c 'mcp_servers={}'";
export const CLAUDE_ORCHESTRATOR_COMMAND = "clscb";
export const DEVIN_ORCHESTRATOR_COMMAND = "devin";
export const DEVIN_ORCHESTRATOR_FLAGS = "--permission-mode dangerous --";

export const ORCHESTRATOR_LAUNCH_PREFIXES: Record<OrchestratorAgentName, string> = {
  claude: CLAUDE_ORCHESTRATOR_COMMAND,
  codex: `${CODEX_ORCHESTRATOR_COMMAND} ${CODEX_ORCHESTRATOR_FLAGS}`,
  devin: `${DEVIN_ORCHESTRATOR_COMMAND} ${DEVIN_ORCHESTRATOR_FLAGS}`,
};

export function isOrchestratorAgentName(value: string | undefined): value is OrchestratorAgentName {
  return Boolean(value) && (ORCHESTRATOR_AGENT_NAMES as readonly string[]).includes(value as string);
}

export function orchestratorAgentDisplayName(agent: OrchestratorAgentName): "Claude" | "Codex" | "Devin" {
  if (agent === "claude") return "Claude";
  if (agent === "devin") return "Devin";
  return "Codex";
}

export function buildAgentLaunchShellCommand(agent: OrchestratorAgentName, prompt: string): string {
  return `${ORCHESTRATOR_LAUNCH_PREFIXES[agent]} ${shellQuote(prompt)}`;
}

export async function runAgentLauncher(agent: OrchestratorAgentName, prompt: string, cwd = process.cwd()): Promise<never> {
  const shellCommand = buildAgentLaunchShellCommand(agent, prompt);
  await new Promise<void>((resolve, reject) => {
    const child = spawn("zsh", ["-lc", shellCommand], {
      cwd,
      stdio: "inherit",
      env: process.env,
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (signal) process.exit(130);
      process.exit(code ?? 0);
    });
  });

  process.exit(0);
}
