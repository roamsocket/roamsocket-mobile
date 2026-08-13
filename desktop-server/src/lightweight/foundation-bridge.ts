/**
 * Spawn the macOS Foundation Models CLI for Lightweight Tasks.
 * On non-macOS or when the CLI is missing / fails, callers fall back to a linked model.
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, chmodSync, copyFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { productDataPath } from '../product.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface FoundationGenerateRequest {
  system?: string;
  user: string;
  maxTokens?: number;
}

export interface FoundationStatus {
  platform: NodeJS.Platform;
  supported: boolean;
  cliPath: string | null;
  ready: boolean;
  detail: string;
}

function cliCandidates(): string[] {
  const out: string[] = [];
  out.push(productDataPath('bin', 'apc-foundation-cli'));
  // Bundled next to packaged resources / repo native folder
  out.push(path.join(__dirname, '..', '..', 'native', 'apc-foundation-cli'));
  out.push(path.join(__dirname, '..', '..', '..', 'native', 'apc-foundation-cli'));
  if (process.env.APC_FOUNDATION_CLI) out.unshift(process.env.APC_FOUNDATION_CLI);
  return out;
}

export function resolveFoundationCli(): string | null {
  for (const p of cliCandidates()) {
    if (existsSync(p)) return p;
  }
  return null;
}

export async function getFoundationStatus(): Promise<FoundationStatus> {
  if (process.platform !== 'darwin') {
    return {
      platform: process.platform,
      supported: false,
      cliPath: null,
      ready: false,
      detail: 'Apple Intelligence is only available on macOS.',
    };
  }
  let cli = resolveFoundationCli();
  if (!cli) {
    cli = await ensureFoundationCliBuilt();
  }
  if (!cli) {
    return {
      platform: 'darwin',
      supported: true,
      cliPath: null,
      ready: false,
      detail:
        'Foundation CLI not installed. On macOS 26+, build native/apc-foundation-cli.swift (see desktop-server/native/README.md). Use a linked model until then.',
    };
  }
  return {
    platform: 'darwin',
    supported: true,
    cliPath: cli,
    ready: true,
    detail: 'Apple Intelligence CLI found. Lightweight Tasks can use it on this Mac.',
  };
}

/**
 * Try to compile the Swift CLI into the product data dir (developer machines).
 * No-op if already present or not on macOS / swiftc missing.
 */
export async function ensureFoundationCliBuilt(): Promise<string | null> {
  const existing = resolveFoundationCli();
  if (existing) return existing;
  if (process.platform !== 'darwin') return null;

  const source = path.join(__dirname, '..', '..', 'native', 'apc-foundation-cli.swift');
  if (!existsSync(source)) {
    // Try repo-relative from packaged layout
    const alt = path.join(process.cwd(), 'native', 'apc-foundation-cli.swift');
    if (!existsSync(alt)) return null;
    return compileSwift(alt);
  }
  return compileSwift(source);
}

async function compileSwift(sourcePath: string): Promise<string | null> {
  const binDir = productDataPath('bin');
  mkdirSync(binDir, { recursive: true });
  const out = path.join(binDir, 'apc-foundation-cli');
  return new Promise((resolve) => {
    const child = spawn('swiftc', ['-O', '-o', out, sourcePath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let err = '';
    child.stderr.on('data', (d) => {
      err += String(d);
    });
    child.on('error', () => resolve(null));
    child.on('close', (code) => {
      if (code === 0 && existsSync(out)) {
        try {
          chmodSync(out, 0o755);
        } catch {
          /* ignore */
        }
        resolve(out);
      } else {
        console.warn('[apc] foundation-cli build failed:', err.slice(0, 400));
        resolve(null);
      }
    });
  });
}

export async function foundationGenerate(
  req: FoundationGenerateRequest,
  cliPath?: string
): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  const cli = cliPath ?? resolveFoundationCli() ?? (await ensureFoundationCliBuilt());
  if (!cli) {
    return {
      ok: false,
      error:
        'Apple Intelligence CLI not available. Use a linked model for Lightweight Tasks, or build native/apc-foundation-cli.swift on macOS 26+.',
    };
  }

  const payload = JSON.stringify({
    system: req.system ?? '',
    user: req.user,
    maxTokens: req.maxTokens ?? 48,
  });

  return new Promise((resolve) => {
    const child = spawn(cli, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      resolve({ ok: false, error: 'Foundation CLI timed out' });
    }, 60_000);
    child.stdout.on('data', (d) => {
      stdout += String(d);
    });
    child.stderr.on('data', (d) => {
      stderr += String(d);
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({ ok: false, error: err.message });
    });
    child.on('close', () => {
      clearTimeout(timer);
      const line = stdout.trim().split('\n').pop() ?? '';
      try {
        const json = JSON.parse(line) as { ok?: boolean; text?: string; error?: string };
        if (json.ok && typeof json.text === 'string' && json.text.trim()) {
          resolve({ ok: true, text: json.text.trim() });
        } else {
          resolve({
            ok: false,
            error: json.error || stderr.slice(0, 300) || 'Foundation CLI failed',
          });
        }
      } catch {
        resolve({
          ok: false,
          error: stderr.slice(0, 300) || `Invalid CLI output: ${line.slice(0, 120)}`,
        });
      }
    });
    child.stdin.write(payload);
    child.stdin.end();
  });
}

/** Copy a prebuilt binary into the product data dir (optional packaging step). */
export function installBundledFoundationCli(fromPath: string): string {
  const binDir = productDataPath('bin');
  mkdirSync(binDir, { recursive: true });
  const dest = path.join(binDir, 'apc-foundation-cli');
  copyFileSync(fromPath, dest);
  chmodSync(dest, 0o755);
  return dest;
}
