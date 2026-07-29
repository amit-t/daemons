import { afterEach, describe, expect, test } from "bun:test";
import {
  CMUX_ENTER_DELAY_DEFAULT_MS,
  CMUX_ENTER_DELAY_FLAG,
  resolveCmuxEnterDelayMs,
  sendCmuxTextAndEnter,
  type CommandRunner,
} from "../src/ai-cmux-orchestrator/orchestrator.ts";

function timedRunner(): { runner: CommandRunner; calls: { args: string[]; at: number }[] } {
  const calls: { args: string[]; at: number }[] = [];
  return {
    calls,
    runner: async (cmd, args) => {
      calls.push({ args: [cmd, ...args], at: performance.now() });
      return { code: 0, stdout: "", stderr: "" };
    },
  };
}

const savedDelayEnv = process.env[CMUX_ENTER_DELAY_FLAG];

afterEach(() => {
  if (savedDelayEnv === undefined) delete process.env[CMUX_ENTER_DELAY_FLAG];
  else process.env[CMUX_ENTER_DELAY_FLAG] = savedDelayEnv;
});

describe("resolveCmuxEnterDelayMs", () => {
  test("defaults when unset or blank", () => {
    expect(resolveCmuxEnterDelayMs({})).toBe(CMUX_ENTER_DELAY_DEFAULT_MS);
    expect(resolveCmuxEnterDelayMs({ [CMUX_ENTER_DELAY_FLAG]: "  " })).toBe(CMUX_ENTER_DELAY_DEFAULT_MS);
  });

  test("honors numeric override including zero", () => {
    expect(resolveCmuxEnterDelayMs({ [CMUX_ENTER_DELAY_FLAG]: "80" })).toBe(80);
    expect(resolveCmuxEnterDelayMs({ [CMUX_ENTER_DELAY_FLAG]: "0" })).toBe(0);
  });

  test("falls back to default on invalid values", () => {
    expect(resolveCmuxEnterDelayMs({ [CMUX_ENTER_DELAY_FLAG]: "abc" })).toBe(CMUX_ENTER_DELAY_DEFAULT_MS);
    expect(resolveCmuxEnterDelayMs({ [CMUX_ENTER_DELAY_FLAG]: "-5" })).toBe(CMUX_ENTER_DELAY_DEFAULT_MS);
  });
});

describe("sendCmuxTextAndEnter", () => {
  test("waits before submitting Enter so paste-burst detection cannot swallow it", async () => {
    process.env[CMUX_ENTER_DELAY_FLAG] = "80";
    const { runner, calls } = timedRunner();
    await sendCmuxTextAndEnter({ runner, workspaceId: "workspace-uuid", surfaceId: "surface:codex", text: "notice\n" });
    expect(calls).toHaveLength(2);
    expect(calls[0]!.args[1]).toBe("send");
    expect(calls[1]!.args[1]).toBe("send-key");
    expect(calls[1]!.at - calls[0]!.at).toBeGreaterThanOrEqual(60);
  });

  test("skips the wait when the delay is zero", async () => {
    process.env[CMUX_ENTER_DELAY_FLAG] = "0";
    const { runner, calls } = timedRunner();
    await sendCmuxTextAndEnter({ runner, workspaceId: "workspace-uuid", surfaceId: "surface:codex", text: "notice\n" });
    expect(calls).toHaveLength(2);
    expect(calls[1]!.at - calls[0]!.at).toBeLessThan(50);
  });
});
