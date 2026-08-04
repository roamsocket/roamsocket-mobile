import type { Tool } from "./types.js";
import { bashTool } from "./bash.js";
import { readFileTool, writeFileTool, editTool, globTool } from "./files.js";

export * from "./types.js";

/** All tools the agent can call, keyed by name. */
export const TOOLS: Record<string, Tool> = {
  [bashTool.name]: bashTool,
  [readFileTool.name]: readFileTool,
  [writeFileTool.name]: writeFileTool,
  [editTool.name]: editTool,
  [globTool.name]: globTool,
};

/** Tools that mutate the filesystem — these gate on permission mode. */
export const MUTATING_TOOLS = new Set([
  writeFileTool.name,
  editTool.name,
  bashTool.name,
]);

export const TOOL_LIST: Tool[] = Object.values(TOOLS);
