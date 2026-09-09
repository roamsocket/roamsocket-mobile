import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
/**
 * Persistent storage for the user's e2b.dev API key on the desktop.
 *
 * Backed by Electron `safeStorage` when available (the OS protects the
 * encryption key with the user's login keychain/DPAPI). When
 * `safeStorage.isEncryptionAvailable()` is false (e.g. Linux without
 * a keyring) we fall back to a plain-text file under the product data
 * dir — same trade-off the renderer-side `desktop-prefs.ts` makes for
 * non-secret prefs. The key is never sent to the desktop-server
 * WebSocket: it stays in the main process and is read only when the
 * renderer asks for an E2B action.
 */
import { app, safeStorage } from 'electron';
import { validateE2BKey } from './direct-e2b-client.js';

const FILE_NAME = 'e2b-api-key.bin';

export interface E2BKeyStatus {
  hasKey: boolean;
  /** `true` when safeStorage encrypted the key; `false` for the plain-text fallback. */
  encrypted: boolean;
  /** Validation result, populated when the user just set a key. */
  validation?: { ok: true } | { ok: false; reason: string };
}

function keyPath(): string {
  // `app.getPath('userData')` is stable per-product and per-user.
  return `${app.getPath('userData')}/${FILE_NAME}`;
}

export function readE2BKey(): string | null {
  const path = keyPath();
  if (!existsSync(path)) return null;
  const buf = readFileSync(path);
  if (buf.length === 0) return null;
  if (safeStorage.isEncryptionAvailable()) {
    try {
      return safeStorage.decryptString(buf).trim() || null;
    } catch {
      // Fall through and try the plain-text branch (could be a key
      // written by an older build that didn't have safeStorage).
    }
  }
  return buf.toString('utf8').trim() || null;
}

export function writeE2BKey(value: string): E2BKeyStatus {
  const trimmed = (value ?? '').trim();
  const validation = validateE2BKey(trimmed);
  if (!validation.ok) {
    return { hasKey: false, encrypted: false, validation };
  }
  const path = keyPath();
  mkdirSync(dirname(path), { recursive: true });
  if (safeStorage.isEncryptionAvailable()) {
    writeFileSync(path, safeStorage.encryptString(trimmed));
  } else {
    // Plain-text fallback. Mode 0600 — same as the iOS / server-side
    // cli-secrets.json pattern.
    writeFileSync(path, trimmed, { mode: 0o600 });
  }
  return { hasKey: true, encrypted: safeStorage.isEncryptionAvailable(), validation };
}

export function clearE2BKey(): void {
  const path = keyPath();
  if (existsSync(path)) {
    try {
      writeFileSync(path, '');
    } catch {
      /* ignore */
    }
  }
}

export function e2bKeyStatus(): E2BKeyStatus {
  const key = readE2BKey();
  return { hasKey: !!key, encrypted: safeStorage.isEncryptionAvailable() };
}
