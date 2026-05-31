import { describe, expect, test } from "bun:test";
import { parseAiCmuxConductorArgs } from "../src/ai-cmux-conductor/args.ts";

const argv = (...rest: string[]) => ["bun", "ai-cmux-conductor", ...rest];

describe("parseAiCmuxConductorArgs", () => {
  test("preserves a bare multi-word prompt", () => {
    const parsed = parseAiCmuxConductorArgs(argv("inspect", "this", "repo"));
    expect(parsed.prompt).toBe("inspect this repo");
  });

  test("parses quiet mode and keeps prompt", () => {
    const parsed = parseAiCmuxConductorArgs(argv("-q", "summarize", "status"));
    expect(parsed.quiet).toBe(true);
    expect(parsed.prompt).toBe("summarize status");
  });

  test("parses interactive mode", () => {
    const parsed = parseAiCmuxConductorArgs(argv("--interactive", "hello"));
    expect(parsed.interactive).toBe(true);
    expect(parsed.prompt).toBe("hello");
  });

  test("parses warm controls", () => {
    const parsed = parseAiCmuxConductorArgs(argv("--no-warm", "--stop-daemon", "--daemon"));
    expect(parsed.noWarm).toBe(true);
    expect(parsed.stopDaemon).toBe(true);
    expect(parsed.daemon).toBe(true);
  });

  test("parses effort and removes its value from the prompt", () => {
    const parsed = parseAiCmuxConductorArgs(argv("--effort", "high", "do", "work"));
    expect(parsed.effort).toBe("high");
    expect(parsed.prompt).toBe("do work");
  });

  test("does not drop first prompt word when effort is absent", () => {
    const parsed = parseAiCmuxConductorArgs(argv("high", "priority"));
    expect(parsed.prompt).toBe("high priority");
  });

  test("reports help and no-args", () => {
    expect(parseAiCmuxConductorArgs(argv("--help")).help).toBe(true);
    expect(parseAiCmuxConductorArgs(argv()).noArgs).toBe(true);
  });
});
