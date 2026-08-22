/**
 * Git operations on a local repo. Mirrors AnyProvCore/.../GitRepoSync.swift
 * on the desktop side so both apps behave the same way. The desktop is the
 * git operator; the iOS app sends edits over the WebSocket and this module
 * does the actual `git commit` / `git push`.
 */
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { productDataPath } from '../product.js';

export interface RepoConfig {
  url: string;
  branch: string;
}

export class GitOpsError extends Error {}

function run(cwd: string, args: string[], env: Record<string, string> = {}): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn('git', args, {
      cwd,
      env: {
        ...process.env,
        GIT_TERMINAL_PROMPT: '0',
        ...env,
      },
    });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', reject);
    proc.on('close', (code) => {
      if (code !== 0) {
        reject(new GitOpsError(`git ${args.join(' ')} exited ${code}: ${stderr}`));
      } else {
        resolve(stdout.trimEnd());
      }
    });
  });
}

export function defaultRoot(): string {
  return productDataPath('sync');
}

export async function ensureDir(p: string): Promise<string> {
  await fs.mkdir(p, { recursive: true });
  return p;
}

export function repoNameFromUrl(url: string): string {
  const cleaned = url.trim().replace(/\/+$/, '');
  const last = cleaned.split('/').pop() ?? 'repo';
  return last.replace(/\.git$/, '');
}

export function localDirFor(repoUrl: string, root: string = defaultRoot()): string {
  return path.join(root, repoNameFromUrl(repoUrl));
}

function injectToken(url: string, token: string | undefined): string {
  if (!token) return url;
  if (!url.startsWith('https://') && !url.startsWith('http://')) return url;
  try {
    const u = new URL(url);
    if (u.username && u.password) return url; // already authenticated
    u.username = 'x-access-token';
    u.password = token;
    return u.toString();
  } catch {
    return url;
  }
}

async function isRepo(dir: string): Promise<boolean> {
  try {
    const stat = await fs.stat(path.join(dir, '.git'));
    return stat.isDirectory() || stat.isFile();
  } catch {
    return false;
  }
}

/**
 * Rewrite the local clone's `origin` remote so the authed URL is what git
 * actually uses for fetch/push. This avoids the bash-askpass credential
 * helper (which is fragile on Windows and embeds the token in a shell
 * function string).
 */
async function setAuthedOrigin(dir: string, url: string, token: string | undefined): Promise<void> {
  const authed = injectToken(url, token);
  // `git remote set-url origin <url>` works on every platform git ships for.
  await run(dir, ['remote', 'set-url', 'origin', authed]);
}

export async function pullOrClone(config: RepoConfig, token?: string): Promise<string> {
  const dir = await ensureDir(localDirFor(config.url));
  const authed = injectToken(config.url, token);
  if (!(await isRepo(dir))) {
    await run(path.dirname(dir), ['clone', '--branch', config.branch, authed, dir]);
    return dir;
  }
  // Existing clone — make sure the local origin is the authed URL so the
  // subsequent fetch / reset / push don't need a credential helper.
  await setAuthedOrigin(dir, config.url, token);
  // Make sure the branch exists locally; create from origin/branch if missing.
  try {
    await run(dir, ['checkout', config.branch]);
  } catch {
    await run(dir, ['checkout', '-b', config.branch, `origin/${config.branch}`]);
  }
  await run(dir, ['fetch', 'origin']);
  await run(dir, ['reset', '--hard', `origin/${config.branch}`]);
  return dir;
}

export interface CommitOptions {
  config: RepoConfig;
  token?: string;
  message: string;
  author: { name: string; email: string };
}

/**
 * Stage, commit, and push. If push fails because of non-fast-forward, pull
 * --rebase and try once more.
 */
export async function commitAndPush(opts: CommitOptions): Promise<string> {
  const dir = localDirFor(opts.config.url);

  await run(dir, ['config', 'user.name', opts.author.name]);
  await run(dir, ['config', 'user.email', opts.author.email]);
  // Auth via the remote URL so we don't need a cross-platform askpass helper.
  await setAuthedOrigin(dir, opts.config.url, opts.token);
  await run(dir, ['add', '-A']);
  await run(dir, ['commit', '-m', opts.message, '--allow-empty']);

  try {
    await run(dir, ['push', 'origin', opts.config.branch]);
  } catch (err) {
    await run(dir, ['pull', '--rebase', 'origin', opts.config.branch]);
    await run(dir, ['push', 'origin', opts.config.branch]);
  }
  return await run(dir, ['rev-parse', 'HEAD']);
}

export async function writeFile(
  repoUrl: string,
  relativePath: string,
  content: string
): Promise<string> {
  const dir = localDirFor(repoUrl);
  const target = path.join(dir, relativePath);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, content, 'utf8');
  return target;
}

export async function deleteFile(repoUrl: string, relativePath: string): Promise<void> {
  const dir = localDirFor(repoUrl);
  const target = path.join(dir, relativePath);
  await fs.rm(target, { force: true });
}
