import { defaultRunner, type CommandRunner } from "./conductor.ts";
import {
  CLAUDE_AUTO_RESUME_DEFAULT_POLL_MS,
  FileClaudeAutoResumeStore,
  scanClaudeSurfacesOnce,
  processDueClaudeAutoResumeJobs,
  type ClaudeAutoResumeStore,
} from "./claude-auto-resume.ts";
import {
  FileDevinPollStore,
  isDevinPollingEnabled,
  scanDevinSurfacesOnce,
  type DevinPollStore,
} from "./devin-poll.ts";

export interface AiCmuxConductorDaemonOptions {
  runner?: CommandRunner;
  claudeStore?: ClaudeAutoResumeStore;
  devinStore?: DevinPollStore;
  pollIntervalMs?: number;
  now?: () => Date;
  defaultTimeZone?: string;
  env?: Record<string, string | undefined>;
}

export async function runAiCmuxConductorDaemon(options: AiCmuxConductorDaemonOptions = {}): Promise<never> {
  const runner = options.runner || defaultRunner;
  const claudeStore = options.claudeStore || new FileClaudeAutoResumeStore();
  const devinStore = options.devinStore || new FileDevinPollStore();
  const now = options.now || (() => new Date());
  const pollIntervalMs = options.pollIntervalMs ?? CLAUDE_AUTO_RESUME_DEFAULT_POLL_MS;
  const env = options.env || process.env;
  let stopped = false;
  process.once("SIGTERM", () => {
    stopped = true;
  });
  process.once("SIGINT", () => {
    stopped = true;
  });

  while (!stopped) {
    const tickNow = now();
    const claudeState = await claudeStore.load();
    await scanClaudeSurfacesOnce(claudeState, runner, tickNow, options.defaultTimeZone);
    await processDueClaudeAutoResumeJobs(claudeState, runner, tickNow);
    await claudeStore.save(claudeState);

    if (isDevinPollingEnabled(env)) {
      const devinState = await devinStore.load();
      await scanDevinSurfacesOnce(devinState, runner, tickNow);
      await devinStore.save(devinState);
    }

    await sleep(pollIntervalMs);
  }

  process.exit(0);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
