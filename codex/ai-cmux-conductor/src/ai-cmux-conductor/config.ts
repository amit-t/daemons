import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const DEVIN_PANEL_FEATURE_FLAG = "AICC_CREATE_DEVIN_PANEL";
export const DEFAULT_ENVIRONMENT_FILE = fileURLToPath(new URL("../../environment.env", import.meta.url));

export function parseEnvironmentFile(contents: string): Record<string, string> {
  const parsed: Record<string, string> = {};

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const assignment = line.startsWith("export ") ? line.slice("export ".length).trim() : line;
    const equalsIndex = assignment.indexOf("=");
    if (equalsIndex <= 0) continue;

    const key = assignment.slice(0, equalsIndex).trim();
    const rawValue = assignment.slice(equalsIndex + 1).trim();
    parsed[key] = stripOptionalQuotes(rawValue);
  }

  return parsed;
}

export function loadAiCmuxConductorEnv(
  baseEnv: Record<string, string | undefined> = process.env,
  envFilePath = DEFAULT_ENVIRONMENT_FILE,
): Record<string, string | undefined> {
  const fileEnv = existsSync(envFilePath) ? parseEnvironmentFile(readFileSync(envFilePath, "utf8")) : {};
  const merged: Record<string, string | undefined> = { ...fileEnv };

  for (const [key, value] of Object.entries(baseEnv)) {
    if (value !== undefined) merged[key] = value;
  }

  return merged;
}

export function isDevinPanelEnabled(env: Record<string, string | undefined>): boolean {
  const value = env[DEVIN_PANEL_FEATURE_FLAG]?.trim().toLowerCase();
  return value !== "false" && value !== "0" && value !== "no";
}

function stripOptionalQuotes(value: string): string {
  if (value.length < 2) return value;
  const quote = value[0];
  return (quote === "\"" || quote === "'") && value.at(-1) === quote ? value.slice(1, -1) : value;
}
