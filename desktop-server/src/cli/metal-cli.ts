/**
 * Metal / MLX helpers for the RoamSocket CLI TUI: catalog list, hub resolve,
 * download/delete/use, and slash completions.
 */
import { getMetalRuntimeStatus } from "../metal/runtime.js";
import { getMetalStore, type MetalDownloadProgress } from "../metal/store.js";
import type { SlashCompletion } from "./commands.js";

export type MetalCliAction =
  | { op: "list" }
  | { op: "browse" }
  | { op: "download"; query: string }
  | { op: "delete"; query: string }
  | { op: "use"; query: string }
  | { op: "runtime" }
  | { op: "install-runtime" }
  | { op: "help" };

const METAL_SUBS = [
  "browse",
  "list",
  "download",
  "delete",
  "use",
  "runtime",
  "install-runtime",
  "help",
] as const;

export function parseMetalArgs(arg: string): MetalCliAction {
  const t = arg.trim();
  if (!t) return { op: "browse" };
  const [head, ...rest] = t.split(/\s+/);
  const cmd = (head ?? "").toLowerCase();
  const restJoin = rest.join(" ").trim();

  switch (cmd) {
    case "browse":
    case "ui":
    case "models":
      return { op: "browse" };
    case "list":
    case "ls":
    case "catalog":
      // Interactive browser (same as bare /metal). Text dump via formatMetalCatalogList for scripts.
      return { op: "browse" };
    case "download":
    case "get":
    case "pull":
    case "install":
      if (!restJoin) return { op: "help" };
      // "install runtime" → install-runtime
      if (restJoin.toLowerCase() === "runtime") return { op: "install-runtime" };
      return { op: "download", query: restJoin };
    case "delete":
    case "rm":
    case "remove":
      return restJoin ? { op: "delete", query: restJoin } : { op: "help" };
    case "use":
    case "select":
      return restJoin ? { op: "use", query: restJoin } : { op: "help" };
    case "runtime":
    case "status":
      return { op: "runtime" };
    case "install-runtime":
    case "setup":
      return { op: "install-runtime" };
    case "help":
    case "?":
      return { op: "help" };
    default:
      // Bare query → treat as download target (e.g. /metal Qwen 3 0.6B)
      return { op: "download", query: t };
  }
}

export function metalHelpText(): string {
  return `Metal / on-device MLX models (macOS)

  /metal                      Open the model browser (families + download/use)
  /metal browse               Same as bare /metal
  /metal list                 Same as bare /metal
  /metal download <name|id>   Download from Hugging Face (public models)
  /metal use <name|id>        Switch agent to localMetal/<hubID>
  /metal delete <name|id>     Remove a downloaded model
  /metal runtime              mlx-lm / Python runtime status
  /metal install-runtime      Install managed Python + mlx-lm
  /metal help                 This help

  Browser keys: ↑↓ navigate · Enter open/use/download · d download · u use · x delete
                ←/Esc back · i install runtime · q close

  After download: /model localMetal/<hubID>  or  /metal use <name>

  Examples:
    /metal
    /metal download Qwen 3 0.6B
    /metal download lmstudio-community/Qwen3-0.6B-MLX-4bit
    /metal use Qwen 3 0.6B`;
}

/** One selectable model row in the TUI Metal browser. */
export interface MetalBrowserModel {
  hubID: string;
  displayName: string;
  approxSize: string;
  blurb: string;
  tags: string[];
  downloaded: boolean;
  family: string;
  section: string;
}

/** Family group for the TUI Metal browser root list. */
export interface MetalBrowserFamily {
  name: string;
  blurb: string;
  models: MetalBrowserModel[];
  downloadedCount: number;
  /** featured | more | legacy | experimental */
  group: "featured" | "more" | "legacy" | "experimental";
}

export interface MetalBrowserSnapshot {
  families: MetalBrowserFamily[];
  /** Downloaded models (catalog + extras). */
  onDevice: MetalBrowserModel[];
  storageBytes: number;
  storageLabel: string;
  storeRoot: string;
}

function toBrowserModel(e: {
  hubID: string;
  displayName: string;
  approxSize?: string;
  blurb?: string;
  tags?: string[];
  downloaded: boolean;
  family: string;
  section?: string;
}): MetalBrowserModel {
  return {
    hubID: e.hubID,
    displayName: e.displayName,
    approxSize: e.approxSize ?? "",
    blurb: e.blurb ?? "",
    tags: e.tags ?? [],
    downloaded: e.downloaded,
    family: e.family,
    section: e.section ?? "standard",
  };
}

/**
 * Snapshot for the interactive TUI Metal browser (families + on-device).
 * Pure over the current Metal store — safe to unit-test.
 */
export function getMetalBrowserSnapshot(): MetalBrowserSnapshot {
  const store = getMetalStore();
  const rows = store.catalogWithStatus();
  const catalogIds = new Set(rows.map((r) => r.hubID));

  const byFamily = new Map<string, MetalBrowserModel[]>();
  for (const e of rows) {
    const m = toBrowserModel(e);
    const list = byFamily.get(e.family) ?? [];
    list.push(m);
    byFamily.set(e.family, list);
  }

  const featuredFamilies = new Set<string>();
  for (const e of rows) {
    if (e.section === "featured" || e.tags.includes("recommended") || e.tags.includes("best")) {
      featuredFamilies.add(e.family);
    }
  }

  const families: MetalBrowserFamily[] = [...byFamily.keys()]
    .sort((a, b) => a.localeCompare(b))
    .map((name) => {
      const models = (byFamily.get(name) ?? []).slice().sort((a, b) =>
        a.displayName.localeCompare(b.displayName),
      );
      const hasLegacy = models.every((m) => m.section === "legacy" || m.tags.includes("legacy"));
      const hasExperimental = models.every(
        (m) => m.section === "experimental" || m.tags.includes("experimental"),
      );
      let group: MetalBrowserFamily["group"] = "more";
      if (featuredFamilies.has(name) && !hasLegacy && !hasExperimental) group = "featured";
      else if (hasLegacy) group = "legacy";
      else if (hasExperimental) group = "experimental";
      return {
        name,
        blurb: metalFamilyBlurb(name),
        models,
        downloadedCount: models.filter((m) => m.downloaded).length,
        group,
      };
    });

  // Order: featured, more, experimental, legacy
  const groupOrder = { featured: 0, more: 1, experimental: 2, legacy: 3 };
  families.sort(
    (a, b) => groupOrder[a.group] - groupOrder[b.group] || a.name.localeCompare(b.name),
  );

  const onDevice: MetalBrowserModel[] = [];
  for (const e of rows.filter((r) => r.downloaded)) {
    onDevice.push(toBrowserModel(e));
  }
  for (const m of store.listDownloaded()) {
    if (catalogIds.has(m.hubID)) continue;
    onDevice.push(
      toBrowserModel({
        hubID: m.hubID,
        displayName: m.displayName,
        downloaded: true,
        family: familyNameFromHub(m.hubID),
        blurb: "",
        approxSize: "",
        tags: [],
        section: "standard",
      }),
    );
  }
  onDevice.sort((a, b) => a.displayName.localeCompare(b.displayName));

  const storageBytes = store.totalStorageBytes();
  const storageLabel =
    storageBytes > 0 ? `${(storageBytes / 1e9).toFixed(2)} GB on disk` : "0 B on disk";

  return {
    families,
    onDevice,
    storageBytes,
    storageLabel,
    storeRoot: store.root,
  };
}

function metalFamilyBlurb(name: string): string {
  // Keep blurbs in sync with catalog.familyBlurb without circular import issues
  // (metal-cli already imports store which imports catalog).
  switch (name) {
    case "Llama":
      return "Meta’s Llama instruct models. Strong general chat in compact sizes.";
    case "Qwen":
      return "Qwen models — strong multilingual chat and instruction following.";
    case "Gemma":
      return "Google Gemma — compact chat variants optimized for Metal.";
    case "LFM":
      return "Liquid AI LFM — efficient chat for on-device inference.";
    case "Phi":
      return "Microsoft Phi — compact reasoning and chat.";
    case "Mistral":
      return "Mistral instruct models. Capable chat; larger variants need more RAM.";
    case "SmolLM":
      return "Ultra-small instruct models for quick replies and low storage.";
    case "Granite":
      return "IBM Granite instruct models for enterprise-style chat on device.";
    case "DeepSeek":
      return "DeepSeek distill / reasoning models.";
    default:
      return "Open MLX models ready for on-device Metal chat.";
  }
}

function familyNameFromHub(hubID: string): string {
  const leaf = hubID.split("/").pop() ?? hubID;
  const lower = leaf.toLowerCase();
  if (lower.includes("qwen")) return "Qwen";
  if (lower.includes("lfm")) return "LFM";
  if (lower.includes("gemma")) return "Gemma";
  if (lower.includes("llama")) return "Llama";
  if (lower.includes("phi")) return "Phi";
  if (lower.includes("mistral") || lower.includes("mixtral")) return "Mistral";
  return "Other";
}

export function formatMetalCatalogList(): string {
  const store = getMetalStore();
  const rows = store.catalogWithStatus();
  const downloaded = store.listDownloaded();
  const lines: string[] = [
    `Metal catalog (${rows.length} recommended) · store: ${store.root}`,
    "",
  ];

  for (const e of rows) {
    const mark = e.downloaded ? "✓" : "·";
    lines.push(
      `${mark} ${e.displayName}  ${e.approxSize ?? ""}`.trimEnd(),
    );
    lines.push(`    ${e.hubID}`);
    if (e.blurb) lines.push(`    ${e.blurb}`);
  }

  // Downloaded hub IDs not in the recommended catalog
  const catalogIds = new Set(rows.map((r) => r.hubID));
  const extras = downloaded.filter((m) => !catalogIds.has(m.hubID));
  if (extras.length > 0) {
    lines.push("");
    lines.push("Also downloaded (not in recommended list):");
    for (const m of extras) {
      lines.push(`✓ ${m.displayName}`);
      lines.push(`    ${m.hubID}`);
    }
  }

  const bytes = store.totalStorageBytes();
  const gb = bytes > 0 ? ` · ${(bytes / 1e9).toFixed(2)} GB on disk` : "";
  lines.push("");
  lines.push(
    `${downloaded.length} downloaded${gb}.  /metal download <name>  ·  /metal use <name>`,
  );
  return lines.join("\n");
}

export async function formatMetalRuntimeStatus(): Promise<string> {
  const st = await getMetalRuntimeStatus();
  const store = getMetalStore();
  const n = store.listDownloaded().length;
  const lines = [
    `Metal runtime: ${st.runtimeReady ? "ready" : "not ready"} (${st.runtimeLabel})`,
    st.detail,
    st.pythonPath ? `Python: ${st.pythonPath}` : "Python: (none)",
    `Platform: ${st.platform}/${st.arch} · supported: ${st.supported ? "yes" : "no"}`,
    `Downloaded models: ${n}`,
    `Store: ${store.root}`,
  ];
  if (!st.runtimeReady) {
    lines.push("Run /metal install-runtime to set up Python + mlx-lm (macOS).");
  }
  return lines.join("\n");
}

/**
 * Resolve a user query to a hub id. Accepts exact hub IDs, display names,
 * and unique partial matches against the catalog + downloaded set.
 */
export function resolveMetalHubQuery(query: string):
  | { ok: true; hubID: string; displayName: string }
  | { ok: false; error: string; suggestions?: string[] } {
  const q = query.trim();
  if (!q) return { ok: false, error: "Specify a model name or hub id." };

  const store = getMetalStore();
  const catalog = store.catalogWithStatus();
  const downloaded = store.listDownloaded();

  // Exact hub id (catalog or free-form HF id with a slash)
  const exactCat = catalog.find((e) => e.hubID === q || e.hubID.toLowerCase() === q.toLowerCase());
  if (exactCat) {
    return { ok: true, hubID: exactCat.hubID, displayName: exactCat.displayName };
  }
  const exactDl = downloaded.find((m) => m.hubID === q || m.hubID.toLowerCase() === q.toLowerCase());
  if (exactDl) {
    return { ok: true, hubID: exactDl.hubID, displayName: exactDl.displayName };
  }
  // Looks like org/name — allow download even if not in recommended list
  if (q.includes("/") && !/\s/.test(q)) {
    return { ok: true, hubID: q, displayName: q.split("/").pop() ?? q };
  }

  const ql = q.toLowerCase();
  type Hit = { hubID: string; displayName: string; score: number };
  const hits: Hit[] = [];

  const consider = (hubID: string, displayName: string) => {
    const dl = displayName.toLowerCase();
    const hl = hubID.toLowerCase();
    let score = 0;
    if (dl === ql) score = 100;
    else if (dl.startsWith(ql)) score = 80;
    else if (dl.includes(ql)) score = 60;
    else if (hl.includes(ql.replace(/\s+/g, ""))) score = 40;
    else if (hl.includes(ql.replace(/\s+/g, "-"))) score = 40;
    else if (ql.split(/\s+/).every((w) => dl.includes(w) || hl.includes(w))) score = 50;
    else return;
    hits.push({ hubID, displayName, score });
  };

  for (const e of catalog) consider(e.hubID, e.displayName);
  for (const m of downloaded) consider(m.hubID, m.displayName);

  hits.sort((a, b) => b.score - a.score);
  // Dedupe by hubID
  const seen = new Set<string>();
  const unique = hits.filter((h) => {
    if (seen.has(h.hubID)) return false;
    seen.add(h.hubID);
    return true;
  });

  if (unique.length === 0) {
    return {
      ok: false,
      error: `No Metal model matched “${q}”. Try /metal list or a full hub id (org/name).`,
    };
  }
  if (unique.length === 1 || (unique[0]!.score >= 80 && unique[0]!.score > (unique[1]?.score ?? 0))) {
    const h = unique[0]!;
    return { ok: true, hubID: h.hubID, displayName: h.displayName };
  }
  return {
    ok: false,
    error: `Ambiguous “${q}” — pick one:`,
    suggestions: unique.slice(0, 8).map((h) => `${h.displayName}  (${h.hubID})`),
  };
}

export function formatDownloadProgress(p: MetalDownloadProgress): string {
  const pct = Math.round(Math.min(1, Math.max(0, p.fraction)) * 100);
  const file = p.file ? ` · ${p.file}` : "";
  let bytes = "";
  if (p.bytesTotal && p.bytesTotal > 0 && p.bytesDownloaded != null) {
    bytes = ` · ${formatBytes(p.bytesDownloaded)}/${formatBytes(p.bytesTotal)}`;
  }
  return `Metal ${pct}%${bytes}${file} · ${p.status}`;
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

/** Completions for `/metal …`. */
export function getMetalCompletions(argPart: string, fullInput: string): SlashCompletion[] {
  const prefix = fullInput.slice(0, fullInput.length - argPart.length);
  const trimmedEnd = argPart.replace(/\s+$/, "");
  const hasSpace = /\s/.test(argPart);
  const parts = trimmedEnd.split(/\s+/).filter(Boolean);

  if (!hasSpace && parts.length <= 1) {
    const q = (parts[0] ?? "").toLowerCase();
    return METAL_SUBS.filter((s) => s.startsWith(q) || q === "")
      .slice(0, 10)
      .map((s) => ({
        token: `${prefix}${s}${
          s === "list" ||
          s === "browse" ||
          s === "runtime" ||
          s === "help" ||
          s === "install-runtime"
            ? ""
            : " "
        }`,
        description: metalSubDescription(s),
      }));
  }

  const sub = (parts[0] ?? "").toLowerCase();
  const rest = parts.slice(1).join(" ");
  const restQ = (argPart.endsWith(" ") && parts.length === 1 ? "" : rest).toLowerCase();

  if (sub === "download" || sub === "get" || sub === "pull" || sub === "install") {
    if (restQ === "runtime" || "runtime".startsWith(restQ)) {
      // also offer install runtime via download path? skip
    }
    return completeMetalTargets(prefix, sub, restQ, { preferNotDownloaded: true });
  }
  if (sub === "delete" || sub === "rm" || sub === "remove") {
    return completeMetalTargets(prefix, sub, restQ, { downloadedOnly: true });
  }
  if (sub === "use" || sub === "select") {
    return completeMetalTargets(prefix, sub, restQ, { downloadedOnly: true });
  }
  return [];
}

function metalSubDescription(s: string): string {
  switch (s) {
    case "browse":
      return "Open interactive model browser";
    case "list":
      return "Open model browser (same as /metal)";
    case "download":
      return "Download a model from Hugging Face";
    case "delete":
      return "Remove a downloaded model";
    case "use":
      return "Switch agent to a downloaded Metal model";
    case "runtime":
      return "Runtime / mlx-lm status";
    case "install-runtime":
      return "Install Python + mlx-lm";
    case "help":
      return "Metal command help";
    default:
      return "";
  }
}

function completeMetalTargets(
  prefix: string,
  sub: string,
  restQ: string,
  opts: { downloadedOnly?: boolean; preferNotDownloaded?: boolean },
): SlashCompletion[] {
  const store = getMetalStore();
  const catalog = store.catalogWithStatus();
  let entries = catalog.map((e) => ({
    hubID: e.hubID,
    displayName: e.displayName,
    downloaded: e.downloaded,
    size: e.approxSize ?? "",
  }));

  if (opts.downloadedOnly) {
    entries = entries.filter((e) => e.downloaded);
    // include non-catalog downloads
    for (const m of store.listDownloaded()) {
      if (!entries.some((e) => e.hubID === m.hubID)) {
        entries.push({
          hubID: m.hubID,
          displayName: m.displayName,
          downloaded: true,
          size: "",
        });
      }
    }
  } else if (opts.preferNotDownloaded) {
    // not-downloaded first, then downloaded
    entries = [
      ...entries.filter((e) => !e.downloaded),
      ...entries.filter((e) => e.downloaded),
    ];
  }

  const q = restQ.toLowerCase();
  const filtered = entries.filter(
    (e) =>
      !q ||
      e.displayName.toLowerCase().includes(q) ||
      e.hubID.toLowerCase().includes(q),
  );

  return filtered.slice(0, 12).map((e) => ({
    token: `${prefix}${sub} ${e.hubID}`,
    description: `${e.displayName}${e.size ? ` · ${e.size}` : ""}${e.downloaded ? " · ✓" : ""}`,
  }));
}
