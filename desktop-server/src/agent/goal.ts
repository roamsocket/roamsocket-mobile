/**
 * `/goal` — session-scoped completion condition.
 *
 * Mirrors Claude Code's slash command: set a verifiable end state, keep the
 * coding agent working across turns until a separate evaluator judges the
 * condition met from the conversation transcript.
 */
import type { ModelSelection, ProviderId } from "../protocol.js";
import type { NormalizedMessage, ProviderAdapter } from "../providers/types.js";

export const MAX_GOAL_CONDITION_LEN = 4000;
/** Safety cap so a stuck evaluator cannot burn unlimited turns. */
export const MAX_GOAL_TURNS = 20;

const CLEAR_ALIASES = new Set(["clear", "stop", "off", "reset", "none", "cancel"]);

export type GoalCommand =
  | { kind: "status" }
  | { kind: "clear" }
  | { kind: "set"; condition: string };

export interface ActiveGoal {
  condition: string;
  startedAt: number;
  turnsEvaluated: number;
  lastReason?: string;
}

export interface AchievedGoal {
  condition: string;
  startedAt: number;
  endedAt: number;
  turnsEvaluated: number;
}

export type GoalStatusKind = "active" | "achieved" | "cleared" | "none";

/**
 * Parse a composer line. Returns null when the text is not a `/goal` command
 * (case-insensitive, must be the whole message).
 */
export function parseGoalCommand(text: string): GoalCommand | null {
  const trimmed = text.trim();
  const m = trimmed.match(/^\/goal(?:\s+([\s\S]*))?$/i);
  if (!m) return null;
  const arg = (m[1] ?? "").trim();
  if (!arg) return { kind: "status" };
  if (CLEAR_ALIASES.has(arg.toLowerCase())) return { kind: "clear" };
  const condition =
    arg.length > MAX_GOAL_CONDITION_LEN ? arg.slice(0, MAX_GOAL_CONDITION_LEN) : arg;
  return { kind: "set", condition };
}

/** User-facing directive that starts (or replaces) a goal turn. */
export function goalKickoffPrompt(condition: string): string {
  return (
    `Work toward this goal until it is fully met:\n\n${condition}\n\n` +
    `Use tools as needed. Run the checks that prove the condition (tests, builds, ` +
    `file contents, git status, etc.) so the results appear in the conversation. ` +
    `When you believe the goal is met, summarize the evidence.`
  );
}

/** Follow-up after the evaluator says the goal is not met yet. */
export function goalContinuePrompt(condition: string, reason: string): string {
  return (
    `The goal is not yet met.\n\n` +
    `Evaluator reason: ${reason}\n\n` +
    `Continue working toward this goal:\n${condition}\n\n` +
    `Address the gap above, then re-check with tools so the transcript shows proof.`
  );
}

export function formatElapsed(ms: number): string {
  if (ms < 60_000) return `${Math.max(1, Math.round(ms / 1000))}s`;
  const mins = Math.floor(ms / 60_000);
  const secs = Math.round((ms % 60_000) / 1000);
  if (mins < 60) return secs > 0 ? `${mins}m ${secs}s` : `${mins}m`;
  const hours = Math.floor(mins / 60);
  const rem = mins % 60;
  return rem > 0 ? `${hours}h ${rem}m` : `${hours}h`;
}

export function buildGoalStatusMessage(opts: {
  status: GoalStatusKind;
  condition?: string;
  reason?: string;
  turnsEvaluated?: number;
  startedAt?: number;
  endedAt?: number;
}): string {
  const { status, condition, reason, turnsEvaluated = 0, startedAt, endedAt } = opts;
  if (status === "none") {
    return "No goal set.";
  }
  if (status === "cleared") {
    return condition ? `Goal cleared: ${condition}` : "Goal cleared.";
  }
  if (status === "achieved") {
    const parts = [`Goal achieved: ${condition ?? ""}`.trim()];
    if (startedAt) {
      const end = endedAt ?? Date.now();
      parts.push(`Duration ${formatElapsed(end - startedAt)}.`);
    }
    if (turnsEvaluated > 0) parts.push(`${turnsEvaluated} turn(s) evaluated.`);
    if (reason) parts.push(reason);
    return parts.join(" ");
  }
  // active
  const parts = [`◎ /goal active: ${condition ?? ""}`.trim()];
  if (startedAt) parts.push(`Running ${formatElapsed(Date.now() - startedAt)}.`);
  if (turnsEvaluated > 0) parts.push(`${turnsEvaluated} turn(s) evaluated.`);
  if (reason) parts.push(`Latest: ${reason}`);
  return parts.join(" ");
}

/** Compact transcript for the evaluator (no tools needed to re-run). */
export function buildTranscriptSnippet(
  messages: NormalizedMessage[],
  maxChars = 14_000,
): string {
  const lines: string[] = [];
  for (const m of messages) {
    if (m.role === "user") {
      lines.push(`User: ${m.text}`);
    } else if (m.role === "assistant") {
      if (m.text.trim()) lines.push(`Assistant: ${m.text}`);
      for (const c of m.toolCalls) {
        lines.push(`Assistant tool_call: ${c.name}(${JSON.stringify(c.input).slice(0, 400)})`);
      }
    } else {
      const out = m.output.length > 800 ? `${m.output.slice(0, 800)}…` : m.output;
      lines.push(`Tool ${m.name} (${m.ok ? "ok" : "fail"}): ${out}`);
    }
  }
  let text = lines.join("\n");
  if (text.length > maxChars) {
    text = `…(truncated)…\n${text.slice(text.length - maxChars)}`;
  }
  return text || "(empty conversation)";
}

/**
 * Prefer a small/fast model for evaluation when the session provider has one.
 * Override with `APC_GOAL_EVAL_MODEL`.
 */
export function evaluatorModelId(selection: ModelSelection): string {
  if (process.env.APC_GOAL_EVAL_MODEL?.trim()) {
    return process.env.APC_GOAL_EVAL_MODEL.trim();
  }
  const p = selection.provider as ProviderId;
  if (p === "localMetal" || p === "local-metal" || String(p).startsWith("custom:")) {
    return selection.model;
  }
  switch (p) {
    case "anthropic":
      return "claude-haiku-4-5-20251001";
    case "openai":
      return "gpt-4o-mini";
    case "google":
      return "gemini-2.0-flash";
    case "groq":
      return "llama-3.1-8b-instant";
    case "openrouter":
      return "anthropic/claude-3.5-haiku";
    case "xai":
      return "grok-3-mini";
    case "mistral":
      return "mistral-small-latest";
    case "minimax":
      return selection.model;
    default:
      return selection.model;
  }
}

const EVAL_SYSTEM = `You are a strict goal evaluator for a coding agent session.
You do not run tools or change code. Judge ONLY from the conversation transcript.
Decide whether the stated completion condition is satisfied based on evidence in the transcript.

Reply with exactly two lines:
Line 1: YES or NO
Line 2: A short reason (one sentence) explaining why.`;

/**
 * Offline / mock path: treat the goal as met once the mock agent has finished
 * its scripted work (NOTES.md written or a "Done" summary).
 */
export function evaluateGoalHeuristic(
  condition: string,
  messages: NormalizedMessage[],
): { met: boolean; reason: string } {
  const wroteNotes = messages.some((m) => {
    if (m.role === "tool" && m.name === "write_file" && m.ok && /NOTES\.md/i.test(m.output)) {
      return true;
    }
    if (m.role === "assistant") {
      return m.toolCalls.some(
        (c) => c.name === "write_file" && /NOTES\.md/i.test(String(c.input.path ?? "")),
      );
    }
    return false;
  });
  const wroteAny = messages.some(
    (m) =>
      (m.role === "tool" && m.name === "write_file" && m.ok) ||
      (m.role === "assistant" && m.toolCalls.some((c) => c.name === "write_file")),
  );
  const assistantDone = messages.some(
    (m) => m.role === "assistant" && /\bdone\b/i.test(m.text) && m.toolCalls.length === 0,
  );
  const lower = condition.toLowerCase();
  if (lower.includes("notes.md") && wroteNotes) {
    return { met: true, reason: "NOTES.md was written successfully." };
  }
  if ((lower.includes("file") || lower.includes("write") || lower.includes("notes")) && wroteAny) {
    return { met: true, reason: "A file write completed successfully." };
  }
  if (assistantDone && wroteAny) {
    return { met: true, reason: "Agent finished and wrote files." };
  }
  if (assistantDone) {
    return { met: true, reason: "Agent reported completion." };
  }
  return {
    met: false,
    reason: "Condition not yet demonstrated in the transcript.",
  };
}

function parseEvalReply(text: string): { met: boolean; reason: string } {
  const lines = text
    .trim()
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  const first = (lines[0] ?? "").toUpperCase();
  const met = /^(YES|TRUE|MET|DONE|ACHIEVED)\b/.test(first) || first === "Y";
  const reason =
    lines
      .slice(1)
      .join(" ")
      .replace(/^(reason:\s*)/i, "")
      .trim() ||
    (met ? "Condition appears satisfied." : "Condition not yet satisfied.");
  return { met, reason: reason.slice(0, 500) };
}

export async function evaluateGoal(opts: {
  condition: string;
  messages: NormalizedMessage[];
  model: ModelSelection;
  adapter: ProviderAdapter;
  signal?: AbortSignal;
  /** Force heuristic (smoke / APC_MOCK). */
  useHeuristic?: boolean;
}): Promise<{ met: boolean; reason: string }> {
  if (opts.useHeuristic || process.env.APC_MOCK === "1" || process.env.APC_GOAL_HEURISTIC === "1") {
    return evaluateGoalHeuristic(opts.condition, opts.messages);
  }

  const transcript = buildTranscriptSnippet(opts.messages);
  const evalModel = evaluatorModelId(opts.model);
  let text = "";
  try {
    const stream = opts.adapter.stream(
      {
        model: evalModel,
        apiKey: opts.model.apiKey,
        system: EVAL_SYSTEM,
        messages: [
          {
            role: "user",
            text:
              `Condition:\n${opts.condition}\n\n` +
              `Transcript:\n${transcript}\n\n` +
              `Is the condition met? Reply YES or NO on line 1, reason on line 2.`,
          },
        ],
        tools: [],
        effort: "low",
      },
      opts.signal,
    );
    for await (const ev of stream) {
      if (ev.kind === "text") text += ev.text;
    }
  } catch (err) {
    // Fall back so a flaky eval model does not kill the goal loop.
    const h = evaluateGoalHeuristic(opts.condition, opts.messages);
    return {
      met: h.met,
      reason: `Evaluator error (${(err as Error).message}); heuristic: ${h.reason}`,
    };
  }

  if (!text.trim()) {
    return evaluateGoalHeuristic(opts.condition, opts.messages);
  }
  return parseEvalReply(text);
}
