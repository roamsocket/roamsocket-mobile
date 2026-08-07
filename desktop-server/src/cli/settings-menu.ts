/**
 * Interactive CLI settings for headless mode (`npm start` on a TTY).
 * Covers the same permission / connection controls as the Electron settings UI.
 */
import * as readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import {
  loadDesktopPrefs,
  saveDesktopPrefs,
  type DesktopPrefs,
  type TunnelProviderPref,
  desktopPrefsPath,
} from "../desktop-config.js";
import { printPairingCodeOnly } from "./banner.js";

export interface CliSettingsContext {
  getPairingCode: () => string;
  getPairHost: () => string;
  rotateCode?: () => string;
  getServerInfo: () => { host: string; port: number; name: string };
}

function yn(v: boolean): string {
  return v ? "on" : "off";
}

export async function runSettingsMenu(ctx: CliSettingsContext): Promise<void> {
  if (!input.isTTY || !output.isTTY) return;

  const rl = readline.createInterface({ input, output });
  let prefs = loadDesktopPrefs();

  const printMenu = () => {
    const info = ctx.getServerInfo();
    console.log(`
── RoamSocket settings ─────────────────────────────
  Config file: ${desktopPrefsPath()}
  Server: ${info.name}  http://${info.host}:${info.port}
  Pairing code: ${ctx.getPairingCode()}
  Pair URL: ${ctx.getPairHost()}

  [1]  LAN discovery (Bonjour) ........ ${yn(prefs.allowLanDiscovery)}
  [2]  Auto tunnel after pair ......... ${yn(prefs.autoTunnelOnPair)}
  [3]  Tunnel provider ................ ${prefs.tunnelProvider}
  [4]  Show pairing code on start ..... ${yn(prefs.showPairingCodePopup)}
  [5]  Rotate code after pair ......... ${yn(prefs.rotateCodeAfterPair)}
  [6]  Show pairing code + QR now
  [7]  Rotate pairing code now
  [8]  Reload prefs from disk
  [h]  Help
  [q]  Quit menu (server keeps running)
──────────────────────────────────────────────────────
`);
  };

  printMenu();
  console.log("Type a number (or q) and press Enter. Server stays online.\n");

  const loop = async (): Promise<void> => {
    while (true) {
      let answer: string;
      try {
        answer = (await rl.question("settings> ")).trim().toLowerCase();
      } catch {
        break;
      }
      if (!answer) continue;
      if (answer === "q" || answer === "quit" || answer === "exit") break;
      if (answer === "h" || answer === "help" || answer === "?") {
        console.log(`
Permissions:
  LAN discovery — phones can find this desktop on the same Wi‑Fi.
  Auto tunnel   — after pair, open Cloudflare/ngrok/localtunnel so the
                  phone can leave the network without re-pairing.
  Pairing popup — print a large verification-style code (and QR) on start.

Changes apply to the next pair / reconnect where noted. Auto tunnel and
LAN discovery take effect for new connections immediately via env prefs.
`);
        continue;
      }

      switch (answer) {
        case "1":
          prefs.allowLanDiscovery = !prefs.allowLanDiscovery;
          saveDesktopPrefs(prefs);
          console.log(`LAN discovery → ${yn(prefs.allowLanDiscovery)} (restart server to re-advertise)`);
          break;
        case "2":
          prefs.autoTunnelOnPair = !prefs.autoTunnelOnPair;
          saveDesktopPrefs(prefs);
          console.log(`Auto tunnel after pair → ${yn(prefs.autoTunnelOnPair)}`);
          break;
        case "3": {
          const order: TunnelProviderPref[] = ["auto", "cloudflare", "ngrok", "localtunnel", "bore"];
          const i = order.indexOf(prefs.tunnelProvider);
          prefs.tunnelProvider = order[(i + 1) % order.length]!;
          saveDesktopPrefs(prefs);
          console.log(`Tunnel provider → ${prefs.tunnelProvider}`);
          break;
        }
        case "4":
          prefs.showPairingCodePopup = !prefs.showPairingCodePopup;
          saveDesktopPrefs(prefs);
          console.log(`Show pairing code on start → ${yn(prefs.showPairingCodePopup)}`);
          break;
        case "5":
          prefs.rotateCodeAfterPair = !prefs.rotateCodeAfterPair;
          saveDesktopPrefs(prefs);
          console.log(`Rotate code after pair → ${yn(prefs.rotateCodeAfterPair)}`);
          break;
        case "6":
          await printPairingCodeOnly(ctx.getPairingCode(), ctx.getPairHost());
          break;
        case "7":
          if (ctx.rotateCode) {
            const code = ctx.rotateCode();
            console.log(`New pairing code: ${code}`);
            await printPairingCodeOnly(code, ctx.getPairHost());
          } else {
            console.log("Rotate not available.");
          }
          break;
        case "8":
          prefs = loadDesktopPrefs();
          printMenu();
          break;
        case "m":
        case "menu":
          printMenu();
          break;
        default:
          console.log("Unknown command. Type h for help, m for menu, q to leave.");
      }
    }
    rl.close();
    console.log("Settings menu closed. Server still running.\n");
  };

  // Don't block startServer's return — run menu in background.
  void loop();
}

export function summarizePrefs(prefs: DesktopPrefs): string {
  return [
    `lan-discovery=${prefs.allowLanDiscovery ? "on" : "off"}`,
    `auto-tunnel=${prefs.autoTunnelOnPair ? "on" : "off"}`,
    `provider=${prefs.tunnelProvider}`,
  ].join(" ");
}
