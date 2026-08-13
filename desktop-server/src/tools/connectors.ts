/**
 * Generic connector tools for the agent loop. Rather than writing a bespoke
 * client per service (Gmail, Figma, GitHub, …), the agent gets one real,
 * generic authenticated-HTTP tool plus a discovery tool. Every connector the
 * user has actually connected (token pasted, or OAuth completed) becomes
 * usable through the same two tools.
 */
import type { Tool, ToolResult } from './types.js';
import { truncate } from './types.js';
import { listConnectorDefinitions } from '../connectors/catalog.js';
import { isConnectorConnected, resolveAuthHeader } from '../connectors/store.js';

export const listConnectorsTool: Tool = {
  name: 'list_connectors',
  description:
    'List the connectors (linked accounts/services) the user has connected in RoamSocket Settings → Connectors. ' +
    'Call this before connector_request to see which connector ids are actually usable right now.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  summarize: () => 'Listing connected connectors',
  async execute(): Promise<ToolResult> {
    const rows = listConnectorDefinitions()
      .filter((d) => d.authType !== 'unsupported')
      .map((d) => ({
        id: d.id,
        name: d.name,
        connected: isConnectorConnected(d.id),
        baseUrl: d.baseUrl,
      }));
    const connected = rows.filter((r) => r.connected);
    if (connected.length === 0) {
      return {
        ok: true,
        output:
          'No connectors are connected. Tell the user to connect one in Settings → Connectors, then try again.',
      };
    }
    return { ok: true, output: JSON.stringify(rows, null, 2) };
  },
};

export const connectorRequestTool: Tool = {
  name: 'connector_request',
  description:
    "Make an authenticated HTTP request to a connected connector's API (e.g. github, figma, godaddy, gmail, gcal, gdrive). " +
    "Call list_connectors first to see which ids are connected. `path` is relative to the connector's base API URL.",
  inputSchema: {
    type: 'object',
    properties: {
      connectorId: { type: 'string', description: 'Connector id, e.g. "github".' },
      method: { type: 'string', enum: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'], default: 'GET' },
      path: {
        type: 'string',
        description: 'Path relative to the connector\'s base URL, e.g. "/user".',
      },
      query: { type: 'object', description: 'Optional query parameters.' },
      body: { description: 'Optional JSON request body.' },
    },
    required: ['connectorId', 'path'],
    additionalProperties: false,
  },
  summarize(input) {
    const id = String(input.connectorId ?? '?');
    const method = String(input.method ?? 'GET');
    const p = String(input.path ?? '');
    return `${method} ${id}${p}`;
  },
  async execute(input): Promise<ToolResult> {
    const connectorId = String(input.connectorId ?? '');
    const method = String(input.method ?? 'GET').toUpperCase();
    const relPath = String(input.path ?? '');
    const query = (input.query as Record<string, unknown> | undefined) ?? undefined;
    const body = input.body;

    const { connectorDefinition } = await import('../connectors/catalog.js');
    const def = connectorDefinition(connectorId);
    if (!def || def.authType === 'unsupported') {
      return {
        ok: false,
        output: def
          ? `${def.name} is not supported: ${def.helpText}`
          : `Unknown connector: ${connectorId}`,
      };
    }
    const authResult = await resolveAuthHeader(connectorId);
    if ('error' in authResult) {
      return { ok: false, output: authResult.error };
    }
    if (!def.baseUrl) {
      return { ok: false, output: `${def.name} has no base URL configured.` };
    }

    const url = new URL(def.baseUrl + relPath);
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v != null) url.searchParams.set(k, String(v));
      }
    }

    try {
      const res = await fetch(url.toString(), {
        method,
        headers: {
          ...authResult.header,
          Accept: 'application/json',
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
      const text = await res.text();
      const summary = `HTTP ${res.status}\n${text}`;
      return { ok: res.ok, output: truncate(summary) };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return { ok: false, output: `Request failed: ${msg}` };
    }
  },
};
