/**
 * Preload bridge between the Electron main process and the sandboxed
 * renderer. Exposes a small, typed `window.cmai` object so the UI never
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
  prefs: { closeBehaviorDecided: boolean; alwaysQuitOnClose: boolean; startMinimized: boolean };
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

  window: { hide: (): Promise<void> => ipcRenderer.invoke("window:hide") },
  app: { quit: (): Promise<void> => ipcRenderer.invoke("app:quit") },

  on: (channel: "navigate", listener: (path: string) => void) => {
    const handler = (_e: unknown, p: string) => listener(p);
    ipcRenderer.on(channel, handler);
    return () => ipcRenderer.removeListener(channel, handler);
  },
};

contextBridge.exposeInMainWorld("cmai", api);

export type CmaiApi = typeof api;
