/**
 * The agentic coding loop. Given a user message, it drives the selected
 * provider through repeated tool-use rounds, streaming assistant text, tool
 * calls, tool results, and per-file diffs back to the app over the WebSocket.
 *
 * Permission modes mirror the composer's permission pill:
 *   - acceptEdits: mutating tools run without asking
 *   - ask:        mutating tools emit a permission_request and wait
 *   - plan:       mutating tools are described but not executed
 */
import { randomUUID } from "node:crypto";
import type { ModelSelection, PermissionMode, ServerMessage } from "../protocol.js";
import { TOOLS, MUTATING_TOOLS } from "../tools/index.js";
import { diffFiles } from "../git/github.js";
import { getAgentAdapter, type NormalizedMessage, type ProviderAdapter } from "../providers/index.js";

const BASE_SYSTEM_PROMPT = `You are a coding agent running on the user's desktop in a cloned Git repository.
Work directly in the repository using the provided tools. Make focused, correct changes.
Prefer reading files before editing them. Run tests or builds when relevant.
When you have completed the request, stop and briefly summarize what you changed.`;

const MAX_ROUNDS = 24;

export interface AgentDeps {
  sessionId: string;
  workdir: string;
  model: ModelSelection;
  permissionMode: PermissionMode;
  emit: (msg: ServerMessage) => void;
  /** Ask the app to allow a mutating tool; resolves with the decision. */
  requestPermission: (requestId: string, tool: string, summary: string) => Promise<"allow" | "deny">;
  signal: AbortSignal;
  /** Override the provider adapter (tests inject the mock). */
  adapter?: ProviderAdapter;
  /** Skill content strings to inject into the system prompt. */
  skills?: string[];
}

export class AgentSession {
  private readonly messages: NormalizedMessage[] = [];
  private readonly adapter: ProviderAdapter;
  private readonly systemPrompt: string;

  constructor(private readonly deps: AgentDeps) {
    this.adapter =
      deps.adapter ?? getAgentAdapter(deps.model.provider, deps.model.customBaseUrl);
    this.systemPrompt = this.buildSystemPrompt();
  }

  private buildSystemPrompt(): string {
    let prompt = BASE_SYSTEM_PROMPT;
    
    if (this.deps.skills && this.deps.skills.length > 0) {
      prompt += "\n\n## Active Skills\n\n";
      prompt += "The following skills are active and should guide your approach:\n\n";
      
      for (const skillContent of this.deps.skills) {
        prompt += skillContent;
        prompt += "\n\n";
      }
    }
    
    return prompt;
  }

  async handleUserMessage(text: string): Promise<void> {
    this.messages.push({ role: "user", text });
    const { emit, sessionId } = this.deps;

    for (let round = 0; round < MAX_ROUNDS; round++) {
      if (this.deps.signal.aborted) return;

      let assistantText = "";
      const toolCalls: { id: string; name: string; input: Record<string, unknown> }[] = [];
      let stopReason = "end_turn";

      const stream = this.adapter.stream(
        {
          model: this.deps.model.model,
          apiKey: this.deps.model.apiKey,
          system: this.systemPrompt,
          messages: this.messages,
          tools: Object.values(TOOLS),
          effort: this.deps.model.effort,
        },
        this.deps.signal,
      );

      for await (const ev of stream) {
        if (ev.kind === "text") {
          assistantText += ev.text;
          emit({ type: "assistant_delta", sessionId, text: ev.text });
        } else if (ev.kind === "tool_call") {
          toolCalls.push(ev.call);
        } else if (ev.kind === "done") {
          stopReason = ev.stopReason;
        }
      }

      // Record the assistant turn (text + any tool calls).
      this.messages.push({ role: "assistant", text: assistantText, toolCalls });

      if (toolCalls.length === 0) {
        emit({ type: "session_done", sessionId, stopReason });
        return;
      }

      // Execute each requested tool call in order.
      for (const call of toolCalls) {
        const tool = TOOLS[call.name];
        const summary = tool ? tool.summarize(call.input) : `${call.name}`;
        emit({ type: "tool_call", sessionId, callId: call.id, tool: call.name, summary, input: call.input });

        let result = { ok: false, output: `Unknown tool: ${call.name}` };
        if (tool) {
          const gated = MUTATING_TOOLS.has(call.name);
          if (gated && this.deps.permissionMode === "plan") {
            result = { ok: true, output: "[plan mode] change described but not executed." };
          } else if (gated && this.deps.permissionMode === "ask") {
            const requestId = randomUUID();
            const decision = await this.deps.requestPermission(requestId, call.name, summary);
            if (decision === "deny") {
              result = { ok: false, output: "Denied by user." };
            } else {
              result = await tool.execute(call.input, {
                workdir: this.deps.workdir,
                onOutput: (chunk) => emit({ type: "assistant_delta", sessionId, text: chunk }),
              });
            }
          } else {
            result = await tool.execute(call.input, {
              workdir: this.deps.workdir,
              onOutput: (chunk) => emit({ type: "assistant_delta", sessionId, text: chunk }),
            });
          }
        }

        emit({ type: "tool_result", sessionId, callId: call.id, ok: result.ok, output: result.output });
        this.messages.push({ role: "tool", toolCallId: call.id, name: call.name, output: result.output, ok: result.ok });
      }

      // Emit per-file diffs after this round's mutations.
      if (this.deps.permissionMode !== "plan") {
        try {
          for (const d of await diffFiles(this.deps.workdir)) {
            emit({ type: "diff", sessionId, path: d.path, patch: d.patch, added: d.added, removed: d.removed });
          }
        } catch {
          // Non-fatal: diffs are best-effort (e.g. workdir not a git repo).
        }
      }
    }

    emit({ type: "error", sessionId, message: `Stopped after ${MAX_ROUNDS} rounds.` });
  }
}
