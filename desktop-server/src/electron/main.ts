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
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { startServer, type RunningServer } from "../index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// --- Single-instance lock so two launches don't fight for port 4319. -----
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
  process.exit(0);
}

// --- Persisted UI prefs. Stored next to userData, plain JSON. -------------
interface Prefs {
  /** First-close "always quit?" decision. Once decided, never asked again. */
  closeBehaviorDecided: boolean;
  /** True = quit app on window close; False = always hide to tray. */
  alwaysQuitOnClose: boolean;
  /** Whether the window starts hidden in the tray (auto-launched at login, etc). */
  startMinimized: boolean;
}
const DEFAULT_PREFS: Prefs = {
  closeBehaviorDecided: false,
  alwaysQuitOnClose: false,
  startMinimized: false,
};

let prefs: Prefs = { ...DEFAULT_PREFS };
let prefsPath = "";
function loadPrefs(): void {
  try {
    prefsPath = path.join(app.getPath("userData"), "prefs.json");
    if (existsSync(prefsPath)) {
      const raw = readFileSync(prefsPath, "utf8");
      const parsed = JSON.parse(raw);
      prefs = { ...DEFAULT_PREFS, ...parsed };
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
  /** User-defined OpenAI-compatible providers. */
  customProviders: CustomProvider[];
}
const DEFAULT_SECRETS: SecretPayload = {
  providerKeys: {},
  githubToken: "",
  lastServerAddress: "",
  lastRepo: null,
  modelPrefs: {},
  customProviders: [],
};

/** Wire-format mirror of `protocol.ts`'s `CustomProvider`. */
type CustomProvider = { id: string; label: string; baseUrl: string };

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
  customProviders: CustomProvider[];
} {
  return {
    providerKeys: Object.fromEntries(
      Object.entries(s.providerKeys).map(([k, v]) => [k, { present: !!v }]),
    ),
    githubTokenPresent: !!s.githubToken,
    lastServerAddress: s.lastServerAddress,
    lastRepo: s.lastRepo,
    modelPrefs: s.modelPrefs,
    customProviders: s.customProviders ?? [],
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
  tray.setToolTip("Code Mobile AI");
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
    },
    {
      label: server ? `  ${server.pairingCode}` : "  (not running)",
      enabled: false,
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
      label: "Quit Code Mobile AI",
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
      title: "Close Code Mobile AI?",
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
    title: "Code Mobile AI",
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
    console.error(`[cmai] renderer failed to load: ${validatedURL} — ${errorCode} ${errorDescription}`);
  });
  wc.on("render-process-gone", (_e, details) => {
    console.error(`[cmai] renderer process gone: reason=${details.reason} exitCode=${details.exitCode}`);
  });
  wc.on("preload-error", (_e, preloadPath, error) => {
    console.error(`[cmai] preload error in ${preloadPath}: ${(error as Error).message}`);
  });
  wc.on("console-message", (_e, level, message, line, source) => {
    const lvl = level >= 2 ? "error" : level === 1 ? "warn" : "log";
    console[level >= 2 ? "error" : "log"](`[cmai:renderer:${lvl}] ${message} (${source}:${line})`);
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  // Dev: Vite serves the renderer with HMR; the URL is injected as
  // MAIN_WINDOW_VITE_DEV_SERVER_URL by the Forge plugin. We retry a couple
  // of times if the dev server is still starting up — its URL is announced
  // slightly after our preload bundle, so the first attempt can race.
  // Prod: the bundled HTML lives at `.vite/renderer/main_window/index.html`.
  const devUrl = process.env["MAIN_WINDOW_VITE_DEV_SERVER_URL" as keyof NodeJS.ProcessEnv] as string | undefined;
  if (devUrl) {
    console.log(`[cmai] loading renderer from dev URL: ${devUrl}`);
    void loadWithRetry(mainWindow, devUrl, 5, 500);
  } else {
    const indexHtml = path.join(__dirname, "..", "renderer", "main_window", "index.html");
    console.log(`[cmai] loading renderer from bundled HTML: ${indexHtml}`);
    void mainWindow.loadFile(indexHtml).catch((err) => {
      console.error(`[cmai] loadFile failed: ${(err as Error).message}`);
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
      console.log(`[cmai] renderer loaded from ${url}`);
      return;
    } catch (err) {
      const last = i === attempts - 1;
      console.warn(
        `[cmai] renderer load attempt ${i + 1}/${attempts} failed: ${(err as Error).message}` +
        (last ? " (giving up)" : `, retrying in ${delayMs}ms`),
      );
      if (last) {
        // Final fallback: load the bundled HTML so the user isn't staring
        // at a blank window.
        const indexHtml = path.join(__dirname, "..", "renderer", "main_window", "index.html");
        await win.loadFile(indexHtml).catch(() => undefined);
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
    prefs,
    secretsAvailable: safeStorage.isEncryptionAvailable(),
  }));

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
  ipcMain.handle("secrets:addCustomProvider", (_e, custom: CustomProvider & { apiKey?: string }) => {
    if (!custom?.id || !custom?.label || !custom?.baseUrl) {
      throw new Error("Custom provider needs id, label, and baseUrl.");
    }
    const list = (secrets.customProviders ?? []).filter((c) => c.id !== custom.id);
    list.push({ id: custom.id, label: custom.label, baseUrl: custom.baseUrl });
    secrets.customProviders = list;
    if (custom.apiKey) {
      secrets.providerKeys[custom.id] = custom.apiKey;
    }
    saveSecrets();
    return redactSecrets(secrets);
  });
  ipcMain.handle("secrets:removeCustomProvider", (_e, id: string) => {
    secrets.customProviders = (secrets.customProviders ?? []).filter((c) => c.id !== id);
    delete secrets.providerKeys[id];
    saveSecrets();
    return redactSecrets(secrets);
  });
  ipcMain.handle("secrets:setCustomProviderKey", (_e, id: string, apiKey: string) => {
    secrets.providerKeys[id] = apiKey;
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

  ipcMain.handle("window:hide", () => hideWindow());
  ipcMain.handle("app:quit", () => {
    isQuitting = true;
    app.quit();
  });

  ipcMain.handle("prefs:set", (_e, next: Partial<Prefs>) => {
    const wasDecided = prefs.closeBehaviorDecided;
    const wasAlwaysQuit = prefs.alwaysQuitOnClose;
    prefs = { ...prefs, ...next };
    savePrefs();
    // If close behaviour flipped for the first time, mark it decided.
    if (!wasDecided && prefs.closeBehaviorDecided) {
      prefs.closeBehaviorDecided = true;
      savePrefs();
    }
    refreshTrayMenu();
    return { ...prefs, wasAlwaysQuit };
  });
}

// --- Lifecycle. ----------------------------------------------------------
app.on("second-instance", () => showWindow());

app.whenReady().then(async () => {
  loadPrefs();
  loadSecrets();
  registerIpc();

  try {
    server = await startServer({
      port: Number(process.env.PORT ?? 4319),
      host: process.env.CMAI_HOST ?? "127.0.0.1",
      silent: true,
      onReady: () => refreshTrayMenu(),
    });
    console.log(`[cmai] server listening on http://${server.host}:${server.port}, code=${server.pairingCode}`);
  } catch (err) {
    console.error("[cmai] server failed to start:", err);
    dialog.showErrorBox("Server failed to start", String((err as Error).message ?? err));
    app.quit();
    return;
  }

  createTray();
  createWindow();
  console.log("[cmai] tray + window created");
}).catch((err) => {
  console.error("[cmai] whenReady chain failed:", err);
});

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
