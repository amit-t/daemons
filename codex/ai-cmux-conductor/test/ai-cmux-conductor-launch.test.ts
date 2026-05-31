import { describe, expect, test } from "bun:test";
import { buildCodexLaunchShellCommand, CODEX_ORCHESTRATOR_COMMAND } from "../src/ai-cmux-conductor/codex-launch.ts";

describe("Codex launch command", () => {
  test("uses Amit's cxscb launcher and passes the orchestrator prompt as one zsh argument", () => {
    expect(CODEX_ORCHESTRATOR_COMMAND).toBe("cxscb");
    expect(buildCodexLaunchShellCommand("coordinate Claude, Devin, and Bob's repo")).toBe(
      "cxscb 'coordinate Claude, Devin, and Bob'\\''s repo'",
    );
  });
});
