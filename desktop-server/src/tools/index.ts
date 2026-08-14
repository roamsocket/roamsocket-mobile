import type { Tool } from './types.js';
import { bashTool } from './bash.js';
import { readFileTool, writeFileTool, editTool, globTool } from './files.js';
import { updateTasksTool } from './todos.js';
import { listConnectorsTool, connectorRequestTool } from './connectors.js';

export * from './types.js';
export type { AgentTask, AgentTaskStatus } from './todos.js';
export { applyTaskUpdate, formatTaskChecklist, normalizeTasks } from './todos.js';

/** All tools the agent can call, keyed by name. */
export const TOOLS: Record<string, Tool> = {
  [bashTool.name]: bashTool,
  [readFileTool.name]: readFileTool,
  [writeFileTool.name]: writeFileTool,
  [editTool.name]: editTool,
  [globTool.name]: globTool,
  [updateTasksTool.name]: updateTasksTool,
  [listConnectorsTool.name]: listConnectorsTool,
  [connectorRequestTool.name]: connectorRequestTool,
};

/** Tools that mutate the filesystem — these gate on permission mode. */
export const MUTATING_TOOLS = new Set([
  writeFileTool.name,
  editTool.name,
  bashTool.name,
  // Connector calls can mutate external state (POST/DELETE against a linked
  // account), so they go through the same permission gate as local edits.
  connectorRequestTool.name,
]);

export const TOOL_LIST: Tool[] = Object.values(TOOLS);
