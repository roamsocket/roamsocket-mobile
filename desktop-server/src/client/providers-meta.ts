/** BYOK chat/coding providers shown in the desktop client. */
export const CHAT_PROVIDERS = [
  { id: "anthropic", label: "Anthropic", defaultModel: "claude-sonnet-4-20250514" },
  { id: "openai", label: "OpenAI", defaultModel: "gpt-4o" },
  { id: "google", label: "Google Gemini", defaultModel: "gemini-2.0-flash" },
  { id: "groq", label: "Groq", defaultModel: "llama-3.3-70b-versatile" },
  { id: "openrouter", label: "OpenRouter", defaultModel: "openai/gpt-4o-mini" },
  { id: "xai", label: "xAI", defaultModel: "grok-3" },
  { id: "mistral", label: "Mistral", defaultModel: "mistral-large-latest" },
  { id: "minimax", label: "MiniMax", defaultModel: "MiniMax-M3" },
  { id: "localMetal", label: "On-device Metal", defaultModel: "" },
] as const;

export type ChatProviderId = (typeof CHAT_PROVIDERS)[number]["id"];

export const EFFORTS = ["low", "medium", "high"] as const;
export type Effort = (typeof EFFORTS)[number];

/** Short + long copy for effort pickers (Claude-style sidebar explanations). */
export function effortExplanation(effort: Effort): { label: string; summary: string; detail: string } {
  switch (effort) {
    case "low":
      return {
        label: "Low",
        summary: "Faster replies",
        detail:
          "Minimal deliberation. Best for quick questions, simple edits, and when latency matters more than depth.",
      };
    case "medium":
      return {
        label: "Medium",
        summary: "Balanced",
        detail:
          "Solid default for everyday coding and chat. Weighs trade-offs without spending a long time planning.",
      };
    case "high":
      return {
        label: "High",
        summary: "Thorough reasoning",
        detail:
          "More careful multi-step reasoning. Prefer for hard bugs, architecture, refactors, and tasks with many tools.",
      };
  }
}

/** Primary sidebar destinations — Vision intentionally excluded. */
export const SIDEBAR_DESTINATIONS = [
  "chats",
  "projects",
  "artifacts",
  "code",
  "settings",
] as const;

export type SidebarDestination = (typeof SIDEBAR_DESTINATIONS)[number];

export function isSidebarDestination(value: string): value is SidebarDestination {
  return (SIDEBAR_DESTINATIONS as readonly string[]).includes(value);
}

export function providerLabel(id: string): string {
  return CHAT_PROVIDERS.find((p) => p.id === id)?.label ?? id;
}

export function defaultModelFor(providerId: string): string {
  return CHAT_PROVIDERS.find((p) => p.id === providerId)?.defaultModel ?? "";
}

/** Built-in catalog entry shape reused when merging custom providers into pickers. */
export interface ProviderCatalogEntry {
  id: string;
  label: string;
  defaultModel: string;
}

/**
 * Built-ins plus custom providers as picker rows.
 * Custom rows use wire id `custom:<slug>`.
 */
export function mergeProviderCatalog(
  customs: Array<{ id: string; label: string; defaultModel?: string }>,
): ProviderCatalogEntry[] {
  const builtIns: ProviderCatalogEntry[] = CHAT_PROVIDERS.map((p) => ({
    id: p.id,
    label: p.label,
    defaultModel: p.defaultModel,
  }));
  const customRows: ProviderCatalogEntry[] = customs.map((c) => ({
    id: c.id.startsWith("custom:") ? c.id : `custom:${c.id}`,
    label: c.label,
    defaultModel: c.defaultModel ?? "",
  }));
  return [...builtIns, ...customRows];
}
