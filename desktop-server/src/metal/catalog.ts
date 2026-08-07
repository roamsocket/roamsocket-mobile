/**
 * On-device Metal / MLX model catalog for desktop chat + coding.
 * Mirrors the phone-friendly recommended set from iOS LocalMetalCatalog,
 * excluding Vision-tagged models (Vision is not a desktop destination).
 *
 * Browse UI groups entries by **family** (Qwen, Gemma, LFM, …) like the
 * mobile Manage models screen.
 */

export type MetalTag =
  | "recommended"
  | "best"
  | "thinking"
  | "vision"
  | "new"
  | "experimental"
  | "legacy";

/** Browse section on the Manage models screen. */
export type MetalSection = "featured" | "standard" | "experimental" | "legacy";

export interface MetalCatalogEntry {
  hubID: string;
  displayName: string;
  approxSize: string;
  blurb: string;
  tags: MetalTag[];
  /** Chat-primary catalog flag (coding can still use downloaded desktop models). */
  chatOnly: true;
}

/**
 * Optional remote / marketplace override (set by marketplace apply).
 * When null, `listChatMetalCatalog` uses the bundled recommended list.
 */
let remoteMetalCatalog: MetalCatalogEntry[] | null = null;

/** Replace the live Metal catalog from marketplace merge. Pass null to reset. */
export function setRemoteMetalCatalog(entries: MetalCatalogEntry[] | null): void {
  remoteMetalCatalog =
    entries && entries.length > 0
      ? entries.map((e) => ({ ...e, chatOnly: true as const }))
      : null;
}

export function getRemoteMetalCatalog(): MetalCatalogEntry[] | null {
  return remoteMetalCatalog;
}

/** Curated desktop chat models (no Vision). Bundled fallback. */
export const RECOMMENDED_METAL_MODELS: MetalCatalogEntry[] = [
  {
    hubID: "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit",
    displayName: "LFM2.5 1.2B",
    approxSize: "~0.7 GB",
    blurb: "Liquid AI LFM2.5 — strong everyday chat and a great on-device starting point.",
    tags: ["recommended", "best", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen3-0.6B-MLX-4bit",
    displayName: "Qwen 3 0.6B",
    approxSize: "~0.4 GB",
    blurb: "Tiny Qwen 3 for low storage and fast replies.",
    tags: ["recommended", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
    displayName: "Qwen 3 1.7B",
    approxSize: "~1.0 GB",
    blurb: "Balanced Qwen 3 size for everyday on-device chat.",
    tags: ["recommended", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen3-4B-Instruct-2507-MLX-4bit",
    displayName: "Qwen 3 4B Instruct",
    approxSize: "~2.3 GB",
    blurb: "Stronger Qwen 3 instruct for higher quality when RAM allows.",
    tags: ["recommended", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen3-4B-Thinking-2507-MLX-4bit",
    displayName: "Qwen 3 4B Thinking",
    approxSize: "~2.3 GB",
    blurb: "Qwen 3 thinking variant for chain-of-thought style replies.",
    tags: ["recommended", "thinking", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen2.5-0.5B-Instruct-MLX-4bit",
    displayName: "Qwen 2.5 0.5B",
    approxSize: "~0.3 GB",
    blurb: "Ultra-small Qwen 2.5 instruct for smoke tests and tight storage.",
    tags: ["recommended"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen2.5-1.5B-Instruct-MLX-4bit",
    displayName: "Qwen 2.5 1.5B",
    approxSize: "~0.9 GB",
    blurb: "Compact multilingual instruct model with solid multi-turn chat.",
    tags: ["recommended"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen2.5-3B-Instruct-MLX-4bit",
    displayName: "Qwen 2.5 3B",
    approxSize: "~1.8 GB",
    blurb: "Larger Qwen 2.5 instruct for higher-quality chat when RAM allows.",
    tags: ["recommended"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Qwen2.5-Coder-1.5B-Instruct-MLX-4bit",
    displayName: "Qwen 2.5 Coder 1.5B",
    approxSize: "~0.9 GB",
    blurb: "Small code-focused instruct model for on-device coding chat.",
    tags: ["recommended"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/Phi-4-mini-reasoning-MLX-4bit",
    displayName: "Phi 4 Mini Reasoning",
    approxSize: "~2.2 GB",
    blurb: "Microsoft Phi 4 mini for compact reasoning and chat.",
    tags: ["recommended", "thinking", "new"],
    chatOnly: true,
  },
  {
    hubID: "lmstudio-community/gemma-3-270m-it-qat-MLX-4bit",
    displayName: "Gemma 3 270M QAT",
    approxSize: "~0.2 GB",
    blurb: "Tiny Gemma for smoke tests and ultra-low storage.",
    tags: ["recommended"],
    chatOnly: true,
  },
];

export function listChatMetalCatalog(): MetalCatalogEntry[] {
  const base = remoteMetalCatalog ?? RECOMMENDED_METAL_MODELS;
  // Explicitly drop vision-tagged entries if any sneak in.
  return base.filter((e) => !e.tags.includes("vision"));
}

export function findMetalEntry(hubID: string): MetalCatalogEntry | undefined {
  return listChatMetalCatalog().find((e) => e.hubID === hubID);
}

export function displayNameForHub(hubID: string): string {
  return findMetalEntry(hubID)?.displayName ?? prettyNameFromHub(hubID);
}

export function prettyNameFromHub(hubID: string): string {
  const leaf = hubID.split("/").pop() ?? hubID;
  let s = leaf
    .replace(/-MLX-\d+bit/gi, "")
    .replace(/-MLX/gi, "")
    .replace(/-\d+bit/gi, "")
    .replace(/-it-qat/gi, "")
    .replace(/-qat/gi, " QAT")
    .replace(/-it(?=-|$)/gi, "")
    .replace(/-/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  // Brand + version: Gemma3 → Gemma 3, Qwen3 → Qwen 3
  s = s.replace(/\b(Gemma|Qwen|Llama|Phi|LFM|SmolLM)(\d)/gi, "$1 $2");
  // Size tokens: 270m → 270M, 1.7b → 1.7B
  s = s.replace(/\b(\d+(?:\.\d+)?)([mb])\b/gi, (_, n: string, u: string) => n + u.toUpperCase());
  // Title-case plain words, keep acronyms / size tokens
  s = s
    .split(" ")
    .filter(Boolean)
    .map((tok) => {
      if (/^\d/.test(tok)) return tok;
      if (tok === tok.toUpperCase() && tok.length <= 4) return tok;
      return tok.charAt(0).toUpperCase() + tok.slice(1).toLowerCase();
    })
    .join(" ");
  return s || hubID;
}

/** Family label for grouping (mirrors iOS `LocalMetalCatalogEntry.family`). */
export function familyNameForHub(hubID: string): string {
  const leaf = hubID.split("/").pop() ?? hubID;
  const lower = leaf.toLowerCase();
  if (lower.includes("llama")) return "Llama";
  if (lower.includes("qwen")) return "Qwen";
  if (lower.includes("gemma") || lower.includes("medgemma")) return "Gemma";
  if (lower.includes("nemotron")) return "Nemotron";
  if (
    lower.includes("mistral") ||
    lower.includes("mixtral") ||
    lower.includes("magistral") ||
    lower.includes("devstral") ||
    lower.includes("ministral")
  ) {
    return "Mistral";
  }
  if (lower.includes("phi")) return "Phi";
  if (lower.includes("deepseek")) return "DeepSeek";
  if (lower.includes("smol")) return "SmolLM";
  if (lower.includes("granite")) return "Granite";
  if (lower.includes("lfm")) return "LFM";
  if (lower.includes("olmo")) return "OLMo";
  if (lower.includes("openelm")) return "OpenELM";
  if (lower.includes("ernie")) return "ERNIE";
  if (lower.includes("glm")) return "GLM";
  if (lower.includes("bitnet")) return "BitNet";
  if (lower.includes("jamba")) return "Jamba";
  return "Other";
}

export function familyBlurb(family: string): string {
  switch (family) {
    case "Llama":
      return "Meta’s Llama instruct models. Strong general chat in compact sizes for on-device Metal.";
    case "Qwen":
      return "Qwen models from the Qwen team. Strong multilingual chat and instruction following.";
    case "Gemma":
      return "Google Gemma models — compact chat variants optimized for Metal.";
    case "LFM":
      return "Liquid AI LFM models. Efficient chat for on-device inference.";
    case "Phi":
      return "Microsoft Phi instruct models. Compact reasoning and chat for smaller memory budgets.";
    case "Mistral":
      return "Mistral instruct models. Capable chat; larger variants need more RAM.";
    case "SmolLM":
      return "Ultra-small instruct models for quick replies and low storage use.";
    case "Granite":
      return "IBM Granite instruct models for enterprise-style chat on device.";
    case "DeepSeek":
      return "DeepSeek distill / reasoning models. Some variants emphasize chain-of-thought.";
    default:
      return "Open MLX models ready for on-device Metal chat.";
  }
}

export function sectionForEntry(entry: Pick<MetalCatalogEntry, "tags">): MetalSection {
  if (entry.tags.includes("legacy")) return "legacy";
  if (entry.tags.includes("experimental")) return "experimental";
  if (entry.tags.includes("recommended") || entry.tags.includes("best")) return "featured";
  return "standard";
}

export const TAG_LABELS: Record<MetalTag, string> = {
  recommended: "Recommended",
  best: "Best",
  thinking: "Thinking",
  vision: "Vision",
  new: "New",
  experimental: "Experimental",
  legacy: "Legacy",
};

export const METAL_PROVIDER_ID = "localMetal" as const;
