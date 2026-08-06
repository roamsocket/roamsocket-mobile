/**
 * Terminal pairing banner: large digits (Apple-verification style) + ASCII QR.
 */
import QRCode from "qrcode";
import { lanIPv4Addresses } from "../discovery.js";

export interface PairBannerInfo {
  serverName: string;
  version: string;
  host: string;
  port: number;
  pairingCode: string;
  mock?: boolean;
  advertise?: boolean;
  autoTunnel?: boolean;
}

/** Build the JSON payload encoded in the QR (scanned by the iOS app). */
export function pairPayload(host: string, port: number, code: string): { host: string; code: string } {
  const lan = lanIPv4Addresses();
  const display =
    host === "0.0.0.0" || host === "::" || host === "127.0.0.1"
      ? lan[0] ?? "127.0.0.1"
      : host;
  return { host: `http://${display}:${port}`, code };
}

function boxLine(width: number, char = "─"): string {
  return char.repeat(width);
}

/** Print a verification-style code card + QR to stdout. */
export async function printPairingBanner(info: PairBannerInfo): Promise<void> {
  const payload = pairPayload(info.host, info.port, info.pairingCode);
  const payloadJson = JSON.stringify(payload);
  const digits = info.pairingCode.replace(/\D/g, "").padStart(6, "0").slice(0, 6);
  const spaced = digits.split("").join("  ");

  const width = 44;
  const lines: string[] = [];
  lines.push("");
  lines.push(`┌${boxLine(width)}┐`);
  lines.push(`│${"AnyProv Code — Pairing code".padStart(Math.floor((width + 26) / 2)).padEnd(width)}│`);
  lines.push(`│${"".padEnd(width)}│`);
  lines.push(`│${spaced.padStart(Math.floor((width + spaced.length) / 2)).padEnd(width)}│`);
  lines.push(`│${"".padEnd(width)}│`);
  lines.push(`│${"Enter this code on your phone".padStart(Math.floor((width + 28) / 2)).padEnd(width)}│`);
  lines.push(`│${"(or scan the QR below)".padStart(Math.floor((width + 22) / 2)).padEnd(width)}│`);
  lines.push(`└${boxLine(width)}┘`);
  lines.push("");
  lines.push(`${info.serverName} v${info.version}`);
  lines.push(`Listening: http://${info.host}:${info.port}`);
  const lan = lanIPv4Addresses();
  if (lan.length > 0) {
    lines.push(`LAN: ${lan.map((ip) => `http://${ip}:${info.port}`).join(", ")}`);
  }
  lines.push(`Pair URL: ${payload.host}`);
  // Keep this exact prefix for smoke tests / log scrapers.
  lines.push(`Pairing code: ${digits}${info.mock ? "  (MOCK agent)" : ""}`);
  if (info.advertise) lines.push("Discovery: Bonjour _anyprov-code._tcp");
  if (info.autoTunnel) lines.push("Auto tunnel: on (public URL after pair)");
  lines.push("");

  console.log(lines.join("\n"));

  try {
    const qr = await QRCode.toString(payloadJson, {
      type: "terminal",
      small: true,
      errorCorrectionLevel: "M",
    });
    console.log("Scan with AnyProv Code → Pair server → Scan QR:\n");
    console.log(qr);
  } catch (err) {
    console.log(`QR unavailable (${(err as Error).message}). Payload: ${payloadJson}`);
  }

  console.log(`Payload: ${payloadJson}`);
  console.log("");
}

/** Compact one-line re-print (e.g. after rotating code). */
export async function printPairingCodeOnly(code: string, pairHost: string): Promise<void> {
  const digits = code.replace(/\D/g, "").padStart(6, "0").slice(0, 6);
  console.log(`\n  ★ Pairing code:  ${digits.split("").join(" ")}\n`);
  try {
    const qr = await QRCode.toString(JSON.stringify({ host: pairHost, code: digits }), {
      type: "terminal",
      small: true,
    });
    console.log(qr);
  } catch {
    /* ignore */
  }
}
