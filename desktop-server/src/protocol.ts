/**
 * Canonical wire protocol shared by the desktop server and the iOS app.
 *
 * Pairing happens over HTTP (`POST /pair`) and yields a bearer token. The app
 * then opens a WebSocket to `/session?token=...`. Every WebSocket frame is a
 * JSON object validated by the schemas below.
 *
 * The Swift `AnyProvCore/Server` Codable models mirror these types exactly;
 * `docs/protocol.md` is the human-readable reference. Keep all three in sync.
 */
import { z } from "zod";

/**
 * Provider identifiers understood by both the app and the server.
 * Built-ins are fixed strings; user-defined endpoints use `custom:<slug>`.
 */
export const BuiltInProviderId = z.enum([
  "anthropic",
  "openai",
  "google",
  "groq",
  "openrouter",
  "xai",
  "mistral",
]);
export type BuiltInProviderId = z.infer<typeof BuiltInProviderId>;

/** Any provider id, including `custom:…` for user-defined endpoints. */
export const ProviderId = z.string().min(1);
export type ProviderId = z.infer<typeof ProviderId>;

/** HTTP shape for chat/completions vs Anthropic messages. */
export const ApiStyle = z.enum(["openai", "anthropic"]);
export type ApiStyle = z.infer<typeof ApiStyle>;

/** Permission mode, mirroring the composer's permission pill. */
export const PermissionMode = z.enum(["acceptEdits", "plan", "ask"]);
export type PermissionMode = z.infer<typeof PermissionMode>;

/** A cloud-environment configuration created in the app (IMG_0990). */
export const EnvironmentConfig = z.object({
  name: z.string(),
  networkAccess: z.enum(["trusted", "limited", "none", "custom"]).default("trusted"),
  /** Domains to allow when `networkAccess === "custom"`. */
  allowedDomains: z.array(z.string()).default([]),
  /** Parsed `.env` variables: KEY -> value. */
  variables: z.record(z.string()).default({}),
});
export type EnvironmentConfig = z.infer<typeof EnvironmentConfig>;

/** A skill that provides guidance to the agent. */
export const Skill = z.object({
  id: z.string(),
  name: z.string(),
  description: z.string(),
  content: z.string(),
  category: z.string(),
  source: z.enum(["official", "community", "custom"]),
  isEnabled: z.boolean(),
  frontmatter: z.record(z.string()).default({}),
});
export type Skill = z.infer<typeof Skill>;

/** An MCP server configuration. */
export const MCPServer = z.object({
  id: z.string(),
  name: z.string(),
  description: z.string(),
  command: z.string(),
  args: z.array(z.string()).default([]),
  env: z.record(z.string()).default({}),
  isEnabled: z.boolean(),
});
export type MCPServer = z.infer<typeof MCPServer>;

/** The model + provider the agent should run with. */
export const ModelSelection = z.object({
  provider: ProviderId,
  model: z.string(),
  /** Maps to reasoning/effort where the provider supports it. */
  effort: z.enum(["low", "medium", "high"]).default("high"),
  /** Provider API key the server uses for this session's agent calls. */
  apiKey: z.string(),
  /**
   * Optional base URL for custom / proxy endpoints (e.g. `http://localhost:11434/v1`).
   * When set, the agent hits this host instead of the built-in provider default.
   */
  baseUrl: z.string().optional(),
  /** API shape when using `baseUrl` (or a `custom:` provider). Defaults to openai. */
  apiStyle: ApiStyle.optional(),
});
export type ModelSelection = z.infer<typeof ModelSelection>;

// ---------------------------------------------------------------------------
// HTTP pairing payloads
// ---------------------------------------------------------------------------

export const PairRequest = z.object({
  /** The short code shown in the server console / QR. */
  code: z.string(),
  /** Human-readable device label, e.g. "Julian's iPhone". */
  deviceName: z.string().default("iOS device"),
});
export type PairRequest = z.infer<typeof PairRequest>;

export const PairResponse = z.object({
  token: z.string(),
  serverName: z.string(),
  serverVersion: z.string(),
  /**
   * Public HTTPS base URL for this desktop (Cloudflare / ngrok / …), when a
   * tunnel is already up at pair time. The phone prefers this for reconnect.
   */
  publicUrl: z.string().optional(),
});
export type PairResponse = z.infer<typeof PairResponse>;

// ---------------------------------------------------------------------------
// WebSocket: app -> server
// ---------------------------------------------------------------------------

export const CreateSessionMsg = z.object({
  type: z.literal("create_session"),
  /** Optional; the server generates one if omitted. */
  sessionId: z.string().optional(),
  repo: z.object({
    /** "owner/name" */
    fullName: z.string(),
    /** Branch to base work on. Defaults to the repo's default branch. */
    baseBranch: z.string().optional(),
    /** Branch the agent commits to. */
    workBranch: z.string(),
    /** GitHub token used to clone/push (scoped to the connecting account). */
    githubToken: z.string().optional(),
  }),
  environment: EnvironmentConfig.optional(),
  model: ModelSelection,
  permissionMode: PermissionMode.default("acceptEdits"),
  /** Skill content strings to inject into the system prompt. */
  skills: z.array(z.string()).default([]),
  /** MCP server configurations for tool integration. */
  mcpServers: z.array(MCPServer).default([]),
});
export type CreateSessionMsg = z.infer<typeof CreateSessionMsg>;

export const UserMessageMsg = z.object({
  type: z.literal("user_message"),
  sessionId: z.string(),
  text: z.string(),
  /**
   * Optional model override for this turn. When set, the agent rebinds to the
   * new provider/model before running so mid-session model switches take effect.
   */
  model: ModelSelection.optional(),
});
export type UserMessageMsg = z.infer<typeof UserMessageMsg>;

export const PermissionResponseMsg = z.object({
  type: z.literal("permission_response"),
  sessionId: z.string(),
  requestId: z.string(),
  decision: z.enum(["allow", "deny"]),
});
export type PermissionResponseMsg = z.infer<typeof PermissionResponseMsg>;

export const InterruptMsg = z.object({
  type: z.literal("interrupt"),
  sessionId: z.string(),
});
export type InterruptMsg = z.infer<typeof InterruptMsg>;

export const CreatePrMsg = z.object({
  type: z.literal("create_pr"),
  sessionId: z.string(),
  title: z.string(),
  body: z.string().default(""),
});
export type CreatePrMsg = z.infer<typeof CreatePrMsg>;

/**
 * Instant git actions from the session composer (commit / push / open PR).
 * Flags may be combined; the server runs them in order: commit → push → PR URL.
 */
export const GitPublishMsg = z.object({
  type: z.literal("git_publish"),
  sessionId: z.string(),
  /** Commit message (required when `commit` is true). */
  message: z.string().default(""),
  commit: z.boolean().default(false),
  push: z.boolean().default(false),
  /** When true, push (if needed) and return a compare/PR URL. */
  openPr: z.boolean().default(false),
});
export type GitPublishMsg = z.infer<typeof GitPublishMsg>;

// Skills/MCP sync — the iOS app is the editor, the desktop is the git operator.

export const SkillsSyncRequestMsg = z.object({
  type: z.literal("skills_sync_request"),
});
export type SkillsSyncRequestMsg = z.infer<typeof SkillsSyncRequestMsg>;

export const SkillUpsertMsg = z.object({
  type: z.literal("skill_upsert"),
  skill: Skill,
});
export type SkillUpsertMsg = z.infer<typeof SkillUpsertMsg>;

export const SkillDeleteMsg = z.object({
  type: z.literal("skill_delete"),
  id: z.string(),
});
export type SkillDeleteMsg = z.infer<typeof SkillDeleteMsg>;

export const MCPSyncRequestMsg = z.object({
  type: z.literal("mcp_sync_request"),
});
export type MCPSyncRequestMsg = z.infer<typeof MCPSyncRequestMsg>;

export const MCPUpsertMsg = z.object({
  type: z.literal("mcp_upsert"),
  server: MCPServer,
});
export type MCPUpsertMsg = z.infer<typeof MCPUpsertMsg>;

export const MCPDeleteMsg = z.object({
  type: z.literal("mcp_delete"),
  id: z.string(),
});
export type MCPDeleteMsg = z.infer<typeof MCPDeleteMsg>;

// Terminal, file explorer, port manager.

export const TerminalOpenMsg = z.object({
  type: z.literal("terminal_open"),
  terminalId: z.string().optional(),
  sessionId: z.string(),
  cols: z.number().int().min(1).max(400).default(80),
  rows: z.number().int().min(1).max(200).default(24),
});
export type TerminalOpenMsg = z.infer<typeof TerminalOpenMsg>;

export const TerminalInputMsg = z.object({
  type: z.literal("terminal_input"),
  terminalId: z.string(),
  data: z.string(),
});
export type TerminalInputMsg = z.infer<typeof TerminalInputMsg>;

export const TerminalResizeMsg = z.object({
  type: z.literal("terminal_resize"),
  terminalId: z.string(),
  cols: z.number().int().min(1).max(400),
  rows: z.number().int().min(1).max(200),
});
export type TerminalResizeMsg = z.infer<typeof TerminalResizeMsg>;

export const TerminalKillMsg = z.object({
  type: z.literal("terminal_kill"),
  terminalId: z.string(),
});
export type TerminalKillMsg = z.infer<typeof TerminalKillMsg>;

export const FileListMsg = z.object({
  type: z.literal("file_list"),
  sessionId: z.string(),
  path: z.string().default(""),
});
export type FileListMsg = z.infer<typeof FileListMsg>;

export const FileReadMsg = z.object({
  type: z.literal("file_read"),
  sessionId: z.string(),
  path: z.string(),
});
export type FileReadMsg = z.infer<typeof FileReadMsg>;

/** Create or overwrite a text file in the session workdir (mobile editor). */
export const FileWriteMsg = z.object({
  type: z.literal("file_write"),
  sessionId: z.string(),
  path: z.string(),
  content: z.string(),
});
export type FileWriteMsg = z.infer<typeof FileWriteMsg>;

export const PortListMsg = z.object({
  type: z.literal("port_list"),
  sessionId: z.string(),
});
export type PortListMsg = z.infer<typeof PortListMsg>;

/** Start a public tunnel to a local listening port (ngrok / cloudflare / …). */
export const TunnelStartMsg = z.object({
  type: z.literal("tunnel_start"),
  sessionId: z.string(),
  port: z.number().int().min(1).max(65535),
  /** auto | ngrok | cloudflare | localtunnel | bore */
  provider: z.enum(["auto", "ngrok", "cloudflare", "localtunnel", "bore"]).default("auto"),
});
export type TunnelStartMsg = z.infer<typeof TunnelStartMsg>;

export const TunnelStopMsg = z.object({
  type: z.literal("tunnel_stop"),
  sessionId: z.string(),
  tunnelId: z.string(),
});
export type TunnelStopMsg = z.infer<typeof TunnelStopMsg>;

export const TunnelListMsg = z.object({
  type: z.literal("tunnel_list"),
  sessionId: z.string(),
});
export type TunnelListMsg = z.infer<typeof TunnelListMsg>;

/**
 * Ask the desktop to (re)publish the coding-server public tunnel URL.
 * Used when the phone fell back to LAN after a dead tunnel and wants a
 * fresh Cloudflare/ngrok/… URL without re-pairing.
 */
export const RemoteEndpointRequestMsg = z.object({
  type: z.literal("remote_endpoint_request"),
  /** When true, tear down any existing access tunnel and start a new one. */
  force: z.boolean().optional().default(false),
});
export type RemoteEndpointRequestMsg = z.infer<typeof RemoteEndpointRequestMsg>;

export const ClientMessage = z.discriminatedUnion("type", [
  CreateSessionMsg,
  UserMessageMsg,
  PermissionResponseMsg,
  InterruptMsg,
  CreatePrMsg,
  GitPublishMsg,
  SkillsSyncRequestMsg,
  SkillUpsertMsg,
  SkillDeleteMsg,
  MCPSyncRequestMsg,
  MCPUpsertMsg,
  MCPDeleteMsg,
  TerminalOpenMsg,
  TerminalInputMsg,
  TerminalResizeMsg,
  TerminalKillMsg,
  FileListMsg,
  FileReadMsg,
  FileWriteMsg,
  PortListMsg,
  TunnelStartMsg,
  TunnelStopMsg,
  TunnelListMsg,
  RemoteEndpointRequestMsg,
]);
export type ClientMessage = z.infer<typeof ClientMessage>;

// ---------------------------------------------------------------------------
// WebSocket: server -> app
// ---------------------------------------------------------------------------

export const SessionCreatedMsg = z.object({
  type: z.literal("session_created"),
  sessionId: z.string(),
  workdir: z.string(),
  baseBranch: z.string(),
  workBranch: z.string(),
});
export type SessionCreatedMsg = z.infer<typeof SessionCreatedMsg>;

export const AssistantDeltaMsg = z.object({
  type: z.literal("assistant_delta"),
  sessionId: z.string(),
  text: z.string(),
});
export type AssistantDeltaMsg = z.infer<typeof AssistantDeltaMsg>;

export const ToolCallMsg = z.object({
  type: z.literal("tool_call"),
  sessionId: z.string(),
  callId: z.string(),
  tool: z.string(),
  /** Human-readable one-line summary, e.g. "bash: npm test". */
  summary: z.string(),
  input: z.record(z.unknown()),
});
export type ToolCallMsg = z.infer<typeof ToolCallMsg>;

export const ToolResultMsg = z.object({
  type: z.literal("tool_result"),
  sessionId: z.string(),
  callId: z.string(),
  ok: z.boolean(),
  /** Truncated, display-ready output. */
  output: z.string(),
});
export type ToolResultMsg = z.infer<typeof ToolResultMsg>;

export const DiffMsg = z.object({
  type: z.literal("diff"),
  sessionId: z.string(),
  path: z.string(),
  /** Unified diff for this file. */
  patch: z.string(),
  added: z.number(),
  removed: z.number(),
});
export type DiffMsg = z.infer<typeof DiffMsg>;

export const PermissionRequestMsg = z.object({
  type: z.literal("permission_request"),
  sessionId: z.string(),
  requestId: z.string(),
  tool: z.string(),
  summary: z.string(),
});
export type PermissionRequestMsg = z.infer<typeof PermissionRequestMsg>;

export const SessionDoneMsg = z.object({
  type: z.literal("session_done"),
  sessionId: z.string(),
  /** Total tokens if the provider reported usage. */
  stopReason: z.string().optional(),
});
export type SessionDoneMsg = z.infer<typeof SessionDoneMsg>;

export const PrCreatedMsg = z.object({
  type: z.literal("pr_created"),
  sessionId: z.string(),
  url: z.string(),
});
export type PrCreatedMsg = z.infer<typeof PrCreatedMsg>;

/** Outcome of an instant git action (`git_publish`). */
export const GitResultMsg = z.object({
  type: z.literal("git_result"),
  sessionId: z.string(),
  /** Which steps ran, e.g. "commit", "push", "commit+push+pr". */
  action: z.string(),
  ok: z.boolean(),
  detail: z.string(),
  /** Compare / open-PR URL when push or openPr succeeded. */
  url: z.string().optional(),
});
export type GitResultMsg = z.infer<typeof GitResultMsg>;

export const ErrorMsg = z.object({
  type: z.literal("error"),
  sessionId: z.string().optional(),
  message: z.string(),
});
export type ErrorMsg = z.infer<typeof ErrorMsg>;

export const SkillsSyncMsg = z.object({
  type: z.literal("skills_sync"),
  skills: z.array(Skill),
});
export type SkillsSyncMsg = z.infer<typeof SkillsSyncMsg>;

export const MCPSyncMsg = z.object({
  type: z.literal("mcp_sync"),
  servers: z.array(MCPServer),
});
export type MCPSyncMsg = z.infer<typeof MCPSyncMsg>;

export const TerminalDataMsg = z.object({
  type: z.literal("terminal_data"),
  terminalId: z.string(),
  stream: z.enum(["out", "err"]),
  data: z.string(),
});
export type TerminalDataMsg = z.infer<typeof TerminalDataMsg>;

export const TerminalControlMsg = z.object({
  type: z.literal("terminal_control"),
  terminalId: z.string(),
  event: z.enum(["ready", "exit"]),
  code: z.number(),
});
export type TerminalControlMsg = z.infer<typeof TerminalControlMsg>;

export interface FileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: string;
}
export const FileListResultMsg = z.object({
  type: z.literal("file_list_result"),
  sessionId: z.string(),
  path: z.string(),
  entries: z.array(z.object({
    name: z.string(),
    path: z.string(),
    isDirectory: z.boolean(),
    size: z.number(),
    modifiedAt: z.string(),
    /** Git short status when dirty: M, A, D, ?, … */
    changeStatus: z.string().optional(),
  })),
  /** Working-tree unified diff / stat (repo root listings). */
  diff: z.string().optional(),
  /** Flat list of changed paths for the Diffs tab. */
  changes: z.array(z.object({
    path: z.string(),
    status: z.string(),
  })).optional(),
});
export type FileListResultMsg = z.infer<typeof FileListResultMsg>;

export const FileReadResultMsg = z.object({
  type: z.literal("file_read_result"),
  sessionId: z.string(),
  path: z.string(),
  content: z.string(),
  truncated: z.boolean(),
  /** Unified diff for this file vs HEAD when dirty. */
  diff: z.string().optional(),
});
export type FileReadResultMsg = z.infer<typeof FileReadResultMsg>;

export const FileWriteResultMsg = z.object({
  type: z.literal("file_write_result"),
  sessionId: z.string(),
  path: z.string(),
  ok: z.boolean(),
  message: z.string().optional(),
});
export type FileWriteResultMsg = z.infer<typeof FileWriteResultMsg>;

export const PortListResultMsg = z.object({
  type: z.literal("port_list_result"),
  sessionId: z.string(),
  ports: z.array(z.object({
    port: z.number(),
    pid: z.number(),
    command: z.string(),
  })),
});
export type PortListResultMsg = z.infer<typeof PortListResultMsg>;

export const TunnelStatusMsg = z.object({
  type: z.literal("tunnel_status"),
  sessionId: z.string(),
  tunnels: z.array(z.object({
    id: z.string(),
    port: z.number(),
    provider: z.string(),
    status: z.enum(["starting", "up", "error", "stopped"]),
    url: z.string().optional(),
    error: z.string().optional(),
  })),
  availableProviders: z.array(z.string()),
});
export type TunnelStatusMsg = z.infer<typeof TunnelStatusMsg>;

/**
 * Public base URL for the coding server (not a preview-app port).
 * Sent after pair / session WS connect once the auto tunnel is ready so the
 * phone can switch off LAN while keeping the same bearer token.
 */
export const RemoteEndpointMsg = z.object({
  type: z.literal("remote_endpoint"),
  status: z.enum(["starting", "up", "error"]),
  /** e.g. https://random.trycloudflare.com — omit while starting / on error */
  url: z.string().optional(),
  provider: z.string().optional(),
  error: z.string().optional(),
});
export type RemoteEndpointMsg = z.infer<typeof RemoteEndpointMsg>;

/** One item in the agent's working checklist (`update_tasks` tool). */
export const AgentTaskItem = z.object({
  id: z.string(),
  content: z.string(),
  status: z.enum(["pending", "in_progress", "completed", "cancelled"]),
});
export type AgentTaskItem = z.infer<typeof AgentTaskItem>;

/**
 * Full snapshot of the agent's task checklist for a session.
 * Emitted after each successful `update_tasks` tool call (and on reattach).
 */
export const TaskListMsg = z.object({
  type: z.literal("task_list"),
  sessionId: z.string(),
  tasks: z.array(AgentTaskItem),
});
export type TaskListMsg = z.infer<typeof TaskListMsg>;

export const ServerMessage = z.discriminatedUnion("type", [
  SessionCreatedMsg,
  AssistantDeltaMsg,
  ToolCallMsg,
  ToolResultMsg,
  DiffMsg,
  PermissionRequestMsg,
  SessionDoneMsg,
  PrCreatedMsg,
  GitResultMsg,
  ErrorMsg,
  SkillsSyncMsg,
  MCPSyncMsg,
  TerminalDataMsg,
  TerminalControlMsg,
  FileListResultMsg,
  FileReadResultMsg,
  FileWriteResultMsg,
  PortListResultMsg,
  TunnelStatusMsg,
  RemoteEndpointMsg,
  TaskListMsg,
]);
export type ServerMessage = z.infer<typeof ServerMessage>;

/** Parse an inbound client frame; throws if invalid. */
export function parseClientMessage(raw: string): ClientMessage {
  return ClientMessage.parse(JSON.parse(raw));
}

/** Serialize a server frame. */
export function encodeServerMessage(msg: ServerMessage): string {
  return JSON.stringify(msg);
}
