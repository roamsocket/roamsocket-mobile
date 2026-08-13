/**
 * Terminal pairing banner: large digits (Apple-verification style) + ASCII QR.
 */
import QRCode from 'qrcode';
import { lanIPv4Addresses } from '../discovery.js';

export interface PairBannerInfo {
  serverName: string;
  version: string;
  host: string;
  port: number;
  pairingCode: string;
  mock?: boolean;
  advertise?: boolean;
  autoTunnel?: boolean;
  /** Public tunnel URL (https://…) when already known at print time. */
  publicUrl?: string | null;
  /** Local proxy base URL (`http://127.0.0.1:<port>`) for external CLIs. */
  proxyBaseUrl?: string;
  /** Static bearer for /v1/* — random per-process unless APC_PROXY_TOKEN is set. */
  proxyToken?: string;
}

export interface TunnelReadyInfo {
  url: string;
  provider: string;
  pairingCode: string;
}

/** Last tunnel URL we printed a full QR for (avoids duplicate banners). */
let lastPrintedTunnelUrl: string | null = null;

/** Build the JSON payload encoded in the QR (scanned by the iOS app). */
export function pairPayload(
  host: string,
  port: number,
  code: string,
  publicUrl?: string | null
): { host: string; code: string } {
  const digits = code.replace(/\D/g, '').padStart(6, '0').slice(0, 6);
  const tunnel = normalizePublicUrl(publicUrl);
  if (tunnel) {
    return { host: tunnel, code: digits };
  }
  const lan = lanIPv4Addresses();
  const display =
    host === '0.0.0.0' || host === '::' || host === '127.0.0.1' ? (lan[0] ?? '127.0.0.1') : host;
  return { host: `http://${display}:${port}`, code: digits };
}

/** Prefer a live public tunnel URL when building pair payloads / QR hosts. */
export function resolvePairHost(host: string, port: number, publicUrl?: string | null): string {
  return pairPayload(host, port, '000000', publicUrl).host;
}

function normalizePublicUrl(url?: string | null): string | null {
  if (!url) return null;
  const trimmed = url.trim().replace(/\/+$/, '');
  if (!trimmed) return null;
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return `https://${trimmed}`;
}

function boxLine(width: number, char = '─'): string {
  return char.repeat(width);
}

async function printQr(payloadJson: string, intro: string): Promise<void> {
  try {
    const qr = await QRCode.toString(payloadJson, {
      type: 'terminal',
      small: true,
      errorCorrectionLevel: 'M',
    });
    console.log(`${intro}\n`);
    console.log(qr);
  } catch (err) {
    console.log(`QR unavailable (${(err as Error).message}). Payload: ${payloadJson}`);
  }
  console.log(`Payload: ${payloadJson}`);
  console.log('');
}

/** Print a verification-style code card + QR to stdout. */
export async function printPairingBanner(info: PairBannerInfo): Promise<void> {
  const payload = pairPayload(info.host, info.port, info.pairingCode, info.publicUrl);
  const payloadJson = JSON.stringify(payload);
  const digits = info.pairingCode.replace(/\D/g, '').padStart(6, '0').slice(0, 6);
  const spaced = digits.split('').join('  ');
  const usingTunnel = Boolean(normalizePublicUrl(info.publicUrl));

  const width = 44;
  const lines: string[] = [];
  lines.push('');
  lines.push(`┌${boxLine(width)}┐`);
  lines.push(
    `│${'RoamSocket — Pairing code'.padStart(Math.floor((width + 26) / 2)).padEnd(width)}│`
  );
  lines.push(`│${''.padEnd(width)}│`);
  lines.push(`│${spaced.padStart(Math.floor((width + spaced.length) / 2)).padEnd(width)}│`);
  lines.push(`│${''.padEnd(width)}│`);
  lines.push(
    `│${'Enter this code on your phone'.padStart(Math.floor((width + 28) / 2)).padEnd(width)}│`
  );
  lines.push(`│${'(or scan the QR below)'.padStart(Math.floor((width + 22) / 2)).padEnd(width)}│`);
  lines.push(`└${boxLine(width)}┘`);
  lines.push('');
  lines.push(`${info.serverName} v${info.version}`);
  lines.push(`Listening: http://${info.host}:${info.port}`);
  const lan = lanIPv4Addresses();
  if (lan.length > 0) {
    lines.push(`LAN: ${lan.map((ip) => `http://${ip}:${info.port}`).join(', ')}`);
  }
  if (usingTunnel) {
    lines.push(`Tunnel URL: ${payload.host}`);
    if (info.publicUrl && normalizePublicUrl(info.publicUrl) === payload.host) {
      lastPrintedTunnelUrl = payload.host;
    }
  }
  lines.push(`Pair URL: ${payload.host}`);
  // Keep this exact prefix for smoke tests / log scrapers.
  lines.push(`Pairing code: ${digits}${info.mock ? "  (MOCK agent)" : ""}`);
  if (info.proxyBaseUrl) {
    // External CLIs (Codex / Claude Code / Aider / Cursor / OpenCode) point at this.
    lines.push(`Proxy:      ${info.proxyBaseUrl}/v1`);
    if (info.proxyToken) lines.push(`Proxy key:  ${info.proxyToken}`);
    lines.push(`Launch one: roamsocket open codex|claude|aider|cursor|opencode`);
  }
  if (info.advertise) lines.push("Discovery: Bonjour _roamsocket._tcp");
  if (info.autoTunnel && !usingTunnel) {
    lines.push('Auto tunnel: on (public URL + QR update when ready)');
  } else if (info.autoTunnel && usingTunnel) {
    lines.push('Auto tunnel: on (QR uses public tunnel URL)');
  }
  lines.push('');

  console.log(lines.join('\n'));

  await printQr(
    payloadJson,
    usingTunnel
      ? 'Scan with RoamSocket → Pair server → Scan QR (tunnel URL):'
      : 'Scan with RoamSocket → Pair server → Scan QR:'
  );
}

/**
 * Print the public tunnel URL once it is live, and re-emit the pairing QR
 * so the phone scans the HTTPS endpoint instead of the LAN address.
 */
export async function printTunnelReadyBanner(info: TunnelReadyInfo): Promise<void> {
  const url = normalizePublicUrl(info.url);
  if (!url) return;

  if (lastPrintedTunnelUrl === url) {
    // Same URL already shown with a QR — still log a one-liner for scrapers.
    console.log(`[apc] access tunnel ready: ${url} (${info.provider})`);
    return;
  }
  lastPrintedTunnelUrl = url;

  const digits = info.pairingCode.replace(/\D/g, '').padStart(6, '0').slice(0, 6);
  const payload = { host: url, code: digits };
  const payloadJson = JSON.stringify(payload);

  console.log('');
  console.log('════════════════════════════════════════════════════');
  console.log('  Public tunnel ready');
  console.log(`  Tunnel URL: ${url}`);
  console.log(`  Provider:   ${info.provider}`);
  console.log(`  Pairing:    ${digits.split('').join(' ')}`);
  console.log('  QR below encodes this tunnel URL (not LAN).');
  console.log('════════════════════════════════════════════════════');
  // Stable log line for scrapers / Electron log viewers.
  console.log(`[apc] access tunnel ready: ${url} (${info.provider})`);
  console.log('');

  await printQr(payloadJson, 'Scan with RoamSocket → Pair server → Scan QR (public tunnel):');
}

/** Compact re-print of code + QR (e.g. after rotating code or from settings). */
export async function printPairingCodeOnly(code: string, pairHost: string): Promise<void> {
  const digits = code.replace(/\D/g, '').padStart(6, '0').slice(0, 6);
  const host = normalizePublicUrl(pairHost) ?? pairHost.trim();
  const isTunnel = /^https:\/\//i.test(host);
  console.log(`\n  ★ Pairing code:  ${digits.split('').join(' ')}`);
  console.log(`  ★ Pair URL:      ${host}${isTunnel ? '  (tunnel)' : ''}\n`);
  if (isTunnel) {
    lastPrintedTunnelUrl = host.replace(/\/+$/, '');
  }
  try {
    const qr = await QRCode.toString(JSON.stringify({ host, code: digits }), {
      type: 'terminal',
      small: true,
      errorCorrectionLevel: 'M',
    });
    console.log(qr);
    console.log(`Payload: ${JSON.stringify({ host, code: digits })}\n`);
  } catch {
    /* ignore */
  }
}

/** Reset print cache (tests). */
export function resetTunnelBannerCache(): void {
  lastPrintedTunnelUrl = null;
}
