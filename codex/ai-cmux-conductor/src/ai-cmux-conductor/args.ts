export interface AiCmuxConductorArgs {
  interactive: boolean;
  quiet: boolean;
  help: boolean;
  daemon: boolean;
  stopDaemon: boolean;
  noWarm: boolean;
  noArgs: boolean;
  effort?: string;
  prompt: string;
}

const FLAG_NAMES = new Set([
  "-i",
  "--interactive",
  "-q",
  "--quiet",
  "-h",
  "--help",
  "--daemon",
  "--stop-daemon",
  "--no-warm",
]);

export function parseAiCmuxConductorArgs(argv: string[]): AiCmuxConductorArgs {
  const args = argv.slice(2);
  const interactive = args.includes("-i") || args.includes("--interactive");
  const quiet = args.includes("-q") || args.includes("--quiet");
  const help = args.includes("-h") || args.includes("--help");
  const daemon = args.includes("--daemon");
  const stopDaemon = args.includes("--stop-daemon");
  const noWarm = args.includes("--no-warm");

  const effortIndex = args.findIndex((arg) => arg === "--effort");
  const effort = effortIndex === -1 ? undefined : args[effortIndex + 1];
  const effortValueIndex = effortIndex === -1 ? -1 : effortIndex + 1;

  const prompt = args
    .filter((arg, index) => !FLAG_NAMES.has(arg) && arg !== "--effort" && index !== effortValueIndex)
    .join(" ");

  return {
    interactive,
    quiet,
    help,
    daemon,
    stopDaemon,
    noWarm,
    noArgs: args.length === 0,
    effort,
    prompt,
  };
}
