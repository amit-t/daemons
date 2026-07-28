import { describe, expect, test } from "bun:test";
import { parseAiCmuxOrchestratorArgs } from "../src/ai-cmux-orchestrator/args.ts";

const argv = (...rest: string[]) => ["bun", "ai-cmux-orchestrator", ...rest];

describe("parseAiCmuxOrchestratorArgs", () => {
  test("preserves a bare multi-word prompt", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("inspect", "this", "repo"));
    expect(parsed.prompt).toBe("inspect this repo");
  });

  test("parses quiet mode and keeps prompt", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("-q", "summarize", "status"));
    expect(parsed.quiet).toBe(true);
    expect(parsed.prompt).toBe("summarize status");
  });

  test("parses interactive mode", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("--interactive", "hello"));
    expect(parsed.interactive).toBe(true);
    expect(parsed.prompt).toBe("hello");
  });

  test("parses warm controls", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("--no-warm", "--stop-daemon", "--daemon"));
    expect(parsed.noWarm).toBe(true);
    expect(parsed.stopDaemon).toBe(true);
    expect(parsed.daemon).toBe(true);
  });

  test("parses reset controls and exact bare Reset request", () => {
    expect(parseAiCmuxOrchestratorArgs(argv("--reset")).reset).toBe(true);
    expect(parseAiCmuxOrchestratorArgs(argv("Reset")).reset).toBe(true);
    expect(parseAiCmuxOrchestratorArgs(argv("Reset", "now")).reset).toBe(false);
  });

  test("parses effort and removes its value from the prompt", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("--effort", "high", "do", "work"));
    expect(parsed.effort).toBe("high");
    expect(parsed.prompt).toBe("do work");
  });

  test("does not drop first prompt word when effort is absent", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("high", "priority"));
    expect(parsed.prompt).toBe("high priority");
  });

  test("reports help, status, and no-args", () => {
    expect(parseAiCmuxOrchestratorArgs(argv("--help")).help).toBe(true);
    expect(parseAiCmuxOrchestratorArgs(argv("--status")).status).toBe(true);
    expect(parseAiCmuxOrchestratorArgs(argv("--auto-resume-status")).status).toBe(true);
    expect(parseAiCmuxOrchestratorArgs(argv()).noArgs).toBe(true);
  });

  test("parses unread event inbox request without treating flags as prompt text", () => {
    const parsed = parseAiCmuxOrchestratorArgs(argv("--events", "--unread"));

    expect(parsed.events).toBe(true);
    expect(parsed.unread).toBe(true);
    expect(parsed.prompt).toBe("");
  });
});
