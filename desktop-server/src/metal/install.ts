/**
 * One-click install of Python + mlx-lm for on-device Metal chat/coding.
 *
 * Creates a managed venv under the product data dir (metal-runtime) and installs
 * mlx-lm there so we don't require the user to touch system Python.
 */
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, mkdirSync, writeFileSync, chmodSync } from "node:fs";
import path from "node:path";
import { resetMetalPythonCache, getMetalRuntimeStatus } from "./runtime.js";
import {
  metalRuntimeRoot,
  managedMetalPythonPath,
  managedMetalPythonMarker,
} from "./paths.js";

const execFileP = promisify(execFile);

export type InstallLog = (line: string) => void;

export interface MetalInstallResult {
  ok: boolean;
  pythonPath: string | null;
  detail: string;
  error?: string;
}

export {
  metalRuntimeRoot,
  managedMetalPythonPath,
  managedMetalPythonMarker,
  readManagedPythonPath,
} from "./paths.js";

function runCmd(
  cmd: string,
  args: string[],
  onLog: InstallLog,
  opts?: { cwd?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number },
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    onLog(`$ ${cmd} ${args.join(" ")}`);
    const child = spawn(cmd, args, {
      cwd: opts?.cwd,
      env: { ...process.env, ...(opts?.env ?? {}), PYTHONUNBUFFERED: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, opts?.timeoutMs ?? 600_000);
    child.stdout.on("data", (d) => {
      const t = String(d);
      stdout += t;
      for (const line of t.split(/\r?\n/)) {
        if (line.trim()) onLog(line);
      }
    });
    child.stderr.on("data", (d) => {
      const t = String(d);
      stderr += t;
      for (const line of t.split(/\r?\n/)) {
        if (line.trim()) onLog(line);
      }
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      onLog(`error: ${err.message}`);
      resolve({ code: 1, stdout, stderr: err.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

async function which(bin: string): Promise<string | null> {
  try {
    const cmd = process.platform === "win32" ? "where" : "which";
    const { stdout } = await execFileP(cmd, [bin], { timeout: 10_000 });
    const line = stdout.trim().split(/\r?\n/)[0]?.trim();
    return line && existsSync(line) ? line : null;
  } catch {
    return null;
  }
}

async function findBootstrapPython(onLog: InstallLog): Promise<string | null> {
  const candidates = [
    process.env.APC_METAL_PYTHON,
    await which("python3"),
    await which("python"),
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
  ].filter(Boolean) as string[];

  for (const py of candidates) {
    const r = await runCmd(py, ["--version"], onLog, { timeoutMs: 15_000 });
    if (r.code === 0) {
      onLog(`Using bootstrap Python: ${py}`);
      return py;
    }
  }
  return null;
}

async function ensurePythonViaBrew(onLog: InstallLog): Promise<string | null> {
  const brew =
    (await which("brew")) ||
    (existsSync("/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : null) ||
    (existsSync("/usr/local/bin/brew") ? "/usr/local/bin/brew" : null);
  if (!brew) {
    onLog("Homebrew not found — cannot auto-install Python without brew or an existing python3.");
    return null;
  }
  onLog("Installing Python via Homebrew (python@3.12)…");
  const install = await runCmd(brew, ["install", "python@3.12"], onLog, {
    timeoutMs: 900_000,
  });
  if (install.code !== 0) {
    // Already installed is fine for brew sometimes exit non-zero in edge cases
    onLog("brew install finished with non-zero exit; checking for python3…");
  }
  const py =
    (await which("python3")) ||
    "/opt/homebrew/opt/python@3.12/bin/python3.12" ||
    "/opt/homebrew/bin/python3";
  if (existsSync(py) || (await which("python3"))) {
    const resolved = existsSync(py) ? py : await which("python3");
    if (resolved) {
      onLog(`Python available: ${resolved}`);
      return resolved;
    }
  }
  return null;
}

/**
 * Platform gate for Metal install (unit-testable without running pip).
 * Returns a failure result when unsupported; null when install may proceed.
 */
export function metalInstallPlatformGate(
  platform: NodeJS.Platform = process.platform,
): MetalInstallResult | null {
  if (platform !== "darwin") {
    return {
      ok: false,
      pythonPath: null,
      detail: "Metal / MLX install is only supported on macOS.",
      error: "unsupported platform",
    };
  }
  return null;
}

/**
 * Install a managed venv + mlx-lm. Streams log lines via onLog.
 * Safe to re-run (reinstalls / upgrades mlx-lm).
 */
export async function installMetalRuntime(onLog: InstallLog = () => undefined): Promise<MetalInstallResult> {
  const blocked = metalInstallPlatformGate();
  if (blocked) {
    onLog(blocked.detail);
    return blocked;
  }

  const root = metalRuntimeRoot();
  mkdirSync(root, { recursive: true });
  onLog(`Runtime directory: ${root}`);

  let bootstrap = await findBootstrapPython(onLog);
  if (!bootstrap) {
    onLog("No system Python found — trying Homebrew…");
    bootstrap = await ensurePythonViaBrew(onLog);
  }
  if (!bootstrap) {
    const msg =
      "Could not find or install Python. Install Homebrew (https://brew.sh) or Python 3.12+, then try again.";
    onLog(msg);
    return { ok: false, pythonPath: null, detail: msg, error: msg };
  }

  const venvDir = path.join(root, "venv");
  const venvPython = managedMetalPythonPath();

  if (!existsSync(venvPython)) {
    onLog("Creating virtual environment…");
    const venv = await runCmd(bootstrap, ["-m", "venv", venvDir], onLog, {
      timeoutMs: 120_000,
    });
    if (venv.code !== 0 || !existsSync(venvPython)) {
      // Ensure pip exists (ensurepip)
      onLog("Retrying venv with ensurepip…");
      await runCmd(bootstrap, ["-m", "ensurepip", "--upgrade"], onLog, {
        timeoutMs: 60_000,
      });
      const venv2 = await runCmd(bootstrap, ["-m", "venv", venvDir], onLog, {
        timeoutMs: 120_000,
      });
      if (venv2.code !== 0 || !existsSync(venvPython)) {
        const msg = "Failed to create Python virtual environment.";
        onLog(msg);
        return { ok: false, pythonPath: null, detail: msg, error: msg };
      }
    }
    try {
      chmodSync(venvPython, 0o755);
    } catch {
      // ignore
    }
  } else {
    onLog(`Reusing existing venv: ${venvPython}`);
  }

  onLog("Upgrading pip…");
  await runCmd(venvPython, ["-m", "pip", "install", "--upgrade", "pip", "wheel", "setuptools"], onLog, {
    timeoutMs: 300_000,
  });

  onLog("Installing mlx-lm (this can take several minutes)…");
  const pip = await runCmd(
    venvPython,
    ["-m", "pip", "install", "--upgrade", "mlx-lm"],
    onLog,
    { timeoutMs: 900_000 },
  );
  if (pip.code !== 0) {
    const msg =
      "pip install mlx-lm failed. See log above. On Apple Silicon, ensure you are on macOS 13+.";
    onLog(msg);
    return { ok: false, pythonPath: venvPython, detail: msg, error: msg };
  }

  // Probe mlx_lm import
  onLog("Verifying mlx-lm import…");
  const probe = await runCmd(
    venvPython,
    ["-c", "import mlx, mlx_lm; print('ok', getattr(mlx, '__version__', '?'))"],
    onLog,
    { timeoutMs: 60_000 },
  );
  if (probe.code !== 0) {
    const msg = "mlx-lm installed but import failed. Check the log for missing system deps.";
    onLog(msg);
    return { ok: false, pythonPath: venvPython, detail: msg, error: msg };
  }

  writeFileSync(managedMetalPythonMarker(), venvPython + "\n", "utf8");
  resetMetalPythonCache();
  const status = await getMetalRuntimeStatus();
  if (!status.runtimeReady) {
    // Still mark path; probe may need cache clear
    resetMetalPythonCache();
  }
  const detail = status.runtimeReady
    ? `Metal runtime ready: ${venvPython}`
    : `Installed at ${venvPython}. ${status.detail}`;
  onLog(detail);
  return {
    ok: status.runtimeReady || probe.code === 0,
    pythonPath: venvPython,
    detail,
  };
}
