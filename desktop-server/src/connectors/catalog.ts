/**
 * Static definitions for the connectors RoamSocket can actually integrate
 * with. Unlike the marketplace catalog (which just lists names/icons for
 * discovery), this file carries the real auth wiring: base API URL, how the
 * token is sent, and (for OAuth2 connectors) the provider's public
 * authorize/token endpoints and scopes.
 *
 * These are all public, documented endpoints — no secrets live here. OAuth2
 * connectors still need the user's own OAuth app (client id + optional
 * secret), entered per-connector in Settings → Connectors, because RoamSocket
 * does not ship a shared Google/Figma/etc. OAuth client.
 */

export type ConnectorAuthType = "token" | "oauth2" | "unsupported";

export interface ConnectorOAuthConfig {
  authUrl: string;
  tokenUrl: string;
  scope: string;
  /** True when the provider's token endpoint accepts a PKCE-only (no secret) exchange. */
  supportsPkce: boolean;
}

export interface ConnectorTokenHeader {
  name: string;
  /** e.g. "Bearer " for `Authorization: Bearer <token>`. */
  prefix?: string;
}

export interface ConnectorDefinition {
  id: string;
  name: string;
  authType: ConnectorAuthType;
  /** Base URL the `connector_request` tool resolves relative paths against. */
  baseUrl?: string;
  /** How a token/access-token is attached to outgoing requests. */
  tokenHeader?: ConnectorTokenHeader;
  oauth?: ConnectorOAuthConfig;
  /** Shown in the UI — where to generate a token, or why it's unsupported. */
  helpText: string;
}

/**
 * Known connectors. `available: true` marketplace entries that aren't listed
 * here fall back to `authType: "unsupported"` (nothing to wire up yet).
 */
export const CONNECTOR_DEFINITIONS: Record<string, ConnectorDefinition> = {
  github: {
    id: "github",
    name: "GitHub",
    authType: "token",
    baseUrl: "https://api.github.com",
    tokenHeader: { name: "Authorization", prefix: "Bearer " },
    helpText:
      "Create a fine-grained personal access token at github.com/settings/tokens and paste it here.",
  },
  figma: {
    id: "figma",
    name: "Figma",
    authType: "token",
    baseUrl: "https://api.figma.com",
    tokenHeader: { name: "X-Figma-Token" },
    helpText:
      "Create a personal access token at figma.com/developers/api#access-tokens and paste it here.",
  },
  godaddy: {
    id: "godaddy",
    name: "GoDaddy",
    authType: "token",
    baseUrl: "https://api.godaddy.com",
    // GoDaddy's API key format is "API_KEY:API_SECRET" sent as a single sso-key value.
    tokenHeader: { name: "Authorization", prefix: "sso-key " },
    helpText:
      "Create an API key/secret at developer.godaddy.com/keys and paste it here as KEY:SECRET.",
  },
  gmail: {
    id: "gmail",
    name: "Gmail",
    authType: "oauth2",
    baseUrl: "https://gmail.googleapis.com",
    oauth: {
      authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
      tokenUrl: "https://oauth2.googleapis.com/token",
      scope: "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send",
      supportsPkce: true,
    },
    helpText:
      "Requires your own Google Cloud OAuth client (Desktop app type, loopback redirect). Create one at console.cloud.google.com/apis/credentials.",
  },
  gcal: {
    id: "gcal",
    name: "Google Calendar",
    authType: "oauth2",
    baseUrl: "https://www.googleapis.com/calendar/v3",
    oauth: {
      authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
      tokenUrl: "https://oauth2.googleapis.com/token",
      scope: "https://www.googleapis.com/auth/calendar",
      supportsPkce: true,
    },
    helpText:
      "Requires your own Google Cloud OAuth client (Desktop app type, loopback redirect). Create one at console.cloud.google.com/apis/credentials.",
  },
  gdrive: {
    id: "gdrive",
    name: "Google Drive",
    authType: "oauth2",
    baseUrl: "https://www.googleapis.com/drive/v3",
    oauth: {
      authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
      tokenUrl: "https://oauth2.googleapis.com/token",
      scope: "https://www.googleapis.com/auth/drive",
      supportsPkce: true,
    },
    helpText:
      "Requires your own Google Cloud OAuth client (Desktop app type, loopback redirect). Create one at console.cloud.google.com/apis/credentials.",
  },
  cashapp: {
    id: "cashapp",
    name: "Cash App",
    authType: "unsupported",
    helpText:
      "Cash App has no public API for personal/consumer accounts, so there is nothing to connect to.",
  },
  granola: {
    id: "granola",
    name: "Granola",
    authType: "unsupported",
    helpText: "Granola does not publish a public API yet.",
  },
};

export function connectorDefinition(id: string): ConnectorDefinition | undefined {
  return CONNECTOR_DEFINITIONS[id];
}

export function listConnectorDefinitions(): ConnectorDefinition[] {
  return Object.values(CONNECTOR_DEFINITIONS);
}
