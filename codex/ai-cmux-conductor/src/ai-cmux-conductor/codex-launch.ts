import { spawn } from "node:child_process";
import { shellQuote } from "./conductor.ts";

export const CODEX_ORCHESTRATOR_COMMAND = "cxscb";
export const CODEX_ORCHESTRATOR_FLAGS = "--disable apps -c 'mcp_servers={}'";

export function buildCodexLaunchShellCommand(prompt: string): string {
  return `${CODEX_ORCHESTRATOR_COMMAND} ${CODEX_ORCHESTRATOR_FLAGS} ${shellQuote(prompt)}`;
}

export async function runCodexLauncher(prompt: string, cwd = process.cwd()): Promise<never> {
  const shellCommand = buildCodexLaunchShellCommand(prompt);
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
