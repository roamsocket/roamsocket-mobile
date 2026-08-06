/**
 * Canonical wire protocol shared by the desktop server and the iOS app.
 *
 * Pairing happens over HTTP (`POST /pair`) and yields a bearer token. The app
 * then opens a WebSocket to `/session?token=...`. Every WebSocket frame is a
 * JSON object validated by the schemas below.
 *
 * The Swift `MobileAICore/Server` Codable models mirror these types exactly;
 * `docs/protocol.md` is the human-readable reference. Keep all three in sync.
 */
import { z } from "zod";

/** Provider identifiers understood by both the app and the server. */
export const ProviderId = z.enum([
  "anthropic",
  "openai",
  "google",
  "groq",
  "openrouter",
  "xai",
  "mistral",
]);
export type ProviderId = z.infer<typeof ProviderId>;

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

export const PortListMsg = z.object({
  type: z.literal("port_list"),
  sessionId: z.string(),
});
export type PortListMsg = z.infer<typeof PortListMsg>;

export const ClientMessage = z.discriminatedUnion("type", [
  CreateSessionMsg,
  UserMessageMsg,
  PermissionResponseMsg,
  InterruptMsg,
  CreatePrMsg,
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
  PortListMsg,
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
  })),
  diff: z.string().optional(),
});
export type FileListResultMsg = z.infer<typeof FileListResultMsg>;

export const FileReadResultMsg = z.object({
  type: z.literal("file_read_result"),
  sessionId: z.string(),
  path: z.string(),
  content: z.string(),
  truncated: z.boolean(),
});
export type FileReadResultMsg = z.infer<typeof FileReadResultMsg>;

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

export const ServerMessage = z.discriminatedUnion("type", [
  SessionCreatedMsg,
  AssistantDeltaMsg,
  ToolCallMsg,
  ToolResultMsg,
  DiffMsg,
  PermissionRequestMsg,
  SessionDoneMsg,
  PrCreatedMsg,
  ErrorMsg,
  SkillsSyncMsg,
  MCPSyncMsg,
  TerminalDataMsg,
  TerminalControlMsg,
  FileListResultMsg,
  FileReadResultMsg,
  PortListResultMsg,
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
