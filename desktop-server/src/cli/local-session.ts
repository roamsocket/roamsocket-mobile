/**
 * Local coding agent session for the RoamSocket CLI.
 * Drives AgentSession against a workdir (default: process.cwd()) without
 * WebSocket or GitHub clone — same tools/loop the phone uses.
 *
 * Turn lifecycle: only one agent turn at a time. `interrupt()` aborts the
 * current turn but keeps `running` until that turn fully exits; `send()` will
 * not start a new turn until the aborted turn has settled (no signal rebind
 * mid-flight).
 */
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { AgentSession } from '../agent/loop.js';
import { readProjectConfig } from '../project/config.js';
import { mockAdapter } from '../providers/index.js';
import type { ModelSelection, PermissionMode, ServerMessage } from '../protocol.js';

export type PermissionDecision = 'allow' | 'deny';

export interface LocalSessionOptions {
  workdir: string;
  model: ModelSelection;
  permissionMode: PermissionMode;
  /** Receive the same ServerMessage shapes as the phone protocol. */
  onMessage: (msg: ServerMessage) => void;
  /**
   * Called when permissionMode is `ask` and a mutating tool needs approval.
   * Must resolve allow/deny (TUI modal).
   */
  onPermission: (req: {
    requestId: string;
    tool: string;
    summary: string;
  }) => Promise<PermissionDecision>;
  /** Use deterministic mock adapter (tests / APC_MOCK). */
  mock?: boolean;
  sessionId?: string;
}

export class LocalCliSession {
  readonly sessionId: string;
  readonly workdir: string;
  private agent: AgentSession;
  private abort: AbortController;
  private pendingPermissions = new Map<string, (d: PermissionDecision) => void>();
  private model: ModelSelection;
  private permissionMode: PermissionMode;
  private readonly onMessage: LocalSessionOptions['onMessage'];
  private readonly onPermission: LocalSessionOptions['onPermission'];
  private readonly mock: boolean;
  private skills: string[] = [];
  /** True while a turn is in-flight (including after interrupt until drain). */
  private running = false;
  /** In-flight turn promise (settles only when handleUserMessage fully exits). */
  private turnPromise: Promise<void> | null = null;
  private turnGen = 0;

  private constructor(
    opts: LocalSessionOptions,
    agent: AgentSession,
    abort: AbortController,
    skills: string[]
  ) {
    this.sessionId = opts.sessionId ?? randomUUID();
    this.workdir = path.resolve(opts.workdir);
    this.agent = agent;
    this.abort = abort;
    this.model = opts.model;
    this.permissionMode = opts.permissionMode;
    this.onMessage = opts.onMessage;
    this.onPermission = opts.onPermission;
    this.mock = opts.mock ?? false;
    this.skills = skills;
  }

  static async create(opts: LocalSessionOptions): Promise<LocalCliSession> {
    const workdir = path.resolve(opts.workdir);
    const sessionId = opts.sessionId ?? randomUUID();
    const abort = new AbortController();
    const skills = await loadSkills(workdir);

    const session = new LocalCliSession(
      { ...opts, sessionId, workdir },
      // placeholder agent replaced immediately below
      null as unknown as AgentSession,
      abort,
      skills
    );
    session.agent = session.buildAgent();
    session.onMessage({
      type: 'session_created',
      sessionId,
      workdir,
      baseBranch: 'local',
      workBranch: 'local',
    });
    return session;
  }

  get isRunning(): boolean {
    return this.running;
  }

  get currentModel(): ModelSelection {
    return this.model;
  }

  get currentPermissionMode(): PermissionMode {
    return this.permissionMode;
  }

  /** Wait until any in-flight (possibly interrupted) turn fully exits. */
  async waitUntilIdle(): Promise<void> {
    if (this.turnPromise) {
      await this.turnPromise.catch(() => {
        /* swallow */
      });
    }
  }

  async send(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;

    // Concurrent send while a healthy turn is active: ignore.
    if (this.running && !this.abort.signal.aborted) {
      return;
    }

    // Interrupted or finished turn may still be draining — wait it out before
    // installing a fresh AbortController (never rebind signal mid-flight).
    if (this.turnPromise) {
      await this.turnPromise.catch(() => {
        /* swallow */
      });
    }

    this.abort = new AbortController();
    this.rebindAgent();

    this.running = true;
    const gen = ++this.turnGen;
    const work = this.runTurn(trimmed, gen);
    this.turnPromise = work;
    await work;
  }

  private async runTurn(text: string, gen: number): Promise<void> {
    try {
      await this.agent.handleUserMessage(text);
      // Agent loop returns without session_done when signal is aborted.
      if (this.abort.signal.aborted) {
        this.onMessage({
          type: 'session_done',
          sessionId: this.sessionId,
          stopReason: 'interrupted',
        });
      }
    } catch (err) {
      this.onMessage({
        type: 'error',
        sessionId: this.sessionId,
        message: (err as Error).message,
      });
      this.onMessage({
        type: 'session_done',
        sessionId: this.sessionId,
        stopReason: 'error',
      });
    } finally {
      if (gen === this.turnGen) {
        this.running = false;
        this.turnPromise = null;
      }
    }
  }

  /**
   * Abort the current turn. Does not clear `running` — callers must
   * `await waitUntilIdle()` / the outstanding `send()` promise before
   * starting another turn.
   */
  interrupt(): void {
    if (!this.running) return;
    try {
      this.abort.abort();
    } catch {
      /* already aborted */
    }
    for (const resolve of this.pendingPermissions.values()) {
      resolve('deny');
    }
    this.pendingPermissions.clear();
  }

  resolvePermission(requestId: string, decision: PermissionDecision): void {
    const r = this.pendingPermissions.get(requestId);
    if (r) {
      this.pendingPermissions.delete(requestId);
      r(decision);
    }
  }

  async setModel(model: ModelSelection): Promise<void> {
    await this.waitUntilIdle();
    this.model = model;
    this.rebindAgent();
  }

  async setPermissionMode(mode: PermissionMode): Promise<void> {
    await this.waitUntilIdle();
    this.permissionMode = mode;
    this.rebindAgent();
  }

  /** Start a fresh conversation; keeps workdir and model. */
  async clear(): Promise<void> {
    this.interrupt();
    await this.waitUntilIdle();
    this.abort = new AbortController();
    this.skills = await loadSkills(this.workdir);
    this.agent = this.buildAgent();
    this.onMessage({
      type: 'session_created',
      sessionId: this.sessionId,
      workdir: this.workdir,
      baseBranch: 'local',
      workBranch: 'local',
    });
  }

  private rebindAgent(): void {
    const sessionId = this.sessionId;
    this.agent.rebind({
      emit: (msg) => this.onMessage(msg),
      signal: this.abort.signal,
      requestPermission: (requestId, tool, summary) =>
        this.makePermissionRequest(sessionId, requestId, tool, summary),
      model: this.model,
      permissionMode: this.permissionMode,
    });
  }

  private buildAgent(): AgentSession {
    const sessionId = this.sessionId;
    return new AgentSession({
      sessionId,
      workdir: this.workdir,
      model: this.model,
      permissionMode: this.permissionMode,
      surface: 'cli',
      skills: this.skills,
      signal: this.abort.signal,
      adapter: this.mock ? mockAdapter : undefined,
      emit: (msg) => this.onMessage(msg),
      requestPermission: (requestId, tool, summary) =>
        this.makePermissionRequest(sessionId, requestId, tool, summary),
    });
  }

  private makePermissionRequest(
    sessionId: string,
    requestId: string,
    tool: string,
    summary: string
  ): Promise<PermissionDecision> {
    return new Promise<PermissionDecision>((resolve) => {
      // If already aborted, deny immediately (do not hang the agent).
      if (this.abort.signal.aborted) {
        resolve('deny');
        return;
      }
      this.pendingPermissions.set(requestId, resolve);
      this.onMessage({
        type: 'permission_request',
        sessionId,
        requestId,
        tool,
        summary,
      });
      void this.onPermission({ requestId, tool, summary }).then((decision) => {
        const r = this.pendingPermissions.get(requestId);
        if (r) {
          this.pendingPermissions.delete(requestId);
          r(decision);
        }
      });
    });
  }
}

async function loadSkills(workdir: string): Promise<string[]> {
  try {
    const project = await readProjectConfig(workdir);
    const skills = project.skills.map((s) => s.content);
    if (project.instructionsMd) {
      skills.unshift(
        `# Agent instructions (global / workspace / folder)\n\n${project.instructionsMd}`
      );
    }
    return skills;
  } catch {
    return [];
  }
}
