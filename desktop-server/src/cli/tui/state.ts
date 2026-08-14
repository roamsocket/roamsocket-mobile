/**
 * Pure TUI state + reducer driven by ServerMessage frames and UI events.
 * Unit-testable without Ink.
 */
import type { PermissionMode, ServerMessage } from '../../protocol.js';
import type { AgentTask } from '../../tools/index.js';

export type StreamItem =
  | { id: string; kind: 'user'; text: string }
  | { id: string; kind: 'assistant'; text: string }
  /** Model reasoning (from `<think>` / `<thinking>` tags), chat-style. */
  | { id: string; kind: 'thinking'; text: string; open?: boolean }
  | {
      id: string;
      kind: 'tool';
      callId: string;
      name: string;
      summary: string;
      /** Compact one-line status only (failures / short notes). Never raw dumps. */
      result?: string;
      ok?: boolean;
    }
  | {
      id: string;
      kind: 'diff';
      path: string;
      /** Kept empty in the live TUI — use added/removed for a one-line summary. */
      patch: string;
      added: number;
      removed: number;
    }
  | { id: string; kind: 'system'; text: string; level?: 'info' | 'error' | 'warn' }
  | { id: string; kind: 'goal'; text: string };

/** Live agent chrome: loading model, thinking, tooling, streaming. */
export type ActivityKind = 'idle' | 'loading' | 'thinking' | 'streaming' | 'tool' | 'permission';

export interface AgentActivity {
  kind: ActivityKind;
  /** Short label for status bar / indicator (e.g. "Thinking", "Loading model"). */
  label: string;
  /** Optional secondary detail (model id, tool summary). */
  detail?: string;
}

export interface PendingPermission {
  requestId: string;
  tool: string;
  summary: string;
}

export interface TuiState {
  items: StreamItem[];
  /** Streaming assistant buffer (merged into last assistant item on flush). */
  streamingText: string;
  busy: boolean;
  tasks: AgentTask[];
  pendingPermission: PendingPermission | null;
  provider: string;
  model: string;
  permissionMode: PermissionMode;
  workdir: string;
  pairingCode: string;
  serverPort: number;
  serverHost: string;
  tunnelUrl: string | null;
  statusLine: string;
  helpOpen: boolean;
  error: string | null;
}

export type TuiAction =
  | { type: 'server_info'; port: number; host: string; pairingCode: string }
  | { type: 'tunnel'; url: string | null }
  | { type: 'model'; provider: string; model: string }
  | { type: 'permission_mode'; mode: PermissionMode }
  | { type: 'workdir'; workdir: string }
  | { type: 'status'; text: string }
  | { type: 'user_submit'; text: string }
  | { type: 'server_message'; msg: ServerMessage }
  | { type: 'permission_resolved' }
  | { type: 'set_pending_permission'; pending: PendingPermission | null }
  | { type: 'toggle_help' }
  | { type: 'clear' }
  | { type: 'interrupt' }
  | { type: 'local_error'; message: string }
  | { type: 'system'; text: string; level?: 'info' | 'error' | 'warn' };

let seq = 0;
function uid(prefix: string): string {
  seq += 1;
  return `${prefix}_${seq}`;
}

/** Reset id counter (tests). */
export function resetTuiIds(): void {
  seq = 0;
}

export function initialTuiState(partial?: Partial<TuiState>): TuiState {
  return {
    items: [],
    streamingText: '',
    busy: false,
    tasks: [],
    pendingPermission: null,
    provider: 'anthropic',
    model: '—',
    permissionMode: 'acceptEdits',
    workdir: process.cwd(),
    pairingCode: '------',
    serverPort: 4319,
    serverHost: '0.0.0.0',
    tunnelUrl: null,
    statusLine: 'Ready',
    helpOpen: false,
    error: null,
    ...partial,
  };
}

export function reduceTui(state: TuiState, action: TuiAction): TuiState {
  switch (action.type) {
    case 'server_info':
      return {
        ...state,
        serverPort: action.port,
        serverHost: action.host,
        pairingCode: action.pairingCode,
      };
    case 'tunnel':
      return { ...state, tunnelUrl: action.url };
    case 'model':
      return { ...state, provider: action.provider, model: action.model };
    case 'permission_mode':
      return { ...state, permissionMode: action.mode };
    case 'workdir':
      return { ...state, workdir: action.workdir };
    case 'status':
      return { ...state, statusLine: action.text };
    case 'toggle_help':
      return { ...state, helpOpen: !state.helpOpen };
    case 'permission_resolved':
      return { ...state, pendingPermission: null };
    case 'set_pending_permission':
      return { ...state, pendingPermission: action.pending };
    case 'system':
      return {
        ...state,
        items: [
          ...flushStream(state),
          {
            id: uid('sys'),
            kind: 'system',
            text: action.text,
            level: action.level ?? 'info',
          },
        ],
        streamingText: '',
      };
    case 'clear':
      return {
        ...state,
        items: [],
        streamingText: '',
        busy: false,
        tasks: [],
        pendingPermission: null,
        error: null,
        statusLine: 'Cleared',
      };
    case 'interrupt':
      return {
        ...state,
        busy: false,
        streamingText: '',
        pendingPermission: null,
        statusLine: 'Interrupted',
        items: [
          ...flushStream(state),
          { id: uid('sys'), kind: 'system', text: 'Interrupted.', level: 'warn' },
        ],
      };
    case 'local_error':
      return {
        ...state,
        busy: false,
        error: action.message,
        items: [
          ...flushStream(state),
          { id: uid('sys'), kind: 'system', text: action.message, level: 'error' },
        ],
        streamingText: '',
      };
    case 'user_submit': {
      const text = action.text.trim();
      if (!text) return state;
      const loading = isMetalProvider(state.provider);
      return {
        ...state,
        busy: true,
        error: null,
        statusLine: loading ? 'Loading model…' : 'Thinking…',
        streamingText: '',
        items: [...flushStream(state), { id: uid('u'), kind: 'user', text }],
      };
    }
    case 'server_message':
      return applyServerMessage(state, action.msg);
    default:
      return state;
  }
}

function flushStream(state: TuiState): StreamItem[] {
  if (!state.streamingText) return state.items;
  const items = [...state.items];
  const { thinking, content } = extractThinking(state.streamingText);
  if (thinking && thinking.trim()) {
    const lastTh = items[items.length - 1];
    if (lastTh?.kind === 'thinking' && lastTh.open) {
      items[items.length - 1] = {
        ...lastTh,
        text: thinking,
        open: false,
      };
    } else {
      items.push({ id: uid('th'), kind: 'thinking', text: thinking, open: false });
    }
  }
  const prose = content.trim();
  if (!prose) return items;
  const last = items[items.length - 1];
  if (last?.kind === 'assistant') {
    items[items.length - 1] = { ...last, text: last.text + prose };
  } else {
    items.push({ id: uid('a'), kind: 'assistant', text: prose });
  }
  return items;
}

function applyServerMessage(state: TuiState, msg: ServerMessage): TuiState {
  switch (msg.type) {
    case 'assistant_delta': {
      const streamingText = state.streamingText + msg.text;
      const { content, isThinkingOpen, thinking } = extractThinking(streamingText);
      const hasProse = content.trim().length > 0;
      let statusLine = state.statusLine;
      if (isThinkingOpen || (thinking && !hasProse)) {
        statusLine = 'Thinking…';
      } else if (hasProse) {
        statusLine = 'Writing…';
      }
      return {
        ...state,
        streamingText,
        busy: true,
        statusLine,
      };
    }
    case 'tool_call': {
      const items = flushStream({ ...state, streamingText: state.streamingText });
      const toolName = msg.tool;
      // Prefer a short label from input; fall back to server summary (capped).
      const fromInput = summarizeTool(toolName, msg.input);
      const summary = truncate(
        fromInput && fromInput !== toolName ? fromInput : msg.summary || toolName,
        80
      );
      return {
        ...state,
        items: [
          ...items,
          {
            id: uid('t'),
            kind: 'tool',
            callId: msg.callId,
            name: toolName,
            summary,
          },
        ],
        streamingText: '',
        busy: true,
        statusLine: `tool: ${toolName}`,
      };
    }
    case 'tool_result': {
      const items = state.items.map((it) => {
        if (it.kind === 'tool' && it.callId === msg.callId) {
          return {
            ...it,
            // Claude Code style: success is silent; failures get one short line.
            result: compactToolResult(msg.output, msg.ok),
            ok: msg.ok,
          };
        }
        return it;
      });
      // Next model round after tools — back to thinking (model already warm).
      return {
        ...state,
        items,
        busy: true,
        statusLine: 'Thinking…',
      };
    }
    case 'diff': {
      // One-line file change summary only — never stream the full patch body.
      return {
        ...state,
        items: [
          ...flushStream(state),
          {
            id: uid('d'),
            kind: 'diff',
            path: msg.path,
            patch: '',
            added: msg.added ?? 0,
            removed: msg.removed ?? 0,
          },
        ],
        streamingText: '',
      };
    }
    case 'permission_request': {
      return {
        ...state,
        pendingPermission: {
          requestId: msg.requestId,
          tool: msg.tool,
          summary: msg.summary,
        },
        statusLine: `Allow ${msg.tool}?`,
      };
    }
    case 'task_list': {
      return { ...state, tasks: msg.tasks as AgentTask[] };
    }
    case 'goal_status': {
      const text =
        msg.message ?? `Goal: ${msg.status}${msg.condition ? ` — ${msg.condition}` : ''}`;
      return {
        ...state,
        items: [...flushStream(state), { id: uid('g'), kind: 'goal', text }],
        streamingText: '',
      };
    }
    case 'session_done': {
      return {
        ...state,
        busy: false,
        streamingText: '',
        items: flushStream(state),
        statusLine: 'Ready',
        pendingPermission: null,
      };
    }
    case 'error': {
      return {
        ...state,
        busy: false,
        error: msg.message,
        items: [
          ...flushStream(state),
          { id: uid('sys'), kind: 'system', text: msg.message, level: 'error' },
        ],
        streamingText: '',
        statusLine: 'Error',
      };
    }
    case 'session_created': {
      return {
        ...state,
        workdir: msg.workdir || state.workdir,
        statusLine: 'Session ready',
      };
    }
    default:
      return state;
  }
}

/**
 * Derive what the TUI should show as live chrome (chat-style Thinking / Loading).
 * Pure — safe for unit tests and render.
 */
export function deriveActivity(state: TuiState): AgentActivity {
  if (state.pendingPermission) {
    return {
      kind: 'permission',
      label: 'Allow tool?',
      detail: state.pendingPermission.summary || state.pendingPermission.tool,
    };
  }
  if (!state.busy) return { kind: 'idle', label: '' };

  if (state.streamingText) {
    const { thinking, content, isThinkingOpen } = extractThinking(state.streamingText);
    const hasProse = content.trim().length > 0;
    if (isThinkingOpen || (thinking && !hasProse)) {
      return {
        kind: 'thinking',
        label: 'Thinking',
        detail: thinking ? firstLine(thinking, 60) : undefined,
      };
    }
    if (hasProse) {
      return { kind: 'streaming', label: 'Writing' };
    }
  }

  const last = state.items[state.items.length - 1];
  if (last?.kind === 'tool' && last.ok === undefined) {
    return {
      kind: 'tool',
      label: last.name,
      detail: last.summary,
    };
  }

  // After user message, before first token: Metal needs weights load.
  if (last?.kind === 'user' && isMetalProvider(state.provider)) {
    return {
      kind: 'loading',
      label: 'Loading model',
      detail: shortModelLabel(state.model),
    };
  }

  // Between tool rounds, after tools, or cloud first-token wait.
  return { kind: 'thinking', label: 'Thinking' };
}

/** Pull `<think>` / `<thinking>` bodies out of assistant text (chat parity). */
export function extractThinking(raw: string): {
  thinking: string | null;
  content: string;
  isThinkingOpen: boolean;
} {
  if (!raw) return { thinking: null, content: '', isThinkingOpen: false };

  const thinkingParts: string[] = [];
  let stripped = raw;
  let isThinkingOpen = false;

  // Closed pairs first
  const pairRe = /<think(?:ing)?>([\s\S]*?)<\/think(?:ing)?>/gi;
  stripped = stripped.replace(pairRe, (_m, body: string) => {
    const t = String(body).trim();
    if (t) thinkingParts.push(t);
    return '';
  });

  // Open tag still streaming
  const openRe = /<think(?:ing)?>([\s\S]*)$/i;
  const openMatch = stripped.match(openRe);
  if (openMatch) {
    isThinkingOpen = true;
    const body = (openMatch[1] ?? '').trim();
    if (body) thinkingParts.push(body);
    stripped = stripped.slice(0, openMatch.index ?? 0);
  } else {
    // Partial open tag at end (`<thi`, `<think`)
    const partial = /<think(?:ing)?\b[^>]*$/i;
    if (partial.test(stripped)) {
      isThinkingOpen = true;
      stripped = stripped.replace(partial, '');
    }
  }

  // Residual stray tags
  stripped = stripped.replace(/<\/?think(?:ing)?>/gi, '');

  const thinking =
    thinkingParts.length > 0 ? thinkingParts.join('\n\n') : isThinkingOpen ? '' : null;

  return {
    thinking,
    content: stripped,
    isThinkingOpen,
  };
}

export function isMetalProvider(provider: string): boolean {
  const p = provider.toLowerCase();
  return p === 'localmetal' || p === 'local-metal' || p === 'metal' || p === 'local';
}

function firstLine(s: string, max: number): string {
  const line = s.split(/\r?\n/).find((l) => l.trim()) ?? s;
  return truncate(line, max);
}

function shortModelLabel(model: string): string | undefined {
  if (!model || model === '—') return undefined;
  // hub IDs are long — show the last segment
  const parts = model.split(/[/:]/).filter(Boolean);
  return truncate(parts[parts.length - 1] ?? model, 40);
}

function summarizeTool(name: string, input: unknown): string {
  if (!input || typeof input !== 'object') return name;
  const o = input as Record<string, unknown>;
  // Prefer a path/command-centric label (Claude Code: "Read foo.ts", "Bash ls")
  if (typeof o.path === 'string') return shortPathLabel(o.path);
  if (typeof o.command === 'string') return truncate(o.command, 72);
  if (typeof o.pattern === 'string') return truncate(o.pattern, 72);
  if (typeof o.query === 'string') return truncate(o.query, 72);
  try {
    return truncate(JSON.stringify(o), 72);
  } catch {
    return name;
  }
}

/** Success → no body. Failure → first non-empty line, capped. */
function compactToolResult(output: string | undefined, ok: boolean): string | undefined {
  if (ok) return undefined;
  const raw = (output ?? '').trim();
  if (!raw) return 'failed';
  const first = raw.split(/\r?\n/).find((l) => l.trim()) ?? raw;
  return truncate(first, 100);
}

function shortPathLabel(p: string): string {
  const norm = p.replace(/\\/g, '/');
  const parts = norm.split('/').filter(Boolean);
  if (parts.length <= 3) return truncate(norm, 72);
  return truncate(parts.slice(-3).join('/'), 72);
}

function truncate(s: string, n: number): string {
  const t = s.replace(/\s+/g, ' ').trim();
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}
