/**
 * The agentic coding loop. Given a user message, it drives the selected
 * provider through repeated tool-use rounds, streaming assistant text, tool
 * calls, tool results, and per-file diffs back to the app over the WebSocket.
 *
 * Permission modes mirror the composer's permission pill:
 *   - acceptEdits: mutating tools run without asking
 *   - ask:        mutating tools emit a permission_request and wait
 *   - plan:       mutating tools are described but not executed
 *
 * `/goal` support: when a session has an active completion condition, each
 * finished turn is evaluated; if not met, another turn starts automatically.
 */
import { randomUUID } from "node:crypto";
import type { ModelSelection, PermissionMode, ServerMessage, EnvironmentConfig } from "../protocol.js";
import {
  TOOLS,
  MUTATING_TOOLS,
  applyTaskUpdate,
  formatTaskChecklist,
  type AgentTask,
} from "../tools/index.js";
import { diffFiles } from "../git/github.js";
import { getAgentAdapter, type NormalizedMessage, type ProviderAdapter } from "../providers/index.js";
import {
  type ActiveGoal,
  type AchievedGoal,
  type GoalStatusKind,
  MAX_GOAL_TURNS,
  buildGoalStatusMessage,
  evaluateGoal,
  goalContinuePrompt,
  goalKickoffPrompt,
  parseGoalCommand,
} from "./goal.js";

const BASE_SYSTEM_PROMPT_PHONE = `You are a coding agent running on the user's desktop in a cloned Git repository.
Work directly in the repository using the provided tools. Make focused, correct changes.
Prefer reading files before editing them. Run tests or builds when relevant.
When you have completed the request, stop and briefly summarize what you changed.

## Task checklist
For multi-step work, call the \`update_tasks\` tool early with a short checklist (3–8 items).
Update statuses as you go (one \`in_progress\` when possible; mark \`completed\` when done).
Use stable task ids so merges update the same items. The user sees this list live on their phone.

## Goals (/goal)
When the user sets a goal, keep working until the condition is verifiably met.
Surface proof in the transcript (test output, build exit codes, file contents).
Do not stop early with a plan-only reply while a goal is active.`;

const BASE_SYSTEM_PROMPT_CLI = `You are a coding agent running in the user's terminal (RoamSocket CLI) inside a local working directory.
Work directly in that directory using the provided tools. Make focused, correct changes.
Prefer reading files before editing them. Run tests or builds when relevant.
When you have completed the request, stop and briefly summarize what you changed.
The user sees your output and tool activity in this terminal (not on a phone).

## Task checklist
For multi-step work, call the \`update_tasks\` tool early with a short checklist (3–8 items).
Update statuses as you go (one \`in_progress\` when possible; mark \`completed\` when done).
Use stable task ids so merges update the same items. The user sees this list in the terminal.

## Goals (/goal)
When the user sets a goal, keep working until the condition is verifiably met.
Surface proof in the transcript (test output, build exit codes, file contents).
Do not stop early with a plan-only reply while a goal is active.`;

const MAX_ROUNDS = 24;

/** Where the agent is being driven from — affects system prompt wording only. */
export type AgentSurface = "phone" | "cli";

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
  /** Optional environment config — drives the bash network policy. */
  environment?: EnvironmentConfig;
  /** Phone (default) vs local terminal CLI surface. */
  surface?: AgentSurface;
}

export class AgentSession {
  private readonly messages: NormalizedMessage[] = [];
  private adapter: ProviderAdapter;
  private readonly systemPrompt: string;
  /** Mutable so a reattached WebSocket can rebind emit / signal / model. */
  private deps: AgentDeps;
  /** Working checklist the agent maintains via `update_tasks`. */
  private agentTasks: AgentTask[] = [];
  /** Session-scoped /goal completion condition. */
  private activeGoal: ActiveGoal | null = null;
  /** Last achieved goal this session (for `/goal` status). */
  private achievedGoal: AchievedGoal | null = null;

  constructor(deps: AgentDeps) {
    this.deps = deps;
    this.adapter =
      deps.adapter ??
      getAgentAdapter(deps.model.provider, {
        baseUrl: deps.model.baseUrl,
        apiStyle: deps.model.apiStyle,
      });
    this.systemPrompt = this.buildSystemPrompt();
  }

  /** Current checklist snapshot (for reattach / debug). */
  get tasks(): readonly AgentTask[] {
    return this.agentTasks;
  }

  get goal(): ActiveGoal | null {
    return this.activeGoal;
  }

  /** Push the current checklist to the app (e.g. after WebSocket reattach). */
  emitTaskList(): void {
    if (this.agentTasks.length === 0) return;
    this.deps.emit({
      type: "task_list",
      sessionId: this.deps.sessionId,
      tasks: this.agentTasks,
    });
  }

  /** Re-send active (or last achieved) goal status after reconnect. */
  emitGoalStatusReplay(): void {
    if (this.activeGoal) {
      this.emitGoalStatus("active", {
        condition: this.activeGoal.condition,
        reason: this.activeGoal.lastReason,
        turnsEvaluated: this.activeGoal.turnsEvaluated,
        startedAt: this.activeGoal.startedAt,
      });
      return;
    }
    if (this.achievedGoal) {
      this.emitGoalStatus("achieved", {
        condition: this.achievedGoal.condition,
        turnsEvaluated: this.achievedGoal.turnsEvaluated,
        startedAt: this.achievedGoal.startedAt,
        endedAt: this.achievedGoal.endedAt,
      });
    }
  }

  /**
   * Rebind this agent to a new WebSocket connection (and fresh abort signal)
   * when the app re-opens an existing session. Keeps workdir + conversation.
   */
  rebind(next: {
    emit: AgentDeps["emit"];
    signal: AbortSignal;
    requestPermission: AgentDeps["requestPermission"];
    model?: ModelSelection;
    permissionMode?: PermissionMode;
    environment?: EnvironmentConfig;
  }): void {
    const previousModel = this.deps.model;
    this.deps = {
      ...this.deps,
      emit: next.emit,
      signal: next.signal,
      requestPermission: next.requestPermission,
      model: next.model ?? this.deps.model,
      permissionMode: next.permissionMode ?? this.deps.permissionMode,
      environment: next.environment ?? this.deps.environment,
    };
    if (next.model) {
      // Always rebuild the provider client when the model changes so mid-session
      // switches (e.g. Anthropic → OpenAI) don't keep the old adapter.
      // Preserve an explicit test override only when the provider is unchanged.
      const override = this.deps.adapter;
      const providerChanged =
        next.model.provider !== previousModel.provider ||
        next.model.baseUrl !== previousModel.baseUrl ||
        next.model.apiStyle !== previousModel.apiStyle;
      if (override && !providerChanged) {
        this.adapter = override;
      } else {
        this.adapter = getAgentAdapter(next.model.provider, {
          baseUrl: next.model.baseUrl,
          apiStyle: next.model.apiStyle,
        });
      }
    }
  }

  private buildSystemPrompt(): string {
    let prompt =
      this.deps.surface === "cli" ? BASE_SYSTEM_PROMPT_CLI : BASE_SYSTEM_PROMPT_PHONE;

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

  private emitGoalStatus(
    status: GoalStatusKind,
    fields: {
      condition?: string;
      reason?: string;
      turnsEvaluated?: number;
      startedAt?: number;
      endedAt?: number;
    } = {},
  ): void {
    const sessionId = this.deps.sessionId;
    const startedAt = fields.startedAt;
    const endedAt = fields.endedAt;
    const elapsedMs =
      startedAt != null ? Math.max(0, (endedAt ?? Date.now()) - startedAt) : undefined;
    const message = buildGoalStatusMessage({
      status,
      condition: fields.condition,
      reason: fields.reason,
      turnsEvaluated: fields.turnsEvaluated,
      startedAt,
      endedAt,
    });
    this.deps.emit({
      type: "goal_status",
      sessionId,
      status,
      condition: fields.condition,
      reason: fields.reason,
      turnsEvaluated: fields.turnsEvaluated,
      startedAt,
      elapsedMs,
      message,
    });
  }

  /**
   * Handle a user composer line. Interprets `/goal` slash commands and runs
   * the agent; while a goal is active, auto-continues turns after evaluation.
   */
  async handleUserMessage(text: string): Promise<void> {
    const sessionId = this.deps.sessionId;
    const cmd = parseGoalCommand(text);

    if (cmd?.kind === "status") {
      if (this.activeGoal) {
        this.emitGoalStatus("active", {
          condition: this.activeGoal.condition,
          reason: this.activeGoal.lastReason,
          turnsEvaluated: this.activeGoal.turnsEvaluated,
          startedAt: this.activeGoal.startedAt,
        });
      } else if (this.achievedGoal) {
        this.emitGoalStatus("achieved", {
          condition: this.achievedGoal.condition,
          turnsEvaluated: this.achievedGoal.turnsEvaluated,
          startedAt: this.achievedGoal.startedAt,
          endedAt: this.achievedGoal.endedAt,
        });
      } else {
        this.emitGoalStatus("none");
      }
      this.deps.emit({ type: "session_done", sessionId, stopReason: "goal_status" });
      return;
    }

    if (cmd?.kind === "clear") {
      if (!this.activeGoal) {
        this.emitGoalStatus("none", { condition: undefined });
        // Explicit "No goal set" is already the none message.
      } else {
        const condition = this.activeGoal.condition;
        this.activeGoal = null;
        this.emitGoalStatus("cleared", { condition });
      }
      this.deps.emit({ type: "session_done", sessionId, stopReason: "goal_cleared" });
      return;
    }

    let kickoff = text;
    if (cmd?.kind === "set") {
      this.activeGoal = {
        condition: cmd.condition,
        startedAt: Date.now(),
        turnsEvaluated: 0,
      };
      this.achievedGoal = null;
      this.emitGoalStatus("active", {
        condition: cmd.condition,
        turnsEvaluated: 0,
        startedAt: this.activeGoal.startedAt,
      });
      kickoff = goalKickoffPrompt(cmd.condition);
    }

    // Outer goal loop: each iteration is one agent "turn" (tool rounds until idle).
    let nextUserText: string | null = kickoff;
    while (nextUserText !== null) {
      if (this.deps.signal.aborted) return;

      await this.runAgentTurn(nextUserText);

      if (this.deps.signal.aborted) return;

      if (!this.activeGoal) {
        this.deps.emit({ type: "session_done", sessionId, stopReason: "end_turn" });
        return;
      }

      const evaluation = await evaluateGoal({
        condition: this.activeGoal.condition,
        messages: this.messages,
        model: this.deps.model,
        adapter: this.adapter,
        signal: this.deps.signal,
      });

      this.activeGoal.turnsEvaluated += 1;
      this.activeGoal.lastReason = evaluation.reason;

      if (evaluation.met) {
        const endedAt = Date.now();
        this.achievedGoal = {
          condition: this.activeGoal.condition,
          startedAt: this.activeGoal.startedAt,
          endedAt,
          turnsEvaluated: this.activeGoal.turnsEvaluated,
        };
        const condition = this.activeGoal.condition;
        const turns = this.activeGoal.turnsEvaluated;
        const startedAt = this.activeGoal.startedAt;
        this.activeGoal = null;
        this.emitGoalStatus("achieved", {
          condition,
          reason: evaluation.reason,
          turnsEvaluated: turns,
          startedAt,
          endedAt,
        });
        this.deps.emit({ type: "session_done", sessionId, stopReason: "goal_achieved" });
        return;
      }

      this.emitGoalStatus("active", {
        condition: this.activeGoal.condition,
        reason: evaluation.reason,
        turnsEvaluated: this.activeGoal.turnsEvaluated,
        startedAt: this.activeGoal.startedAt,
      });

      if (this.activeGoal.turnsEvaluated >= MAX_GOAL_TURNS) {
        this.deps.emit({
          type: "error",
          sessionId,
          message: `Goal stopped after ${MAX_GOAL_TURNS} evaluation turns without meeting the condition.`,
        });
        this.deps.emit({ type: "session_done", sessionId, stopReason: "goal_max_turns" });
        return;
      }

      nextUserText = goalContinuePrompt(this.activeGoal.condition, evaluation.reason);
    }
  }

  /**
   * One user → assistant multi-round tool loop. Does not emit `session_done`
   * (caller decides based on goal state).
   */
  private async runAgentTurn(userText: string): Promise<void> {
    this.messages.push({ role: "user", text: userText });
    const sessionId = this.deps.sessionId;

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
          this.deps.emit({ type: "assistant_delta", sessionId, text: ev.text });
        } else if (ev.kind === "model_status") {
          this.deps.emit({
            type: "model_status",
            sessionId,
            status: ev.status,
            hubID: ev.hubID,
            message: ev.message,
          });
        } else if (ev.kind === "tool_call") {
          toolCalls.push(ev.call);
        } else if (ev.kind === "done") {
          stopReason = ev.stopReason;
        }
      }

      // Record the assistant turn (text + any tool calls).
      this.messages.push({ role: "assistant", text: assistantText, toolCalls });

      if (toolCalls.length === 0) {
        void stopReason;
        return;
      }

      // Execute each requested tool call in order.
      for (const call of toolCalls) {
        const tool = TOOLS[call.name];
        const summary = tool ? tool.summarize(call.input) : `${call.name}`;
        this.deps.emit({
          type: "tool_call",
          sessionId,
          callId: call.id,
          tool: call.name,
          summary,
          input: call.input,
        });

        let result = { ok: false, output: `Unknown tool: ${call.name}` };
        if (tool) {
          const gated = MUTATING_TOOLS.has(call.name);
          // Do NOT stream tool stdout as assistant_delta — that dumped `ls` /
          // build logs into the chat transcript. Capture completes in
          // `tool_result` and the iOS ToolCard shows it collapsed-by-default.
          const baseCtx = {
            workdir: this.deps.workdir,
            network: this.deps.environment
              ? {
                  access: this.deps.environment.networkAccess,
                  allowedDomains: this.deps.environment.allowedDomains ?? [],
                }
              : undefined,
          };
          if (gated && this.deps.permissionMode === "plan") {
            result = { ok: true, output: "[plan mode] change described but not executed." };
          } else if (gated && this.deps.permissionMode === "ask") {
            const requestId = randomUUID();
            const decision = await this.deps.requestPermission(requestId, call.name, summary);
            if (decision === "deny") {
              result = { ok: false, output: "Denied by user." };
            } else {
              result = await tool.execute(call.input, baseCtx);
            }
          } else {
            result = await tool.execute(call.input, baseCtx);
          }

          // Apply checklist state after a successful update_tasks call and
          // push a full snapshot so the phone checklist stays live.
          if (call.name === "update_tasks" && result.ok) {
            this.agentTasks = applyTaskUpdate(this.agentTasks, call.input);
            result = {
              ok: true,
              output: formatTaskChecklist(this.agentTasks),
            };
            this.deps.emit({
              type: "task_list",
              sessionId,
              tasks: this.agentTasks,
            });
          }
        }

        this.deps.emit({
          type: "tool_result",
          sessionId,
          callId: call.id,
          ok: result.ok,
          output: result.output,
        });
        this.messages.push({
          role: "tool",
          toolCallId: call.id,
          name: call.name,
          output: result.output,
          ok: result.ok,
        });
      }

      // Emit per-file diffs after this round's mutations.
      if (this.deps.permissionMode !== "plan") {
        try {
          for (const d of await diffFiles(this.deps.workdir)) {
            this.deps.emit({
              type: "diff",
              sessionId,
              path: d.path,
              patch: d.patch,
              added: d.added,
              removed: d.removed,
            });
          }
        } catch {
          // Non-fatal: diffs are best-effort (e.g. workdir not a git repo).
        }
      }
    }

    this.deps.emit({
      type: "error",
      sessionId,
      message: `Stopped after ${MAX_ROUNDS} rounds.`,
    });
  }
}
