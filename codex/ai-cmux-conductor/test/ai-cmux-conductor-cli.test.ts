import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const GENERIC_NAME = ["codex", "daemon"].join("-");

function runCommand(command: string, args: string[]): Promise<{ code: number | null; output: string }> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk.toString()));
    child.stderr.on("data", (chunk) => (output += chunk.toString()));
    child.on("close", (code) => resolve({ code, output }));
  });
}

function readTextFiles(dir: string): string[] {
  const texts: string[] = [];
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === "bun.lock") continue;
    const path = join(dir, name);
    const stat = statSync(path);
    if (stat.isDirectory()) texts.push(...readTextFiles(path));
    else if (/\.(ts|json|md|zsh)$/.test(name) || name === "ai-cmux-conductor") texts.push(readFileSync(path, "utf8"));
  }
  return texts;
}

describe("ai-cmux-conductor CLI", () => {
  test("prints help from the daemon entrypoint", async () => {
    const { code, output } = await runCommand("bun", ["ai-cmux-conductor", "--help"]);
    expect(code).toBe(0);
    expect(output).toContain("ai-cmux-conductor");
    expect(output).toContain("aicc");
    expect(output).toContain("cxscb");
    expect(output).toContain("Claude");
    expect(output).toContain("Devin");
    expect(output).not.toContain(GENERIC_NAME);
  });

  test("zsh wrappers forward to daemon help", async () => {
    for (const wrapper of ["bin/aicc", "bin/ai-cmux-conductor"]) {
      const { code, output } = await runCommand(wrapper, ["--help"]);
      expect(code).toBe(0);
      expect(output).toContain("cMUX AI workspace conductor");
    }
  });

  test("README documents purpose and verification", () => {
    const readme = readFileSync(join(ROOT, "README.md"), "utf8");
    expect(readme).toContain("Purpose");
    expect(readme).toContain("Verification");
    expect(readme).toContain("aicc");
  });

  test("daemon package text does not use the old generic source namespace", () => {
    expect(readTextFiles(ROOT).join("\n")).not.toContain(GENERIC_NAME);
  });
});
