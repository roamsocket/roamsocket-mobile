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
  ServerMessage,
} from "./protocol.js";
import { AgentSession } from "./agent/loop.js";
import { cloneAndBranch, commitAll, pushBranch, type RepoSpec } from "./git/github.js";
import type { ProviderAdapter } from "./providers/index.js";
import { readProjectClaude } from "./project/claude.js";

interface Session {
  id: string;
  workdir: string;
  repo: RepoSpec;
  agent: AgentSession;
  abort: AbortController;
  pendingPermissions: Map<string, (d: "allow" | "deny") => void>;
}

export class SessionManager {
  private readonly sessions = new Map<string, Session>();

  constructor(
    private readonly emit: (msg: ServerMessage) => void,
    /** Optional adapter override (tests inject the mock). */
    private readonly adapterOverride?: ProviderAdapter,
  ) {}

  async create(msg: CreateSessionMsg): Promise<void> {
    const id = msg.sessionId ?? cryptoRandomId();
    const repo: RepoSpec = {
      fullName: msg.repo.fullName,
      baseBranch: msg.repo.baseBranch,
      workBranch: msg.repo.workBranch,
      githubToken: msg.repo.githubToken,
    };

    let workdir: string;
    let baseBranch = repo.baseBranch ?? "main";
    try {
      const root = await mkdtemp(path.join(tmpdir(), "cmai-"));
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

    // Read per-project `.claude/` config and merge into the session:
    // CLAUDE.md and project skills get injected into the agent system
    // prompt; project MCP servers are surfaced for the upcoming tool
    // registration pass; env vars are warned about (no shell injection
    // today — they need to be set in the desktop's environment).
    const project = await readProjectClaude(workdir);
    const mergedSkills = [
      ...msg.skills,
      ...project.skills.map((s) => s.content),
    ];
    if (project.claudeMd) {
      mergedSkills.unshift(`# Project instructions (from .claude/CLAUDE.md)\n\n${project.claudeMd}`);
    }
    if (Object.keys(project.env).length > 0) {
      this.emit({
        type: "error",
        sessionId: id,
        message: `Project .claude/ provided ${Object.keys(project.env).length} env var(s); the agent loop does not currently consume them — set them on the desktop shell.`,
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

    this.sessions.set(id, { id, workdir, repo, agent, abort, pendingPermissions });
    this.emit({
      type: "session_created",
      sessionId: id,
      workdir,
      baseBranch,
      workBranch: repo.workBranch,
    });
  }

  async handleUserMessage(sessionId: string, text: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      this.emit({ type: "error", sessionId, message: "Unknown session." });
      return;
    }
    try {
      await session.agent.handleUserMessage(text);
    } catch (err) {
      this.emit({ type: "error", sessionId, message: (err as Error).message });
    }
  }

  resolvePermission(sessionId: string, requestId: string, decision: "allow" | "deny"): void {
    const session = this.sessions.get(sessionId);
    const resolve = session?.pendingPermissions.get(requestId);
    if (resolve) {
      session!.pendingPermissions.delete(requestId);
      resolve(decision);
    }
  }

  workdirFor(sessionId: string): string | null {
    return this.sessions.get(sessionId)?.workdir ?? null;
  }

  interrupt(sessionId: string): void {
    this.sessions.get(sessionId)?.abort.abort();
  }

  async createPr(msg: CreatePrMsg): Promise<void> {
    const session = this.sessions.get(msg.sessionId);
    if (!session) {
      this.emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
      return;
    }
    try {
      const committed = await commitAll(session.workdir, msg.title);
      if (!committed) {
        this.emit({ type: "error", sessionId: msg.sessionId, message: "No changes to commit." });
        return;
      }
      const url = await pushBranch(session.repo, session.workdir);
      this.emit({ type: "pr_created", sessionId: msg.sessionId, url });
    } catch (err) {
      this.emit({ type: "error", sessionId: msg.sessionId, message: (err as Error).message });
    }
  }
}

function cryptoRandomId(): string {
  return "s_" + Math.random().toString(36).slice(2, 10);
}
