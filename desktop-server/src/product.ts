/**
 * Canonical product identity for the desktop companion.
 * User-facing name: CodeSocket. Data dir prefers ~/.codesocket; falls back to
 * ~/.anyprov-code when that legacy folder already exists (no silent data loss).
 */
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export const PRODUCT_NAME = "CodeSocket";
export const PRODUCT_SLUG = "codesocket";
/** Bonjour service type (no leading underscore / protocol). Publishes as `_codesocket._tcp`. */
export const BONJOUR_SERVICE_TYPE = "codesocket";
export const LEGACY_DATA_DIRNAME = ".anyprov-code";
export const DATA_DIRNAME = `.${PRODUCT_SLUG}`;

/** ~/.codesocket, or ~/.anyprov-code if the user already has data there. */
export function productDataDir(): string {
  const home = os.homedir();
  const preferred = path.join(home, DATA_DIRNAME);
  const legacy = path.join(home, LEGACY_DATA_DIRNAME);
  if (existsSync(legacy) && !existsSync(preferred)) return legacy;
  return preferred;
}

export function productDataPath(...parts: string[]): string {
  return path.join(productDataDir(), ...parts);
}
