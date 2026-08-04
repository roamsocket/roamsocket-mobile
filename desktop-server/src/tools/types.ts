/** Shared types for agent tools. */
import path from "node:path";

export interface ToolContext {
  /** Absolute path to the session's cloned working directory. */
  workdir: string;
  /** Emit a line of streaming output (e.g. bash stdout) to the app. */
  onOutput?: (chunk: string) => void;
}

export interface ToolResult {
  ok: boolean;
  /** Display-ready, already-truncated output. */
  output: string;
}

export interface Tool {
  name: string;
  description: string;
  /** JSON Schema for the tool input, used in provider tool-use requests. */
  inputSchema: Record<string, unknown>;
  /** One-line human summary for the tool_call event. */
  summarize(input: Record<string, unknown>): string;
  execute(input: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult>;
}

/** Clamp large tool output so a single result can't blow up the transcript. */
export function truncate(text: string, max = 16_000): string {
  if (text.length <= max) return text;
  const head = text.slice(0, max);
  return `${head}\n… [truncated ${text.length - max} chars]`;
}

/** Resolve a user-supplied path safely inside the workdir (no escaping). */
export function resolveInside(workdir: string, p: string): string {
  const resolved = path.resolve(workdir, p);
  const rel = path.relative(workdir, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Path escapes the working directory: ${p}`);
  }
  return resolved;
}
