/**
 * Download + track Metal/MLX model weights under the product metal-models dir.
 *
 * Large weight files are **streamed** to disk (never fully buffered in RAM).
 * Progress is byte-weighted when Hugging Face reports sizes.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  rmSync,
  readdirSync,
  statSync,
  createWriteStream,
  renameSync,
} from "node:fs";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import path from "node:path";
import { productDataPath } from "../product.js";
import os from "node:os";
import {
  familyNameForHub,
  findMetalEntry,
  listChatMetalCatalog,
  sectionForEntry,
  type MetalCatalogEntry,
  type MetalSection,
} from "./catalog.js";

export interface MetalDownloadProgress {
  hubID: string;
  fraction: number;
  status: string;
  /** Optional human label for UI (e.g. file name). */
  file?: string;
  bytesDownloaded?: number;
  bytesTotal?: number;
}

export interface DownloadedMetalModel {
  hubID: string;
  localPath: string;
  downloadedAt: number;
  displayName: string;
}

interface StoreFile {
  models: DownloadedMetalModel[];
}

function defaultRoot(): string {
  return productDataPath("metal-models");
}

function safeDirName(hubID: string): string {
  return hubID.replace(/[^\w.-]+/g, "__");
}

export class MetalModelStore {
  readonly root: string;
  private indexPath: string;
  private models: DownloadedMetalModel[] = [];

  constructor(root = defaultRoot()) {
    this.root = root;
    this.indexPath = path.join(root, "index.json");
    mkdirSync(root, { recursive: true });
    this.load();
  }

  private load(): void {
    try {
      if (!existsSync(this.indexPath)) {
        this.models = [];
        return;
      }
      const parsed = JSON.parse(readFileSync(this.indexPath, "utf8")) as StoreFile;
      this.models = Array.isArray(parsed.models) ? parsed.models : [];
    } catch {
      this.models = [];
    }
  }

  private persist(): void {
    writeFileSync(this.indexPath, JSON.stringify({ models: this.models }, null, 2));
  }

  listDownloaded(): DownloadedMetalModel[] {
    return this.models.filter((m) => existsSync(m.localPath));
  }

  isDownloaded(hubID: string): boolean {
    const m = this.models.find((x) => x.hubID === hubID);
    return !!(m && existsSync(m.localPath) && this.looksLikeModelDir(m.localPath));
  }

  pathFor(hubID: string): string {
    return path.join(this.root, safeDirName(hubID));
  }

  private looksLikeModelDir(dir: string): boolean {
    if (!existsSync(dir) || !statSync(dir).isDirectory()) return false;
    const names = readdirSync(dir);
    // HF snapshot typically has config.json + weights
    return (
      names.includes("config.json") ||
      names.some((n) => n.endsWith(".safetensors") || n.endsWith(".npz") || n === "model.safetensors.index.json")
    );
  }

  markDownloaded(hubID: string, localPath: string): DownloadedMetalModel {
    const entry = findMetalEntry(hubID);
    const rec: DownloadedMetalModel = {
      hubID,
      localPath,
      downloadedAt: Date.now(),
      displayName: entry?.displayName ?? hubID,
    };
    this.models = this.models.filter((m) => m.hubID !== hubID);
    this.models.push(rec);
    this.persist();
    return rec;
  }

  delete(hubID: string): void {
    const local = this.pathFor(hubID);
    if (existsSync(local)) {
      rmSync(local, { recursive: true, force: true });
    }
    this.models = this.models.filter((m) => m.hubID !== hubID);
    this.persist();
  }

  catalogWithStatus(): Array<
    MetalCatalogEntry & {
      downloaded: boolean;
      localPath?: string;
      family: string;
      section: MetalSection;
    }
  > {
    return listChatMetalCatalog().map((e) => {
      const downloaded = this.isDownloaded(e.hubID);
      return {
        ...e,
        family: familyNameForHub(e.hubID),
        section: sectionForEntry(e),
        downloaded,
        localPath: downloaded ? this.pathFor(e.hubID) : undefined,
      };
    });
  }

  /** Sum of on-disk sizes for downloaded model directories. */
  totalStorageBytes(): number {
    let total = 0;
    for (const m of this.listDownloaded()) {
      total += dirSize(m.localPath);
    }
    return total;
  }

  deleteAll(): number {
    const ids = this.listDownloaded().map((m) => m.hubID);
    for (const id of ids) this.delete(id);
    return ids.length;
  }

  /**
   * Download a model snapshot from Hugging Face into the local store.
   * Uses the public Hub API (no token required for public models).
   * Streams each file to disk so multi‑GB weights do not OOM the process.
   */
  async download(
    hubID: string,
    onProgress?: (p: MetalDownloadProgress) => void,
    signal?: AbortSignal,
  ): Promise<DownloadedMetalModel> {
    const dest = this.pathFor(hubID);
    mkdirSync(dest, { recursive: true });
    onProgress?.({ hubID, fraction: 0, status: "Listing files…" });

    const tree = await listRepoFiles(hubID, signal);
    const files = tree.filter((f) => f.type === "file" && !f.path.includes(".git"));
    if (files.length === 0) {
      throw new Error(
        `No files found for ${hubID} on Hugging Face. Check the hub id or network.`,
      );
    }

    const toFetch = selectModelFiles(files);
    if (toFetch.length === 0) {
      throw new Error(`No model files found for ${hubID} after filtering the repo tree.`);
    }

    const totalBytes = toFetch.reduce((sum, f) => sum + (f.size && f.size > 0 ? f.size : 0), 0);
    let bytesDone = 0;
    let filesDone = 0;

    const report = (status: string, file?: string, fileBytes = 0) => {
      const known = totalBytes > 0;
      const fraction = known
        ? Math.min(0.999, (bytesDone + fileBytes) / totalBytes)
        : filesDone / toFetch.length;
      onProgress?.({
        hubID,
        fraction,
        status,
        file,
        bytesDownloaded: known ? bytesDone + fileBytes : undefined,
        bytesTotal: known ? totalBytes : undefined,
      });
    };

    try {
      for (const file of toFetch) {
        if (signal?.aborted) {
          throw new Error("Download cancelled");
        }
        const target = path.join(dest, file.path);
        mkdirSync(path.dirname(target), { recursive: true });
        const expected = file.size && file.size > 0 ? file.size : undefined;

        // Resume: skip files already fully present.
        if (expected && existsSync(target)) {
          try {
            if (statSync(target).size === expected) {
              bytesDone += expected;
              filesDone += 1;
              report(`Skipped ${file.path} (already on disk)`, file.path);
              continue;
            }
          } catch {
            // re-download
          }
        }

        report(`Downloading ${file.path}…`, file.path, 0);
        await downloadFileStreaming(hubID, file.path, target, signal, (written) => {
          report(`Downloading ${file.path}…`, file.path, written);
        });

        // Verify size when Hub reported one.
        if (expected) {
          const got = statSync(target).size;
          if (got !== expected) {
            throw new Error(
              `Incomplete download of ${file.path}: got ${got} bytes, expected ${expected}.`,
            );
          }
          bytesDone += expected;
        } else {
          bytesDone += statSync(target).size;
        }
        filesDone += 1;
        report(`Downloaded ${filesDone}/${toFetch.length}`, file.path);
      }
    } catch (err) {
      // Leave partial files for resume; surface a clear message.
      const msg = err instanceof Error ? err.message : String(err);
      throw new Error(`Download failed for ${hubID}: ${msg}`);
    }

    if (!this.looksLikeModelDir(dest)) {
      throw new Error(
        `Download finished but ${hubID} does not look like a complete MLX model (missing config/weights).`,
      );
    }

    onProgress?.({ hubID, fraction: 1, status: "Ready", bytesDownloaded: bytesDone, bytesTotal: totalBytes || bytesDone });
    return this.markDownloaded(hubID, dest);
  }
}

interface HFTreeEntry {
  type: "file" | "directory";
  path: string;
  size?: number;
}

/** Pick weights + tokenizer/config; drop README / images / git. */
function selectModelFiles(files: HFTreeEntry[]): HFTreeEntry[] {
  const skipName = /^(readme|license|notice|\.gitattributes)/i;
  const skipExt = /\.(md|png|jpg|jpeg|gif|webp|svg|html|pdf|onnx|bin\.index\.json)$/i;
  const keep = files.filter((f) => {
    const base = path.basename(f.path);
    if (skipName.test(base)) return false;
    if (skipExt.test(base)) return false;
    if (f.path.includes(".git/")) return false;
    // Keep model weights, configs, tokenizer pieces, chat templates.
    if (/\.(safetensors|json|txt|model|jinja|tiktoken)$/i.test(base)) return true;
    if (/^(config|tokenizer|special_tokens|generation_config|vocab|merges|added_tokens)/i.test(base)) {
      return true;
    }
    if (base.includes("tokenizer") || base.includes("vocab") || base.includes("merges")) return true;
    if (f.path.endsWith(".safetensors") || f.path.endsWith(".json")) return true;
    return false;
  });
  // Prefer larger / weight files last? Keep hub order but put small configs first
  // so a failure mid-weight still leaves configs for debugging.
  return keep.slice().sort((a, b) => {
    const aw = /\.safetensors$/i.test(a.path) ? 1 : 0;
    const bw = /\.safetensors$/i.test(b.path) ? 1 : 0;
    if (aw !== bw) return aw - bw;
    return (a.size ?? 0) - (b.size ?? 0);
  });
}

async function listRepoFiles(hubID: string, signal?: AbortSignal): Promise<HFTreeEntry[]> {
  // Hub ids are `org/name` — do not encode the slash.
  const url = `https://huggingface.co/api/models/${hubID}/tree/main?recursive=1`;
  const res = await fetch(url, {
    signal,
    headers: {
      "user-agent": "RoamSocket-desktop/1.0 (metal-store)",
      accept: "application/json",
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Hugging Face tree failed ${res.status} for ${hubID}: ${body.slice(0, 200)}`);
  }
  const json = (await res.json()) as HFTreeEntry[];
  return Array.isArray(json) ? json : [];
}

/**
 * Stream a Hub file to disk. Never buffers the whole body in RAM.
 */
async function downloadFileStreaming(
  hubID: string,
  filePath: string,
  dest: string,
  signal?: AbortSignal,
  onBytes?: (written: number) => void,
): Promise<void> {
  const encodedPath = filePath
    .split("/")
    .map((seg) => encodeURIComponent(seg))
    .join("/");
  const url = `https://huggingface.co/${hubID}/resolve/main/${encodedPath}?download=true`;
  const res = await fetch(url, {
    signal,
    headers: {
      "user-agent": "RoamSocket-desktop/1.0 (metal-store)",
    },
    redirect: "follow",
  });
  if (!res.ok || !res.body) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `Failed to download ${filePath}: HTTP ${res.status}${body ? ` — ${body.slice(0, 160)}` : ""}`,
    );
  }

  const partial = `${dest}.partial`;
  try {
    if (existsSync(partial)) rmSync(partial, { force: true });
    if (existsSync(dest)) rmSync(dest, { force: true });

    const nodeStream = Readable.fromWeb(res.body as import("stream/web").ReadableStream, { signal });
    let written = 0;
    let lastReport = 0;
    nodeStream.on("data", (chunk: Buffer | string) => {
      written += typeof chunk === "string" ? Buffer.byteLength(chunk) : chunk.length;
      // Throttle progress so multi‑GB files don't flood the renderer.
      if (written - lastReport >= 512 * 1024 || lastReport === 0) {
        lastReport = written;
        onBytes?.(written);
      }
    });
    await pipeline(nodeStream, createWriteStream(partial), { signal });
    onBytes?.(written);
    // Atomic rename so a crash mid-write never leaves a half "complete" file.
    renameSync(partial, dest);
  } catch (err) {
    try {
      if (existsSync(partial)) rmSync(partial, { force: true });
    } catch {
      /* ignore */
    }
    throw err;
  }
}

function dirSize(root: string): number {
  if (!existsSync(root)) return 0;
  let total = 0;
  const walk = (dir: string) => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const full = path.join(dir, name);
      try {
        const st = statSync(full);
        if (st.isDirectory()) walk(full);
        else total += st.size;
      } catch {
        // skip unreadable
      }
    }
  };
  walk(root);
  return total;
}

let sharedStore: MetalModelStore | null = null;
export function getMetalStore(root?: string): MetalModelStore {
  if (root) return new MetalModelStore(root);
  if (!sharedStore) sharedStore = new MetalModelStore();
  return sharedStore;
}
