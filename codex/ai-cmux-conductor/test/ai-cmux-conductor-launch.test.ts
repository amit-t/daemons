import { describe, expect, test } from "bun:test";
import {
  buildAgentLaunchShellCommand,
  CODEX_ORCHESTRATOR_COMMAND,
  DEFAULT_ORCHESTRATOR_AGENT,
  ORCHESTRATOR_LAUNCH_PREFIXES,
} from "../src/ai-cmux-conductor/agent-launch.ts";
import { parseAiCmuxConductorArgs } from "../src/ai-cmux-conductor/args.ts";

describe("orchestrator launch command", () => {
  test("codex stays the default and uses Amit's cxscb launcher, suppresses MCP startup, and passes the orchestrator prompt as one zsh argument", () => {
    expect(DEFAULT_ORCHESTRATOR_AGENT).toBe("codex");
    expect(CODEX_ORCHESTRATOR_COMMAND).toBe("cxscb");
    expect(buildAgentLaunchShellCommand("codex", "coordinate Claude, Devin, and Bob's repo")).toBe(
      "cxscb --disable apps -c 'mcp_servers={}' 'coordinate Claude, Devin, and Bob'\\''s repo'",
    );
  });

  test("claude orchestrator uses Amit's clscb launcher with the prompt as one zsh argument", () => {
    expect(buildAgentLaunchShellCommand("claude", "coordinate Bob's repo")).toBe("clscb 'coordinate Bob'\\''s repo'");
  });

  test("devin orchestrator launches the devin CLI interactively with dangerous permissions and the prompt after --", () => {
    expect(buildAgentLaunchShellCommand("devin", "coordinate Bob's repo")).toBe(
      "devin --permission-mode dangerous -- 'coordinate Bob'\\''s repo'",
    );
  });

  test("every supported orchestrator agent has a launch prefix", () => {
    expect(Object.keys(ORCHESTRATOR_LAUNCH_PREFIXES).sort()).toEqual(["claude", "codex", "devin"]);
  });
});

describe("orchestrator agent argument parsing", () => {
  const parse = (...argv: string[]) => parseAiCmuxConductorArgs(["bun", "ai-cmux-conductor", ...argv]);

  test("defaults to codex with no agent flag", () => {
    const args = parse("ship the release");
    expect(args.agent).toBe("codex");
    expect(args.agentError).toBeUndefined();
    expect(args.prompt).toBe("ship the release");
  });

  test("--agent claude selects claude and keeps the prompt clean", () => {
    const args = parse("--agent", "claude", "ship the release");
    expect(args.agent).toBe("claude");
    expect(args.agentError).toBeUndefined();
    expect(args.prompt).toBe("ship the release");
  });

  test("--agent=devin selects devin and keeps the prompt clean", () => {
    const args = parse("--agent=devin", "ship the release");
    expect(args.agent).toBe("devin");
    expect(args.prompt).toBe("ship the release");
  });

  test("shorthand flags --claude/--codex/--devin select the agent and stay out of the prompt", () => {
    for (const agent of ["claude", "codex", "devin"] as const) {
      const args = parse(`--${agent}`, "ship the release");
      expect(args.agent).toBe(agent);
      expect(args.prompt).toBe("ship the release");
    }
  });

  test("invalid --agent value reports an error", () => {
    const args = parse("--agent", "gemini");
    expect(args.agentError).toContain("gemini");
  });

  test("missing --agent value reports an error", () => {
    const args = parse("--agent");
    expect(args.agentError).toContain("<missing>");
  });

  test("agent flags compose with --effort and prompt extraction", () => {
    const args = parse("--claude", "--effort", "high", "ship", "the", "release");
    expect(args.agent).toBe("claude");
    expect(args.effort).toBe("high");
    expect(args.prompt).toBe("ship the release");
  });
});
