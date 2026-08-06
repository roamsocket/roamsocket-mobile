/**
 * Shared desktop preferences for headless CLI + Electron.
 * Stored at ~/.anyprov-code/desktop-prefs.json (Electron may also keep a
 * copy under userData for window/tray prefs).
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export type TunnelProviderPref = "auto" | "ngrok" | "cloudflare" | "localtunnel" | "bore";

export interface DesktopPrefs {
  /** Advertise on LAN via Bonjour so phones can discover this machine. */
  allowLanDiscovery: boolean;
  /**
   * After a phone pairs, automatically open a public tunnel (Cloudflare /
   * ngrok / …) and push the HTTPS URL so the session survives leaving Wi‑Fi.
   */
  autoTunnelOnPair: boolean;
  /** Preferred tunnel provider when auto-tunnel or remote access runs. */
  tunnelProvider: TunnelProviderPref;
  /** Show the large pairing-code popup (Electron) / banner (CLI) on start. */
  showPairingCodePopup: boolean;
  /** Rotate pairing code after a successful pair. */
  rotateCodeAfterPair: boolean;
  /** Persist last public tunnel URL (informational). */
  remoteAccessUrl: string;
  /** User explicitly enabled always-on remote tunnel (Electron remote access). */
  remoteAccessEnabled: boolean;
}

export const DEFAULT_DESKTOP_PREFS: DesktopPrefs = {
  allowLanDiscovery: true,
  autoTunnelOnPair: true,
  tunnelProvider: "auto",
  showPairingCodePopup: true,
  rotateCodeAfterPair: false,
  remoteAccessUrl: "",
  remoteAccessEnabled: false,
};

function configDir(): string {
  return path.join(os.homedir(), ".anyprov-code");
}

export function desktopPrefsPath(): string {
  return path.join(configDir(), "desktop-prefs.json");
}

export function loadDesktopPrefs(): DesktopPrefs {
  try {
    const p = desktopPrefsPath();
    if (!existsSync(p)) return { ...DEFAULT_DESKTOP_PREFS };
    const parsed = JSON.parse(readFileSync(p, "utf8")) as Partial<DesktopPrefs>;
    return { ...DEFAULT_DESKTOP_PREFS, ...parsed };
  } catch {
    return { ...DEFAULT_DESKTOP_PREFS };
  }
}

export function saveDesktopPrefs(prefs: DesktopPrefs): void {
  try {
    const dir = configDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(desktopPrefsPath(), JSON.stringify(prefs, null, 2));
  } catch {
    // best effort
  }
}

export function updateDesktopPrefs(patch: Partial<DesktopPrefs>): DesktopPrefs {
  const next = { ...loadDesktopPrefs(), ...patch };
  saveDesktopPrefs(next);
  return next;
}

/** Env overrides win for CI/smoke; otherwise use saved prefs. */
export function resolveAdvertise(prefs: DesktopPrefs, explicit?: boolean): boolean {
  if (explicit !== undefined) return explicit;
  if (process.env.APC_ADVERTISE === "0" || process.env.APC_ADVERTISE === "false") return false;
  if (process.env.APC_ADVERTISE === "1" || process.env.APC_ADVERTISE === "true") return true;
  return prefs.allowLanDiscovery;
}

export function resolveAutoTunnel(prefs: DesktopPrefs, explicit?: boolean): boolean {
  if (explicit !== undefined) return explicit;
  if (process.env.APC_AUTO_TUNNEL === "0" || process.env.APC_AUTO_TUNNEL === "false") return false;
  if (process.env.APC_AUTO_TUNNEL === "1" || process.env.APC_AUTO_TUNNEL === "true") return true;
  return prefs.autoTunnelOnPair;
}
