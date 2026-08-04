/**
 * Pairing: the server prints a short code; the app posts it to `/pair` and
 * receives a bearer token used to authenticate the WebSocket connection.
 *
 * This is intentionally simple and local-network oriented: the code is a
 * shared secret proven over the LAN. Tokens are held in memory for the life
 * of the process.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";

export interface PairedDevice {
  token: string;
  deviceName: string;
  pairedAt: number;
}

function randomCode(): string {
  // 6 digits, easy to type on a phone.
  return String(randomBytes(4).readUInt32BE(0) % 1_000_000).padStart(6, "0");
}

function randomToken(): string {
  return randomBytes(32).toString("hex");
}

/** Constant-time string comparison to avoid leaking the code via timing. */
function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export class PairingManager {
  private code: string;
  private readonly tokens = new Map<string, PairedDevice>();

  constructor() {
    this.code = randomCode();
  }

  /** The current pairing code (shown in the console / QR). */
  get pairingCode(): string {
    return this.code;
  }

  /** Rotate the pairing code (e.g. after a successful pair, if desired). */
  rotateCode(): string {
    this.code = randomCode();
    return this.code;
  }

  /** Exchange a pairing code for a bearer token. Returns null on mismatch. */
  pair(code: string, deviceName: string): PairedDevice | null {
    if (!safeEqual(code.trim(), this.code)) return null;
    const device: PairedDevice = {
      token: randomToken(),
      deviceName,
      pairedAt: Date.now(),
    };
    this.tokens.set(device.token, device);
    return device;
  }

  /** Validate a bearer token presented on the WebSocket. */
  verify(token: string | undefined | null): PairedDevice | null {
    if (!token) return null;
    return this.tokens.get(token) ?? null;
  }

  revoke(token: string): void {
    this.tokens.delete(token);
  }
}
