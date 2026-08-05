/**
 * MCP sync on the desktop. Mirrors the iOS MCPManager layout:
 *   <repo>/<server-id>/.mcp.json
 *
 * Each `.mcp.json` has:
 *   { "mcpServers": { "<server-name>": { type, command?, args?, env?, ... } } }
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { commitAndPush, deleteFile, localDirFor, pullOrClone, writeFile, type RepoConfig } from "../git/ops.js";
import type { MCPServer } from "../protocol.js";

interface McpFile {
  mcpServers?: Record<string, McpServerSpec>;
}
interface McpServerSpec {
  type?: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  description?: string;
  isEnabled?: boolean;
}

async function readMcpFile(dir: string, id: string): Promise<MCPServer | null> {
  try {
    const text = await fs.readFile(path.join(dir, id, ".mcp.json"), "utf8");
    const data = JSON.parse(text) as McpFile;
    const entries = Object.entries(data.mcpServers ?? {});
    const first = entries[0];
    if (!first) return null;
    const [name, spec] = first;
    return {
      id,
      name,
      description: spec.description ?? "",
      command: spec.command ?? "",
      args: spec.args ?? [],
      env: spec.env ?? {},
      isEnabled: spec.isEnabled ?? true,
    };
  } catch {
    return null;
  }
}

function renderMcpFile(server: MCPServer): string {
  const spec: McpServerSpec = {};
  if (server.command && server.command.length > 0) {
    spec.type = "stdio";
    spec.command = server.command;
    if (server.args?.length) spec.args = server.args;
  } else {
    spec.type = "http";
  }
  if (server.env && Object.keys(server.env).length > 0) spec.env = server.env;
  if (server.description) spec.description = server.description;
  spec.isEnabled = server.isEnabled;
  const file: McpFile = { mcpServers: { [server.name]: spec } };
  return JSON.stringify(file, null, 2) + "\n";
}

export async function listMCPServers(repoUrl: string): Promise<MCPServer[]> {
  const dir = localDirFor(repoUrl);
  let entries: string[] = [];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }
  const out: MCPServer[] = [];
  for (const id of entries) {
    const server = await readMcpFile(dir, id);
    if (server) out.push(server);
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

export async function syncMCPRepo(
  config: RepoConfig,
  token?: string,
): Promise<MCPServer[]> {
  await pullOrClone(config, token);
  return await listMCPServers(config.url);
}

export async function upsertMCPServer(
  server: MCPServer,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string> {
  await pullOrClone(config, token);
  const json = renderMcpFile(server);
  await writeFile(config.url, `${server.id}/.mcp.json`, json);
  return await commitAndPush({
    config,
    token,
    message: `Update MCP server: ${server.name}`,
    author,
  });
}

export async function removeMCPServer(
  id: string,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string | null> {
  await pullOrClone(config, token);
  await deleteFile(config.url, `${id}/.mcp.json`);
  return await commitAndPush({
    config,
    token,
    message: `Remove MCP server: ${id}`,
    author,
  });
}
