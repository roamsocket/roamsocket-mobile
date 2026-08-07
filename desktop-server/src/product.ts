/**
 * Canonical product identity for the desktop companion.
 * User-facing name: RoamSocket only. Data dir prefers ~/.roamsocket; falls back
 * to LEGACY_DATA_DIRNAMES when those folders already exist (no silent data loss).
 */
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export const PRODUCT_NAME = "RoamSocket";
export const PRODUCT_SLUG = "roamsocket";
/** Bonjour service type (no leading underscore / protocol). Publishes as `_roamsocket._tcp`. */
export const BONJOUR_SERVICE_TYPE = "roamsocket";
/**
 * LEGACY data-dir basenames only (pre-RoamSocket installs). Not product branding.
 * Used solely so existing user data under older folder names is still found.
 */
export const LEGACY_DATA_DIRNAMES = [".codesocket", ".anyprov-code"] as const;
export const DATA_DIRNAME = `.${PRODUCT_SLUG}`;

/** ~/.roamsocket, or a LEGACY data dir if the user already has data there. */
export function productDataDir(): string {
  const home = os.homedir();
  const preferred = path.join(home, DATA_DIRNAME);
  if (existsSync(preferred)) return preferred;
  for (const legacyName of LEGACY_DATA_DIRNAMES) {
    const legacy = path.join(home, legacyName);
    if (existsSync(legacy)) return legacy;
  }
  return preferred;
}

export function productDataPath(...parts: string[]): string {
  return path.join(productDataDir(), ...parts);
}
