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

async function injectToken(url: string, token: string | undefined): Promise<string> {
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

export async function pullOrClone(config: RepoConfig, token?: string): Promise<string> {
  const dir = await ensureDir(localDirFor(config.url));
  const authed = await injectToken(config.url, token);
  const env = tokenEnv(token);
  if (!(await isRepo(dir))) {
    await run(path.dirname(dir), ['clone', '--branch', config.branch, authed, dir], env);
    return dir;
  }
  // Make sure the branch exists locally; create from origin/branch if missing.
  try {
    await run(dir, ['checkout', config.branch], env);
  } catch {
    await run(dir, ['checkout', '-b', config.branch, `origin/${config.branch}`], env);
  }
  await run(dir, ['fetch', 'origin'], env);
  await run(dir, ['reset', '--hard', `origin/${config.branch}`], env);
  return dir;
}

function tokenEnv(token?: string): Record<string, string> {
  if (!token) return {};
  // Inject the token as a credential helper so it never lands in the
  // remote URL or on disk. Mirrors the helper used in git/github.ts.
  return {
    GIT_ASKPASS: '/bin/echo',
    GIT_TERMINAL_PROMPT: '0',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'credential.helper',
    GIT_CONFIG_VALUE_0: `!f() { echo username=x-access-token; echo password=${token}; }; f`,
  };
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
  const env = tokenEnv(opts.token);

  await run(dir, ['config', 'user.name', opts.author.name], env);
  await run(dir, ['config', 'user.email', opts.author.email], env);
  await run(dir, ['add', '-A'], env);
  await run(dir, ['commit', '-m', opts.message, '--allow-empty'], env);

  try {
    await run(dir, ['push', 'origin', opts.config.branch], env);
  } catch (err) {
    await run(dir, ['pull', '--rebase', 'origin', opts.config.branch], env);
    await run(dir, ['push', 'origin', opts.config.branch], env);
  }
  return await run(dir, ['rev-parse', 'HEAD'], env);
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
