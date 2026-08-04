/**
 * Git helpers for a session: clone a GitHub repo, create the work branch,
 * commit changes, push, and produce a compare/PR URL. Uses the system `git`
 * binary. A GitHub token, when provided, is injected via an ephemeral
 * credential helper so it never lands in the remote URL or on disk.
 */
import { spawn } from "node:child_process";

export interface RepoSpec {
  /** "owner/name" */
  fullName: string;
  baseBranch?: string;
  workBranch: string;
  githubToken?: string;
}

export interface GitResult {
  code: number;
  stdout: string;
  stderr: string;
}

function run(
  args: string[],
  opts: { cwd?: string; token?: string } = {},
): Promise<GitResult> {
  return new Promise((resolve) => {
    const env = { ...process.env };
    // Feed the token to git without persisting it: an askpass script echoes it.
    if (opts.token) {
      env.GIT_ASKPASS = "echo";
      env.GIT_TERMINAL_PROMPT = "0";
      // The username is arbitrary for token auth; the token is the password.
      env.GIT_CONFIG_COUNT = "1";
      env.GIT_CONFIG_KEY_0 = "credential.helper";
      env.GIT_CONFIG_VALUE_0 = `!f() { echo username=x-access-token; echo password=${opts.token}; }; f`;
    }
    const child = spawn("git", args, { cwd: opts.cwd, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (b) => (stdout += b.toString()));
    child.stderr.on("data", (b) => (stderr += b.toString()));
    child.on("error", (e) => resolve({ code: 1, stdout, stderr: stderr + e.message }));
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

function remoteUrl(fullName: string): string {
  // Accept explicit URLs / local paths (used for offline testing) as-is;
  // otherwise treat "owner/name" as a github.com HTTPS remote.
  if (fullName.includes("://") || fullName.startsWith("/") || fullName.startsWith("file:")) {
    return fullName;
  }
  return `https://github.com/${fullName}.git`;
}

/** Clone the repo into `dir` and check out (or create) the work branch. */
export async function cloneAndBranch(spec: RepoSpec, dir: string): Promise<{ baseBranch: string }> {
  const clone = await run(["clone", "--depth", "50", remoteUrl(spec.fullName), dir], {
    token: spec.githubToken,
  });
  if (clone.code !== 0) {
    throw new Error(`git clone failed: ${clone.stderr.trim()}`);
  }

  // Determine the base branch (either explicit or the remote HEAD).
  let baseBranch = spec.baseBranch;
  if (!baseBranch) {
    const head = await run(["rev-parse", "--abbrev-ref", "HEAD"], { cwd: dir });
    baseBranch = head.stdout.trim() || "main";
  } else {
    await run(["checkout", baseBranch], { cwd: dir, token: spec.githubToken });
  }

  // Create the work branch if it doesn't already exist.
  const created = await run(["checkout", "-b", spec.workBranch], { cwd: dir });
  if (created.code !== 0) {
    await run(["checkout", spec.workBranch], { cwd: dir });
  }
  return { baseBranch };
}

/** Stage everything, commit. Returns false if there was nothing to commit. */
export async function commitAll(dir: string, message: string): Promise<boolean> {
  await run(["add", "-A"], { cwd: dir });
  const status = await run(["status", "--porcelain"], { cwd: dir });
  if (!status.stdout.trim()) return false;
  // Identity is required for commit; set a bot identity locally.
  await run(["config", "user.email", "agent@code-mobile-ai.local"], { cwd: dir });
  await run(["config", "user.name", "code-mobile-ai"], { cwd: dir });
  const commit = await run(["commit", "-m", message], { cwd: dir });
  if (commit.code !== 0) throw new Error(`git commit failed: ${commit.stderr.trim()}`);
  return true;
}

/** Push the work branch and return a GitHub compare URL for opening a PR. */
export async function pushBranch(spec: RepoSpec, dir: string): Promise<string> {
  const push = await run(["push", "-u", "origin", spec.workBranch], {
    cwd: dir,
    token: spec.githubToken,
  });
  if (push.code !== 0) throw new Error(`git push failed: ${push.stderr.trim()}`);
  const base = spec.baseBranch ?? "main";
  return `https://github.com/${spec.fullName}/compare/${base}...${spec.workBranch}?expand=1`;
}

/**
 * Per-file diffs of the working tree vs the branch's start, using numstat +
 * per-path unified diff. Includes untracked files (added via intent-to-add).
 */
export async function diffFiles(dir: string): Promise<
  { path: string; patch: string; added: number; removed: number }[]
> {
  // Intent-to-add so new files show up in `git diff`.
  await run(["add", "-AN"], { cwd: dir });
  const numstat = await run(["diff", "--numstat"], { cwd: dir });
  const results: { path: string; patch: string; added: number; removed: number }[] = [];
  for (const line of numstat.stdout.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const parts = trimmed.split("\t");
    if (parts.length < 3) continue;
    const [addedStr, removedStr, filePath] = parts as [string, string, string];
    const patch = await run(["diff", "--", filePath], { cwd: dir });
    results.push({
      path: filePath,
      patch: patch.stdout,
      added: Number(addedStr) || 0,
      removed: Number(removedStr) || 0,
    });
  }
  return results;
}
