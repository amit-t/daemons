import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { defaultRunner, shellQuote, type CommandResult, type CommandRunner, type ConductorContext } from "./conductor.ts";
import { CLAUDE_PANEL_TITLE, isExactManagedPanelTitle, isManagedAgentSurfaceTitle } from "./panel-titles.ts";

export const CLAUDE_AUTO_RESUME_MESSAGE = "continue\n";
export const CLAUDE_AUTO_RESUME_SEND_DELAY_MS = 60_000;
export const CLAUDE_AUTO_RESUME_RETRY_DELAY_MS = 60_000;
export const CLAUDE_AUTO_RESUME_MAX_ATTEMPTS = 3;
export const CLAUDE_AUTO_RESUME_GRACE_WINDOW_MS = 30 * 60_000;
export const CLAUDE_AUTO_RESUME_DEFAULT_POLL_MS = 60_000;
export const CLAUDE_AUTO_RESUME_DEFAULT_TIME_ZONE = "Asia/Kolkata";
export const CLAUDE_AUTO_RESUME_DISABLE_FLAG = "AICC_CLAUDE_AUTO_RESUME_DAEMON";
export const CLAUDE_AUTO_RESUME_STATE_DIR = "AICC_STATE_DIR";

export type ClaudeAutoResumeJobStatus = "pending" | "sent" | "failed" | "stale";

export interface ClaudeSurfaceRegistration {
  workspaceId: string;
  surfaceId: string;
  agentIdentity: string;
  windowId?: string;
  workspaceName?: string;
  title?: string;
  cwd?: string;
  updatedAt: string;
}

export interface ClaudeLimitDetection {
  resetAt: string;
  sendAt: string;
  timeZone: string;
  sourceExcerpt: string;
  resetText: string;
}

export interface ClaudeAutoResumeJob {
  id: string;
  workspaceId: string;
  agentIdentity: string;
  resetAt: string;
  sendAt: string;
  message: string;
  sourceExcerpt: string;
  status: ClaudeAutoResumeJobStatus;
  attempts: number;
  createdAt: string;
  updatedAt: string;
  windowId?: string;
  workspaceName?: string;
  surfaceId?: string;
  timeZone?: string;
  resetText?: string;
  nextAttemptAt?: string;
  sentAt?: string;
  lastError?: string;
  lastResult?: string;
}

export interface ClaudeAutoResumeEvent {
  id: string;
  type: string;
  at: string;
  message: string;
  workspaceId?: string;
  surfaceId?: string;
  jobId?: string;
  error?: string;
}

export interface ClaudeAutoResumeState {
  registrations: ClaudeSurfaceRegistration[];
  jobs: ClaudeAutoResumeJob[];
  events: ClaudeAutoResumeEvent[];
}

export interface ClaudeAutoResumeStore {
  load(): Promise<ClaudeAutoResumeState>;
  save(state: ClaudeAutoResumeState): Promise<void>;
}

interface CmuxSurface {
  id?: string;
  ref?: string;
  title?: string;
  type?: string;
  pane_id?: string;
  pane_ref?: string;
}

interface ProcessDueOptions {
  graceWindowMs?: number;
  retryDelayMs?: number;
  maxAttempts?: number;
}

interface RunDaemonOptions {
  runner?: CommandRunner;
  store?: ClaudeAutoResumeStore;
  pollIntervalMs?: number;
  now?: () => Date;
  defaultTimeZone?: string;
}

export function createEmptyClaudeAutoResumeState(): ClaudeAutoResumeState {
  return { registrations: [], jobs: [], events: [] };
}

export function claudeAutoResumeStateDirectory(env: Record<string, string | undefined> = process.env): string {
  return env[CLAUDE_AUTO_RESUME_STATE_DIR] || join(env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "ai-cmux-conductor");
}

export function claudeAutoResumeStatePath(env: Record<string, string | undefined> = process.env): string {
  return join(claudeAutoResumeStateDirectory(env), "claude-auto-resume.json");
}

export function claudeAutoResumePidPath(env: Record<string, string | undefined> = process.env): string {
  return join(claudeAutoResumeStateDirectory(env), "claude-auto-resume.pid");
}

export class FileClaudeAutoResumeStore implements ClaudeAutoResumeStore {
  constructor(private readonly path = claudeAutoResumeStatePath()) {}

  async load(): Promise<ClaudeAutoResumeState> {
    if (!existsSync(this.path)) return createEmptyClaudeAutoResumeState();
    const parsed = JSON.parse(await readFile(this.path, "utf8")) as Partial<ClaudeAutoResumeState>;
    return normalizeState(parsed);
  }

  async save(state: ClaudeAutoResumeState): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const tempPath = `${this.path}.${process.pid}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(normalizeState(state), null, 2)}\n`, "utf8");
    await rename(tempPath, this.path);
  }
}

function normalizeState(state: Partial<ClaudeAutoResumeState>): ClaudeAutoResumeState {
  return {
    registrations: Array.isArray(state.registrations) ? state.registrations.filter(isRegistrationLike) : [],
    jobs: Array.isArray(state.jobs) ? state.jobs.filter(isJobLike) : [],
    events: Array.isArray(state.events) ? state.events.filter(isEventLike).slice(-200) : [],
  };
}

function isRegistrationLike(value: unknown): value is ClaudeSurfaceRegistration {
  const item = value as ClaudeSurfaceRegistration;
  return Boolean(item && item.workspaceId && item.surfaceId && item.agentIdentity && item.updatedAt);
}

function isJobLike(value: unknown): value is ClaudeAutoResumeJob {
  const item = value as ClaudeAutoResumeJob;
  return Boolean(item && item.id && item.workspaceId && item.agentIdentity && item.resetAt && item.sendAt && item.message && item.status);
}

function isEventLike(value: unknown): value is ClaudeAutoResumeEvent {
  const item = value as ClaudeAutoResumeEvent;
  return Boolean(item && item.id && item.type && item.at && item.message);
}

export function normalizeClaudeTimeZone(timeZone?: string): string {
  const cleaned = (timeZone || CLAUDE_AUTO_RESUME_DEFAULT_TIME_ZONE).trim().replace(/\s*\/\s*/g, "/");
  const normalized = cleaned === "Asia/Calcutta" ? "Asia/Kolkata" : cleaned;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: normalized }).format(new Date(0));
    return normalized;
  } catch {
    return CLAUDE_AUTO_RESUME_DEFAULT_TIME_ZONE;
  }
}

export function detectClaudeUsageLimit(
  screenText: string,
  now = new Date(),
  defaultTimeZone = resolveDefaultTimeZone(),
): ClaudeLimitDetection | undefined {
  if (!isUsageLimitText(screenText)) return undefined;

  const resetMatch = screenText.match(/\bresets?\s+(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?(?:\s*\(([^)]+)\))?/i);
  if (!resetMatch) return undefined;

  const [, rawHour, rawMinute = "0", rawPeriod, rawTimeZone] = resetMatch;
  let hour = Number(rawHour);
  const minute = Number(rawMinute);
  if (!Number.isInteger(hour) || !Number.isInteger(minute) || hour < 1 || hour > 12 || minute < 0 || minute > 59) return undefined;

  const period = rawPeriod.toLowerCase();
  if (period === "a" && hour === 12) hour = 0;
  if (period === "p" && hour !== 12) hour += 12;

  const timeZone = normalizeClaudeTimeZone(rawTimeZone || defaultTimeZone);
  const resetAtMs = resolveNextZonedTime({ hour, minute, second: 0 }, timeZone, now);
  const sendAtMs = resetAtMs + CLAUDE_AUTO_RESUME_SEND_DELAY_MS;
  return {
    resetAt: new Date(resetAtMs).toISOString(),
    sendAt: new Date(sendAtMs).toISOString(),
    timeZone,
    sourceExcerpt: sourceExcerpt(screenText, resetMatch[0]),
    resetText: resetMatch[0],
  };
}

function resolveDefaultTimeZone(): string {
  return normalizeClaudeTimeZone(process.env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone || CLAUDE_AUTO_RESUME_DEFAULT_TIME_ZONE);
}

function isUsageLimitText(text: string): boolean {
  return /you(?:'|’)ve hit your session limit/i.test(text) || /\busage limit\b/i.test(text) || /\bsession limit\b/i.test(text);
}

function sourceExcerpt(text: string, resetText: string): string {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const line = lines.find((candidate) => candidate.includes(resetText)) || lines.find(isUsageLimitText) || text.trim();
  return line.slice(0, 500);
}

interface ZonedClockTime {
  hour: number;
  minute: number;
  second: number;
}

interface ZonedDateTimeParts extends ZonedClockTime {
  year: number;
  month: number;
  day: number;
}

function resolveNextZonedTime(time: ZonedClockTime, timeZone: string, now: Date): number {
  const today = zonedParts(now, timeZone);
  let targetParts: ZonedDateTimeParts = { year: today.year, month: today.month, day: today.day, ...time };
  let targetMs = zonedDateTimeToEpochMs(targetParts, timeZone);
  if (targetMs <= now.getTime()) {
    targetParts = { ...nextCalendarDay(targetParts), ...time };
    targetMs = zonedDateTimeToEpochMs(targetParts, timeZone);
  }
  return targetMs;
}

function zonedParts(date: Date, timeZone: string): ZonedDateTimeParts {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const parts = Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    second: Number(parts.second),
  };
}

function zonedDateTimeToEpochMs(parts: ZonedDateTimeParts, timeZone: string): number {
  const desiredAsUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  let epochMs = desiredAsUtc;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const observed = zonedParts(new Date(epochMs), timeZone);
    const observedAsUtc = Date.UTC(observed.year, observed.month - 1, observed.day, observed.hour, observed.minute, observed.second);
    const diff = desiredAsUtc - observedAsUtc;
    if (diff === 0) break;
    epochMs += diff;
  }
  return epochMs;
}

function nextCalendarDay(parts: Pick<ZonedDateTimeParts, "year" | "month" | "day">): Pick<ZonedDateTimeParts, "year" | "month" | "day"> {
  const next = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + 1, 12, 0, 0));
  return { year: next.getUTCFullYear(), month: next.getUTCMonth() + 1, day: next.getUTCDate() };
}

export function scheduleClaudeAutoResumeJob(
  state: ClaudeAutoResumeState,
  registration: ClaudeSurfaceRegistration,
  detection: ClaudeLimitDetection,
  now = new Date(),
): { created: boolean; job: ClaudeAutoResumeJob } {
  const existing = state.jobs.find(
    (job) =>
      job.workspaceId === registration.workspaceId &&
      job.agentIdentity === registration.agentIdentity &&
      job.resetAt === detection.resetAt &&
      (job.surfaceId || registration.surfaceId) === registration.surfaceId,
  );
  if (existing) {
    existing.sourceExcerpt = detection.sourceExcerpt;
    existing.surfaceId = registration.surfaceId;
    existing.windowId = registration.windowId;
    existing.updatedAt = now.toISOString();
    recordEvent(state, {
      type: "deduped",
      at: now.toISOString(),
      workspaceId: registration.workspaceId,
      surfaceId: registration.surfaceId,
      jobId: existing.id,
      message: `Claude auto-resume already scheduled for ${detection.sendAt}`,
    });
    return { created: false, job: existing };
  }

  const job: ClaudeAutoResumeJob = {
    id: claudeAutoResumeJobId(registration.workspaceId, registration.agentIdentity, detection.resetAt, registration.surfaceId),
    workspaceId: registration.workspaceId,
    windowId: registration.windowId,
    workspaceName: registration.workspaceName,
    agentIdentity: registration.agentIdentity,
    surfaceId: registration.surfaceId,
    resetAt: detection.resetAt,
    sendAt: detection.sendAt,
    timeZone: detection.timeZone,
    resetText: detection.resetText,
    message: CLAUDE_AUTO_RESUME_MESSAGE,
    sourceExcerpt: detection.sourceExcerpt,
    status: "pending",
    attempts: 0,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
  };
  state.jobs.push(job);
  recordEvent(state, {
    type: "scheduled",
    at: now.toISOString(),
    workspaceId: registration.workspaceId,
    surfaceId: registration.surfaceId,
    jobId: job.id,
    message: `Claude limited until ${detection.resetAt}; auto-continue scheduled for ${detection.sendAt}`,
  });
  return { created: true, job };
}

function claudeAutoResumeJobId(workspaceId: string, agentIdentity: string, resetAt: string, surfaceId?: string): string {
  return `${workspaceId}:${agentIdentity}:${surfaceId || "surface"}:${resetAt}`.replace(/[^A-Za-z0-9_.:-]+/g, "_");
}

export async function scanClaudeSurfacesOnce(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  now = new Date(),
  defaultTimeZone = resolveDefaultTimeZone(),
): Promise<void> {
  await discoverClaudeSurfaceRegistrations(state, runner, now);
  for (const registration of state.registrations.filter((candidate) => candidate.agentIdentity.toLowerCase() === "claude")) {
    try {
      const surface = await resolveClaudeSurface(runner, registration);
      registration.surfaceId = surface.surfaceId;
      registration.title = surface.title;
      registration.updatedAt = now.toISOString();
      const screen = await readClaudeScreen(runner, registration, surface.surfaceId);
      const detection = detectClaudeUsageLimit(screen, now, defaultTimeZone);
      if (!detection) continue;
      scheduleClaudeAutoResumeJob(state, registration, detection, now);
    } catch (error) {
      recordEvent(state, {
        type: "scan_failed",
        at: now.toISOString(),
        workspaceId: registration.workspaceId,
        surfaceId: registration.surfaceId,
        message: `Claude auto-resume scan failed: ${errorMessage(error)}`,
        error: errorMessage(error),
      });
    }
  }
}

async function discoverClaudeSurfaceRegistrations(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  now: Date,
): Promise<void> {
  const workspaceRegistrations = new Map<string, ClaudeSurfaceRegistration>();
  for (const registration of state.registrations.filter((candidate) => candidate.agentIdentity.toLowerCase() === "claude")) {
    const key = `${registration.workspaceId}\n${registration.windowId || ""}`;
    if (!workspaceRegistrations.has(key)) workspaceRegistrations.set(key, registration);
  }

  for (const registration of workspaceRegistrations.values()) {
    try {
      const surfaces = await readCmuxTreeSurfaces(runner, registration.workspaceId, registration.windowId);
      for (const surface of surfaces.filter(isClaudeTitledSurface)) {
        const discoveredSurfaceId = surfaceId(surface);
        if (!discoveredSurfaceId) continue;
        const exists = state.registrations.some(
          (candidate) =>
            candidate.workspaceId === registration.workspaceId &&
            candidate.agentIdentity.toLowerCase() === "claude" &&
            candidate.surfaceId === discoveredSurfaceId,
        );
        if (exists) continue;
        state.registrations.push({
          workspaceId: registration.workspaceId,
          windowId: registration.windowId,
          workspaceName: registration.workspaceName,
          cwd: registration.cwd,
          surfaceId: discoveredSurfaceId,
          agentIdentity: "Claude",
          title: surface.title || CLAUDE_PANEL_TITLE,
          updatedAt: now.toISOString(),
        });
        recordEvent(state, {
          type: "registered",
          at: now.toISOString(),
          workspaceId: registration.workspaceId,
          surfaceId: discoveredSurfaceId,
          message: `Discovered Claude surface ${discoveredSurfaceId} for auto-resume`,
        });
      }
    } catch (error) {
      recordEvent(state, {
        type: "scan_failed",
        at: now.toISOString(),
        workspaceId: registration.workspaceId,
        surfaceId: registration.surfaceId,
        message: `Claude auto-resume discovery failed: ${errorMessage(error)}`,
        error: errorMessage(error),
      });
    }
  }
}

export async function processDueClaudeAutoResumeJobs(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  now = new Date(),
  options: ProcessDueOptions = {},
): Promise<void> {
  const graceWindowMs = options.graceWindowMs ?? CLAUDE_AUTO_RESUME_GRACE_WINDOW_MS;
  const retryDelayMs = options.retryDelayMs ?? CLAUDE_AUTO_RESUME_RETRY_DELAY_MS;
  const maxAttempts = options.maxAttempts ?? CLAUDE_AUTO_RESUME_MAX_ATTEMPTS;

  for (const job of state.jobs) {
    if (job.status !== "pending") continue;

    const sendAtMs = Date.parse(job.sendAt);
    const dueAtMs = Date.parse(job.nextAttemptAt || job.sendAt);
    if (Number.isNaN(sendAtMs) || Number.isNaN(dueAtMs)) {
      markFailed(state, job, now, "invalid job timestamp");
      continue;
    }

    if (now.getTime() > sendAtMs + graceWindowMs) {
      job.status = "stale";
      job.updatedAt = now.toISOString();
      job.lastError = `auto-continue stale beyond ${Math.round(graceWindowMs / 60_000)} minute grace window`;
      recordEvent(state, {
        type: "stale",
        at: now.toISOString(),
        workspaceId: job.workspaceId,
        surfaceId: job.surfaceId,
        jobId: job.id,
        message: `Auto-continue stale: ${job.lastError}`,
        error: job.lastError,
      });
      continue;
    }

    if (now.getTime() < dueAtMs) continue;

    await attemptSend(state, runner, job, now, retryDelayMs, maxAttempts);
  }
}

async function attemptSend(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  job: ClaudeAutoResumeJob,
  now: Date,
  retryDelayMs: number,
  maxAttempts: number,
): Promise<void> {
  try {
    const surface = await resolveClaudeSurface(runner, job);
    job.surfaceId = surface.surfaceId;
    const args = ["send", "--workspace", job.workspaceId, ...windowArgs(job.windowId), "--surface", surface.surfaceId, "--", job.message];
    const result = await runner("cmux", args);
    job.attempts += 1;
    job.updatedAt = now.toISOString();
    job.lastResult = exactResult("cmux send", result);

    if (result.code === 0) {
      job.status = "sent";
      job.sentAt = now.toISOString();
      job.nextAttemptAt = undefined;
      recordEvent(state, {
        type: "sent",
        at: now.toISOString(),
        workspaceId: job.workspaceId,
        surfaceId: surface.surfaceId,
        jobId: job.id,
        message: `Auto-continue sent at ${now.toISOString()}: ${job.lastResult}`,
      });
      return;
    }

    const error = exactFailure("cmux send", result);
    if (job.attempts >= maxAttempts) {
      markFailed(state, job, now, error);
      return;
    }

    job.lastError = error;
    job.nextAttemptAt = new Date(now.getTime() + retryDelayMs).toISOString();
    recordEvent(state, {
      type: "retry_scheduled",
      at: now.toISOString(),
      workspaceId: job.workspaceId,
      surfaceId: surface.surfaceId,
      jobId: job.id,
      message: `Auto-continue failed: ${error}; retry ${job.attempts + 1}/${maxAttempts} at ${job.nextAttemptAt}`,
      error,
    });
  } catch (error) {
    job.attempts += 1;
    job.updatedAt = now.toISOString();
    const message = errorMessage(error);
    if (job.attempts >= maxAttempts) {
      markFailed(state, job, now, message);
      return;
    }
    job.lastError = message;
    job.nextAttemptAt = new Date(now.getTime() + retryDelayMs).toISOString();
    recordEvent(state, {
      type: "retry_scheduled",
      at: now.toISOString(),
      workspaceId: job.workspaceId,
      surfaceId: job.surfaceId,
      jobId: job.id,
      message: `Auto-continue failed: ${message}; retry ${job.attempts + 1}/${maxAttempts} at ${job.nextAttemptAt}`,
      error: message,
    });
  }
}

function markFailed(state: ClaudeAutoResumeState, job: ClaudeAutoResumeJob, now: Date, error: string): void {
  job.status = "failed";
  job.lastError = error;
  job.nextAttemptAt = undefined;
  job.updatedAt = now.toISOString();
  recordEvent(state, {
    type: "failed",
    at: now.toISOString(),
    workspaceId: job.workspaceId,
    surfaceId: job.surfaceId,
    jobId: job.id,
    message: `Auto-continue failed: ${error}`,
    error,
  });
}

function exactResult(command: string, result: CommandResult): string {
  const output = (result.stderr || result.stdout).trim();
  return `${command} exit ${result.code}${output ? `: ${output}` : ""}`;
}

function exactFailure(command: string, result: CommandResult): string {
  const output = (result.stderr || result.stdout).trim();
  return `${command} failed${output ? `: ${output}` : ` with exit ${result.code}`}`;
}

async function readClaudeScreen(runner: CommandRunner, registration: Pick<ClaudeSurfaceRegistration, "workspaceId" | "windowId">, surfaceId: string): Promise<string> {
  const result = await runner("cmux", [
    "read-screen",
    "--workspace",
    registration.workspaceId,
    ...windowArgs(registration.windowId),
    "--surface",
    surfaceId,
    "--scrollback",
    "--lines",
    "160",
  ]);
  if (result.code !== 0) throw new Error(exactFailure("cmux read-screen", result));
  return result.stdout;
}

async function resolveClaudeSurface(
  runner: CommandRunner,
  selector: Pick<ClaudeSurfaceRegistration | ClaudeAutoResumeJob, "workspaceId" | "windowId" | "surfaceId" | "agentIdentity">,
): Promise<{ surfaceId: string; title?: string }> {
  const tree = await runner("cmux", ["--id-format", "both", "--json", "tree", "--workspace", selector.workspaceId, ...windowArgs(selector.windowId)]);
  if (tree.code !== 0) throw new Error(exactFailure("cmux tree", tree));

  const surfaces = parseTreeSurfaces(tree.stdout);
  const oldSurface = surfaces.find((surface) => surfaceId(surface) === selector.surfaceId);
  const oldSurfaceId = oldSurface && surfaceId(oldSurface);
  if (oldSurfaceId && isPlausibleClaudeSurface(oldSurface)) return { surfaceId: oldSurfaceId, title: oldSurface.title };

  const titleMatch = surfaces.find((surface) => isClaudeTitledSurface(surface));
  const titleMatchId = titleMatch && surfaceId(titleMatch);
  if (titleMatchId) return { surfaceId: titleMatchId, title: titleMatch.title };

  if (oldSurfaceId) return { surfaceId: oldSurfaceId, title: oldSurface.title };
  throw new Error(`Unable to resolve ${selector.agentIdentity} surface in workspace ${selector.workspaceId}`);
}

function parseTreeSurfaces(stdout: string): CmuxSurface[] {
  const parsed = JSON.parse(stdout || "{}");
  const surfaces: CmuxSurface[] = [];
  for (const window of parsed.windows || []) {
    for (const workspace of window.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          surfaces.push(surface);
        }
      }
    }
  }
  return surfaces;
}

export function isPlausibleClaudeSurface(surface: CmuxSurface, screenText?: string): boolean {
  if (surface.type === "browser") return false;
  if (surface.title && !/claude/i.test(surface.title)) return false;
  if (!screenText) return true;
  if (hasClaudeUiMarkers(screenText)) return true;
  if (hasShellPromptMarkers(screenText) || hasPromptEchoedIntoShellMarkers(screenText)) return false;
  return true;
}

function hasClaudeUiMarkers(screenText: string): boolean {
  return /Claude Code|Welcome to Claude|Bypassing Permissions|\bOpus\b|\bSonnet\b|\bHaiku\b|\bclaude\b.*\bready\b/i.test(screenText);
}

function hasShellPromptMarkers(screenText: string): boolean {
  return /Last login:|(?:^|\n)[^\n]*[%$#]\s*$/m.test(screenText);
}

function hasPromptEchoedIntoShellMarkers(screenText: string): boolean {
  return /zsh: command not found:|command not found:|parse error near|no matches found:/i.test(screenText);
}

function isClaudeTitledSurface(surface: CmuxSurface): boolean {
  return surface.type !== "browser" && isManagedAgentSurfaceTitle("Claude", surface.title);
}

function surfaceId(surface: CmuxSurface): string | undefined {
  return surface.ref || surface.id;
}

function windowArgs(windowId?: string): string[] {
  return windowId ? ["--window", windowId] : [];
}


export interface ClaudePromptWithHealthGuardOptions {
  workspaceId: string;
  prompt: string;
  cwd: string;
  windowId?: string;
  now?: Date;
  readyPollIntervalMs?: number;
  maxReadyPolls?: number;
}

export interface ClaudePromptWithHealthGuardResult {
  surfaceId: string;
  recovered: boolean;
}

export async function sendClaudePromptWithHealthGuard(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  options: ClaudePromptWithHealthGuardOptions,
): Promise<ClaudePromptWithHealthGuardResult> {
  const now = options.now || new Date();
  const registration = state.registrations.find(
    (candidate) => candidate.workspaceId === options.workspaceId && candidate.agentIdentity.toLowerCase() === "claude",
  );
  if (!registration) throw new Error(`No Claude surface registered in workspace ${options.workspaceId}`);

  const resolved = await resolveClaudeSurfaceDetails(runner, registration);
  const screen = await readClaudeScreen(runner, registration, resolved.surfaceId);
  let target = resolved;
  let recovered = false;

  if (!isPlausibleClaudeSurface(resolved.surface, screen)) {
    target = await recoverClaudeSurface(state, runner, registration, resolved, options, now);
    recovered = true;
  }

  const message = options.prompt.endsWith("\n") ? options.prompt : `${options.prompt}\n`;
  const sendResult = await runner("cmux", [
    "send",
    "--workspace",
    options.workspaceId,
    ...windowArgs(options.windowId),
    "--surface",
    target.surfaceId,
    "--",
    message,
  ]);
  if (sendResult.code !== 0) throw new Error(exactFailure("cmux send", sendResult));
  return { surfaceId: target.surfaceId, recovered };
}

async function recoverClaudeSurface(
  state: ClaudeAutoResumeState,
  runner: CommandRunner,
  registration: ClaudeSurfaceRegistration,
  stale: { surface: CmuxSurface; surfaceId: string },
  options: ClaudePromptWithHealthGuardOptions,
  now: Date,
): Promise<{ surface: CmuxSurface; surfaceId: string }> {
  if (!isExactManagedPanelTitle("Claude", stale.surface.title)) {
    throw new Error(`Refusing to auto-close non-exact Claude surface ${stale.surfaceId} titled ${stale.surface.title || "untitled"}`);
  }
  const paneRef = stale.surface.pane_ref || stale.surface.pane_id;
  if (!paneRef) throw new Error(`Unable to recover Claude surface ${stale.surfaceId}: missing pane ref`);

  const closeResult = await runner("cmux", [
    "close-surface",
    "--workspace",
    options.workspaceId,
    ...windowArgs(options.windowId),
    "--surface",
    stale.surfaceId,
  ]);
  if (closeResult.code !== 0) throw new Error(exactFailure("cmux close-surface", closeResult));

  const createResult = await runner("cmux", [
    "new-surface",
    "--workspace",
    options.workspaceId,
    ...windowArgs(options.windowId),
    "--pane",
    paneRef,
    "--type",
    "terminal",
    "--focus",
    "true",
  ]);
  if (createResult.code !== 0) throw new Error(exactFailure("cmux new-surface", createResult));

  const createdRef = firstCmuxRef(createResult.stdout, "surface");
  const surfaces = await readCmuxTreeSurfaces(runner, options.workspaceId, options.windowId);
  const createdSurface =
    (createdRef && surfaces.find((surface) => surfaceId(surface) === createdRef)) ||
    surfaces.find((surface) => surface.pane_ref === paneRef || surface.pane_id === paneRef);
  const createdSurfaceId = createdSurface && surfaceId(createdSurface);
  if (!createdSurface || !createdSurfaceId) throw new Error(`Unable to find recovered Claude surface in pane ${paneRef}`);

  const renameResult = await runner("cmux", ["rename-tab", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdSurfaceId, CLAUDE_PANEL_TITLE]);
  if (renameResult.code !== 0) throw new Error(exactFailure("cmux rename-tab", renameResult));

  const launch = `zsh -lc ${shellQuote(`cd ${shellQuote(options.cwd)} && clscb`)}\n`;
  const launchResult = await runner("cmux", ["send", "--workspace", options.workspaceId, ...windowArgs(options.windowId), "--surface", createdSurfaceId, launch]);
  if (launchResult.code !== 0) throw new Error(exactFailure("cmux send", launchResult));

  await waitForClaudeUi(runner, options.workspaceId, options.windowId, createdSurfaceId, options.readyPollIntervalMs ?? 1_000, options.maxReadyPolls ?? 12);

  registration.surfaceId = createdSurfaceId;
  registration.cwd = options.cwd;
  registration.updatedAt = now.toISOString();
  recordEvent(state, {
    type: "surface_recovered",
    at: now.toISOString(),
    workspaceId: options.workspaceId,
    surfaceId: createdSurfaceId,
    message: `Claude surface recovered: ${stale.surfaceId} → ${createdSurfaceId}`,
  });
  return { surface: createdSurface, surfaceId: createdSurfaceId };
}

async function waitForClaudeUi(
  runner: CommandRunner,
  workspaceId: string,
  windowId: string | undefined,
  surfaceIdValue: string,
  pollIntervalMs: number,
  maxPolls: number,
): Promise<void> {
  let lastScreen = "";
  for (let attempt = 0; attempt < maxPolls; attempt += 1) {
    lastScreen = await readClaudeScreen(runner, { workspaceId, windowId }, surfaceIdValue);
    if (hasClaudeUiMarkers(lastScreen)) return;
    if (pollIntervalMs > 0) await sleep(pollIntervalMs);
  }
  throw new Error(`Recovered Claude surface ${surfaceIdValue} did not show Claude UI markers. Last screen: ${lastScreen.slice(0, 200)}`);
}

async function resolveClaudeSurfaceDetails(
  runner: CommandRunner,
  selector: Pick<ClaudeSurfaceRegistration | ClaudeAutoResumeJob, "workspaceId" | "windowId" | "surfaceId" | "agentIdentity">,
): Promise<{ surface: CmuxSurface; surfaceId: string }> {
  const surfaces = await readCmuxTreeSurfaces(runner, selector.workspaceId, selector.windowId);
  const oldSurface = surfaces.find((surface) => surfaceId(surface) === selector.surfaceId);
  const oldSurfaceId = oldSurface && surfaceId(oldSurface);
  if (oldSurface && oldSurfaceId && isPlausibleClaudeSurface(oldSurface)) return { surface: oldSurface, surfaceId: oldSurfaceId };

  const titleMatch = surfaces.find((surface) => isClaudeTitledSurface(surface));
  const titleMatchId = titleMatch && surfaceId(titleMatch);
  if (titleMatch && titleMatchId) return { surface: titleMatch, surfaceId: titleMatchId };

  if (oldSurface && oldSurfaceId) return { surface: oldSurface, surfaceId: oldSurfaceId };
  throw new Error(`Unable to resolve ${selector.agentIdentity} surface in workspace ${selector.workspaceId}`);
}

async function readCmuxTreeSurfaces(runner: CommandRunner, workspaceId: string, windowId?: string): Promise<CmuxSurface[]> {
  const tree = await runner("cmux", ["--id-format", "both", "--json", "tree", "--workspace", workspaceId, ...windowArgs(windowId)]);
  if (tree.code !== 0) throw new Error(exactFailure("cmux tree", tree));
  return parseTreeSurfaces(tree.stdout);
}

function firstCmuxRef(stdout: string, prefix: string): string | undefined {
  return stdout.match(new RegExp(`${prefix}:[A-Za-z0-9_-]+`))?.[0] || stdout.match(/[0-9A-Fa-f-]{36}/)?.[0];
}

export async function registerClaudeAutoResumeSurface(
  registration: ClaudeSurfaceRegistration,
  store: ClaudeAutoResumeStore = new FileClaudeAutoResumeStore(),
): Promise<ClaudeAutoResumeState> {
  const state = await store.load();
  upsertClaudeSurfaceRegistration(state, registration);
  await store.save(state);
  return state;
}

export function upsertClaudeSurfaceRegistration(state: ClaudeAutoResumeState, registration: ClaudeSurfaceRegistration): void {
  const index = state.registrations.findIndex(
    (candidate) => candidate.workspaceId === registration.workspaceId && candidate.agentIdentity === registration.agentIdentity,
  );
  if (index === -1) state.registrations.push(registration);
  else state.registrations[index] = { ...state.registrations[index], ...registration };
  recordEvent(state, {
    type: "registered",
    at: registration.updatedAt,
    workspaceId: registration.workspaceId,
    surfaceId: registration.surfaceId,
    message: `Registered ${registration.agentIdentity} surface ${registration.surfaceId} for auto-resume`,
  });
}

export async function registerClaudeSurfaceFromConductorContext(
  context: ConductorContext,
  windowId: string | undefined,
  store?: ClaudeAutoResumeStore,
): Promise<ClaudeAutoResumeState> {
  if (context.claudePanelEnabled === false || !context.claudeSurfaceId) {
    const resolvedStore = store || new FileClaudeAutoResumeStore();
    const state = await resolvedStore.load();
    state.registrations = state.registrations.filter(
      (registration) => !(registration.workspaceId === context.workspaceId && registration.agentIdentity.toLowerCase() === "claude"),
    );
    await resolvedStore.save(state);
    return state;
  }
  return registerClaudeAutoResumeSurface(
    {
      workspaceId: context.workspaceId,
      windowId,
      workspaceName: context.workspaceName,
      surfaceId: context.claudeSurfaceId,
      agentIdentity: "Claude",
      title: CLAUDE_PANEL_TITLE,
      updatedAt: new Date().toISOString(),
    },
    store,
  );
}

function recordEvent(
  state: ClaudeAutoResumeState,
  event: Omit<ClaudeAutoResumeEvent, "id">,
): void {
  state.events.push({ id: `${event.at}:${event.type}:${state.events.length}`.replace(/[^A-Za-z0-9_.:-]+/g, "_"), ...event });
  if (state.events.length > 200) state.events.splice(0, state.events.length - 200);
}

export function formatClaudeAutoResumeSitrep(
  state: ClaudeAutoResumeState,
  now = new Date(),
  defaultTimeZone = resolveDefaultTimeZone(),
): string {
  const pending = state.jobs.filter((job) => job.status === "pending").sort((a, b) => Date.parse(a.sendAt) - Date.parse(b.sendAt));
  const recentTerminal = state.jobs
    .filter((job) => job.status !== "pending")
    .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))
    .slice(0, 5);
  const lines: string[] = ["Claude auto-resume status"];

  if (!state.registrations.length) lines.push("No Claude auto-resume surfaces registered.");
  for (const registration of state.registrations) {
    lines.push(`Registered ${registration.agentIdentity}: workspace ${registration.workspaceId}, surface ${registration.surfaceId}.`);
  }
  for (const job of pending) {
    const timeZone = normalizeClaudeTimeZone(job.timeZone || defaultTimeZone);
    const due = Date.parse(job.nextAttemptAt || job.sendAt) <= now.getTime() ? "due now" : `due ${formatInZone(job.nextAttemptAt || job.sendAt, timeZone)}`;
    lines.push(
      `Claude limited until ${formatInZone(job.resetAt, timeZone)}; auto-continue scheduled for ${formatInZone(job.sendAt, timeZone)} (${due}).`,
    );
  }
  for (const job of recentTerminal) {
    if (job.status === "sent") lines.push(`Auto-continue sent at ${job.sentAt || job.updatedAt}: ${job.lastResult || "cmux send exit 0"}.`);
    if (job.status === "failed") lines.push(`Auto-continue failed: ${job.lastError || "unknown error"}.`);
    if (job.status === "stale") lines.push(`Auto-continue stale: ${job.lastError || "beyond grace window"}.`);
  }
  for (const event of state.events.filter((candidate) => candidate.type === "surface_recovered").slice(-5)) {
    lines.push(event.message);
  }
  if (!pending.length && !recentTerminal.length) lines.push("No pending Claude auto-resume jobs.");
  return lines.join("\n");
}

function formatInZone(iso: string, timeZone: string): string {
  const formatted = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
    timeZoneName: "short",
  }).format(new Date(iso));
  return `${formatted.replace(/\sGMT[+-]\S+$/, "")} ${timeZone}`;
}

export async function loadClaudeAutoResumeStatus(store: ClaudeAutoResumeStore = new FileClaudeAutoResumeStore()): Promise<string> {
  return formatClaudeAutoResumeSitrep(await store.load());
}

export async function runClaudeAutoResumeDaemon(options: RunDaemonOptions = {}): Promise<never> {
  const runner = options.runner || defaultRunner;
  const store = options.store || new FileClaudeAutoResumeStore();
  const now = options.now || (() => new Date());
  const pollIntervalMs = options.pollIntervalMs ?? CLAUDE_AUTO_RESUME_DEFAULT_POLL_MS;
  const defaultTimeZone = options.defaultTimeZone || resolveDefaultTimeZone();
  let stopped = false;
  process.once("SIGTERM", () => {
    stopped = true;
  });
  process.once("SIGINT", () => {
    stopped = true;
  });

  while (!stopped) {
    const tickNow = now();
    const state = await store.load();
    await scanClaudeSurfacesOnce(state, runner, tickNow, defaultTimeZone);
    await processDueClaudeAutoResumeJobs(state, runner, tickNow);
    await store.save(state);
    await sleep(pollIntervalMs);
  }

  process.exit(0);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function ensureClaudeAutoResumeDaemon(
  env: Record<string, string | undefined> = process.env,
  entrypoint = process.argv[1],
): Promise<{ started: boolean; pid?: number; reason?: string }> {
  if (env[CLAUDE_AUTO_RESUME_DISABLE_FLAG]?.trim().toLowerCase() === "false") {
    return { started: false, reason: `${CLAUDE_AUTO_RESUME_DISABLE_FLAG}=false` };
  }

  const pidPath = claudeAutoResumePidPath(env);
  const livePid = await readLivePid(pidPath);
  if (livePid) return { started: false, pid: livePid, reason: "already running" };

  await mkdir(dirname(pidPath), { recursive: true });
  const child = spawn(process.execPath, [entrypoint, "--daemon"], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env, ...env },
  });
  child.unref();
  await writeFile(pidPath, `${child.pid}\n`, "utf8");
  return { started: true, pid: child.pid };
}

export async function stopClaudeAutoResumeDaemon(env: Record<string, string | undefined> = process.env): Promise<{ stopped: boolean; pid?: number; reason?: string }> {
  const pidPath = claudeAutoResumePidPath(env);
  const pidText = existsSync(pidPath) ? (await readFile(pidPath, "utf8")).trim() : "";
  const pid = Number(pidText);
  if (!Number.isInteger(pid) || pid <= 0) return { stopped: false, reason: "not running" };
  try {
    process.kill(pid, "SIGTERM");
    await rm(pidPath, { force: true });
    return { stopped: true, pid };
  } catch (error) {
    await rm(pidPath, { force: true });
    return { stopped: false, pid, reason: errorMessage(error) };
  }
}

async function readLivePid(pidPath: string): Promise<number | undefined> {
  if (!existsSync(pidPath)) return undefined;
  const pid = Number((await readFile(pidPath, "utf8")).trim());
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    await rm(pidPath, { force: true });
    return undefined;
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
