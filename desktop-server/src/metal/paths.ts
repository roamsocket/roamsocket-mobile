/**
 * Managed Metal runtime paths (venv created by one-click install).
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { productDataPath } from "../product.js";

export function metalRuntimeRoot(): string {
  return productDataPath("metal-runtime");
}

/** Path to the managed venv python (preferred after install). */
export function managedMetalPythonPath(): string {
  const root = metalRuntimeRoot();
  if (process.platform === "win32") {
    return path.join(root, "venv", "Scripts", "python.exe");
  }
  return path.join(root, "venv", "bin", "python3");
}

export function managedMetalPythonMarker(): string {
  return path.join(metalRuntimeRoot(), "python.path");
}

/** Read the last successfully installed python path, if any. */
export function readManagedPythonPath(): string | null {
  try {
    const marker = managedMetalPythonMarker();
    if (existsSync(marker)) {
      const p = readFileSync(marker, "utf8").trim();
      if (p && existsSync(p)) return p;
    }
  } catch {
    // ignore
  }
  const fallback = managedMetalPythonPath();
  return existsSync(fallback) ? fallback : null;
}
