import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { detectClaudeUsageLimit } from "./claude-auto-resume.ts";
import { defaultRunner, type CommandResult, type CommandRunner, type ConductorContext } from "./conductor.ts";

export const DEVIN_POLL_DISABLE_FLAG = "AICC_DEVIN_POLL_DAEMON";
export const DEVIN_POLL_STATE_DIR = "AICC_STATE_DIR";
export const DEVIN_POLL_DEFAULT_LINES = 200;
export const AICC_DAEMON_NOTICE_VERSION = "AICC_DAEMON_NOTICE_V1";

export type AiccAgentIdentity = "Claude" | "Codex" | "Devin";
export type AiccAgentState = "working" | "needs_input" | "blocked" | "completed" | "usage_limited" | "error";
export type AiccEventSeverity = "info" | "action_required";

export interface DevinPollRegistration {
  workspaceId: string;
  orchestratorSurfaceId: string;
  devinSurfaceId?: string;
  updatedAt: string;
  claudePanelEnabled?: boolean;
  codexPanelEnabled?: boolean;
  codexPanelSurfaceId?: string;
  devinPanelEnabled?: boolean;
  claudeSurfaceId?: string;
  windowId?: string;
  workspaceName?: string;
  cwd?: string;
  lastInputRequestFingerprint?: string;
  lastInputRequestAt?: string;
  lastInputRequestExcerpt?: string;
  lastNotifiedAt?: string;
  lastError?: string;
  lastInputRequestFingerprints?: Record<string, string>;
  lastAgentEventAt?: Record<string, string>;
}

export interface DevinPollEvent {
  id: string;
  type: string;
  at: string;
  message: string;
  workspaceId?: string;
  devinSurfaceId?: string;
  codexPanelSurfaceId?: string;
  orchestratorSurfaceId?: string;
  error?: string;
  agent?: AiccAgentIdentity;
  state?: AiccAgentState;
  severity?: AiccEventSeverity;
  summary?: string;
  excerptHash?: string;
  readAt?: string;
}

export interface DevinPollState {
  registrations: DevinPollRegistration[];
  events: DevinPollEvent[];
}

export interface DevinPollStore {
  load(): Promise<DevinPollState>;
  save(state: DevinPollState): Promise<void>;
}

export interface DevinInputRequestDetection {
  reason: string;
  excerpt: string;
  fingerprint: string;
}

export interface AiccDaemonNoticeOptions {
  workspaceId: string;
  noticeId: string;
  createdAt: string;
}

interface CmuxSurface {
  id?: string;
  ref?: string;
  title?: string;
  type?: string;
  pane_id?: string;
  pane_ref?: string;
}

export function createEmptyDevinPollState(): DevinPollState {
  return { registrations: [], events: [] };
}

export function devinPollStateDirectory(env: Record<string, string | undefined> = process.env): string {
  return env[DEVIN_POLL_STATE_DIR] || join(env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "ai-cmux-conductor");
}

export function devinPollStatePath(env: Record<string, string | undefined> = process.env): string {
  return join(devinPollStateDirectory(env), "devin-poll.json");
}

export class FileDevinPollStore implements DevinPollStore {
  constructor(private readonly path = devinPollStatePath()) {}

  async load(): Promise<DevinPollState> {
    if (!existsSync(this.path)) return createEmptyDevinPollState();
    const parsed = JSON.parse(await readFile(this.path, "utf8")) as Partial<DevinPollState>;
    return normalizeState(parsed);
  }

  async save(state: DevinPollState): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const tempPath = `${this.path}.${process.pid}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(normalizeState(state), null, 2)}\n`, "utf8");
    await rename(tempPath, this.path);
  }
}

function normalizeState(state: Partial<DevinPollState>): DevinPollState {
  return {
    registrations: Array.isArray(state.registrations) ? state.registrations.filter(isRegistrationLike) : [],
    events: Array.isArray(state.events) ? state.events.filter(isEventLike).slice(-200) : [],
  };
}

function isRegistrationLike(value: unknown): value is DevinPollRegistration {
  const item = value as DevinPollRegistration;
  return Boolean(item && item.workspaceId && item.orchestratorSurfaceId && item.updatedAt);
}

function isEventLike(value: unknown): value is DevinPollEvent {
  const item = value as DevinPollEvent;
  return Boolean(item && item.id && item.type && item.at && item.message);
}

export function isDevinPollingEnabled(env: Record<string, string | undefined>): boolean {
  const value = env[DEVIN_POLL_DISABLE_FLAG]?.trim().toLowerCase();
  return value !== "false" && value !== "0" && value !== "no";
}

export async function registerDevinPollFromConductorContext(
  context: ConductorContext,
  windowId: string | undefined,
  store: DevinPollStore = new FileDevinPollStore(),
): Promise<DevinPollState | undefined> {
  const state = await store.load();
  const registration: DevinPollRegistration = {
    workspaceId: context.workspaceId,
    windowId,
    workspaceName: context.workspaceName,
    cwd: context.cwd,
    orchestratorSurfaceId: context.orchestratorSurfaceId,
    claudePanelEnabled: context.claudePanelEnabled !== false && Boolean(context.claudeSurfaceId),
    claudeSurfaceId: context.claudeSurfaceId,
    codexPanelEnabled: context.codexPanelEnabled !== false && Boolean(context.codexPanelSurfaceId),
    codexPanelSurfaceId: context.codexPanelEnabled !== false ? context.codexPanelSurfaceId : undefined,
    devinPanelEnabled: context.devinPanelEnabled,
    devinSurfaceId: context.devinPanelEnabled ? context.devinSurfaceId || "" : "",
    updatedAt: new Date().toISOString(),
  };
  upsertDevinPollRegistration(state, registration);
  await store.save(state);
  return state;
}

export function upsertDevinPollRegistration(state: DevinPollState, registration: DevinPollRegistration): void {
  const index = state.registrations.findIndex((candidate) => candidate.workspaceId === registration.workspaceId);
  if (index === -1) state.registrations.push(registration);
  else state.registrations[index] = { ...state.registrations[index], ...registration };
  recordEvent(state, {
    type: "registered",
    at: registration.updatedAt,
    workspaceId: registration.workspaceId,
    devinSurfaceId: registration.devinSurfaceId,
    orchestratorSurfaceId: registration.orchestratorSurfaceId,
    message: `Registered AICC event poller: workspace ${registration.workspaceId}, Claude ${registration.claudePanelEnabled === false ? "disabled" : registration.claudeSurfaceId || "unregistered"}, Codex panel ${registration.codexPanelEnabled === false ? "disabled" : registration.codexPanelSurfaceId || "unregistered"}, Devin ${registration.devinPanelEnabled === false ? "disabled" : registration.devinSurfaceId || "unregistered"}, orchestrator ${registration.orchestratorSurfaceId}`,
  });
}

export function detectDevinInputRequest(screenText: string): DevinInputRequestDetection | undefined {
  return detectAgentInputRequest("Devin", screenText);
}

function detectAgentInputRequest(agent: AiccAgentIdentity, screenText: string): DevinInputRequestDetection | undefined {
  const lines = screenText.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const markerIndex = lines.findIndex((line) => devinInputRequestPatterns.some((pattern) => pattern.test(line)));
  if (markerIndex === -1) return undefined;

  const start = Math.max(0, markerIndex - 1);
  const end = Math.min(lines.length, markerIndex + 2);
  const excerpt = lines.slice(start, end).join("\n").slice(0, 800);
  const reason = lines[markerIndex].slice(0, 240);
  return { reason, excerpt, fingerprint: stableFingerprint(excerpt) };
}

const devinInputRequestPatterns = [
  /waiting for (?:your|user|the user's) input\b/i,
  /awaiting (?:your|user|the user's) input\b/i,
  /needs? (?:your|user|the user's) input\b/i,
  /requires? (?:your|user|the user's) input\b/i,
  /waiting for (?:your )?(?:approval|confirmation|response)\b/i,
  /(?:approve|confirm) (?:the )?(?:plan|planner|handoff|next step)/i,
  /do you want (?:me|devin) to (?:proceed|continue)/i,
  /type (?:your )?(?:answer|response|input)/i,
];

export async function scanDevinSurfacesOnce(
  state: DevinPollState,
  runner: CommandRunner = defaultRunner,
  now = new Date(),
): Promise<void> {
  for (const registration of state.registrations) {
    try {
      const surfaces = await readCmuxTreeSurfaces(runner, registration.workspaceId, registration.windowId);
      const orchestratorSurfaceId = resolveSurfaceId(surfaces, registration.orchestratorSurfaceId, isCodexSurface);
      if (!orchestratorSurfaceId) throw new Error(`Unable to resolve Codex orchestrator surface ${registration.orchestratorSurfaceId}`);

      const claudeSurfaces = shouldPollClaudeRegistration(registration) ? discoverAgentSurfaces(surfaces, registration.claudeSurfaceId, isClaudeSurface) : [];
      if (registration.claudeSurfaceId && shouldPollClaudeRegistration(registration) && !claudeSurfaces.length) throw new Error(`Unable to resolve Claude surface ${registration.claudeSurfaceId}`);

      const codexPanelSurfaces = shouldPollCodexPanelRegistration(registration) ? discoverCodexPanelSurfaces(surfaces, registration.codexPanelSurfaceId) : [];
      if (registration.codexPanelSurfaceId && shouldPollCodexPanelRegistration(registration) && !codexPanelSurfaces.length) throw new Error(`Unable to resolve Codex panel surface ${registration.codexPanelSurfaceId}`);

      const devinSurfaces = shouldPollDevinRegistration(registration) ? discoverDevinSurfaces(surfaces, registration.devinSurfaceId) : [];
      if (registration.devinSurfaceId && shouldPollDevinRegistration(registration) && !devinSurfaces.length) throw new Error(`Unable to resolve Devin surface ${registration.devinSurfaceId}`);

      registration.orchestratorSurfaceId = orchestratorSurfaceId;
      if (claudeSurfaces[0]) registration.claudeSurfaceId = claudeSurfaces[0].surfaceId;
      if (codexPanelSurfaces[0]) registration.codexPanelSurfaceId = codexPanelSurfaces[0].surfaceId;
      if (devinSurfaces[0]) registration.devinSurfaceId = devinSurfaces[0].surfaceId;
      registration.updatedAt = now.toISOString();
      registration.lastError = undefined;
      registration.lastInputRequestFingerprints ||= {};
      registration.lastAgentEventAt ||= {};

      let createdUnreadEvent = false;
      for (const claudeSurface of claudeSurfaces) {
        const screenText = await readSurfaceScreen(runner, registration, claudeSurface.surfaceId, DEVIN_POLL_DEFAULT_LINES);
        const detection = detectClaudeUsageLimit(screenText, now);
        if (!detection) continue;

        const fingerprint = stableFingerprint(`${claudeSurface.surfaceId}:${detection.resetAt}`);
        const fingerprintKey = `Claude:${claudeSurface.surfaceId}:usage_limited`;
        if (!shouldEmitAgentEvent(registration, fingerprintKey, fingerprint, now, false)) continue;

        const summary = `Claude usage-limited until ${detection.resetAt}; auto-continue scheduled ${detection.sendAt}.`;
        createAgentInboxEvent({
          state,
          workspaceId: registration.workspaceId,
          agent: "Claude",
          agentState: "usage_limited",
          severity: "info",
          surfaceId: claudeSurface.surfaceId,
          orchestratorSurfaceId,
          at: now.toISOString(),
          summary,
          excerptHash: fingerprint,
        });
        rememberAgentEvent(registration, fingerprintKey, fingerprint, now);
        createdUnreadEvent = true;
      }

      const polledInteractiveSurfaces = [
        ...codexPanelSurfaces.map((surface) => ({ agent: "Codex" as const, ...surface })),
        ...devinSurfaces.map((surface) => ({ agent: "Devin" as const, ...surface })),
      ];
      for (const agentSurface of polledInteractiveSurfaces) {
        const screenText = await readSurfaceScreen(runner, registration, agentSurface.surfaceId, DEVIN_POLL_DEFAULT_LINES);
        const detection = detectAgentInputRequest(agentSurface.agent, screenText);
        const fingerprintKey = `${agentSurface.agent}:${agentSurface.surfaceId}:needs_input`;
        if (!detection) {
          delete registration.lastInputRequestFingerprints[fingerprintKey];
          if (agentSurface.agent === "Devin" && agentSurface.surfaceId === registration.devinSurfaceId) registration.lastInputRequestFingerprint = undefined;
          const meaningful = detectAgentScreenState(agentSurface.agent, screenText);
          if (!meaningful) continue;
          const meaningfulKey = `${agentSurface.agent}:${agentSurface.surfaceId}:${meaningful.state}`;
          if (!shouldEmitAgentEvent(registration, meaningfulKey, meaningful.fingerprint, now, true)) continue;
          createAgentInboxEvent({
            state,
            workspaceId: registration.workspaceId,
            agent: agentSurface.agent,
            agentState: meaningful.state,
            severity: meaningful.severity,
            surfaceId: agentSurface.surfaceId,
            orchestratorSurfaceId,
            at: now.toISOString(),
            summary: meaningful.summary,
            excerptHash: meaningful.fingerprint,
          });
          rememberAgentEvent(registration, meaningfulKey, meaningful.fingerprint, now);
          createdUnreadEvent = true;
          continue;
        }
        if (!shouldEmitAgentEvent(registration, fingerprintKey, detection.fingerprint, now, true)) continue;

        const summary = summarizeAgentInputRequest(agentSurface.agent, detection);
        const event = createAgentInboxEvent({
          state,
          workspaceId: registration.workspaceId,
          agent: agentSurface.agent,
          agentState: "needs_input",
          severity: "action_required",
          surfaceId: agentSurface.surfaceId,
          orchestratorSurfaceId,
          at: now.toISOString(),
          summary,
          excerptHash: detection.fingerprint,
        });
        createdUnreadEvent = true;
        rememberAgentEvent(registration, fingerprintKey, detection.fingerprint, now);
        if (agentSurface.agent === "Devin") {
          registration.lastInputRequestFingerprint = detection.fingerprint;
          registration.lastInputRequestAt = now.toISOString();
          registration.lastInputRequestExcerpt = summary;
        }
        recordEvent(state, {
          type: "input_request_noticed",
          at: now.toISOString(),
          workspaceId: registration.workspaceId,
          devinSurfaceId: agentSurface.agent === "Devin" ? agentSurface.surfaceId : undefined,
          codexPanelSurfaceId: agentSurface.agent === "Codex" ? agentSurface.surfaceId : undefined,
          orchestratorSurfaceId,
          message: `${agentSurface.agent} waiting input noticed at ${now.toISOString()}: ${summary}`,
        });
        event.message = summary;
      }

      if (createdUnreadEvent) {
        const notice = buildAiccDaemonNotice({
          workspaceId: registration.workspaceId,
          noticeId: daemonNoticeId(registration.workspaceId, now),
          createdAt: now.toISOString(),
        });
        const result = await runner("cmux", [
          "send",
          "--workspace",
          registration.workspaceId,
          ...windowArgs(registration.windowId),
          "--surface",
          orchestratorSurfaceId,
          "--",
          notice,
        ]);
        if (result.code !== 0) throw new Error(exactFailure("cmux send", result));
        registration.lastNotifiedAt = now.toISOString();
      }
    } catch (error) {
      const message = errorMessage(error);
      registration.updatedAt = now.toISOString();
      registration.lastError = message;
      recordEvent(state, {
        type: "scan_failed",
        at: now.toISOString(),
        workspaceId: registration.workspaceId,
        devinSurfaceId: registration.devinSurfaceId,
        orchestratorSurfaceId: registration.orchestratorSurfaceId,
        message: `Devin poll scan failed: ${message}`,
        error: message,
      });
    }
  }
}

function summarizeAgentInputRequest(agent: AiccAgentIdentity, detection: DevinInputRequestDetection): string {
  return `${agent} needs user input: ${detection.reason.replace(/\s+/g, " ").trim()}`.slice(0, 280);
}

function detectAgentScreenState(
  agent: AiccAgentIdentity,
  screenText: string,
): { state: AiccAgentState; severity: AiccEventSeverity; summary: string; fingerprint: string } | undefined {
  const lines = screenText.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const blocked = lines.find((line) => /\b(blocked|stuck|cannot proceed|can't proceed|need(?:s)? .*(?:approval|permission|access|credential|key|token)|waiting on)\b/i.test(line));
  if (blocked) {
    const summary = `${agent} blocked: ${blocked.replace(/\s+/g, " ").trim()}`.slice(0, 280);
    return { state: "blocked", severity: "action_required", summary, fingerprint: stableFingerprint(summary) };
  }
  const error = lines.find((line) => /\b(error|failed|failure|exception|permission denied|unauthorized|forbidden)\b/i.test(line));
  if (error) {
    const summary = `${agent} error: ${error.replace(/\s+/g, " ").trim()}`.slice(0, 280);
    return { state: "error", severity: "action_required", summary, fingerprint: stableFingerprint(summary) };
  }
  const completed = lines.find((line) => /\b(done|complete|completed|finished|ready for review|task complete)\b/i.test(line));
  if (completed) {
    const summary = `${agent} completed work: ${completed.replace(/\s+/g, " ").trim()}`.slice(0, 280);
    return { state: "completed", severity: "info", summary, fingerprint: stableFingerprint(summary) };
  }
  return undefined;
}

const AGENT_EVENT_REMINDER_MS = 10 * 60_000;

function shouldEmitAgentEvent(
  registration: DevinPollRegistration,
  key: string,
  fingerprint: string,
  now: Date,
  repeatUnresolved: boolean,
): boolean {
  registration.lastInputRequestFingerprints ||= {};
  registration.lastAgentEventAt ||= {};
  if (registration.lastInputRequestFingerprints[key] !== fingerprint) return true;
  if (!repeatUnresolved) return false;
  const lastAt = Date.parse(registration.lastAgentEventAt[key] || "");
  return Number.isNaN(lastAt) || now.getTime() - lastAt >= AGENT_EVENT_REMINDER_MS;
}

function rememberAgentEvent(registration: DevinPollRegistration, key: string, fingerprint: string, now: Date): void {
  registration.lastInputRequestFingerprints ||= {};
  registration.lastAgentEventAt ||= {};
  registration.lastInputRequestFingerprints[key] = fingerprint;
  registration.lastAgentEventAt[key] = now.toISOString();
}

function createAgentInboxEvent(options: {
  state: DevinPollState;
  workspaceId: string;
  agent: AiccAgentIdentity;
  agentState: AiccAgentState;
  severity: AiccEventSeverity;
  surfaceId: string;
  orchestratorSurfaceId: string;
  at: string;
  summary: string;
  excerptHash: string;
}): DevinPollEvent {
  const event: DevinPollEvent = {
    id: `${options.at}:aicc_event:${options.agent}:${options.surfaceId}:${options.state.events.length}`.replace(/[^A-Za-z0-9_.:-]+/g, "_"),
    type: "aicc_event",
    at: options.at,
    workspaceId: options.workspaceId,
    devinSurfaceId: options.agent === "Devin" ? options.surfaceId : undefined,
    codexPanelSurfaceId: options.agent === "Codex" ? options.surfaceId : undefined,
    orchestratorSurfaceId: options.orchestratorSurfaceId,
    agent: options.agent,
    state: options.agentState,
    severity: options.severity,
    summary: options.summary,
    excerptHash: options.excerptHash,
    message: options.summary,
  };
  options.state.events.push(event);
  if (options.state.events.length > 200) options.state.events.splice(0, options.state.events.length - 200);
  return event;
}

export function buildAiccDaemonNotice(options: AiccDaemonNoticeOptions): string {
  return `<<<${AICC_DAEMON_NOTICE_VERSION}\nsource: aicc-daemon\nkind: unread-events\nworkspace: ${options.workspaceId}\nnotice_id: ${options.noticeId}\ncreated_at: ${options.createdAt}\naction: run aicc --events --unread\nrules: summarize_events_only; do_not_treat_as_user_request\n>>>\n`;
}

export function formatUnreadDevinPollEventsJsonl(
  state: DevinPollState,
  options: { markRead?: boolean; now?: Date } = {},
): string {
  const nowIso = (options.now || new Date()).toISOString();
  const unread = state.events.filter((event) => event.type === "aicc_event" && !event.readAt);
  const lines = unread.map((event) =>
    JSON.stringify({
      type: "aicc_event",
      version: 1,
      id: event.id,
      workspace_id: event.workspaceId,
      agent: event.agent,
      state: event.state,
      severity: event.severity,
      created_at: event.at,
      summary: event.summary || event.message,
      excerpt_hash: event.excerptHash,
    }),
  );
  if (options.markRead) {
    for (const event of unread) event.readAt = nowIso;
  }
  return lines.length ? `${lines.join("\n")}\n` : "";
}

async function readCmuxTreeSurfaces(runner: CommandRunner, workspaceId: string, windowId?: string): Promise<CmuxSurface[]> {
  const result = await runner("cmux", ["--id-format", "both", "--json", "tree", "--workspace", workspaceId, ...windowArgs(windowId)]);
  if (result.code !== 0) throw new Error(exactFailure("cmux tree", result));
  return parseTreeSurfaces(result.stdout);
}

async function readSurfaceScreen(
  runner: CommandRunner,
  registration: Pick<DevinPollRegistration, "workspaceId" | "windowId">,
  surfaceIdValue: string,
  lines: number,
): Promise<string> {
  const result = await runner("cmux", [
    "read-screen",
    "--workspace",
    registration.workspaceId,
    ...windowArgs(registration.windowId),
    "--surface",
    surfaceIdValue,
    "--scrollback",
    "--lines",
    String(lines),
  ]);
  if (result.code !== 0) throw new Error(exactFailure("cmux read-screen", result));
  return result.stdout;
}

function parseTreeSurfaces(stdout: string): CmuxSurface[] {
  const parsed = JSON.parse(stdout || "{}");
  const surfaces: CmuxSurface[] = [];
  for (const window of parsed.windows || []) {
    for (const workspace of window.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) surfaces.push(surface);
      }
    }
  }
  return surfaces;
}

function discoverDevinSurfaces(surfaces: CmuxSurface[], preferredId: string | undefined): Array<{ surface: CmuxSurface; surfaceId: string }> {
  return discoverAgentSurfaces(surfaces, preferredId, isDevinSurface);
}

function discoverCodexPanelSurfaces(surfaces: CmuxSurface[], preferredId: string | undefined): Array<{ surface: CmuxSurface; surfaceId: string }> {
  return discoverAgentSurfaces(surfaces, preferredId, isCodexPanelSurface);
}

function discoverAgentSurfaces(
  surfaces: CmuxSurface[],
  preferredId: string | undefined,
  predicate: (surface: CmuxSurface) => boolean,
): Array<{ surface: CmuxSurface; surfaceId: string }> {
  const discovered = surfaces
    .filter(predicate)
    .map((surface) => ({ surface, surfaceId: surfaceId(surface) }))
    .filter((candidate): candidate is { surface: CmuxSurface; surfaceId: string } => Boolean(candidate.surfaceId));
  discovered.sort((a, b) => (a.surfaceId === preferredId ? -1 : b.surfaceId === preferredId ? 1 : a.surfaceId.localeCompare(b.surfaceId)));
  const preferred = preferredId ? surfaces.find((surface) => surface.ref === preferredId || surface.id === preferredId) : undefined;
  const preferredSurfaceId = preferred && surfaceId(preferred);
  if (preferredSurfaceId && !discovered.some((candidate) => candidate.surfaceId === preferredSurfaceId)) {
    discovered.unshift({ surface: preferred, surfaceId: preferredSurfaceId });
  }
  return discovered;
}

function resolveSurfaceId(surfaces: CmuxSurface[], preferredId: string, fallback: (surface: CmuxSurface) => boolean): string | undefined {
  const preferred = surfaces.find((surface) => surface.ref === preferredId || surface.id === preferredId);
  const preferredSurfaceId = preferred && surfaceId(preferred);
  if (preferredSurfaceId) return preferredSurfaceId;
  const fallbackSurface = surfaces.find(fallback);
  return fallbackSurface && surfaceId(fallbackSurface);
}

function isDevinSurface(surface: CmuxSurface): boolean {
  return surface.type !== "browser" && /\bDevin\b/i.test(surface.title || "");
}

function isClaudeSurface(surface: CmuxSurface): boolean {
  return surface.type !== "browser" && /\bClaude\b/i.test(surface.title || "");
}

function isCodexSurface(surface: CmuxSurface): boolean {
  return surface.type !== "browser" && surface.title === "codex";
}

function isCodexPanelSurface(surface: CmuxSurface): boolean {
  return surface.type !== "browser" && surface.title === "Codex";
}

function surfaceId(surface: CmuxSurface): string | undefined {
  return surface.ref || surface.id;
}

function windowArgs(windowId?: string): string[] {
  return windowId ? ["--window", windowId] : [];
}

function exactFailure(command: string, result: CommandResult): string {
  const output = (result.stderr || result.stdout).trim();
  return `${command} failed${output ? `: ${output}` : ` with exit ${result.code}`}`;
}

function stableFingerprint(value: string): string {
  return `sha256:${createHash("sha256").update(value.toLowerCase().replace(/\s+/g, " ").trim()).digest("hex")}`;
}

function daemonNoticeId(workspaceId: string, now: Date): string {
  return `notice-${workspaceId}-${now.toISOString()}`;
}

function recordEvent(state: DevinPollState, event: Omit<DevinPollEvent, "id">): void {
  state.events.push({ id: `${event.at}:${event.type}:${state.events.length}`.replace(/[^A-Za-z0-9_.:-]+/g, "_"), ...event });
  if (state.events.length > 200) state.events.splice(0, state.events.length - 200);
}

export function formatDevinPollSitrep(state: DevinPollState): string {
  const unreadCount = state.events.filter((event) => event.type === "aicc_event" && !event.readAt).length;
  const lines: string[] = ["AICC event poll status", `Unread AICC events: ${unreadCount}`];
  if (!state.registrations.length) lines.push("No AICC event poll surfaces registered.");
  for (const registration of state.registrations) {
    const claudeStatus = registration.claudePanelEnabled === false ? "Claude disabled" : `Claude surface ${registration.claudeSurfaceId || "unregistered"}`;
    const codexStatus = registration.codexPanelEnabled === false ? "Codex panel disabled" : `Codex panel surface ${registration.codexPanelSurfaceId || "unregistered"}`;
    const devinStatus = registration.devinPanelEnabled === false ? "Devin disabled" : `Devin surface ${registration.devinSurfaceId || "unregistered"}`;
    lines.push(`Registered AICC event watcher: workspace ${registration.workspaceId}, ${claudeStatus}, ${codexStatus}, ${devinStatus}, base Codex surface ${registration.orchestratorSurfaceId}.`);
    if (registration.lastInputRequestAt) lines.push(`Devin waiting input noticed at ${registration.lastInputRequestAt}: ${registration.lastInputRequestExcerpt || "input requested"}`);
    if (registration.lastError) lines.push(`Devin poll error: ${registration.lastError}`);
  }
  for (const event of state.events.filter((candidate) => candidate.type === "aicc_event").slice(-5)) {
    lines.push(`${event.agent || "Agent"}: ${event.summary || event.message}`);
  }
  return lines.join("\n");
}

export async function loadDevinPollStatus(store: DevinPollStore = new FileDevinPollStore()): Promise<string> {
  return formatDevinPollSitrep(await store.load());
}

export async function loadUnreadDevinPollEvents(
  store: DevinPollStore = new FileDevinPollStore(),
  options: { markRead?: boolean; now?: Date } = {},
): Promise<string> {
  const state = await store.load();
  const output = formatUnreadDevinPollEventsJsonl(state, options);
  if (options.markRead) await store.save(state);
  return output;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function shouldPollDevinRegistration(registration: DevinPollRegistration): boolean {
  return registration.devinPanelEnabled === true && Boolean(registration.devinSurfaceId);
}

function shouldPollClaudeRegistration(registration: DevinPollRegistration): boolean {
  return registration.claudePanelEnabled !== false && Boolean(registration.claudeSurfaceId);
}

function shouldPollCodexPanelRegistration(registration: DevinPollRegistration): boolean {
  return registration.codexPanelEnabled === true && Boolean(registration.codexPanelSurfaceId);
}
