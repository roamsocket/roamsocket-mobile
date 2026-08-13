/**
 * GitHub pull-request presentation for the Code session PR chip.
 * Colors / icons / labels change by PR state (open, draft, merged, closed).
 */

export type GitHubPrState = 'open' | 'draft' | 'merged' | 'closed' | 'unknown';

export interface ParsedPrUrl {
  url: string;
  owner: string;
  repo: string;
  /** Short repo label (repo name only, matching Claude chip). */
  repoLabel: string;
  number: number;
  apiUrl: string;
}

export interface PrChipModel {
  url: string;
  number: number | null;
  owner: string | null;
  repo: string | null;
  repoLabel: string;
  branch: string | null;
  state: GitHubPrState;
  stateLabel: string;
  /** CSS modifier class: pr-open | pr-draft | pr-merged | pr-closed | pr-unknown */
  toneClass: string;
  /** Unicode/simple icon glyph for the chip leading mark */
  icon: string;
}

/** Parse https://github.com/owner/repo/pull/225 (and compare URLs when possible). */
export function parseGitHubPrUrl(url: string): ParsedPrUrl | null {
  try {
    const u = new URL(url.trim());
    if (!/github\.com$/i.test(u.hostname.replace(/^www\./, ''))) return null;
    // /owner/repo/pull/123
    const m = u.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)/i);
    if (!m) return null;
    const owner = m[1]!;
    const repo = m[2]!;
    const number = Number(m[3]);
    if (!Number.isFinite(number)) return null;
    return {
      url: `https://github.com/${owner}/${repo}/pull/${number}`,
      owner,
      repo,
      repoLabel: repo,
      number,
      apiUrl: `https://api.github.com/repos/${owner}/${repo}/pulls/${number}`,
    };
  } catch {
    return null;
  }
}

export function prStateFromGitHub(json: {
  state?: string;
  draft?: boolean;
  merged?: boolean;
  merged_at?: string | null;
}): GitHubPrState {
  if (json.merged === true || json.merged_at) return 'merged';
  if (json.state === 'closed') return 'closed';
  if (json.draft === true) return 'draft';
  if (json.state === 'open') return 'open';
  return 'unknown';
}

export function prChipFromParts(opts: {
  url: string;
  state?: GitHubPrState;
  branch?: string | null;
  number?: number | null;
  repoLabel?: string | null;
  owner?: string | null;
  repo?: string | null;
}): PrChipModel {
  const parsed = parseGitHubPrUrl(opts.url);
  const state = opts.state ?? 'open';
  const number = opts.number ?? parsed?.number ?? null;
  const repoLabel = opts.repoLabel ?? parsed?.repoLabel ?? 'repo';
  const { stateLabel, toneClass, icon } = prStatePresentation(state);
  return {
    url: parsed?.url ?? opts.url,
    number,
    owner: opts.owner ?? parsed?.owner ?? null,
    repo: opts.repo ?? parsed?.repo ?? null,
    repoLabel,
    branch: opts.branch ?? null,
    state,
    stateLabel,
    toneClass,
    icon,
  };
}

export function prStatePresentation(state: GitHubPrState): {
  stateLabel: string;
  toneClass: string;
  icon: string;
} {
  switch (state) {
    case 'merged':
      return { stateLabel: 'Merged', toneClass: 'pr-merged', icon: '⑂' };
    case 'closed':
      return { stateLabel: 'Closed', toneClass: 'pr-closed', icon: '⊗' };
    case 'draft':
      return { stateLabel: 'Draft', toneClass: 'pr-draft', icon: '◌' };
    case 'open':
      return { stateLabel: 'Open', toneClass: 'pr-open', icon: '⑂' };
    default:
      return { stateLabel: 'PR', toneClass: 'pr-unknown', icon: '⑂' };
  }
}

/**
 * Fetch live PR state from GitHub (optional token for private repos / rate limits).
 */
export async function fetchGitHubPrState(
  url: string,
  token?: string | null
): Promise<{
  state: GitHubPrState;
  branch: string | null;
  title: string | null;
  number: number;
  repoLabel: string;
} | null> {
  const parsed = parseGitHubPrUrl(url);
  if (!parsed) return null;
  const headers: Record<string, string> = {
    accept: 'application/vnd.github+json',
    'user-agent': 'RoamSocket-desktop',
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(parsed.apiUrl, { headers });
  if (!res.ok) return null;
  const json = (await res.json()) as {
    state?: string;
    draft?: boolean;
    merged?: boolean;
    merged_at?: string | null;
    title?: string;
    head?: { ref?: string };
  };
  return {
    state: prStateFromGitHub(json),
    branch: json.head?.ref ?? null,
    title: json.title ?? null,
    number: parsed.number,
    repoLabel: parsed.repoLabel,
  };
}
