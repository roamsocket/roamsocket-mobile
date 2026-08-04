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
  networkAccess: z.enum(["trusted", "limited", "none"]).default("trusted"),
  /** Parsed `.env` variables: KEY -> value. */
  variables: z.record(z.string()).default({}),
});
export type EnvironmentConfig = z.infer<typeof EnvironmentConfig>;

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

export const ClientMessage = z.discriminatedUnion("type", [
  CreateSessionMsg,
  UserMessageMsg,
  PermissionResponseMsg,
  InterruptMsg,
  CreatePrMsg,
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
