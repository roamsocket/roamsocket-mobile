/**
 * Electron main process.
 *
 * Responsibilities:
 *   1. Start the same Express + WebSocket server the headless CLI runs, but
 *      in-process so the GUI and the server share memory.
 *   2. Open a single BrowserWindow that loads the renderer (settings,
 *      composer, history).
 *   3. Tray icon: the app lives in the macOS menu bar / Windows task tray
 *      and closing the window hides to the tray by default. The first
 *      close asks the user whether they want the app to quit entirely on
 *      future closes; subsequent closes honour that choice.
 *   4. Expose IPC for renderer-side concerns (config persistence via
 *      safeStorage, server control, copy-to-clipboard, open external URLs).
 */
import { app, BrowserWindow, Tray, Menu, ipcMain, dialog, shell, clipboard, safeStorage, nativeImage } from "electron";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { startServer, type RunningServer } from "../index.js";
import {
  hostTriple,
  installStrategySummary,
  installTunnelCli,
  listTunnelCliStatus,
  managedBinDir,
  type TunnelCliId,
} from "../workspace/tunnel-clis.js";
import {
  detectTunnelProviders,
  listTunnels,
  startTunnel,
  stopTunnel,
  type TunnelInfo,
} from "../workspace/tunnels.js";
import {
  findConflictingProcesses,
  formatConflictDetail,
  isPortHeld,
  killProcesses,
} from "./instance-cleanup.js";
import {
  loadDesktopPrefs,
  saveDesktopPrefs,
  type DesktopPrefs,
  type TunnelProviderPref,
} from "../desktop-config.js";
import {
  getMetalStore,
  getMetalRuntimeStatus,
  metalGenerate,
  installMetalRuntime,
  resetMetalPythonCache,
} from "../metal/index.js";
import {
  applyMarketplaceToDesktop,
  getMarketplaceStore,
} from "../marketplace/index.js";
import {
  getFoundationStatus,
  foundationGenerate,
  ensureFoundationCliBuilt,
} from "../lightweight/foundation-bridge.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Compile-time constants injected by `@electron-forge/plugin-vite` via Vite
// `define` (NOT process.env). In `electron-forge start` the first is the
// renderer dev-server URL; in production builds it is undefined and the
// second names the renderer folder under `.vite/renderer/`.
declare const MAIN_WINDOW_VITE_DEV_SERVER_URL: string | undefined;
declare const MAIN_WINDOW_VITE_NAME: string;

function rendererIndexHtml(): string {
  const name =
    typeof MAIN_WINDOW_VITE_NAME === "string" && MAIN_WINDOW_VITE_NAME.length > 0
      ? MAIN_WINDOW_VITE_NAME
      : "main_window";
  return path.join(__dirname, "..", "renderer", name, "index.html");
}

function rendererDevServerUrl(): string | undefined {
  // Must reference the free identifier so Vite's define can replace it.
  // Reading process.env.MAIN_WINDOW_VITE_DEV_SERVER_URL never works — Forge
  // does not put this in the environment.
  return typeof MAIN_WINDOW_VITE_DEV_SERVER_URL === "string" &&
    MAIN_WINDOW_VITE_DEV_SERVER_URL.length > 0
    ? MAIN_WINDOW_VITE_DEV_SERVER_URL
    : undefined;
}

// --- Single-instance lock so two launches don't fight for port 4319. -----
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  // Another Electron instance of this app already owns the lock. That
  // instance will raise its window via the `second-instance` handler; we
  // exit quietly so only one GUI runs.
  app.quit();
  process.exit(0);
}

// --- Persisted UI prefs. Stored next to userData, plain JSON. -------------
// Connection permissions also sync to product data dir desktop-prefs.json
// so the headless CLI and Electron share the same knobs.

interface Prefs {
  /** First-close "always quit?" decision. Once decided, never asked again. */
  closeBehaviorDecided: boolean;
  /** True = quit app on window close; False = always hide to tray. */
  alwaysQuitOnClose: boolean;
  /** Whether the window starts hidden in the tray (auto-launched at login, etc). */
  startMinimized: boolean;
  /**
   * When true, expose the local coding server port via a public tunnel
   * so phones can pair / reconnect away from home.
   */
  remoteAccessEnabled: boolean;
  /** Last known public URL for the coding server tunnel. */
  remoteAccessUrl: string;
  /** Tunnel provider preference for remote access. */
  remoteAccessProvider: TunnelProviderPref;
  /** Phones can discover this machine on the LAN (Bonjour). */
  allowLanDiscovery: boolean;
  /** After pair, auto-start public tunnel and send URL to the phone. */
  autoTunnelOnPair: boolean;
  /** Show large pairing-code window on launch. */
  showPairingCodePopup: boolean;
  /** Rotate pairing code after each successful pair. */
  rotateCodeAfterPair: boolean;
}
const DEFAULT_PREFS: Prefs = {
  closeBehaviorDecided: false,
  alwaysQuitOnClose: false,
  startMinimized: false,
  remoteAccessEnabled: false,
  remoteAccessUrl: "",
  remoteAccessProvider: "auto",
  allowLanDiscovery: true,
  autoTunnelOnPair: true,
  showPairingCodePopup: true,
  rotateCodeAfterPair: false,
};

/** Live remote-access tunnel id (process-local). */
let remoteAccessTunnelId: string | null = null;
let codeWindow: BrowserWindow | null = null;

let prefs: Prefs = { ...DEFAULT_PREFS };
let prefsPath = "";
function loadPrefs(): void {
  try {
    prefsPath = path.join(app.getPath("userData"), "prefs.json");
    // Merge shared desktop prefs first, then Electron-local overrides.
    const shared = loadDesktopPrefs();
    prefs = {
      ...DEFAULT_PREFS,
      allowLanDiscovery: shared.allowLanDiscovery,
      autoTunnelOnPair: shared.autoTunnelOnPair,
      remoteAccessProvider: shared.tunnelProvider,
      showPairingCodePopup: shared.showPairingCodePopup,
      rotateCodeAfterPair: shared.rotateCodeAfterPair,
      remoteAccessUrl: shared.remoteAccessUrl,
      remoteAccessEnabled: shared.remoteAccessEnabled,
    };
    if (existsSync(prefsPath)) {
      const raw = readFileSync(prefsPath, "utf8");
      const parsed = JSON.parse(raw);
      prefs = { ...prefs, ...parsed };
    }
  } catch {
    prefs = { ...DEFAULT_PREFS };
  }
}
function savePrefs(): void {
  try {
    writeFileSync(prefsPath, JSON.stringify(prefs, null, 2));
  } catch {
    // best effort
  }
  // Keep headless CLI in sync for connection permissions.
  const shared: DesktopPrefs = {
    allowLanDiscovery: prefs.allowLanDiscovery,
    autoTunnelOnPair: prefs.autoTunnelOnPair,
    tunnelProvider: prefs.remoteAccessProvider,
    showPairingCodePopup: prefs.showPairingCodePopup,
    rotateCodeAfterPair: prefs.rotateCodeAfterPair,
    remoteAccessUrl: prefs.remoteAccessUrl,
    remoteAccessEnabled: prefs.remoteAccessEnabled,
  };
  saveDesktopPrefs(shared);
}

/** Apple-verification style pairing code popup. */
function showPairingCodeWindow(code: string): void {
  if (!prefs.showPairingCodePopup) return;
  const digits = (code || "------").replace(/\D/g, "").padStart(6, "0").slice(0, 6);
  const spaced = digits.split("").join("  ");

  if (codeWindow && !codeWindow.isDestroyed()) {
    codeWindow.focus();
    codeWindow.webContents.executeJavaScript(
      `document.getElementById('code').textContent=${JSON.stringify(spaced)}`,
    ).catch(() => undefined);
    return;
  }

  codeWindow = new BrowserWindow({
    width: 420,
    height: 280,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    alwaysOnTop: true,
    title: "Pairing code",
    backgroundColor: "#0b0d10",
    show: true,
    webPreferences: {
      contextIsolation: true,
      sandbox: true,
    },
  });
  codeWindow.setMenuBarVisibility(false);
  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"/>
<style>
  html,body{height:100%;margin:0;background:#0b0d10;color:#e8ecf1;
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
  .wrap{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px}
  .label{font-size:13px;color:#9aa3ad;letter-spacing:.04em}
  .code{font:600 42px/1.1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    letter-spacing:.08em;padding:18px 22px;border-radius:16px;background:#14181d;
    border:1px solid #262c34;min-width:280px;text-align:center}
  .hint{font-size:13px;color:#6b727b;text-align:center;max-width:320px;line-height:1.4}
</style></head><body><div class="wrap">
  <div class="label">RoamSocket</div>
  <div class="code" id="code">${spaced}</div>
  <div class="hint">Enter this code on your phone to pair<br/>(Settings → Desktop server)</div>
</div></body></html>`;
  codeWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);
  codeWindow.on("closed", () => {
    codeWindow = null;
  });
}

// --- Encrypted client-side secrets (API keys, GitHub tokens). ------------
interface SecretPayload {
  /** Map of provider id -> api key. */
  providerKeys: Record<string, string>;
  /** GitHub personal access token. */
  githubToken: string;
  /** Last-used server address (for showing the QR / connection state). */
  lastServerAddress: string;
  /** Last repo full name + base + work branch. */
  lastRepo: { fullName: string; baseBranch: string; workBranch: string } | null;
  /** Per-provider model selection: provider -> model id + effort. */
  modelPrefs: Record<string, { model: string; effort: "low" | "medium" | "high" }>;
}
const DEFAULT_SECRETS: SecretPayload = {
  providerKeys: {},
  githubToken: "",
  lastServerAddress: "",
  lastRepo: null,
  modelPrefs: {},
};

let secrets: SecretPayload = { ...DEFAULT_SECRETS };
let secretsPath = "";
let secretsEncrypted = true;

function loadSecrets(): void {
  secretsPath = path.join(app.getPath("userData"), "secrets.enc");
  try {
    if (!existsSync(secretsPath)) {
      secrets = { ...DEFAULT_SECRETS };
      return;
    }
    const buf = readFileSync(secretsPath);
    if (!safeStorage.isEncryptionAvailable() || buf.length === 0) {
      secretsEncrypted = false;
      secrets = { ...DEFAULT_SECRETS };
      return;
    }
    const decrypted = safeStorage.decryptString(buf);
    secrets = { ...DEFAULT_SECRETS, ...JSON.parse(decrypted) };
  } catch {
    secrets = { ...DEFAULT_SECRETS };
  }
}
function saveSecrets(): void {
  try {
    if (!safeStorage.isEncryptionAvailable()) {
      secretsEncrypted = false;
      return;
    }
    const buf = safeStorage.encryptString(JSON.stringify(secrets));
    writeFileSync(secretsPath, buf);
  } catch {
    // best effort
  }
}

function redactSecrets(s: SecretPayload): {
  providerKeys: Record<string, { present: boolean }>;
  githubTokenPresent: boolean;
  lastServerAddress: string;
  lastRepo: SecretPayload["lastRepo"];
  modelPrefs: SecretPayload["modelPrefs"];
} {
  return {
    providerKeys: Object.fromEntries(
      Object.entries(s.providerKeys).map(([k, v]) => [k, { present: !!v }]),
    ),
    githubTokenPresent: !!s.githubToken,
    lastServerAddress: s.lastServerAddress,
    lastRepo: s.lastRepo,
    modelPrefs: s.modelPrefs,
  };
}

// --- Window + tray. ------------------------------------------------------
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let server: RunningServer | null = null;
let isQuitting = false;

function buildTrayIcon(): Electron.NativeImage {
  // Tiny PNG generated at build time; for now we draw a simple square so
  // the tray entry always has an icon, even on Linux without an .icns.
  const size = 16;
  const img = nativeImage.createEmpty();
  // Use the app's default icon if available; fallback to a generated 1x1 png.
  const appIcon = nativeImage.createFromPath(path.join(__dirname, "..", "..", "build", "icon.png"));
  if (!appIcon.isEmpty()) return appIcon.resize({ width: size, height: size });
  // 16x16 transparent PNG (placeholder so macOS doesn't show a blank square).
  const png1x1 = Buffer.from(
    "89504e470d0a1a0a0000000d49484452000000100000001008060000001ff3ff610000001849444154388f63601805a30050330c0d0a26ab0104c7a3f01a1c0c0c4c1c0c00c0c0c0c0c000c0c04c0c0c00c0c0c0c0c0c00c0000009c1c0218df8c43c0000000049454e44ae426082",
    "hex",
  );
  return nativeImage.createFromBuffer(png1x1);
}

function createTray(): void {
  if (tray) return;
  tray = new Tray(buildTrayIcon());
  tray.setToolTip("RoamSocket");
  refreshTrayMenu();
  tray.on("click", () => {
    if (process.platform === "darwin") {
      // On macOS the click is handled by the menu; just show the window.
      showWindow();
      return;
    }
    if (mainWindow?.isVisible()) hideWindow();
    else showWindow();
  });
}

function refreshTrayMenu(): void {
  if (!tray) return;
  const menu = Menu.buildFromTemplate([
    {
      label: mainWindow?.isVisible() ? "Hide window" : "Show window",
      click: () => (mainWindow?.isVisible() ? hideWindow() : showWindow()),
    },
    { type: "separator" },
    {
      label: "Pairing code",
      enabled: !!server,
      click: () => {
        if (server?.pairingCode) showPairingCodeWindow(server.pairingCode);
      },
    },
    {
      label: server ? `  ${server.pairingCode}` : "  (not running)",
      enabled: false,
    },
    {
      label: "Show code popup",
      enabled: !!server,
      click: () => {
        if (server?.pairingCode) showPairingCodeWindow(server.pairingCode);
      },
    },
    { type: "separator" },
    {
      label: "Open settings",
      click: () => {
        showWindow();
        mainWindow?.webContents.send("navigate", "/settings");
      },
    },
    {
      label: "Quit RoamSocket",
      click: () => {
        isQuitting = true;
        app.quit();
      },
    },
  ]);
  tray.setContextMenu(menu);
}

function showWindow(): void {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

function hideWindow(): void {
  if (!mainWindow) return;
  mainWindow.hide();
  // On macOS also hide from the dock so the app behaves like a tray app
  // when the window is closed.
  if (process.platform === "darwin" && app.dock && !prefs.alwaysQuitOnClose) {
    app.dock.hide();
  }
}

async function handleWindowClose(event: Electron.Event): Promise<void> {
  if (isQuitting) return;
  if (prefs.alwaysQuitOnClose) {
    isQuitting = true;
    app.quit();
    return;
  }
  event.preventDefault();

  if (!prefs.closeBehaviorDecided) {
    const result = await dialog.showMessageBox(mainWindow!, {
      type: "question",
      buttons: ["Hide to tray", "Quit app"],
      defaultId: 0,
      cancelId: 0,
      title: "Close RoamSocket?",
      message: "Closing the window keeps the server running in the background.",
      detail:
        "Hide to tray: the app stays in the menu bar / task tray and the WebSocket server keeps running so paired devices stay connected.\n\n" +
        "Quit app: the server stops and any paired devices will be disconnected.",
    });
    prefs.closeBehaviorDecided = true;
    prefs.alwaysQuitOnClose = result.response === 1;
    savePrefs();
    refreshTrayMenu();
    if (result.response === 1) {
      isQuitting = true;
      app.quit();
      return;
    }
  }
  hideWindow();
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 740,
    minWidth: 880,
    minHeight: 560,
    show: !prefs.startMinimized,
    title: "RoamSocket",
    backgroundColor: "#0b0d10",
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      sandbox: false,
      nodeIntegration: false,
    },
  });

  mainWindow.on("close", handleWindowClose);
  mainWindow.on("show", () => {
    if (process.platform === "darwin" && app.dock) app.dock.show();
    refreshTrayMenu();
  });
  mainWindow.on("hide", refreshTrayMenu);

  // Surface renderer load failures to the main process console so a blank
  // window has a visible cause instead of being a mystery.
  const wc = mainWindow.webContents;
  wc.on("did-fail-load", (_e, errorCode, errorDescription, validatedURL, isMainFrame) => {
    if (!isMainFrame) return;
    console.error(`[apc] renderer failed to load: ${validatedURL} — ${errorCode} ${errorDescription}`);
  });
  wc.on("render-process-gone", (_e, details) => {
    console.error(`[apc] renderer process gone: reason=${details.reason} exitCode=${details.exitCode}`);
  });
  wc.on("preload-error", (_e, preloadPath, error) => {
    console.error(`[apc] preload error in ${preloadPath}: ${(error as Error).message}`);
  });
  wc.on("console-message", (_e, level, message, line, source) => {
    const lvl = level >= 2 ? "error" : level === 1 ? "warn" : "log";
    console[level >= 2 ? "error" : "log"](`[apc:renderer:${lvl}] ${message} (${source}:${line})`);
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  // Dev: Vite serves the renderer with HMR; the URL is injected as the
  // compile-time constant MAIN_WINDOW_VITE_DEV_SERVER_URL by the Forge Vite
  // plugin. We retry a couple of times if the dev server is still starting.
  // Prod: the bundled HTML lives at `.vite/renderer/${MAIN_WINDOW_VITE_NAME}/index.html`.
  const devUrl = rendererDevServerUrl();
  if (devUrl) {
    console.log(`[apc] loading renderer from dev URL: ${devUrl}`);
    void loadWithRetry(mainWindow, devUrl, 5, 500);
  } else {
    const indexHtml = rendererIndexHtml();
    console.log(`[apc] loading renderer from bundled HTML: ${indexHtml}`);
    if (!existsSync(indexHtml)) {
      console.error(
        `[apc] renderer HTML missing at ${indexHtml}. ` +
        `Run via "npm run electron:dev" (Forge + Vite), or "npm run electron:package" for a production build.`,
      );
    }
    void mainWindow.loadFile(indexHtml).catch((err) => {
      console.error(`[apc] loadFile failed: ${(err as Error).message}`);
    });
  }
}

async function loadWithRetry(
  win: BrowserWindow,
  url: string,
  attempts: number,
  delayMs: number,
): Promise<void> {
  for (let i = 0; i < attempts; i++) {
    try {
      await win.loadURL(url);
      console.log(`[apc] renderer loaded from ${url}`);
      return;
    } catch (err) {
      const last = i === attempts - 1;
      console.warn(
        `[apc] renderer load attempt ${i + 1}/${attempts} failed: ${(err as Error).message}` +
        (last ? " (giving up)" : `, retrying in ${delayMs}ms`),
      );
      if (last) {
        // Final fallback: load the bundled HTML so the user isn't staring
        // at a blank window.
        const indexHtml = rendererIndexHtml();
        if (existsSync(indexHtml)) {
          await win.loadFile(indexHtml).catch(() => undefined);
        } else {
          console.error(
            `[apc] renderer dev server unreachable and no bundled HTML at ${indexHtml}`,
          );
        }
        return;
      }
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

// --- IPC surface for the renderer. --------------------------------------
function registerIpc(): void {
  ipcMain.handle("app:getBootstrap", () => ({
    version: app.getVersion(),
    platform: process.platform,
    pairingCode: server?.pairingCode ?? null,
    serverPort: server?.port ?? null,
    serverHost: server?.host ?? null,
    serverRunning: !!server,
    prefs: {
      closeBehaviorDecided: prefs.closeBehaviorDecided,
      alwaysQuitOnClose: prefs.alwaysQuitOnClose,
      startMinimized: prefs.startMinimized,
      remoteAccessEnabled: prefs.remoteAccessEnabled,
      remoteAccessUrl: prefs.remoteAccessUrl,
      remoteAccessProvider: prefs.remoteAccessProvider,
      allowLanDiscovery: prefs.allowLanDiscovery,
      autoTunnelOnPair: prefs.autoTunnelOnPair,
      showPairingCodePopup: prefs.showPairingCodePopup,
      rotateCodeAfterPair: prefs.rotateCodeAfterPair,
    },
    secretsAvailable: safeStorage.isEncryptionAvailable(),
  }));

  ipcMain.handle(
    "prefs:set",
    (_e, patch: Partial<Prefs>) => {
      prefs = { ...prefs, ...patch };
      savePrefs();
      return prefs;
    },
  );

  ipcMain.handle("pairing:showCode", () => {
    if (server?.pairingCode) showPairingCodeWindow(server.pairingCode);
    return server?.pairingCode ?? null;
  });

  ipcMain.handle("pairing:rotateCode", () => {
    const next = server?.rotatePairingCode?.() ?? server?.pairingCode ?? null;
    if (next) {
      showPairingCodeWindow(next);
      mainWindow?.webContents.send("pairing:code", next);
      refreshTrayMenu();
    }
    return next;
  });

  ipcMain.handle("secrets:get", () => redactSecrets(secrets));
  ipcMain.handle("secrets:set", (_e, next: Partial<SecretPayload>) => {
    secrets = {
      ...secrets,
      ...next,
      providerKeys: { ...secrets.providerKeys, ...(next.providerKeys ?? {}) },
      modelPrefs: { ...secrets.modelPrefs, ...(next.modelPrefs ?? {}) },
    };
    saveSecrets();
    return redactSecrets(secrets);
  });
  ipcMain.handle("secrets:clearProvider", (_e, providerId: string) => {
    delete secrets.providerKeys[providerId];
    saveSecrets();
    return redactSecrets(secrets);
  });
  ipcMain.handle("secrets:clearGithub", () => {
    secrets.githubToken = "";
    saveSecrets();
    return redactSecrets(secrets);
  });
  ipcMain.handle("secrets:readProviderKey", (_e, providerId: string) => secrets.providerKeys[providerId] ?? null);
  ipcMain.handle("secrets:readGithubToken", () => secrets.githubToken || null);

  ipcMain.handle("clipboard:write", (_e, text: string) => clipboard.writeText(text));
  ipcMain.handle("shell:open", (_e, url: string) => shell.openExternal(url));

  ipcMain.handle("server:rotateCode", () => {
    // PairingManager is private; expose via a fresh code path. For now we
    // bounce through a restart of the server.
    return server?.pairingCode ?? null;
  });

  // --- Tunnel CLIs (cloudflared / ngrok) ---------------------------------
  ipcMain.handle("tools:tunnelCliStatus", async () => {
    return {
      binDir: managedBinDir(),
      platform: hostTriple(),
      strategy: installStrategySummary(),
      tools: await listTunnelCliStatus(),
      availableProviders: await detectTunnelProviders(),
      remoteAccess: {
        enabled: prefs.remoteAccessEnabled,
        url: prefs.remoteAccessUrl,
        provider: prefs.remoteAccessProvider,
        tunnelId: remoteAccessTunnelId,
        serverPort: server?.port ?? null,
        live: listTunnels().find((t) => t.id === remoteAccessTunnelId) ?? null,
      },
    };
  });
  ipcMain.handle(
    "tools:installTunnelCli",
    async (event, id: TunnelCliId, opts?: { force?: boolean }) => {
      if (id !== "cloudflared" && id !== "ngrok") {
        throw new Error(`Unsupported tunnel CLI: ${id}`);
      }
      const sendLog = (line: string) => {
        event.sender.send("tools:installLog", { id, line });
      };
      try {
        sendLog(`Installing ${id}…`);
        const status = await installTunnelCli(id, sendLog, { force: !!opts?.force });
        event.sender.send("tools:installDone", { id, ok: true, status });
        return { ok: true as const, status };
      } catch (err) {
        const message = (err as Error).message ?? String(err);
        sendLog(`Error: ${message}`);
        event.sender.send("tools:installDone", { id, ok: false, error: message });
        return { ok: false as const, error: message };
      }
    },
  );

  ipcMain.handle(
    "tools:setRemoteAccess",
    async (
      _e,
      opts: { enabled: boolean; provider?: Prefs["remoteAccessProvider"] },
    ) => {
      if (opts.provider) prefs.remoteAccessProvider = opts.provider;
      prefs.remoteAccessEnabled = opts.enabled;
      savePrefs();
      if (opts.enabled) {
        const info = await ensureRemoteAccessTunnel();
        return { ok: true as const, remote: info };
      }
      const { stopAccessTunnel } = await import("../workspace/access-tunnel.js");
      stopAccessTunnel();
      if (remoteAccessTunnelId) {
        stopTunnel(remoteAccessTunnelId);
        remoteAccessTunnelId = null;
      }
      prefs.remoteAccessUrl = "";
      savePrefs();
      return { ok: true as const, remote: null };
    },
  );

  ipcMain.handle("tools:refreshRemoteAccess", async () => {
    if (!prefs.remoteAccessEnabled) {
      return { enabled: false, url: "", live: null as TunnelInfo | null };
    }
    const info = await ensureRemoteAccessTunnel();
    return info;
  });

  ipcMain.handle("window:hide", () => hideWindow());
  ipcMain.handle("app:quit", () => {
    isQuitting = true;
    app.quit();
  });

  // --- Marketplace (connectors / skills / plugins / metal catalogs) -------
  ipcMain.handle("marketplace:status", async () => getMarketplaceStore().status());
  ipcMain.handle("marketplace:refresh", async () => {
    const status = await getMarketplaceStore().refresh();
    applyMarketplaceToDesktop(status.catalog);
    return status;
  });
  ipcMain.handle(
    "marketplace:addSource",
    async (_e, input: { name?: string; url: string; enabled?: boolean }) => {
      const src = getMarketplaceStore().addSource(input);
      const status = await getMarketplaceStore().refresh();
      applyMarketplaceToDesktop(status.catalog);
      return { source: src, status };
    },
  );
  ipcMain.handle("marketplace:removeSource", async (_e, id: string) => {
    getMarketplaceStore().removeSource(id);
    const status = await getMarketplaceStore().refresh();
    applyMarketplaceToDesktop(status.catalog);
    return status;
  });
  ipcMain.handle(
    "marketplace:setSourceEnabled",
    async (_e, id: string, enabled: boolean) => {
      getMarketplaceStore().setSourceEnabled(id, enabled);
      const status = await getMarketplaceStore().refresh();
      applyMarketplaceToDesktop(status.catalog);
      return status;
    },
  );
  ipcMain.handle("marketplace:setSourceUrl", async (_e, id: string, url: string) => {
    getMarketplaceStore().setSourceUrl(id, url);
    const status = await getMarketplaceStore().refresh();
    applyMarketplaceToDesktop(status.catalog);
    return status;
  });

  // --- On-device Metal ----------------------------------------------------
  const metalDownloadControllers = new Map<string, AbortController>();

  ipcMain.handle("metal:status", async () => getMetalRuntimeStatus());
  ipcMain.handle("metal:catalog", async () => getMetalStore().catalogWithStatus());
  ipcMain.handle("metal:storage", async () => ({
    bytes: getMetalStore().totalStorageBytes(),
    root: getMetalStore().root,
    count: getMetalStore().listDownloaded().length,
  }));
  ipcMain.handle("metal:download", async (event, hubID: string) => {
    if (typeof hubID !== "string" || !hubID.includes("/")) {
      throw new Error("Invalid model hub id");
    }
    const controller = new AbortController();
    metalDownloadControllers.set(hubID, controller);
    try {
      return await getMetalStore().download(hubID, (p) => {
        event.sender.send("metal:downloadProgress", p);
      }, controller.signal);
    } finally {
      metalDownloadControllers.delete(hubID);
    }
  });
  ipcMain.handle("metal:cancel", async (_e, hubID: string) => {
    const controller = metalDownloadControllers.get(hubID);
    if (controller) {
      controller.abort();
      metalDownloadControllers.delete(hubID);
      return { ok: true as const, cancelled: true };
    }
    return { ok: true as const, cancelled: false };
  });
  ipcMain.handle("metal:delete", async (_e, hubID: string) => {
    getMetalStore().delete(hubID);
    return { ok: true as const };
  });
  ipcMain.handle("metal:deleteAll", async () => {
    const removed = getMetalStore().deleteAll();
    return { ok: true as const, removed };
  });
  ipcMain.handle("metal:openDir", async () => {
    const root = getMetalStore().root;
    mkdirSync(root, { recursive: true });
    await shell.openPath(root);
    return { ok: true as const, path: root };
  });
  ipcMain.handle(
    "metal:generate",
    async (
      _e,
      req: {
        hubID: string;
        messages: Array<{ role: "user" | "assistant" | "system"; content: string }>;
        maxTokens?: number;
      },
    ) => metalGenerate(req),
  );
  /** One-click Python + mlx-lm install into product metal-runtime dir */
  ipcMain.handle("metal:installRuntime", async (event) => {
    const sendLog = (line: string) => {
      event.sender.send("metal:installLog", { line });
    };
    try {
      sendLog("Starting Metal runtime install (Python + mlx-lm)…");
      const result = await installMetalRuntime(sendLog);
      resetMetalPythonCache();
      event.sender.send("metal:installDone", result);
      return result;
    } catch (err) {
      const message = String((err as Error).message ?? err);
      sendLog(`Error: ${message}`);
      const fail = {
        ok: false as const,
        pythonPath: null,
        detail: message,
        error: message,
      };
      event.sender.send("metal:installDone", fail);
      return fail;
    }
  });

  // --- Lightweight Tasks / Apple Foundation (macOS) ----------------------
  ipcMain.handle("lightweight:foundationStatus", async () => {
    await ensureFoundationCliBuilt();
    return getFoundationStatus();
  });
  ipcMain.handle(
    "lightweight:foundationGenerate",
    async (
      _e,
      req: { system?: string; user: string; maxTokens?: number },
    ) => {
      if (!req || typeof req.user !== "string") {
        return { ok: false as const, error: "Invalid request" };
      }
      return foundationGenerate({
        system: req.system,
        user: req.user,
        maxTokens: req.maxTokens,
      });
    },
  );
}

// --- Lifecycle. ----------------------------------------------------------
app.on("second-instance", () => showWindow());

/**
 * If port / leftover APC processes would block startup, ask the user to
 * quit them. Returns false when the user declines (caller should exit).
 */
async function promptKillConflictingInstances(port: number): Promise<boolean> {
  let conflicts = await findConflictingProcesses(port);
  if (conflicts.length === 0) return true;

  const result = await dialog.showMessageBox({
    type: "warning",
    buttons: ["Quit other instances", "Cancel"],
    defaultId: 0,
    cancelId: 1,
    title: "Another RoamSocket is running",
    message: "Quit other RoamSocket processes?",
    detail: formatConflictDetail(conflicts, port),
    noLink: true,
  });

  if (result.response !== 0) return false;

  console.log(
    `[apc] killing conflicting processes: ${conflicts.map((c) => c.pid).join(", ")}`,
  );
  await killProcesses(conflicts.map((c) => c.pid));

  // Second pass: port still held by something we didn't map (rare).
  if (await isPortHeld(port)) {
    conflicts = await findConflictingProcesses(port);
    if (conflicts.length > 0) {
      await killProcesses(conflicts.map((c) => c.pid));
    }
  }

  if (await isPortHeld(port)) {
    dialog.showErrorBox(
      "Could not free port",
      `Port ${port} is still in use after quitting other instances.\n\n` +
      `Quit the process manually (Activity Monitor / Task Manager) or set PORT to a free port and relaunch.`,
    );
    return false;
  }

  return true;
}

app.whenReady().then(async () => {
  loadPrefs();
  loadSecrets();
  // App-managed tunnel binaries (cloudflared / ngrok) live under userData/bin
  // so installs work without admin and are found by the tunnel spawner.
  process.env.APC_BIN_DIR = path.join(app.getPath("userData"), "bin");
  registerIpc();

  // Apply last-known marketplace merge immediately, then refresh remotes.
  try {
    applyMarketplaceToDesktop(getMarketplaceStore().getCatalog());
  } catch {
    /* ignore */
  }
  void getMarketplaceStore()
    .refresh()
    .then((status) => applyMarketplaceToDesktop(status.catalog))
    .catch(() => {
      /* offline — keep bundled / cache */
    });

  const port = Number(process.env.PORT ?? 4319);
  // Bind all interfaces so phones on the LAN can pair; override with APC_HOST.
  const host = process.env.APC_HOST ?? "0.0.0.0";

  const canStart = await promptKillConflictingInstances(port);
  if (!canStart) {
    isQuitting = true;
    app.quit();
    return;
  }

  try {
    server = await startServer({
      port,
      host,
      silent: true,
      onReady: () => refreshTrayMenu(),
    });
    console.log(`[apc] server listening on http://${server.host}:${server.port}, code=${server.pairingCode}`);
  } catch (err) {
    const message = String((err as Error).message ?? err);
    console.error("[apc] server failed to start:", err);

    // Race: something bound the port between our scan and listen. Offer one more kill.
    if (message.includes("already in use") || message.includes("EADDRINUSE")) {
      const retry = await promptKillConflictingInstances(port);
      if (retry) {
        try {
          server = await startServer({
            port,
            host,
            silent: true,
            onReady: () => refreshTrayMenu(),
          });
          console.log(
            `[apc] server listening on http://${server.host}:${server.port}, code=${server.pairingCode}`,
          );
        } catch (err2) {
          dialog.showErrorBox("Server failed to start", String((err2 as Error).message ?? err2));
          isQuitting = true;
          app.quit();
          return;
        }
      } else {
        isQuitting = true;
        app.quit();
        return;
      }
    } else {
      dialog.showErrorBox("Server failed to start", message);
      isQuitting = true;
      app.quit();
      return;
    }
  }

  createTray();
  createWindow();
  console.log("[apc] tray + window created");

  // Verification hook: dump shell DOM after renderer bootstrap, then optional quit.
  if (process.env.APC_DOM_DUMP === "1" && mainWindow) {
    // Avoid pairing popup covering / racing the dump window.
    prefs.showPairingCodePopup = false;
    const win = mainWindow;
    let dumped = false;
    const dump = async (reason: string) => {
      if (dumped) return;
      try {
        // Wait for renderer main() to paint chat empty state / nav.
        await new Promise((r) => setTimeout(r, 1500));
        if (win.isDestroyed()) return;
        const snapshot = await win.webContents.executeJavaScript(`
          (() => {
            const nav = Array.from(document.querySelectorAll('#main-nav .nav-item, .nav-item[data-route]'))
              .map((a) => ({
                route: a.getAttribute('data-route'),
                text: (a.textContent || '').replace(/\\s+/g, ' ').trim(),
                active: a.classList.contains('active'),
              }));
            const viewChats = document.getElementById('view-chats');
            const greeting = viewChats?.querySelector('.greeting')?.textContent?.trim() || null;
            const empty = !!viewChats?.querySelector('.chat-empty');
            const composer = !!document.getElementById('chat-input');
            const views = ['chats','projects','artifacts','code','settings'].map((id) => ({
              id,
              hidden: document.getElementById('view-' + id)?.classList.contains('hidden') ?? true,
            }));
            const hasVisionNav = nav.some((n) => n.route === 'vision' || /vision/i.test(n.text || ''));
            return {
              ok: true,
              reason: ${JSON.stringify("PLACEHOLDER")},
              href: location.href,
              title: document.title,
              bodyLen: (document.body && document.body.innerHTML) ? document.body.innerHTML.length : 0,
              nav,
              hasVisionNav,
              greeting,
              emptyHome: empty,
              composer,
              views,
              topbar: document.getElementById('topbar-title')?.textContent?.trim() || null,
              appPresent: !!document.getElementById('app'),
              sidebarPresent: !!document.getElementById('sidebar'),
            };
          })()
        `.replace('"PLACEHOLDER"', JSON.stringify(reason)));
        dumped = true;
        console.log("[apc] DOM_SNAPSHOT " + JSON.stringify(snapshot));
      } catch (err) {
        console.error("[apc] DOM_SNAPSHOT_ERROR " + String((err as Error).message ?? err));
      } finally {
        if (dumped && process.env.APC_DOM_DUMP_QUIT === "1") {
          isQuitting = true;
          app.quit();
        }
      }
    };
    win.webContents.on("did-finish-load", () => {
      console.log("[apc] did-finish-load " + win.webContents.getURL());
      void dump("did-finish-load");
    });
    win.webContents.on("did-fail-load", (_e, code, desc, url) => {
      console.error(`[apc] did-fail-load ${code} ${desc} ${url}`);
    });
    // Fallback if load events were missed
    setTimeout(() => void dump("timeout"), 4000);
  }

  // Apple-style verification code popup on launch.
  if (server?.pairingCode && prefs.showPairingCodePopup) {
    showPairingCodeWindow(server.pairingCode);
  }

  // Auto-start remote-access tunnel when the user left it enabled.
  if (prefs.remoteAccessEnabled || prefs.autoTunnelOnPair === false) {
    /* remoteAccessEnabled alone drives always-on tunnel */
  }
  if (prefs.remoteAccessEnabled) {
    void ensureRemoteAccessTunnel().then((info) => {
      console.log(`[apc] remote access: ${info?.url ?? "(starting)"}`);
    });
  }
}).catch((err) => {
  console.error("[apc] whenReady chain failed:", err);
});

/** Expose the coding server port through the preferred tunnel provider. */
async function ensureRemoteAccessTunnel(): Promise<{
  enabled: boolean;
  url: string;
  provider: string;
  live: TunnelInfo | null;
}> {
  const port = server?.port;
  if (!port) {
    return { enabled: prefs.remoteAccessEnabled, url: prefs.remoteAccessUrl, provider: prefs.remoteAccessProvider, live: null };
  }
  // Shared singleton with the headless auto-tunnel path so we don't spawn two.
  const { ensureAccessTunnel, currentAccessTunnel, accessTunnelId } = await import(
    "../workspace/access-tunnel.js"
  );
  const started = await ensureAccessTunnel({
    port,
    provider: prefs.remoteAccessProvider ?? "auto",
  });
  remoteAccessTunnelId = accessTunnelId() ?? started.id;
  if (started.url) {
    prefs.remoteAccessUrl = started.url;
    savePrefs();
  }
  return {
    enabled: true,
    url: started.url ?? prefs.remoteAccessUrl,
    provider: started.provider,
    live: currentAccessTunnel() ?? started,
  };
}

app.on("window-all-closed", () => {
  // Keep running in tray on every platform; explicit Quit ends the process.
  if (isQuitting && process.platform !== "darwin") app.quit();
});

app.on("before-quit", async () => {
  isQuitting = true;
  await server?.close().catch(() => undefined);
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
  else showWindow();
});
