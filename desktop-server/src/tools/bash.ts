import { spawn } from 'node:child_process';
import type { Tool, ToolContext, ToolResult } from './types.js';
import { truncate } from './types.js';

/**
 * Heuristically extract hostnames the shell command is about to contact.
 * We only need to flag obvious network calls — `curl`, `wget`, `http`, `git
 * clone/fetch/push`, `npm install`, `pip install`, `ssh`, `rsync`, and raw
 * host-like tokens. This isn't a complete network firewall; the OS-level
 * DNS / firewall does the heavy lifting in the "none" / "custom" modes.
 */
function extractHostnames(command: string): string[] {
  const hosts = new Set<string>();
  const tokens = command.split(/\s+/);
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i] ?? '';
    // `curl/wget <url>` — URL may be the next token or glued to the flag.
    if (/^(curl|wget)$/i.test(t)) {
      const next = tokens[i + 1] ?? '';
      const url = next.startsWith('-') ? (tokens[i + 2] ?? '') : next;
      if (url) hosts.add(url);
      continue;
    }
    // `git clone <url>` / `git fetch <remote>` etc.
    if (/^git$/i.test(t)) {
      const next = tokens[i + 1] ?? '';
      if (/^(clone|fetch|push|pull|ls-remote)$/i.test(next)) {
        const target = tokens[i + 2] ?? '';
        if (target) hosts.add(target);
      }
      continue;
    }
    // Package managers touch the network.
    if (/^(npm|pnpm|yarn|bun|pip|pip3|poetry|uv)$/i.test(t)) {
      // Mark "any" — they hit whatever registry is configured.
      hosts.add('*');
    }
  }
  // Also catch bare `https?://` or `ssh://` URLs in the raw command string.
  const urlRe = /\b((?:https?|ssh|git):\/\/[^\s'"]+)/gi;
  for (const match of command.matchAll(urlRe)) {
    const m = match[1] ?? '';
    if (m) hosts.add(m);
  }
  return [...hosts];
}

function hostnameOf(input: string): string | null {
  // Strip a scheme and pull the host out of an authority.
  const m = input.match(/^(?:[a-z]+:\/\/)?([^/\s:]+)/i);
  return m && m[1] ? m[1].toLowerCase() : null;
}

function isHostAllowed(
  host: string,
  policy: { access: string; allowedDomains: string[] }
): boolean {
  if (host === '*') return policy.access !== 'none';
  if (policy.access === 'trusted' || policy.access === 'limited') return true;
  if (policy.access === 'none') return false;
  // custom: allow only listed domains (and their subdomains).
  const h = host.toLowerCase();
  return policy.allowedDomains.some((d) => {
    const dom = d.trim().toLowerCase();
    if (!dom) return false;
    return h === dom || h.endsWith('.' + dom);
  });
}

function networkViolationMessage(
  command: string,
  policy: { access: string; allowedDomains: string[] }
): string {
  if (policy.access === 'none') {
    return `Network is disabled for this environment. Refusing to run: ${command}`;
  }
  return `Command is not in this environment's allowed domains (${policy.allowedDomains.join(', ')}): ${command}`;
}

/** Run a shell command in the session workdir, streaming stdout/stderr. */
export const bashTool: Tool = {
  name: 'bash',
  description:
    'Run a bash command in the repository working directory. Use for building, testing, running scripts, and inspecting the project. Output is captured and returned.',
  inputSchema: {
    type: 'object',
    properties: {
      command: { type: 'string', description: 'The bash command to run.' },
      timeoutMs: {
        type: 'number',
        description: 'Optional timeout in milliseconds (default 120000).',
      },
    },
    required: ['command'],
  },
  summarize(input) {
    const cmd = String(input.command ?? '');
    return `bash: ${cmd.length > 80 ? cmd.slice(0, 80) + '…' : cmd}`;
  },
  execute(input, ctx: ToolContext): Promise<ToolResult> {
    const command = String(input.command ?? '');
    const timeoutMs = Number(input.timeoutMs ?? 120_000);

    // Enforce the session's network policy. We only flag obvious network
    // calls so a benign `echo foo` never trips the gate. The OS-level
    // firewall / DNS is the real source of truth for actual traffic.
    const policy = ctx.network;
    if (policy && policy.access !== 'trusted' && policy.access !== 'limited') {
      const hosts = extractHostnames(command);
      const blocked = hosts.find((h) => {
        const host = hostnameOf(h);
        if (!host) return false;
        return !isHostAllowed(host, policy);
      });
      if (blocked) {
        return Promise.resolve({ ok: false, output: networkViolationMessage(command, policy) });
      }
    }

    return new Promise((resolve) => {
      const child = spawn('bash', ['-lc', command], {
        cwd: ctx.workdir,
        env: process.env,
      });
      let out = '';
      const append = (chunk: Buffer) => {
        const s = chunk.toString();
        out += s;
        ctx.onOutput?.(s);
      };
      child.stdout.on('data', append);
      child.stderr.on('data', append);

      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        out += `\n[timed out after ${timeoutMs}ms]`;
      }, timeoutMs);

      child.on('error', (err) => {
        clearTimeout(timer);
        resolve({ ok: false, output: truncate(`${out}\n${err.message}`) });
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        const status = code === 0 ? '' : `\n[exit code ${code}]`;
        resolve({ ok: code === 0, output: truncate(out + status) });
      });
    });
  },
};
