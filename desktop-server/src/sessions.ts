/**
 * Session manager: owns per-session working directories, the agent instance,
 * pending permission requests, and PR creation. One SessionManager exists per
 * connected app; sessions are keyed by id.
 */
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import type {
  CreateSessionMsg,
  CreatePrMsg,
  GitPublishMsg,
  ServerMessage,
} from "./protocol.js";
import { AgentSession } from "./agent/loop.js";
import { cloneAndBranch, commitAll, compareURL, pushBranch, type RepoSpec } from "./git/github.js";
import type { ProviderAdapter } from "./providers/index.js";
import { readProjectConfig } from "./project/config.js";

interface Session {
  id: string;
  workdir: string;
  repo: RepoSpec;
  agent: AgentSession;
  abort: AbortController;
  pendingPermissions: Map<string, (d: "allow" | "deny") => void>;
}

/**
 * Process-wide session registry. Tools (file explorer, terminal, ports) open a
 * second WebSocket; they must resolve the same sessions the agent connection
 * created. Per-connection maps caused "Unknown session." on every tool call.
 */
const globalSessions = new Map<string, Session>();

export class SessionManager {
  constructor(
    private readonly emit: (msg: ServerMessage) => void,
    /** Optional adapter override (tests inject the mock). */
    private readonly adapterOverride?: ProviderAdapter,
  ) {}

  async create(msg: CreateSessionMsg): Promise<void> {
    const id = msg.sessionId ?? cryptoRandomId();

    // Re-open: reuse an existing workdir if this wire id is still live, and
    // rebind emit/signal onto this WebSocket so follow-ups reach the app.
    const existing = globalSessions.get(id);
    if (existing) {
      this.reattach(existing, msg);
      this.emit({
        type: "session_created",
        sessionId: id,
        workdir: existing.workdir,
        baseBranch: existing.repo.baseBranch ?? "main",
        workBranch: existing.repo.workBranch,
      });
      return;
    }

    const repo: RepoSpec = {
      fullName: msg.repo.fullName,
      baseBranch: msg.repo.baseBranch,
      workBranch: msg.repo.workBranch,
      githubToken: msg.repo.githubToken,
    };

    let workdir: string;
    let baseBranch = repo.baseBranch ?? "main";
    try {
      const root = await mkdtemp(path.join(tmpdir(), "apc-"));
      workdir = path.join(root, "repo");
      const cloned = await cloneAndBranch(repo, workdir);
      baseBranch = cloned.baseBranch;
      repo.baseBranch = baseBranch;
    } catch (err) {
      this.emit({ type: "error", sessionId: id, message: (err as Error).message });
      return;
    }

    const abort = new AbortController();
    const pendingPermissions = new Map<string, (d: "allow" | "deny") => void>();

    // Read per-project config and merge into the session:
    // AGENTS.md / project skills get injected into the agent system
    // prompt; project MCP servers are surfaced for the upcoming tool
    // registration pass; env vars are warned about (no shell injection
    // today — they need to be set in the desktop's environment).
    const project = await readProjectConfig(workdir);
    const mergedSkills = [
      ...msg.skills,
      ...project.skills.map((s) => s.content),
    ];
    if (project.instructionsMd) {
      mergedSkills.unshift(`# Project instructions\n\n${project.instructionsMd}`);
    }
    if (Object.keys(project.env).length > 0) {
      this.emit({
        type: "error",
        sessionId: id,
        message: `Project config provided ${Object.keys(project.env).length} env var(s); the agent loop does not currently consume them — set them on the desktop shell.`,
      });
    }

    const agent = new AgentSession({
      sessionId: id,
      workdir,
      model: msg.model,
      permissionMode: msg.permissionMode,
      emit: this.emit,
      signal: abort.signal,
      adapter: this.adapterOverride,
      skills: mergedSkills,
      environment: msg.environment,
      requestPermission: (requestId, tool, summary) =>
        new Promise<"allow" | "deny">((resolve) => {
          pendingPermissions.set(requestId, resolve);
          this.emit({ type: "permission_request", sessionId: id, requestId, tool, summary });
        }),
    });

    globalSessions.set(id, { id, workdir, repo, agent, abort, pendingPermissions });
    this.emit({
      type: "session_created",
      sessionId: id,
      workdir,
      baseBranch,
      workBranch: repo.workBranch,
    });
  }

  /**
   * Point a live in-memory session at the current connection. Called when the
   * app re-opens a recent session (same wire sessionId) after disconnecting.
   */
  private reattach(session: Session, msg: CreateSessionMsg): void {
    // Drop any in-flight permission waiters from the previous socket.
    for (const resolve of session.pendingPermissions.values()) {
      resolve("deny");
    }
    session.pendingPermissions.clear();

    // Fresh abort so a prior interrupt doesn't permanently kill the agent.
    try {
      session.abort.abort();
    } catch {
      // already aborted
    }
    session.abort = new AbortController();

    // Refresh github token on the stored repo when the app re-sends it.
    if (msg.repo.githubToken) {
      session.repo.githubToken = msg.repo.githubToken;
    }

    const pendingPermissions = session.pendingPermissions;
    const emit = this.emit;
    const sessionId = session.id;
    session.agent.rebind({
      emit,
      signal: session.abort.signal,
      requestPermission: (requestId, tool, summary) =>
        new Promise<"allow" | "deny">((resolve) => {
          pendingPermissions.set(requestId, resolve);
          emit({ type: "permission_request", sessionId, requestId, tool, summary });
        }),
      model: msg.model,
      permissionMode: msg.permissionMode,
      environment: msg.environment,
    });
  }

  async handleUserMessage(
    sessionId: string,
    text: string,
    model?: import("./protocol.js").ModelSelection,
  ): Promise<void> {
    const session = globalSessions.get(sessionId);
    if (!session) {
      this.emit({ type: "error", sessionId, message: "Unknown session." });
      return;
    }
    // Mid-session model switch from the phone's model picker.
    if (model) {
      const pendingPermissions = session.pendingPermissions;
      const emit = this.emit;
      const sid = session.id;
      session.agent.rebind({
        emit,
        signal: session.abort.signal,
        requestPermission: (requestId, tool, summary) =>
          new Promise<"allow" | "deny">((resolve) => {
            pendingPermissions.set(requestId, resolve);
            emit({ type: "permission_request", sessionId: sid, requestId, tool, summary });
          }),
        model,
      });
    }
    try {
      await session.agent.handleUserMessage(text);
    } catch (err) {
      this.emit({ type: "error", sessionId, message: (err as Error).message });
    }
  }

  resolvePermission(sessionId: string, requestId: string, decision: "allow" | "deny"): void {
    const session = globalSessions.get(sessionId);
    const resolve = session?.pendingPermissions.get(requestId);
    if (resolve) {
      session!.pendingPermissions.delete(requestId);
      resolve(decision);
    }
  }

  workdirFor(sessionId: string): string | null {
    return globalSessions.get(sessionId)?.workdir ?? null;
  }

  interrupt(sessionId: string): void {
    globalSessions.get(sessionId)?.abort.abort();
  }

  async createPr(msg: CreatePrMsg): Promise<void> {
    // Backward-compatible: commit + push + open PR URL.
    await this.gitPublish({
      type: "git_publish",
      sessionId: msg.sessionId,
      message: msg.title,
      commit: true,
      push: true,
      openPr: true,
    });
  }

  /**
   * Instant commit / push / open-PR from the session UI.
   * Steps run in order when their flags are set.
   */
  async gitPublish(msg: GitPublishMsg): Promise<void> {
    const session = globalSessions.get(msg.sessionId);
    if (!session) {
      this.emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
      return;
    }
    if (!msg.commit && !msg.push && !msg.openPr) {
      this.emit({
        type: "error",
        sessionId: msg.sessionId,
        message: "Nothing to do — pick commit, push, and/or open PR.",
      });
      return;
    }

    const steps: string[] = [];
    const details: string[] = [];
    let url: string | undefined;

    try {
      if (msg.commit) {
        const message = msg.message.trim();
        if (!message) {
          this.emit({
            type: "error",
            sessionId: msg.sessionId,
            message: "Commit message is required.",
          });
          return;
        }
        const committed = await commitAll(session.workdir, message);
        steps.push("commit");
        details.push(committed ? `Committed: ${message}` : "Nothing new to commit.");
        if (!committed && !msg.push && !msg.openPr) {
          this.emit({
            type: "git_result",
            sessionId: msg.sessionId,
            action: "commit",
            ok: false,
            detail: "No changes to commit.",
          });
          return;
        }
      }

      // openPr implies a push so the compare URL is meaningful.
      if (msg.push || msg.openPr) {
        url = await pushBranch(session.repo, session.workdir);
        steps.push("push");
        details.push(`Pushed ${session.repo.workBranch}.`);
      }

      if (msg.openPr) {
        url = url ?? compareURL(session.repo);
        steps.push("pr");
        details.push("Open pull request ready.");
        this.emit({ type: "pr_created", sessionId: msg.sessionId, url });
      }

      this.emit({
        type: "git_result",
        sessionId: msg.sessionId,
        action: steps.join("+") || "none",
        ok: true,
        detail: details.join(" "),
        url,
      });
    } catch (err) {
      this.emit({
        type: "error",
        sessionId: msg.sessionId,
        message: (err as Error).message,
      });
    }
  }
}

function cryptoRandomId(): string {
  return "s_" + Math.random().toString(36).slice(2, 10);
}
