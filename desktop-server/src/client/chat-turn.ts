/**
 * Pure helpers for constructing outbound chat turns (system + user content).
 * Used by the desktop renderer on send — unit-tested without DOM.
 */
import type { ProjectItem } from "./projects-store.js";
import { isMemoryEmptyStateChrome } from "./projects-store.js";
import {
  type ComposerToolsState,
  composerToolsSystemHints,
} from "./composer-tools.js";
import type { SkillRecord } from "./skills-store.js";

export type ChatAttachment = { name: string; content: string };

export type ChatTurn = { role: "user" | "assistant" | "system"; content: string };

/**
 * Merge user text + file/url attachments into one user message body.
 */
export function buildUserContent(text: string, attachments: ChatAttachment[] = []): string {
  const body = text.trim();
  if (!attachments.length) return body;
  const block = attachments
    .map((a) => `### Attachment: ${a.name}\n${a.content.slice(0, 12000)}`)
    .join("\n\n");
  return body ? `${body}\n\n${block}` : block;
}

/**
 * Project instructions / memory / context files for system injection.
 */
export function projectSystemParts(
  project: ProjectItem | undefined | null,
  opts?: { includeMemory?: boolean },
): string[] {
  if (!project) return [];
  const includeMemory = opts?.includeMemory !== false;
  const parts: string[] = [];
  if (project.instructions.trim()) {
    parts.push(`Project instructions:\n${project.instructions.trim()}`);
  }
  const mem = project.memory.trim();
  if (includeMemory && mem && !isMemoryEmptyStateChrome(mem)) {
    parts.push(`Project memory (private):\n${mem}`);
  }
  if (project.contextItems?.length) {
    const ctx = project.contextItems
      .slice(0, 8)
      .map((c) => `### ${c.title}\n${c.content.slice(0, 4000)}`)
      .join("\n\n");
    parts.push(`Project context files:\n${ctx}`);
  }
  return parts;
}

/**
 * Instructions for chat-driven memory auto-save (mirrors the iOS prompt).
 * The model emits self-closing `<memory />` tags inline; the renderer
 * strips them and applies the mutations to the local memory store.
 */
export const MEMORY_AUTO_SAVE_PROMPT = `
You have access to the user's private on-device memory (shown above as "User memory"). You can record new facts about the user, or update / forget existing ones, by emitting self-closing <memory /> tags anywhere in your reply. The tags are stripped from the visible text automatically and the user sees an undo card for each one.

Tag format:
  <memory action="add" category="you|topic|area" title="Profile" summary="…" details="…" />
  <memory action="forget" target="Verizon" />
  <memory action="rename" target="Profile" value="About me" />
  <memory action="set_summary" target="Profile" value="…" />
  <memory action="set_details" target="Profile" value="A|B|C" />

Only save STABLE personal facts — identity (name, role, location, relationships), lasting preferences, recurring project / area context, and the user's own explicit "remember that X" requests. Do NOT save transient task info, one-off chat content, or speculative inferences. Anything inside a code block or inline code span is never parsed. When unsure, do not emit a tag. Never emit more than one tag per reply unless the user is doing a deliberate batch. Do not narrate that you saved something; the UI surfaces it.
`;

/**
 * Full system prefix: composer tools + optional user profile memory + project.
 */
export function buildChatSystemContent(opts: {
  tools: ComposerToolsState;
  project?: ProjectItem | null;
  /** Project memory narrative (when search/reference chats is on). */
  includeMemory?: boolean;
  /** Structured user memory from Settings → Memory. */
  userMemorySystem?: string | null;
  /** When true, append the auto-save instructions so the model emits tags. */
  autoSaveMemory?: boolean;
  resolveSkill?: (id: string) => SkillRecord | { id: string; name: string; description: string } | undefined;
}): string {
  const parts = [
    ...composerToolsSystemHints(opts.tools, opts.resolveSkill),
  ];
  const userMem = (opts.userMemorySystem ?? "").trim();
  if (userMem) {
    parts.push(`User memory (private, on this device):\n${userMem}`);
    if (opts.autoSaveMemory) {
      parts.push(MEMORY_AUTO_SAVE_PROMPT.trim());
    }
  }
  parts.push(...projectSystemParts(opts.project, { includeMemory: opts.includeMemory }));
  return parts.join("\n\n");
}

/**
 * Prepend a system turn when content is non-empty.
 */
export function withSystemTurn(
  turns: ChatTurn[],
  systemContent: string,
): ChatTurn[] {
  const sys = systemContent.trim();
  if (!sys) return turns;
  return [{ role: "system", content: sys }, ...turns];
}
