export type ManagedAgentName = "Claude" | "Codex" | "Devin";

export type ManagedPanelTitle = "kid-claude" | "kid-codex" | "kid-devin";

export const MANAGED_PANEL_TITLES: Record<ManagedAgentName, ManagedPanelTitle> = {
  Claude: "kid-claude",
  Codex: "kid-codex",
  Devin: "kid-devin",
};

export const LEGACY_MANAGED_PANEL_TITLES: Record<ManagedAgentName, string> = {
  Claude: "Claude",
  Codex: "Codex",
  Devin: "Devin",
};

export const CLAUDE_PANEL_TITLE = MANAGED_PANEL_TITLES.Claude;
export const CODEX_PANEL_TITLE = MANAGED_PANEL_TITLES.Codex;
export const DEVIN_PANEL_TITLE = MANAGED_PANEL_TITLES.Devin;

export function managedPanelTitle(agent: ManagedAgentName): ManagedPanelTitle {
  return MANAGED_PANEL_TITLES[agent];
}

export function isManagedAgentSurfaceTitle(agent: ManagedAgentName, title: string | undefined): boolean {
  if (!title) return false;
  if (agent === "Codex") {
    return title === MANAGED_PANEL_TITLES.Codex || title === LEGACY_MANAGED_PANEL_TITLES.Codex;
  }
  return new RegExp(`\\b${agent}\\b`, "i").test(title);
}

export function isExactManagedPanelTitle(agent: ManagedAgentName, title: string | undefined): boolean {
  return title === MANAGED_PANEL_TITLES[agent] || title === LEGACY_MANAGED_PANEL_TITLES[agent];
}

export function shouldRenameToCanonicalManagedPanelTitle(agent: ManagedAgentName, title: string | undefined): boolean {
  return title === LEGACY_MANAGED_PANEL_TITLES[agent];
}
