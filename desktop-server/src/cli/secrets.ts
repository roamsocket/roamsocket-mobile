/**
 * Legacy `roamsocket --tui` CLI secrets/persistence helper.
 *
 * The original implementation was removed during a refactor; this stub
 * restores the API surface (`loadCliSecrets`, `resolveApiKey`,
 * `resolveModelSelection`, `setProviderKey`, `updateCliSecrets`,
 * `hasAnyKey`, `defaultPermissionMode`) so the CLI's existing imports
 * resolve and the TUI can start. Persistence is intentionally in-memory
 * only: the live desktop shell (`desktop-server/src/index.ts`) is the
 * supported runtime; the TUI is a legacy `roamsocket --tui` entry point
 * kept for users who haven't migrated.
 *
 * API keys are read from environment variables (`<PROVIDER>_API_KEY`),
 * matching what the new `mountProxy()` proxy does. There is no on-disk
 * key store here.
 */
import type { ModelSelection, PermissionMode, ProviderId } from '../protocol.js';

export interface CliSecrets {
  providerKeys: Record<string, string>;
  provider?: string;
  model?: string;
  permissionMode?: PermissionMode;
  effort?: 'low' | 'medium' | 'high';
}

const ENV_KEY_BY_PROVIDER: Record<string, string> = {
  anthropic: 'ANTHROPIC_API_KEY',
  openai: 'OPENAI_API_KEY',
  google: 'GOOGLE_API_KEY',
  groq: 'GROQ_API_KEY',
  openrouter: 'OPENROUTER_API_KEY',
  xai: 'XAI_API_KEY',
  mistral: 'MISTRAL_API_KEY',
  minimax: 'MINIMAX_API_KEY',
};

/** In-memory snapshot — never persisted. The desktop shell is the source of truth. */
let inMemory: CliSecrets = {
  providerKeys: {},
};

export function loadCliSecrets(): CliSecrets {
  return {
    providerKeys: { ...inMemory.providerKeys },
    provider: inMemory.provider,
    model: inMemory.model,
    permissionMode: inMemory.permissionMode,
    effort: inMemory.effort,
  };
}

export function updateCliSecrets(updates: Partial<CliSecrets>): void {
  inMemory = {
    providerKeys: updates.providerKeys
      ? { ...updates.providerKeys }
      : { ...inMemory.providerKeys },
    provider: updates.provider ?? inMemory.provider,
    model: updates.model ?? inMemory.model,
    permissionMode: updates.permissionMode ?? inMemory.permissionMode,
    effort: updates.effort ?? inMemory.effort,
  };
}

export function setProviderKey(provider: string, key: string): void {
  inMemory.providerKeys[provider] = key;
}

export function hasAnyKey(secrets: CliSecrets = loadCliSecrets()): boolean {
  if (Object.keys(secrets.providerKeys).length > 0) return true;
  for (const envName of Object.values(ENV_KEY_BY_PROVIDER)) {
    if (process.env[envName]) return true;
  }
  return false;
}

export function resolveApiKey(
  provider: ProviderId | string,
  secrets: CliSecrets = loadCliSecrets()
): string | undefined {
  if (secrets.providerKeys[provider]) return secrets.providerKeys[provider];
  const envName = ENV_KEY_BY_PROVIDER[provider];
  if (envName && process.env[envName]) return process.env[envName];
  // Custom providers (e.g. `custom:ollama`) may carry their key in baseUrl
  // flows; leave undefined here so callers can fall back to mock mode.
  return undefined;
}

export function defaultPermissionMode(secrets: CliSecrets = loadCliSecrets()): PermissionMode {
  return secrets.permissionMode ?? 'acceptEdits';
}

/**
 * Build a ModelSelection from CLI flags + secrets. Mock mode bypasses
 * key resolution so the offline smoke test still works.
 */
export function resolveModelSelection(opts: {
  provider?: string;
  model?: string;
  mock?: boolean;
  secrets?: CliSecrets;
  baseUrl?: string;
  apiStyle?: 'openai' | 'anthropic';
}): ModelSelection {
  const secrets = opts.secrets ?? loadCliSecrets();
  const provider = (opts.provider ?? secrets.provider ?? 'anthropic') as ProviderId;
  const model = opts.model ?? secrets.model ?? 'mock';
  const effort = secrets.effort ?? 'high';
  const apiKey = opts.mock ? 'none' : resolveApiKey(provider, secrets) ?? '';
  return {
    provider,
    model,
    effort,
    apiKey,
    baseUrl: opts.baseUrl,
    apiStyle: opts.apiStyle,
  };
}
