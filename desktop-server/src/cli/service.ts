/**
 * System-service install/uninstall for the headless RoamSocket server.
 *
 *   roamsocket install-service [--user|--system] [--start]
 *   roamsocket uninstall-service [--user|--system]
 *   roamsocket service status [--user|--system]
 *
 * Platform plumbing:
 *   - macOS:  launchd plist in ~/Library/LaunchAgents (user) or
 *             /Library/LaunchDaemons (system, needs sudo).
 *   - Linux:  systemd unit in ~/.config/systemd/user (user) or
 *             /etc/systemd/system (system, needs sudo).
 *   - Windows: sc.exe service (system-wide; user-level would be a
 *             scheduled task, not a service, so --user is rejected).
 *
 * The unit/plist runs `roamsocket --serve-only` so external coding CLIs
 * can hit the local proxy on the same port the iOS app pairs against.
 */
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export type ServicePlatform = 'darwin' | 'linux' | 'win32' | 'unsupported';
export type ServiceScope = 'user' | 'system';

export interface InstallOptions {
  scope: ServiceScope;
  /** Run the platform's "start" command after install (default true). */
  start?: boolean;
}

export interface ServiceStatus {
  installed: boolean;
  running: boolean;
  unitPath: string;
  scope: ServiceScope;
  platform: ServicePlatform;
  /** Raw stderr from the probe (useful when status=false). */
  detail?: string;
}

export interface ServiceCommandResult {
  ok: boolean;
  unitPath: string;
  scope: ServiceScope;
  platform: ServicePlatform;
  started: boolean;
  detail?: string;
}

/** Resolved entry point for the running service. Prefers a `roamsocket`
 *  binary on PATH (the post-install happy path); falls back to invoking
 *  `node bin/roamsocket.js` from the package install root. */
export interface ResolvedExecutable {
  /** argv[0] used to launch the service. */
  command: string;
  /** argv[1..n] used to launch the service. */
  args: string[];
  /** Source of the resolution — useful for log output. */
  source: 'path' | 'package-bin';
}

const SERVICE_LABEL = 'ai.roamsocket.server';
const SERVICE_DISPLAY_NAME = 'RoamSocket desktop server';
const SERVICE_DESCRIPTION =
  'RoamSocket desktop companion: headless WebSocket coding server + local OpenAI/Anthropic proxy for the iOS app.';

/** Best-effort: where is the roamsocket binary the package shipped? */
function packageBinDir(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  // src/cli/service.ts → ../../ (package root) → bin/
  const candidates = [path.resolve(here, '..', '..', 'bin'), path.resolve(here, '..', 'bin')];
  for (const dir of candidates) {
    if (existsSync(path.join(dir, 'roamsocket.js'))) return dir;
  }
  return candidates[0]!;
}

export function detectPlatform(): ServicePlatform {
  const p = process.platform;
  if (p === 'darwin' || p === 'linux' || p === 'win32') return p;
  return 'unsupported';
}

/** Resolve how to invoke the server when the service actually starts. Tries
 *  PATH first so a globally-installed `roamsocket` (the post-install happy
 *  path) wins; falls back to `node <pkg>/bin/roamsocket.js` so a service
 *  installed from a dev checkout still works. */
export function resolveExecutable(): ResolvedExecutable {
  const which = process.platform === 'win32' ? 'where' : 'which';
  const probe = spawnSync(which, ['roamsocket'], { encoding: 'utf8' });
  if (probe.status === 0) {
    const found = probe.stdout
      .split(/\r?\n/)
      .map((s) => s.trim())
      .find((s) => s.length > 0);
    if (found) return { command: found, args: ['--serve-only'], source: 'path' };
  }
  const bin = path.join(packageBinDir(), 'roamsocket.js');
  // Prefer the node on PATH; absolute fallback to the common locations.
  const nodeProbe = spawnSync(which, ['node'], { encoding: 'utf8' });
  const nodeCmd =
    nodeProbe.status === 0 && nodeProbe.stdout.trim().length > 0
      ? nodeProbe.stdout.split(/\r?\n/)[0]!.trim()
      : process.platform === 'win32'
        ? 'node.exe'
        : '/usr/bin/env';
  // `env node …` is the portable POSIX incantation; on Windows node.exe is
  // expected to be on PATH (the npm-installed default).
  if (nodeCmd === '/usr/bin/env') {
    return {
      command: nodeCmd,
      args: ['node', bin, '--serve-only'],
      source: 'package-bin',
    };
  }
  return {
    command: nodeCmd,
    args: [bin, '--serve-only'],
    source: 'package-bin',
  };
}

function expandHome(p: string): string {
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

function ensureDir(p: string): void {
  mkdirSync(p, { recursive: true });
}

/** Path to the unit / plist / service definition file for the given scope. */
export function unitPathFor(platform: ServicePlatform, scope: ServiceScope): string {
  if (platform === 'darwin') {
    return scope === 'user'
      ? path.join(os.homedir(), 'Library', 'LaunchAgents', `${SERVICE_LABEL}.plist`)
      : path.join('/Library', 'LaunchDaemons', `${SERVICE_LABEL}.plist`);
  }
  if (platform === 'linux') {
    return scope === 'user'
      ? path.join(os.homedir(), '.config', 'systemd', 'user', 'roamsocket.service')
      : path.join('/etc', 'systemd', 'system', 'roamsocket.service');
  }
  // Windows: only system scope is meaningful.
  return ''; // Windows uses sc.exe; no file is written.
}

// ─── macOS (launchd) ─────────────────────────────────────────────────────

function renderLaunchdPlist(exe: ResolvedExecutable): string {
  // PATH for launchd is intentionally minimal; `roamsocket` from PATH is
  // the happy path, but we include common global install dirs so the
  // homebrew / npm-global locations work out of the box.
  const envPath = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    `${os.homedir()}/.npm-global/bin`,
    '/usr/bin',
    '/bin',
  ].join(':');
  const stdoutPath = `${os.tmpdir()}/roamsocket.log`;
  const argv = [exe.command, ...exe.args];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${argv.map((a) => `    <string>${escapeXml(a)}</string>`).join('\n')}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${envPath}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>StandardOutPath</key>
  <string>${escapeXml(stdoutPath)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(stdoutPath)}</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
`;
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

async function installMac(opts: InstallOptions): Promise<ServiceCommandResult> {
  const exe = resolveExecutable();
  const unitPath = unitPathFor('darwin', opts.scope);
  ensureDir(path.dirname(unitPath));
  writeFileSync(unitPath, renderLaunchdPlist(exe), 'utf8');

  // For system scope, sudo is required to write into /Library/LaunchDaemons.
  // `launchctl load` already needs sudo for system, so the load call itself
  // will fail loudly if the file is owned by the wrong user.
  const load = runCommand('launchctl', ['load', '-w', unitPath], { sudo: opts.scope === 'system' });
  if (!load.ok) {
    return resultFrom('darwin', opts, false, false, load.stderr || load.stdout);
  }
  const started =
    opts.start === false
      ? false
      : runCommand('launchctl', ['start', SERVICE_LABEL], { sudo: opts.scope === 'system' }).ok;
  return resultFrom('darwin', opts, true, started, started ? undefined : 'launchctl start failed');
}

async function uninstallMac(opts: InstallOptions): Promise<ServiceCommandResult> {
  const unitPath = unitPathFor('darwin', opts.scope);
  const unload = runCommand('launchctl', ['unload', unitPath], {
    sudo: opts.scope === 'system',
    allowMissing: true,
  });
  if (existsSync(unitPath)) {
    const rm = runCommand('rm', [unitPath], { sudo: opts.scope === 'system' });
    if (!rm.ok) {
      return resultFrom('darwin', opts, true, false, `unload ok but rm failed: ${rm.stderr}`);
    }
  }
  return resultFrom('darwin', opts, true, true, unload.stderr);
}

async function statusMac(opts: InstallOptions): Promise<ServiceStatus> {
  const unitPath = unitPathFor('darwin', opts.scope);
  const installed = existsSync(unitPath);
  const probe = runCommand('launchctl', ['print', `gui/${getUid()}/${SERVICE_LABEL}`], {
    sudo: opts.scope === 'system',
    allowMissing: true,
  });
  // `launchctl print` returns non-zero when not loaded; fall back to
  // `list` for a quick "is it running" check.
  const list = runCommand('launchctl', ['list'], { allowMissing: true });
  const running =
    probe.ok || list.stdout.split(/\r?\n/).some((line) => line.includes(`\t${SERVICE_LABEL}\t`));
  return {
    installed,
    running,
    unitPath,
    scope: opts.scope,
    platform: 'darwin',
    detail: installed ? undefined : 'plist not found',
  };
}

function getUid(): string {
  return process.getuid ? String(process.getuid()) : '501';
}

// ─── Linux (systemd) ─────────────────────────────────────────────────────

function renderSystemdUnit(exe: ResolvedExecutable, scope: ServiceScope): string {
  const exec = [exe.command, ...exe.args].map((a) => (a.includes(' ') ? `"${a}"` : a)).join(' ');
  const wantedBy = scope === 'user' ? 'default.target' : 'multi-user.target';
  return `[Unit]
Description=${SERVICE_DESCRIPTION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec}
Restart=on-failure
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=${wantedBy}
`;
}

async function installLinux(opts: InstallOptions): Promise<ServiceCommandResult> {
  const exe = resolveExecutable();
  const unitPath = unitPathFor('linux', opts.scope);
  ensureDir(path.dirname(unitPath));
  writeFileSync(unitPath, renderSystemdUnit(exe, opts.scope), 'utf8');

  const sudo = opts.scope === 'system';
  const reload = runCommand('systemctl', sudo ? ['daemon-reload'] : ['--user', 'daemon-reload'], {
    sudo,
    allowMissing: true,
  });
  if (!reload.ok) {
    return resultFrom('linux', opts, false, false, reload.stderr || reload.stdout);
  }
  const enable = runCommand(
    'systemctl',
    sudo ? ['enable', 'roamsocket.service'] : ['--user', 'enable', 'roamsocket.service'],
    { sudo }
  );
  if (!enable.ok) {
    return resultFrom('linux', opts, false, false, enable.stderr || enable.stdout);
  }
  const started =
    opts.start === false
      ? false
      : runCommand(
          'systemctl',
          sudo ? ['start', 'roamsocket.service'] : ['--user', 'start', 'roamsocket.service'],
          { sudo }
        ).ok;
  return resultFrom('linux', opts, true, started, started ? undefined : 'systemctl start failed');
}

async function uninstallLinux(opts: InstallOptions): Promise<ServiceCommandResult> {
  const unitPath = unitPathFor('linux', opts.scope);
  const sudo = opts.scope === 'system';
  runCommand(
    'systemctl',
    sudo
      ? ['disable', '--now', 'roamsocket.service']
      : ['--user', 'disable', '--now', 'roamsocket.service'],
    { sudo, allowMissing: true }
  );
  if (existsSync(unitPath)) {
    const rm = runCommand('rm', [unitPath], { sudo });
    if (!rm.ok) {
      return resultFrom('linux', opts, true, false, `disable ok but rm failed: ${rm.stderr}`);
    }
  }
  runCommand('systemctl', sudo ? ['daemon-reload'] : ['--user', 'daemon-reload'], {
    sudo,
    allowMissing: true,
  });
  return resultFrom('linux', opts, true, true);
}

async function statusLinux(opts: InstallOptions): Promise<ServiceStatus> {
  const unitPath = unitPathFor('linux', opts.scope);
  const installed = existsSync(unitPath);
  const sudo = opts.scope === 'system';
  const probe = runCommand(
    'systemctl',
    sudo ? ['is-active', 'roamsocket.service'] : ['--user', 'is-active', 'roamsocket.service'],
    { sudo, allowMissing: true }
  );
  const running = probe.ok && probe.stdout.trim() === 'active';
  return {
    installed,
    running,
    unitPath,
    scope: opts.scope,
    platform: 'linux',
    detail: installed ? probe.stdout.trim() : 'unit not found',
  };
}

// ─── Windows (sc.exe) ────────────────────────────────────────────────────

async function installWindows(opts: InstallOptions): Promise<ServiceCommandResult> {
  if (opts.scope === 'user') {
    return {
      ok: false,
      unitPath: '',
      scope: opts.scope,
      platform: 'win32',
      started: false,
      detail:
        'Windows services are system-wide only. Pass --system (re-run from an elevated shell if needed).',
    };
  }
  const exe = resolveExecutable();
  // sc.exe binPath= requires embedded quoting; escape any internal quotes.
  const binPath = `"${exe.command}" ${exe.args.map((a) => `"${a}"`).join(' ')}`;
  const args = [
    'create',
    'roamsocket',
    `binPath= ${binPath}`,
    'start= auto',
    'DisplayName= RoamSocket Server',
  ];
  const create = runCommand('sc.exe', args, { elevatedHint: true });
  if (!create.ok) {
    return resultFrom('win32', opts, false, false, create.stderr || create.stdout);
  }
  const started =
    opts.start === false
      ? false
      : runCommand('sc.exe', ['start', 'roamsocket'], { elevatedHint: true }).ok;
  return resultFrom('win32', opts, true, started, started ? undefined : 'sc start failed');
}

async function uninstallWindows(opts: InstallOptions): Promise<ServiceCommandResult> {
  if (opts.scope === 'user') {
    return resultFrom('win32', opts, true, true, 'user scope has nothing to remove');
  }
  runCommand('sc.exe', ['stop', 'roamsocket'], { allowMissing: true, elevatedHint: true });
  runCommand('sc.exe', ['delete', 'roamsocket'], { allowMissing: true, elevatedHint: true });
  return resultFrom('win32', opts, true, true);
}

async function statusWindows(opts: InstallOptions): Promise<ServiceStatus> {
  const probe = runCommand('sc.exe', ['query', 'roamsocket'], { allowMissing: true });
  // `sc query` prints "STATE       : 4  RUNNING" on a running service.
  const running = probe.ok && /STATE\s*:\s*\d+\s+RUNNING/i.test(probe.stdout);
  const installed = probe.ok && /SERVICE_NAME/i.test(probe.stdout);
  return {
    installed,
    running,
    unitPath: '(sc.exe query roamsocket)',
    scope: opts.scope,
    platform: 'win32',
    detail: installed
      ? probe.stdout.split(/\r?\n/).find((l) => l.includes('STATE'))
      : 'service not installed',
  };
}

// ─── dispatch ────────────────────────────────────────────────────────────

export async function installService(opts: InstallOptions): Promise<ServiceCommandResult> {
  const platform = detectPlatform();
  if (platform === 'unsupported') {
    return {
      ok: false,
      unitPath: '',
      scope: opts.scope,
      platform,
      started: false,
      detail: `Unsupported platform: ${process.platform}`,
    };
  }
  if (platform === 'darwin') return installMac(opts);
  if (platform === 'linux') return installLinux(opts);
  return installWindows(opts);
}

export async function uninstallService(opts: InstallOptions): Promise<ServiceCommandResult> {
  const platform = detectPlatform();
  if (platform === 'unsupported') {
    return {
      ok: false,
      unitPath: '',
      scope: opts.scope,
      platform,
      started: false,
      detail: `Unsupported platform: ${process.platform}`,
    };
  }
  if (platform === 'darwin') return uninstallMac(opts);
  if (platform === 'linux') return uninstallLinux(opts);
  return uninstallWindows(opts);
}

export async function serviceStatus(opts: InstallOptions): Promise<ServiceStatus> {
  const platform = detectPlatform();
  if (platform === 'unsupported') {
    return {
      installed: false,
      running: false,
      unitPath: '',
      scope: opts.scope,
      platform,
      detail: `Unsupported platform: ${process.platform}`,
    };
  }
  if (platform === 'darwin') return statusMac(opts);
  if (platform === 'linux') return statusLinux(opts);
  return statusWindows(opts);
}

// ─── helpers ─────────────────────────────────────────────────────────────

interface CommandResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

interface RunOptions {
  sudo?: boolean;
  elevatedHint?: boolean;
  /** Treat ENOENT / non-zero exit as ok when the command is a probe. */
  allowMissing?: boolean;
}

function runCommand(cmd: string, args: string[], opts: RunOptions): CommandResult {
  let effective = cmd;
  let effectiveArgs = args;
  if (opts.sudo) {
    effective = 'sudo';
    effectiveArgs = ['-n', cmd, ...args];
  }
  try {
    const res = spawnSync(effective, effectiveArgs, { encoding: 'utf8' });
    const ok = res.status === 0;
    return {
      ok: opts.allowMissing ? true : ok,
      stdout: res.stdout ?? '',
      stderr: res.stderr ?? '',
    };
  } catch (err) {
    return {
      ok: !!opts.allowMissing,
      stdout: '',
      stderr: `${effective} failed: ${(err as Error).message}`,
    };
  }
}

function resultFrom(
  platform: ServicePlatform,
  opts: InstallOptions,
  installed: boolean,
  started: boolean,
  detail?: string
): ServiceCommandResult {
  return {
    ok: installed,
    unitPath: platform === 'win32' ? '(sc.exe)' : unitPathFor(platform, opts.scope),
    scope: opts.scope,
    platform,
    started,
    detail,
  };
}

/** Parse CLI flags after the subcommand. */
export function parseServiceFlags(args: string[]): {
  scope: ServiceScope;
  start: boolean;
  help: boolean;
} {
  let scope: ServiceScope = 'user';
  let start = true;
  let help = false;
  for (const a of args) {
    if (a === '--user') scope = 'user';
    else if (a === '--system') scope = 'system';
    else if (a === '--no-start') start = false;
    else if (a === '--help' || a === '-h') help = true;
  }
  return { scope, start, help };
}

/** Human-readable one-liner for `roamsocket service status`. */
export function formatStatus(s: ServiceStatus): string {
  const state = s.running ? 'running' : s.installed ? 'installed (not running)' : 'not installed';
  const unit = s.unitPath || '(none)';
  return `[${s.platform}/${s.scope}] ${state} — unit: ${unit}${s.detail ? ` — ${s.detail}` : ''}`;
}
