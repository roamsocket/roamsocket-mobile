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
 * Full system prefix: composer tools + optional user profile memory + project.
 */
export function buildChatSystemContent(opts: {
  tools: ComposerToolsState;
  project?: ProjectItem | null;
  /** Project memory narrative (when search/reference chats is on). */
  includeMemory?: boolean;
  /** Structured user memory from Settings → Memory. */
  userMemorySystem?: string | null;
  resolveSkill?: (id: string) => SkillRecord | { id: string; name: string; description: string } | undefined;
}): string {
  const parts = [
    ...composerToolsSystemHints(opts.tools, opts.resolveSkill),
  ];
  const userMem = (opts.userMemorySystem ?? "").trim();
  if (userMem) {
    parts.push(`User memory (private, on this device):\n${userMem}`);
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
