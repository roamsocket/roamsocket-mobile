/**
 * Detect and install tunnel CLIs (cloudflared, ngrok) on every supported OS.
 *
 * Platforms: macOS (darwin), Linux, Windows (win32)
 * Architectures: arm64, x64 (amd64), ia32 (where vendors publish builds)
 *
 * Install order:
 *   1. Native package managers when present
 *      - macOS / Linux: Homebrew
 *      - Windows: winget → scoop → chocolatey
 *   2. Official binary download into APC_BIN_DIR (app-managed, no admin)
 *
 * Detection checks PATH (with managed bin prepended) and the managed bin dir.
 */
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { createWriteStream, existsSync, mkdirSync, chmodSync } from "node:fs";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import https from "node:https";
import http from "node:http";
import { pipeline } from "node:stream/promises";
import { productDataPath } from "../product.js";

const execFileP = promisify(execFile);

export type TunnelCliId = "cloudflared" | "ngrok";

export interface TunnelCliStatus {
  id: TunnelCliId;
  label: string;
  installed: boolean;
  path: string | null;
  source: "path" | "managed" | null;
  version: string | null;
  /** Host triple used for downloads, e.g. darwin-arm64. */
  platform: string;
}

export type InstallLog = (line: string) => void;

const CLI_META: Record<
  TunnelCliId,
  {
    label: string;
    bin: string;
    brewFormula: string;
    wingetId: string;
    scoopId: string;
    chocoId: string;
  }
> = {
  cloudflared: {
    label: "Cloudflare Tunnel",
    bin: "cloudflared",
    brewFormula: "cloudflare/cloudflare/cloudflared",
    wingetId: "Cloudflare.cloudflared",
    scoopId: "cloudflared",
    chocoId: "cloudflared",
  },
  ngrok: {
    label: "ngrok",
    bin: "ngrok",
    brewFormula: "ngrok/ngrok/ngrok",
    wingetId: "Ngrok.Ngrok",
    scoopId: "ngrok",
    chocoId: "ngrok",
  },
};

// ---------------------------------------------------------------------------
// Platform helpers
// ---------------------------------------------------------------------------

export type HostOs = "darwin" | "linux" | "win32";
export type HostArch = "arm64" | "amd64" | "386" | "arm";

export function hostOs(): HostOs {
  const p = process.platform;
  if (p === "darwin" || p === "linux" || p === "win32") return p;
  // FreeBSD / others — treat like Linux for binary selection when possible.
  if (p === "freebsd" || p === "openbsd" || p === "sunos" || p === "aix") return "linux";
  throw new Error(`Unsupported operating system: ${p}`);
}

export function hostArch(): HostArch {
  switch (process.arch) {
    case "arm64":
      return "arm64";
    case "x64":
      return "amd64";
    case "ia32":
      return "386";
    case "arm":
      // 32-bit ARM (armv6/7) — cloudflared ships linux-arm.
      return "arm";
    default:
      // e.g. loong64, riscv64 — try amd64 assets; platformAsset may still throw.
      return "amd64";
  }
}

export function hostTriple(): string {
  return `${hostOs()}-${hostArch()}`;
}

export function isWindows(): boolean {
  return process.platform === "win32";
}

function exeName(bin: string): string {
  return isWindows() ? `${bin}.exe` : bin;
}

/** Directory for app-managed tunnel binaries. Overridable via APC_BIN_DIR. */
export function managedBinDir(): string {
  if (process.env.APC_BIN_DIR) return process.env.APC_BIN_DIR;
  return productDataPath("bin");
}

export function ensureManagedBinDir(): string {
  const dir = managedBinDir();
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** PATH / Path prefix so spawn() can see managed installs on every OS. */
export function pathWithManagedBin(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const dir = managedBinDir();
  const sep = isWindows() ? ";" : ":";
  const current = env.PATH ?? env.Path ?? "";
  const parts = current.split(sep).filter(Boolean);
  if (parts.some((p) => path.resolve(p) === path.resolve(dir))) {
    return { ...env, PATH: current, Path: current };
  }
  const next = `${dir}${sep}${current}`;
  return { ...env, PATH: next, Path: next };
}

async function which(bin: string): Promise<string | null> {
  const candidates = isWindows() ? [bin, `${bin}.exe`, `${bin}.cmd`, `${bin}.bat`] : [bin];
  const env = pathWithManagedBin();

  for (const name of candidates) {
    // Direct managed path first (works even if `where`/`which` is broken).
    const managed = path.join(managedBinDir(), exeName(bin));
    if (name === bin || name === `${bin}.exe`) {
      if (existsSync(managed)) return managed;
    }

    try {
      if (isWindows()) {
        // `where` is a cmd built-in; shell required on some Electron builds.
        const { stdout } = await execFileP("cmd.exe", ["/d", "/s", "/c", `where ${name}`], {
          env,
          windowsHide: true,
        });
        const first = stdout
          .trim()
          .split(/\r?\n/)
          .map((l) => l.trim())
          .find((l) => l && !l.toLowerCase().includes("could not find"));
        if (first && existsSync(first)) return first;
      } else {
        const { stdout } = await execFileP("which", [name], { env });
        const first = stdout.trim().split(/\r?\n/)[0]?.trim();
        if (first) return first;
      }
    } catch {
      /* try next candidate */
    }
  }
  return null;
}

async function versionOf(binPath: string, id: TunnelCliId): Promise<string | null> {
  try {
    const args = id === "ngrok" ? ["version"] : ["--version"];
    const { stdout, stderr } = await execFileP(binPath, args, {
      env: pathWithManagedBin(),
      timeout: 10_000,
      windowsHide: true,
    });
    const text = (stdout || stderr).trim().split(/\r?\n/)[0] ?? "";
    return text || null;
  } catch {
    return null;
  }
}

function managedBinaryPath(id: TunnelCliId): string {
  return path.join(managedBinDir(), exeName(CLI_META[id].bin));
}

export async function getTunnelCliStatus(id: TunnelCliId): Promise<TunnelCliStatus> {
  const meta = CLI_META[id];
  const platform = hostTriple();
  const managed = managedBinaryPath(id);
  if (existsSync(managed)) {
    return {
      id,
      label: meta.label,
      installed: true,
      path: managed,
      source: "managed",
      version: await versionOf(managed, id),
      platform,
    };
  }
  const onPath = await which(meta.bin);
  if (onPath) {
    const isManaged = path.resolve(onPath) === path.resolve(managed);
    return {
      id,
      label: meta.label,
      installed: true,
      path: onPath,
      source: isManaged ? "managed" : "path",
      version: await versionOf(onPath, id),
      platform,
    };
  }
  return {
    id,
    label: meta.label,
    installed: false,
    path: null,
    source: null,
    version: null,
    platform,
  };
}

export async function listTunnelCliStatus(): Promise<TunnelCliStatus[]> {
  return Promise.all([getTunnelCliStatus("cloudflared"), getTunnelCliStatus("ngrok")]);
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

function runCommand(
  cmd: string,
  args: string[],
  log: InstallLog,
  opts: { shell?: boolean } = {},
): Promise<void> {
  return new Promise((resolve, reject) => {
    log(`$ ${cmd} ${args.join(" ")}`);
    const child = spawn(cmd, args, {
      env: pathWithManagedBin(),
      stdio: ["ignore", "pipe", "pipe"],
      shell: opts.shell ?? false,
      windowsHide: true,
    });
    const onChunk = (buf: Buffer) => {
      for (const line of buf.toString("utf8").split(/\r?\n/)) {
        if (line.trim()) log(line);
      }
    };
    child.stdout?.on("data", onChunk);
    child.stderr?.on("data", onChunk);
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} exited with code ${code ?? "?"}`));
    });
  });
}

async function commandExists(bin: string): Promise<boolean> {
  return (await which(bin)) != null;
}

// ---------------------------------------------------------------------------
// Download assets (official vendor URLs per OS/arch)
// ---------------------------------------------------------------------------

type AssetKind = "zip" | "tgz" | "bin";

interface Asset {
  url: string;
  kind: AssetKind;
}

/**
 * Resolve the official release asset for the current host.
 * Throws with a clear message when the vendor has no build for this OS/arch.
 */
export function platformAsset(id: TunnelCliId, osName = hostOs(), arch = hostArch()): Asset {
  if (id === "cloudflared") {
    // https://github.com/cloudflare/cloudflared/releases
    const table: Record<string, Asset> = {
      "darwin-arm64": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz",
        kind: "tgz",
      },
      "darwin-amd64": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz",
        kind: "tgz",
      },
      "linux-arm64": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64",
        kind: "bin",
      },
      "linux-amd64": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
        kind: "bin",
      },
      "linux-386": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386",
        kind: "bin",
      },
      "linux-arm": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm",
        kind: "bin",
      },
      "win32-amd64": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe",
        kind: "bin",
      },
      "win32-386": {
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-386.exe",
        kind: "bin",
      },
      "win32-arm64": {
        // Cloudflare ships amd64 Windows builds; ARM64 Windows runs them via emulation.
        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe",
        kind: "bin",
      },
    };
    const key = `${osName}-${arch}`;
    const asset = table[key];
    if (!asset) {
      throw new Error(
        `No cloudflared build for ${osName}/${arch}. Supported: macOS (Intel/Apple Silicon), Linux (amd64/arm64/arm/386), Windows (amd64/386/arm64).`,
      );
    }
    return asset;
  }

  // ngrok v3 stable — https://ngrok.com/download
  // No official linux-arm (32-bit) build; arm64/amd64/386 only.
  const ngrok: Record<string, string> = {
    "darwin-arm64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip",
    "darwin-amd64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip",
    "linux-arm64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.zip",
    "linux-amd64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.zip",
    "linux-386": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-386.zip",
    "win32-amd64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip",
    "win32-386": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-386.zip",
    "win32-arm64": "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-arm64.zip",
  };
  const key = `${osName}-${arch}`;
  const url = ngrok[key];
  if (!url) {
    throw new Error(
      `No ngrok build for ${osName}/${arch}. Supported: macOS (Intel/Apple Silicon), Linux (amd64/arm64/386), Windows (amd64/386/arm64).`,
    );
  }
  return { url, kind: "zip" };
}

function download(url: string, dest: string, log: InstallLog): Promise<void> {
  return new Promise((resolve, reject) => {
    log(`Downloading ${url}`);
    const get = (u: string, redirects = 0) => {
      if (redirects > 10) {
        reject(new Error("Too many redirects"));
        return;
      }
      const lib = u.startsWith("https") ? https : http;
      const req = lib.get(
        u,
        {
          headers: {
            "User-Agent": "CodeSocket-desktop",
            Accept: "*/*",
          },
        },
        (res) => {
          const code = res.statusCode ?? 0;
          if (code >= 300 && code < 400 && res.headers.location) {
            res.resume();
            const next = res.headers.location.startsWith("http")
              ? res.headers.location
              : new URL(res.headers.location, u).toString();
            get(next, redirects + 1);
            return;
          }
          if (code !== 200) {
            res.resume();
            reject(new Error(`Download failed: HTTP ${code} for ${u}`));
            return;
          }
          const file = createWriteStream(dest);
          void pipeline(res, file).then(resolve).catch(reject);
        },
      );
      req.on("error", reject);
      req.setTimeout(120_000, () => {
        req.destroy(new Error("Download timed out"));
      });
    };
    get(url);
  });
}

async function findBinaryInDir(dir: string, binName: string): Promise<string | null> {
  const want = new Set([binName, `${binName}.exe`]);
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop()!;
    let entries: string[];
    try {
      entries = await fs.readdir(cur);
    } catch {
      continue;
    }
    for (const e of entries) {
      const full = path.join(cur, e);
      let st;
      try {
        st = await fs.stat(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        // Don't walk forever into deep trees.
        if (path.relative(dir, full).split(path.sep).length < 4) stack.push(full);
      } else if (want.has(e)) {
        return full;
      }
    }
  }
  return null;
}

async function extractArchive(
  archive: string,
  kind: AssetKind,
  destDir: string,
  binName: string,
  log: InstallLog,
): Promise<string> {
  if (kind === "bin") {
    return archive;
  }

  log(`Extracting ${path.basename(archive)} (${kind})`);

  if (kind === "tgz") {
    // tar is available on macOS, Linux, and modern Windows 10+ (bsdtar).
    try {
      await runCommand("tar", ["-xzf", archive, "-C", destDir], log);
    } catch (err) {
      // Windows may need `tar.exe` explicitly or fail if disabled.
      if (isWindows()) {
        await runCommand(
          "tar.exe",
          ["-xzf", archive, "-C", destDir],
          log,
        ).catch(() => {
          throw err;
        });
      } else {
        throw err;
      }
    }
  } else {
    // zip
    let extracted = false;
    if (isWindows()) {
      const ps = `
$ErrorActionPreference = 'Stop'
Expand-Archive -Force -LiteralPath '${archive.replace(/'/g, "''")}' -DestinationPath '${destDir.replace(/'/g, "''")}'
`;
      await runCommand("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], log);
      extracted = true;
    } else {
      // Prefer unzip when present.
      if (await commandExists("unzip")) {
        await runCommand("unzip", ["-o", archive, "-d", destDir], log);
        extracted = true;
      } else {
        // macOS bsdtar / GNU tar with zip support
        try {
          await runCommand("tar", ["-xf", archive, "-C", destDir], log);
          extracted = true;
        } catch {
          // Python is common on Linux / macOS developer machines.
          if (await commandExists("python3")) {
            await runCommand(
              "python3",
              ["-c", `import zipfile; zipfile.ZipFile(r'''${archive}''').extractall(r'''${destDir}''')`],
              log,
            );
            extracted = true;
          } else if (await commandExists("python")) {
            await runCommand(
              "python",
              ["-c", `import zipfile; zipfile.ZipFile(r'''${archive}''').extractall(r'''${destDir}''')`],
              log,
            );
            extracted = true;
          }
        }
      }
    }
    if (!extracted) {
      throw new Error(
        "Could not extract zip archive. Install `unzip` (Linux) or ensure PowerShell is available (Windows).",
      );
    }
  }

  const found = await findBinaryInDir(destDir, binName);
  if (!found) throw new Error(`Could not find ${binName} inside the downloaded archive`);
  return found;
}

// ---------------------------------------------------------------------------
// Package-manager installers
// ---------------------------------------------------------------------------

async function installViaBrew(id: TunnelCliId, log: InstallLog): Promise<void> {
  const formula = CLI_META[id].brewFormula;
  log(`Installing ${id} with Homebrew…`);
  try {
    const tap = formula.split("/").slice(0, 2).join("/");
    await runCommand("brew", ["tap", tap], log);
  } catch {
    log("(tap already present or unavailable — continuing)");
  }
  await runCommand("brew", ["install", formula], log);
}

async function installViaWinget(id: TunnelCliId, log: InstallLog): Promise<void> {
  const pkg = CLI_META[id].wingetId;
  log(`Installing ${id} with winget…`);
  await runCommand(
    "winget",
    [
      "install",
      "-e",
      "--id",
      pkg,
      "--accept-package-agreements",
      "--accept-source-agreements",
      "--disable-interactivity",
    ],
    log,
    { shell: true },
  );
}

async function installViaScoop(id: TunnelCliId, log: InstallLog): Promise<void> {
  log(`Installing ${id} with scoop…`);
  await runCommand("scoop", ["install", CLI_META[id].scoopId], log, { shell: true });
}

async function installViaChoco(id: TunnelCliId, log: InstallLog): Promise<void> {
  log(`Installing ${id} with Chocolatey…`);
  await runCommand("choco", ["install", CLI_META[id].chocoId, "-y"], log, { shell: true });
}

async function installViaDownload(id: TunnelCliId, log: InstallLog): Promise<void> {
  ensureManagedBinDir();
  const osName = hostOs();
  const arch = hostArch();
  log(`Host: ${osName}/${arch} (${process.platform}/${process.arch})`);
  const { url, kind } = platformAsset(id, osName, arch);
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), `apc-${id}-`));
  try {
    const archiveName =
      kind === "bin"
        ? exeName(CLI_META[id].bin)
        : path.basename(new URL(url).pathname) || `${id}-download`;
    const archivePath = path.join(tmpDir, archiveName);
    await download(url, archivePath, log);

    let extracted: string;
    if (kind === "bin") {
      extracted = archivePath;
    } else {
      extracted = await extractArchive(archivePath, kind, tmpDir, CLI_META[id].bin, log);
    }

    const binaryPath = managedBinaryPath(id);
    await fs.copyFile(extracted, binaryPath);
    if (!isWindows()) {
      chmodSync(binaryPath, 0o755);
    }
    // On macOS, clear quarantine so Gatekeeper doesn't block first launch.
    if (process.platform === "darwin") {
      try {
        await runCommand("xattr", ["-d", "com.apple.quarantine", binaryPath], log);
      } catch {
        /* attribute may not exist */
      }
    }
    log(`Installed to ${binaryPath}`);
  } finally {
    try {
      await fs.rm(tmpDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

interface InstallMethod {
  name: string;
  available: () => Promise<boolean>;
  run: (id: TunnelCliId, log: InstallLog) => Promise<void>;
}

function installMethods(): InstallMethod[] {
  const methods: InstallMethod[] = [];

  if (process.platform === "darwin" || process.platform === "linux") {
    methods.push({
      name: "Homebrew",
      available: () => commandExists("brew"),
      run: installViaBrew,
    });
  }

  if (isWindows()) {
    methods.push(
      {
        name: "winget",
        available: () => commandExists("winget"),
        run: installViaWinget,
      },
      {
        name: "scoop",
        available: () => commandExists("scoop"),
        run: installViaScoop,
      },
      {
        name: "Chocolatey",
        available: () => commandExists("choco"),
        run: installViaChoco,
      },
    );
  }

  // Always available fallback.
  methods.push({
    name: "official download",
    available: async () => true,
    run: installViaDownload,
  });

  return methods;
}

/**
 * Install cloudflared or ngrok for the current OS.
 * @param force When true, reinstall even if already present (managed path preferred).
 */
export async function installTunnelCli(
  id: TunnelCliId,
  log: InstallLog = () => undefined,
  opts: { force?: boolean } = {},
): Promise<TunnelCliStatus> {
  if (id !== "cloudflared" && id !== "ngrok") {
    throw new Error(`Unknown tunnel CLI: ${id}`);
  }

  log(`Platform: ${hostTriple()} (node ${process.platform}/${process.arch})`);

  const before = await getTunnelCliStatus(id);
  if (before.installed && !opts.force) {
    log(`${CLI_META[id].label} is already installed at ${before.path}`);
    return before;
  }
  if (before.installed && opts.force) {
    log(`Reinstalling ${CLI_META[id].label} (was at ${before.path})…`);
  }

  ensureManagedBinDir();
  const errors: string[] = [];

  for (const method of installMethods()) {
    if (!(await method.available())) {
      log(`Skip ${method.name} (not available)`);
      continue;
    }
    try {
      log(`Trying ${method.name}…`);
      await method.run(id, log);
      const after = await getTunnelCliStatus(id);
      if (after.installed) {
        log(`✓ ${CLI_META[id].label} ready via ${method.name}`);
        log(`  path: ${after.path}`);
        if (after.version) log(`  ${after.version}`);
        if (id === "ngrok") {
          log("Note: ngrok needs a free authtoken — run `ngrok config add-authtoken <token>` once.");
        }
        return after;
      }
      errors.push(`${method.name}: finished but binary not found`);
      log(`${method.name} finished but ${id} was not detected — trying next method…`);
    } catch (err) {
      const msg = (err as Error).message ?? String(err);
      errors.push(`${method.name}: ${msg}`);
      log(`${method.name} failed: ${msg}`);
    }
  }

  throw new Error(
    `Failed to install ${id} on ${hostTriple()}.\n` +
      errors.map((e) => `  • ${e}`).join("\n") +
      (id === "ngrok"
        ? "\nTip: after a manual install, run `ngrok config add-authtoken <token>` (free at ngrok.com)."
        : ""),
  );
}

/** Resolve binary path for tunnel spawners (PATH + managed). */
export async function resolveTunnelBin(
  bin: "cloudflared" | "ngrok" | "lt" | "bore",
): Promise<string | null> {
  if (bin === "cloudflared" || bin === "ngrok") {
    const st = await getTunnelCliStatus(bin);
    return st.path;
  }
  return which(bin);
}

/** Human-readable list of install strategies for the current OS (UI copy). */
export function installStrategySummary(): string {
  const osName = hostOs();
  if (osName === "darwin") {
    return "macOS: Homebrew when available, otherwise official binary (Apple Silicon & Intel).";
  }
  if (osName === "linux") {
    return "Linux: Homebrew/Linuxbrew when available, otherwise official binary (amd64, arm64, 386).";
  }
  return "Windows: winget, scoop, or Chocolatey when available, otherwise official binary (amd64, arm64, 386).";
}
