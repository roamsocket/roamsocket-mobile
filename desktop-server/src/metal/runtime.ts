/**
 * Metal chat inference runtime for macOS (Apple Silicon).
 *
 * Uses mlx-lm via a Python child process when available. Desktop chat uses
 * this path directly; the coding agent uses the same runtime via the Metal
 * provider adapter (`providers/metal.ts`) with a text tool-call protocol.
 *
 * Clear errors when:
 *  - not on darwin/arm64
 *  - mlx-lm not installed
 *  - model not downloaded
 */
import { spawn } from "node:child_process";
import { existsSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { getMetalStore } from "./store.js";
import { METAL_PROVIDER_ID } from "./catalog.js";
import { readManagedPythonPath } from "./paths.js";

export interface MetalRuntimeStatus {
  providerId: typeof METAL_PROVIDER_ID;
  chatOnly: true;
  platform: NodeJS.Platform;
  arch: string;
  supported: boolean;
  runtimeReady: boolean;
  runtimeLabel: string;
  pythonPath: string | null;
  detail: string;
}

export interface MetalGenerateRequest {
  hubID: string;
  messages: Array<{ role: "user" | "assistant" | "system"; content: string }>;
  maxTokens?: number;
}

export interface MetalGenerateResult {
  text: string;
  hubID: string;
  modelPath: string;
}

/** Progress while weights load / tokens generate (desktop chat + agent UI). */
export type MetalGeneratePhase = "loading" | "generating";

export interface MetalGenerateProgress {
  phase: MetalGeneratePhase;
  message?: string;
  hubID: string;
}

const MLX_PROBE = `
import json, sys
try:
    import mlx
    import mlx_lm
    print(json.dumps({"ok": True, "mlx": getattr(mlx, "__version__", "unknown")}))
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e)}))
    sys.exit(1)
`;

const MLX_GENERATE = `
import json, sys
from pathlib import Path

def progress(phase, message=""):
    # Progress on stderr so stdout stays a single final JSON result.
    print(json.dumps({"phase": phase, "message": message}), file=sys.stderr, flush=True)

payload = json.loads(sys.stdin.read())
model_path = payload["modelPath"]
messages = payload["messages"]
max_tokens = int(payload.get("maxTokens") or 512)

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

progress("loading", "Loading model weights into memory…")
model, tokenizer = load(model_path)

# Prefer chat template when available
if hasattr(tokenizer, "apply_chat_template") and tokenizer.chat_template:
    prompt = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
else:
    parts = []
    for m in messages:
        parts.append(f"{m['role'].upper()}: {m['content']}")
    parts.append("ASSISTANT:")
    prompt = "\\n".join(parts)

progress("generating", "Generating…")
sampler = make_sampler(temp=0.7)
text = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, sampler=sampler)
# Strip the prompt if the backend echoes it
if isinstance(text, str) and text.startswith(prompt):
    text = text[len(prompt):]
print(json.dumps({"ok": True, "text": text.strip()}))
`;

function candidatePythons(): string[] {
  const out: string[] = [];
  const env = process.env.APC_METAL_PYTHON;
  if (env) out.push(env);
  // One-click install path (Settings → Install Metal runtime)
  const managed = readManagedPythonPath();
  if (managed) out.push(managed);
  // Common locations on Apple Silicon
  out.push(
    "python3",
    "/usr/bin/python3",
    "/opt/homebrew/bin/python3",
    `${os.homedir()}/.local/bin/python3`,
  );
  return [...new Set(out)];
}

async function runPython(
  python: string,
  code: string,
  stdin?: string,
  timeoutMs = 120_000,
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(python, ["-c", code], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      stdout += String(d);
    });
    child.stderr.on("data", (d) => {
      stderr += String(d);
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ code: 1, stdout, stderr: String(err.message) });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    if (stdin != null) {
      child.stdin.write(stdin);
    }
    child.stdin.end();
  });
}

let cachedPython: string | null | undefined;

export async function resolveMetalPython(): Promise<string | null> {
  if (cachedPython !== undefined) return cachedPython;
  for (const py of candidatePythons()) {
    const probe = await runPython(py, MLX_PROBE, undefined, 15_000);
    if (probe.code === 0) {
      try {
        const line = probe.stdout.trim().split("\n").pop() ?? "";
        const json = JSON.parse(line) as { ok?: boolean };
        if (json.ok) {
          cachedPython = py;
          return py;
        }
      } catch {
        // try next
      }
    }
  }
  cachedPython = null;
  return null;
}

/** Reset cached python probe (tests). */
export function resetMetalPythonCache(): void {
  cachedPython = undefined;
}

export async function getMetalRuntimeStatus(): Promise<MetalRuntimeStatus> {
  const platform = process.platform;
  const arch = process.arch;
  const supported = platform === "darwin" && (arch === "arm64" || arch === "x64");
  if (!supported) {
    return {
      providerId: METAL_PROVIDER_ID,
      chatOnly: true,
      platform,
      arch,
      supported: false,
      runtimeReady: false,
      runtimeLabel: "unavailable",
      pythonPath: null,
      detail: "On-device Metal chat requires macOS (Apple Silicon preferred).",
    };
  }

  const python = await resolveMetalPython();
  if (!python) {
    return {
      providerId: METAL_PROVIDER_ID,
      chatOnly: true,
      platform,
      arch,
      supported: true,
      runtimeReady: false,
      runtimeLabel: "mlx-lm missing",
      pythonPath: null,
      detail:
        "Metal runtime is not ready. Use Settings → On-device Metal → Install Python + mlx-lm, or Manage models. Models can still be downloaded without the runtime.",
    };
  }

  return {
    providerId: METAL_PROVIDER_ID,
    chatOnly: true,
    platform,
    arch,
    supported: true,
    runtimeReady: true,
    runtimeLabel: "mlx-lm",
    pythonPath: python,
    detail: `mlx-lm ready via ${python}. Available for desktop chat and coding agent.`,
  };
}

/**
 * Run a chat completion on a downloaded Metal model.
 * Throws with a clear message when runtime or weights are missing.
 * Optional `onProgress` reports loading vs generating (Python stderr phases).
 */
export async function metalGenerate(
  req: MetalGenerateRequest,
  onProgress?: (p: MetalGenerateProgress) => void,
): Promise<MetalGenerateResult> {
  const status = await getMetalRuntimeStatus();
  if (!status.supported) {
    throw new Error(status.detail);
  }
  if (!status.runtimeReady || !status.pythonPath) {
    throw new Error(
      "Metal runtime is not available. Install mlx-lm: `pip install mlx-lm` (Apple Silicon macOS). " +
        "Download models in Settings → On-device Metal, then use them for chat or coding.",
    );
  }

  const store = getMetalStore();
  if (!store.isDownloaded(req.hubID)) {
    throw new Error(
      `Model not downloaded: ${req.hubID}. Open Settings → On-device Metal, download the model, then try again.`,
    );
  }
  const modelPath = store.pathFor(req.hubID);
  if (!existsSync(modelPath)) {
    throw new Error(`Model path missing for ${req.hubID}: ${modelPath}`);
  }

  const payload = JSON.stringify({
    modelPath,
    messages: req.messages,
    maxTokens: req.maxTokens ?? 512,
  });

  // Immediate UI signal before the Python process even starts.
  onProgress?.({
    phase: "loading",
    message: "Starting Metal runtime…",
    hubID: req.hubID,
  });

  // Write script to temp file for reliability with longer code
  const tmp = mkdtempSync(path.join(os.tmpdir(), "apc-metal-"));
  const scriptPath = path.join(tmp, "generate.py");
  try {
    writeFileSync(scriptPath, MLX_GENERATE);
    const result = await new Promise<{ code: number | null; stdout: string; stderr: string }>(
      (resolve) => {
        const child = spawn(status.pythonPath!, [scriptPath], {
          stdio: ["pipe", "pipe", "pipe"],
          env: { ...process.env, PYTHONUNBUFFERED: "1" },
        });
        let stdout = "";
        let stderr = "";
        let stderrBuf = "";
        const timer = setTimeout(() => child.kill("SIGKILL"), 300_000);
        child.stdout.on("data", (d) => {
          stdout += String(d);
        });
        child.stderr.on("data", (d) => {
          const chunk = String(d);
          stderr += chunk;
          stderrBuf += chunk;
          // Parse NDJSON phase lines as they arrive
          const lines = stderrBuf.split("\n");
          stderrBuf = lines.pop() ?? "";
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("{")) continue;
            try {
              const j = JSON.parse(trimmed) as { phase?: string; message?: string };
              if (j.phase === "loading" || j.phase === "generating") {
                onProgress?.({
                  phase: j.phase,
                  message: typeof j.message === "string" ? j.message : undefined,
                  hubID: req.hubID,
                });
              }
            } catch {
              /* non-JSON stderr (mlx logs) — ignore */
            }
          }
        });
        child.on("error", (err) => {
          clearTimeout(timer);
          resolve({ code: 1, stdout, stderr: err.message });
        });
        child.on("close", (code) => {
          clearTimeout(timer);
          resolve({ code, stdout, stderr });
        });
        child.stdin.write(payload);
        child.stdin.end();
      },
    );

    if (result.code !== 0) {
      const err = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
      throw new Error(`Metal generate failed: ${err.slice(0, 800)}`);
    }
    const line = result.stdout.trim().split("\n").pop() ?? "";
    let json: { ok?: boolean; text?: string; error?: string };
    try {
      json = JSON.parse(line);
    } catch {
      throw new Error(`Metal generate returned invalid JSON: ${line.slice(0, 200)}`);
    }
    if (!json.ok || typeof json.text !== "string") {
      throw new Error(json.error || "Metal generate failed with no text");
    }
    return { text: json.text, hubID: req.hubID, modelPath };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
