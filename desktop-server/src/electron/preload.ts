/**
 * Preload bridge between the Electron main process and the sandboxed
 * renderer. Exposes a small, typed `window.apc` object so the UI never
 * touches Node APIs directly.
 */
import { contextBridge, ipcRenderer } from "electron";

interface BootstrapInfo {
  version: string;
  platform: NodeJS.Platform;
  pairingCode: string | null;
  serverPort: number | null;
  serverHost: string | null;
  serverRunning: boolean;
  prefs: {
    closeBehaviorDecided: boolean;
    alwaysQuitOnClose: boolean;
    startMinimized: boolean;
    remoteAccessEnabled: boolean;
    remoteAccessUrl: string;
    remoteAccessProvider: string;
    allowLanDiscovery: boolean;
    autoTunnelOnPair: boolean;
    showPairingCodePopup: boolean;
    rotateCodeAfterPair: boolean;
  };
  secretsAvailable: boolean;
}

interface RedactedSecrets {
  providerKeys: Record<string, { present: boolean }>;
  githubTokenPresent: boolean;
  lastServerAddress: string;
  lastRepo: { fullName: string; baseBranch: string; workBranch: string } | null;
  modelPrefs: Record<string, { model: string; effort: "low" | "medium" | "high" }>;
}

interface SecretPayload {
  providerKeys: Record<string, string>;
  githubToken: string;
  lastServerAddress: string;
  lastRepo: { fullName: string; baseBranch: string; workBranch: string } | null;
  modelPrefs: Record<string, { model: string; effort: "low" | "medium" | "high" }>;
}

interface MarketplaceSourceInfo {
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  isDefault?: boolean;
  lastFetchedAt?: number;
  lastError?: string | null;
  catalogName?: string | null;
}

interface MarketplaceStatusInfo {
  sources: MarketplaceSourceInfo[];
  catalog: {
    schemaVersion: number;
    updatedAt?: string;
    name?: string;
    description?: string;
    connectors: Array<{
      id: string;
      name: string;
      description?: string;
      available?: boolean;
      category?: string;
    }>;
    skills: Array<{
      id: string;
      name: string;
      description: string;
      category?: string;
      featured?: boolean;
    }>;
    plugins: Array<{
      id: string;
      name: string;
      description?: string;
      category?: string;
      skillIds?: string[];
      featured?: boolean;
    }>;
    pluginCategories: Array<{ id: string; label: string }>;
    metalModels: Array<{
      hubID: string;
      displayName: string;
      approxSize?: string;
      blurb?: string;
      tags?: string[];
      platforms?: string[];
    }>;
  };
  lastMergedAt: number | null;
  usingBundledOnly: boolean;
}

const api = {
  bootstrap: (): Promise<BootstrapInfo> => ipcRenderer.invoke("app:getBootstrap"),

  prefs: {
    set: (patch: Record<string, unknown>): Promise<BootstrapInfo["prefs"]> =>
      ipcRenderer.invoke("prefs:set", patch),
  },

  pairing: {
    showCode: (): Promise<string | null> => ipcRenderer.invoke("pairing:showCode"),
    rotateCode: (): Promise<string | null> => ipcRenderer.invoke("pairing:rotateCode"),
  },

  secrets: {
    get: (): Promise<RedactedSecrets> => ipcRenderer.invoke("secrets:get"),
    set: (next: Partial<SecretPayload>): Promise<RedactedSecrets> =>
      ipcRenderer.invoke("secrets:set", next),
    clearProvider: (providerId: string): Promise<RedactedSecrets> =>
      ipcRenderer.invoke("secrets:clearProvider", providerId),
    clearGithub: (): Promise<RedactedSecrets> => ipcRenderer.invoke("secrets:clearGithub"),
    /** Pull the raw value of one provider's API key. Used by the composer when sending a task. */
    readProviderKey: (providerId: string): Promise<string | null> =>
      ipcRenderer.invoke("secrets:readProviderKey", providerId),
    /** Pull the raw GitHub token. */
    readGithubToken: (): Promise<string | null> =>
      ipcRenderer.invoke("secrets:readGithubToken"),
  },

  clipboard: { write: (text: string): Promise<void> => ipcRenderer.invoke("clipboard:write", text) },
  shell: { open: (url: string): Promise<void> => ipcRenderer.invoke("shell:open", url) },

  tools: {
    tunnelCliStatus: (): Promise<{
      binDir: string;
      platform: string;
      strategy: string;
      availableProviders: string[];
      remoteAccess: {
        enabled: boolean;
        url: string;
        provider: string;
        tunnelId: string | null;
        serverPort: number | null;
        live: { id: string; port: number; provider: string; status: string; url?: string; error?: string } | null;
      };
      tools: Array<{
        id: "cloudflared" | "ngrok";
        label: string;
        installed: boolean;
        path: string | null;
        source: "path" | "managed" | null;
        version: string | null;
        platform: string;
      }>;
    }> => ipcRenderer.invoke("tools:tunnelCliStatus"),
    installTunnelCli: (
      id: "cloudflared" | "ngrok",
      opts?: { force?: boolean },
    ): Promise<
      | { ok: true; status: unknown }
      | { ok: false; error: string }
    > => ipcRenderer.invoke("tools:installTunnelCli", id, opts),
    setRemoteAccess: (opts: {
      enabled: boolean;
      provider?: "auto" | "ngrok" | "cloudflare" | "localtunnel" | "bore";
    }): Promise<{ ok: true; remote: unknown }> =>
      ipcRenderer.invoke("tools:setRemoteAccess", opts),
    refreshRemoteAccess: (): Promise<{
      enabled: boolean;
      url: string;
      provider?: string;
      live: unknown;
    }> => ipcRenderer.invoke("tools:refreshRemoteAccess"),
  },

  window: { hide: (): Promise<void> => ipcRenderer.invoke("window:hide") },
  app: { quit: (): Promise<void> => ipcRenderer.invoke("app:quit") },

  /**
   * Marketplace catalogs (connectors, skills, plugins, Metal models).
   * Default official source + user-added GitHub raw catalog.json URLs.
   */
  marketplace: {
    status: (): Promise<MarketplaceStatusInfo> => ipcRenderer.invoke("marketplace:status"),
    refresh: (): Promise<MarketplaceStatusInfo> => ipcRenderer.invoke("marketplace:refresh"),
    addSource: (input: {
      name?: string;
      url: string;
      enabled?: boolean;
    }): Promise<{ source: MarketplaceSourceInfo; status: MarketplaceStatusInfo }> =>
      ipcRenderer.invoke("marketplace:addSource", input),
    removeSource: (id: string): Promise<MarketplaceStatusInfo> =>
      ipcRenderer.invoke("marketplace:removeSource", id),
    setSourceEnabled: (id: string, enabled: boolean): Promise<MarketplaceStatusInfo> =>
      ipcRenderer.invoke("marketplace:setSourceEnabled", id, enabled),
    setSourceUrl: (id: string, url: string): Promise<MarketplaceStatusInfo> =>
      ipcRenderer.invoke("marketplace:setSourceUrl", id, url),
  },

  /** On-device Metal / MLX models — managed in a dedicated desktop view. */
  metal: {
    status: (): Promise<{
      providerId: string;
      chatOnly: true;
      platform: string;
      arch: string;
      supported: boolean;
      runtimeReady: boolean;
      runtimeLabel: string;
      pythonPath: string | null;
      detail: string;
    }> => ipcRenderer.invoke("metal:status"),
    catalog: (): Promise<
      Array<{
        hubID: string;
        displayName: string;
        approxSize: string;
        blurb: string;
        tags: string[];
        chatOnly: true;
        family: string;
        section: string;
        downloaded: boolean;
        localPath?: string;
      }>
    > => ipcRenderer.invoke("metal:catalog"),
    storage: (): Promise<{ bytes: number; root: string; count: number }> =>
      ipcRenderer.invoke("metal:storage"),
    download: (
      hubID: string,
    ): Promise<{ hubID: string; localPath: string; downloadedAt: number; displayName: string }> =>
      ipcRenderer.invoke("metal:download", hubID),
    delete: (hubID: string): Promise<{ ok: true }> => ipcRenderer.invoke("metal:delete", hubID),
    deleteAll: (): Promise<{ ok: true; removed: number }> => ipcRenderer.invoke("metal:deleteAll"),
    openDir: (): Promise<{ ok: true; path: string }> => ipcRenderer.invoke("metal:openDir"),
    generate: (req: {
      hubID: string;
      messages: Array<{ role: "user" | "assistant" | "system"; content: string }>;
      maxTokens?: number;
    }): Promise<{ text: string; hubID: string; modelPath: string }> =>
      ipcRenderer.invoke("metal:generate", req),
    /** Install managed Python venv + mlx-lm (macOS). Streams metal:installLog. */
    installRuntime: (): Promise<{
      ok: boolean;
      pythonPath: string | null;
      detail: string;
      error?: string;
    }> => ipcRenderer.invoke("metal:installRuntime"),
  },

  /** Lightweight Tasks — Apple Intelligence on Mac, or linked models elsewhere. */
  lightweight: {
    foundationStatus: (): Promise<{
      platform: string;
      supported: boolean;
      cliPath: string | null;
      ready: boolean;
      detail: string;
    }> => ipcRenderer.invoke("lightweight:foundationStatus"),
    foundationGenerate: (req: {
      system?: string;
      user: string;
      maxTokens?: number;
    }): Promise<{ ok: true; text: string } | { ok: false; error: string }> =>
      ipcRenderer.invoke("lightweight:foundationGenerate", req),
  },

  on: (
    channel:
      | "navigate"
      | "tools:installLog"
      | "tools:installDone"
      | "pairing:code"
      | "metal:downloadProgress"
      | "metal:installLog"
      | "metal:installDone",
    listener: (payload: any) => void,
  ) => {
    const handler = (_e: unknown, p: any) => listener(p);
    ipcRenderer.on(channel, handler);
    return () => ipcRenderer.removeListener(channel, handler);
  },
};

contextBridge.exposeInMainWorld("apc", api);

export type ApcApi = typeof api;
