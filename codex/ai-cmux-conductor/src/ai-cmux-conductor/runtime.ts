import { Codex, type ModelReasoningEffort, type ThreadEvent, type ThreadOptions } from "@openai/codex-sdk";
import { mkdtempSync, rmSync, existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

export interface ProfileConfig {
  name: string;
  baseInstructions: string;
  developerInstructions: string;
  model?: string;
  reasoningEffort?: ModelReasoningEffort;
  sandboxMode?: "read-only" | "workspace-write" | "danger-full-access";
  extraEnv?: Record<string, string>;
}

export type WireEvent =
  | { kind: "stdout"; text: string }
  | { kind: "stderr"; text: string }
  | { kind: "command"; command: string }
  | { kind: "command-output"; text: string }
  | { kind: "command-exit"; exitCode: number }
  | { kind: "todo"; text: string; completed: boolean };

export interface TurnRunOptions {
  cwd?: string;
  effort?: string;
  quiet?: boolean;
  signal?: AbortSignal;
  onEvent?: (event: WireEvent) => void;
}

export function effectiveModel(config: ProfileConfig): string {
  return config.model || process.env.CODEX_DAEMON_MODEL || process.env.CODEX_PROFILE_MODEL || "gpt-5.3-codex-spark";
}

export function effectiveEffort(config: ProfileConfig, effort?: string): ModelReasoningEffort {
  const requested = effort || config.reasoningEffort || "low";
  // The default Codex daemon model rejects `minimal`; keep the CLI-friendly
  // alias but normalize it to the narrowest supported effort.
  if (requested === "minimal") return "low";
  return requested as ModelReasoningEffort;
}

function codexConfig(config: ProfileConfig, effort?: string) {
  return {
    base_instructions: config.baseInstructions,
    developer_instructions: config.developerInstructions,
    model_reasoning_effort: effectiveEffort(config, effort),
    show_raw_agent_reasoning: true,
    skills: { include_instructions: false },
    include_apps_instructions: false,
    include_environment_context: false,
    include_collaboration_mode_instructions: false,
    include_permissions_instructions: false,
    project_doc_max_bytes: 0,
    memories: { use_memories: false },
    mcp_servers: {},
    web_search: "disabled",
    features: {
      plugins: false,
      hooks: false,
      memories: false,
      apps: false,
      image_generation: false,
      tool_search: false,
      tool_suggest: false,
    },
  };
}

function writeConfigToml(home: string, config: ProfileConfig, effort?: string) {
  const toml = [
    `base_instructions = ${JSON.stringify(config.baseInstructions)}`,
    `developer_instructions = ${JSON.stringify(config.developerInstructions)}`,
    `model_reasoning_effort = ${JSON.stringify(effectiveEffort(config, effort))}`,
    "show_raw_agent_reasoning = true",
    "include_apps_instructions = false",
    "include_environment_context = false",
    "include_collaboration_mode_instructions = false",
    "include_permissions_instructions = false",
    "project_doc_max_bytes = 0",
    'web_search = "disabled"',
    "",
    "[skills]",
    "include_instructions = false",
    "",
    "[memories]",
    "use_memories = false",
    "",
    "[features]",
    "plugins = false",
    "hooks = false",
    "memories = false",
    "apps = false",
    "image_generation = false",
    "tool_search = false",
    "tool_suggest = false",
    "",
  ].join("\n");
  writeFileSync(join(home, "config.toml"), toml, "utf8");
}

export function prepareIsolatedCodexHome(config: ProfileConfig, effort?: string) {
  const realHome = process.env.HOME || "";
  const isolatedHome = mkdtempSync(join(tmpdir(), `${config.name}-codex-home-`));
  mkdirSync(isolatedHome, { recursive: true });

  const authSrc = join(realHome, ".codex", "auth.json");
  const authDst = join(isolatedHome, "auth.json");
  if (existsSync(authSrc) && !existsSync(authDst)) {
    symlinkSync(authSrc, authDst);
  }
  writeConfigToml(isolatedHome, config, effort);

  const cleanup = () => rmSync(isolatedHome, { recursive: true, force: true });
  return { isolatedHome, realHome, cleanup };
}

export function createCodex(config: ProfileConfig, effort?: string) {
  const home = prepareIsolatedCodexHome(config, effort);
  const codex = new Codex({
    env: {
      PATH: process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      HOME: home.realHome,
      CODEX_HOME: home.isolatedHome,
      ...config.extraEnv,
    },
    config: codexConfig(config, effort),
  });

  const startThread = (cwd = process.cwd()) => {
    const options: ThreadOptions = {
      model: effectiveModel(config),
      modelReasoningEffort: effectiveEffort(config, effort),
      workingDirectory: cwd,
      skipGitRepoCheck: true,
      sandboxMode: config.sandboxMode || "danger-full-access",
      approvalPolicy: "never",
      webSearchMode: "disabled",
      networkAccessEnabled: true,
    };
    return codex.startThread(options);
  };

  return { codex, startThread, cleanup: home.cleanup, isolatedHome: home.isolatedHome };
}

export function eventToWire(event: ThreadEvent): WireEvent[] {
  if (event.type === "item.started") {
    if (event.item.type === "command_execution") {
      return [{ kind: "command", command: event.item.command }];
    }
    return [];
  }

  if (event.type === "item.updated" || event.type === "item.completed") {
    const item = event.item;
    if (item.type === "agent_message" && item.text) {
      return [{ kind: "stdout", text: item.text.endsWith("\n") ? item.text : `${item.text}\n` }];
    }
    if (item.type === "reasoning" && item.text) {
      return [{ kind: "stderr", text: `\x1b[2;3m${item.text}\x1b[0m\n` }];
    }
    if (item.type === "command_execution") {
      const events: WireEvent[] = [];
      if (item.aggregated_output) events.push({ kind: "command-output", text: item.aggregated_output });
      if (typeof item.exit_code === "number" && item.exit_code !== 0) {
        events.push({ kind: "command-exit", exitCode: item.exit_code });
      }
      return events;
    }
    if (item.type === "todo_list") {
      return item.items.map((todo) => ({ kind: "todo", text: todo.text, completed: todo.completed }));
    }
  }

  if (event.type === "turn.failed") {
    return [{ kind: "stderr", text: `turn failed: ${event.error.message}\n` }];
  }
  if (event.type === "error") {
    return [{ kind: "stderr", text: `error: ${event.message}\n` }];
  }
  return [];
}

export function renderWireEvent(event: WireEvent) {
  switch (event.kind) {
    case "stdout":
      process.stdout.write(event.text);
      break;
    case "stderr":
      process.stderr.write(event.text);
      break;
    case "command":
      process.stderr.write(`\x1b[2m$ ${event.command}\x1b[0m\n`);
      break;
    case "command-output":
      process.stderr.write(`\x1b[2m${event.text}\x1b[0m`);
      if (!event.text.endsWith("\n")) process.stderr.write("\n");
      break;
    case "command-exit":
      process.stderr.write(`\x1b[31m→ exit ${event.exitCode}\x1b[0m\n`);
      break;
    case "todo": {
      const mark = event.completed ? "✓" : "○";
      process.stderr.write(`\x1b[2m  ${mark} ${event.text}\x1b[0m\n`);
      break;
    }
  }
}

export async function runTurn(config: ProfileConfig, prompt: string, options: TurnRunOptions = {}): Promise<string> {
  const runtime = createCodex(config, options.effort);
  const thread = runtime.startThread(options.cwd || process.cwd());
  try {
    if (options.quiet) {
      const turn = await thread.run(prompt, { signal: options.signal });
      return turn.finalResponse || "";
    }

    const streamed = await thread.runStreamed(prompt, { signal: options.signal });
    let finalText = "";
    for await (const event of streamed.events) {
      if (event.type === "item.completed" && event.item.type === "agent_message") {
        finalText = event.item.text || finalText;
      }
      for (const wireEvent of eventToWire(event)) {
        options.onEvent?.(wireEvent);
      }
    }
    return finalText;
  } finally {
    runtime.cleanup();
  }
}

export async function runCold(config: ProfileConfig, prompt: string, options: TurnRunOptions = {}) {
  const finalText = await runTurn(config, prompt, {
    ...options,
    onEvent: (event) => renderWireEvent(event),
  });
  if (options.quiet && finalText) console.log(finalText);
  return finalText;
}

export async function runInteractive(config: ProfileConfig, prompt?: string, effort?: string): Promise<void> {
  const home = prepareIsolatedCodexHome(config, effort);
  const args = [
    "--dangerously-bypass-approvals-and-sandbox",
    "-m",
    effectiveModel(config),
    ...(prompt ? [prompt] : []),
  ];

  await new Promise<void>((resolve, reject) => {
    const child = spawn("codex", args, {
      cwd: process.cwd(),
      stdio: "inherit",
      env: {
        ...process.env,
        CODEX_HOME: home.isolatedHome,
        HOME: home.realHome,
        ...config.extraEnv,
      },
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      home.cleanup();
      if (signal) process.exit(130);
      process.exit(code ?? 0);
    });
  });
}
