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

  on: (
    channel: "navigate" | "tools:installLog" | "tools:installDone" | "pairing:code",
    listener: (payload: any) => void,
  ) => {
    const handler = (_e: unknown, p: any) => listener(p);
    ipcRenderer.on(channel, handler);
    return () => ipcRenderer.removeListener(channel, handler);
  },
};

contextBridge.exposeInMainWorld("apc", api);

export type ApcApi = typeof api;
