import {
  DEFAULT_ORCHESTRATOR_AGENT,
  isOrchestratorAgentName,
  type OrchestratorAgentName,
} from "./agent-launch.ts";

export interface AiCmuxConductorArgs {
  interactive: boolean;
  quiet: boolean;
  help: boolean;
  status: boolean;
  events: boolean;
  unread: boolean;
  reset: boolean;
  daemon: boolean;
  stopDaemon: boolean;
  noWarm: boolean;
  noArgs: boolean;
  effort?: string;
  agent: OrchestratorAgentName;
  agentError?: string;
  prompt: string;
}

const FLAG_NAMES = new Set([
  "-i",
  "--interactive",
  "-q",
  "--quiet",
  "-h",
  "--help",
  "--status",
  "--auto-resume-status",
  "--events",
  "--unread",
  "--reset",
  "--daemon",
  "--stop-daemon",
  "--no-warm",
  "--claude",
  "--codex",
  "--devin",
]);

export function parseAiCmuxConductorArgs(argv: string[]): AiCmuxConductorArgs {
  const args = argv.slice(2);
  const interactive = args.includes("-i") || args.includes("--interactive");
  const quiet = args.includes("-q") || args.includes("--quiet");
  const help = args.includes("-h") || args.includes("--help");
  const status = args.includes("--status") || args.includes("--auto-resume-status");
  const events = args.includes("--events");
  const unread = args.includes("--unread");
  const daemon = args.includes("--daemon");
  const stopDaemon = args.includes("--stop-daemon");
  const noWarm = args.includes("--no-warm");

  const effortIndex = args.findIndex((arg) => arg === "--effort");
  const effort = effortIndex === -1 ? undefined : args[effortIndex + 1];
  const effortValueIndex = effortIndex === -1 ? -1 : effortIndex + 1;

  let agent: OrchestratorAgentName = DEFAULT_ORCHESTRATOR_AGENT;
  let agentError: string | undefined;
  const agentValueIndexes = new Set<number>();
  args.forEach((arg, index) => {
    if (arg === "--claude" || arg === "--codex" || arg === "--devin") {
      agent = arg.slice(2) as OrchestratorAgentName;
      return;
    }
    if (arg !== "--agent" && !arg.startsWith("--agent=")) return;
    const value = arg === "--agent" ? args[index + 1] : arg.slice("--agent=".length);
    if (arg === "--agent" && value !== undefined) agentValueIndexes.add(index + 1);
    if (isOrchestratorAgentName(value)) agent = value;
    else agentError = `--agent expects one of claude, codex, devin (got: ${value || "<missing>"})`;
  });

  const prompt = args
    .filter(
      (arg, index) =>
        !FLAG_NAMES.has(arg) &&
        arg !== "--effort" &&
        index !== effortValueIndex &&
        arg !== "--agent" &&
        !arg.startsWith("--agent=") &&
        !agentValueIndexes.has(index),
    )
    .join(" ");
  const reset = args.includes("--reset") || prompt === "Reset";

  return {
    interactive,
    quiet,
    help,
    status,
    events,
    unread,
    reset,
    daemon,
    stopDaemon,
    noWarm,
    noArgs: args.length === 0,
    effort,
    agent,
    agentError,
    prompt,
  };
}
