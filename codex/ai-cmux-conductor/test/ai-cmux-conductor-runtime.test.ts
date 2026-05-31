import { describe, expect, test } from "bun:test";
import { effectiveEffort, type ProfileConfig } from "../src/ai-cmux-conductor/runtime.ts";

const config: ProfileConfig = {
  name: "ai-cmux-conductor",
  baseInstructions: "base",
  developerInstructions: "developer",
};

describe("effectiveEffort", () => {
  test("defaults to low for the default Codex conductor model", () => {
    expect(effectiveEffort(config)).toBe("low");
  });

  test("treats minimal as low because the default Codex model rejects minimal", () => {
    expect(effectiveEffort({ ...config, reasoningEffort: "minimal" as any })).toBe("low");
    expect(effectiveEffort(config, "minimal")).toBe("low");
  });
});
