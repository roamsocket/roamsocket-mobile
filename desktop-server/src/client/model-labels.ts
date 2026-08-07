/**
 * Human-friendly model labels for the composer pill and pickers.
 */
import { displayNameForHub, prettyNameFromHub } from "../metal/catalog.js";

/** Known cloud model id → short product name. */
const CLOUD_ALIASES: Array<{ match: RegExp; label: string }> = [
  { match: /claude-opus-4/i, label: "Claude Opus 4" },
  { match: /claude-sonnet-4/i, label: "Claude Sonnet 4" },
  { match: /claude-haiku-4/i, label: "Claude Haiku 4" },
  { match: /claude-3-5-sonnet/i, label: "Claude 3.5 Sonnet" },
  { match: /claude-3-5-haiku/i, label: "Claude 3.5 Haiku" },
  { match: /claude-3-opus/i, label: "Claude 3 Opus" },
  { match: /claude-3-sonnet/i, label: "Claude 3 Sonnet" },
  { match: /claude-3-haiku/i, label: "Claude 3 Haiku" },
  { match: /gpt-4o-mini/i, label: "GPT-4o mini" },
  { match: /gpt-4o/i, label: "GPT-4o" },
  { match: /gpt-4\.1/i, label: "GPT-4.1" },
  { match: /gpt-4-turbo/i, label: "GPT-4 Turbo" },
  { match: /gpt-4/i, label: "GPT-4" },
  { match: /o3-mini/i, label: "o3-mini" },
  { match: /o3/i, label: "o3" },
  { match: /o1-mini/i, label: "o1-mini" },
  { match: /o1/i, label: "o1" },
  { match: /gemini-2\.0-flash/i, label: "Gemini 2.0 Flash" },
  { match: /gemini-1\.5-pro/i, label: "Gemini 1.5 Pro" },
  { match: /gemini-1\.5-flash/i, label: "Gemini 1.5 Flash" },
  { match: /grok-3/i, label: "Grok 3" },
  { match: /grok-2/i, label: "Grok 2" },
  { match: /llama-3\.3-70b/i, label: "Llama 3.3 70B" },
  { match: /llama-3\.1-70b/i, label: "Llama 3.1 70B" },
  { match: /llama-3\.1-8b/i, label: "Llama 3.1 8B" },
  { match: /mistral-large/i, label: "Mistral Large" },
  { match: /mistral-small/i, label: "Mistral Small" },
  { match: /pixtral/i, label: "Pixtral" },
  { match: /minimax-m3/i, label: "MiniMax M3" },
  { match: /minimax-m2\.7-highspeed/i, label: "MiniMax M2.7 Highspeed" },
  { match: /minimax-m2\.7/i, label: "MiniMax M2.7" },
  { match: /minimax-m2\.5-highspeed/i, label: "MiniMax M2.5 Highspeed" },
  { match: /minimax-m2\.5/i, label: "MiniMax M2.5" },
  { match: /minimax-m2\.1-highspeed/i, label: "MiniMax M2.1 Highspeed" },
  { match: /minimax-m2\.1/i, label: "MiniMax M2.1" },
  { match: /minimax-m2/i, label: "MiniMax M2" },
];

/**
 * Friendly display name for a provider + model id.
 * Metal / hub ids use the Metal catalog + pretty-name rules.
 */
export function friendlyModelLabel(provider: string, modelId: string): string {
  const raw = (modelId || "").trim();
  if (!raw) return "";

  if (
    provider === "localMetal" ||
    provider === "local-metal" ||
    raw.includes("/") ||
    /mlx/i.test(raw)
  ) {
    // Prefer catalog hand names; otherwise humanize the hub leaf.
    const fromCatalog = displayNameForHub(raw.includes("/") ? raw : tryExpandMetalHub(raw));
    if (fromCatalog && fromCatalog !== raw && !fromCatalog.includes("/")) {
      return fromCatalog;
    }
    return improvePrettyMetalName(prettyNameFromHub(raw));
  }

  for (const a of CLOUD_ALIASES) {
    if (a.match.test(raw)) return a.label;
  }

  // Generic: strip date suffixes, turn separators into spaces, title-case.
  let s = raw
    .replace(/-\d{8}$/g, "")
    .replace(/[_/]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^\-+|\-+$/g, "");
  s = s
    .split("-")
    .filter(Boolean)
    .map((tok) => {
      if (/^\d+(\.\d+)?[bBmMkK]?$/.test(tok)) return tok.toUpperCase().replace(/B$/, "B");
      if (tok.length <= 3 && tok === tok.toLowerCase()) return tok.toUpperCase();
      return tok.charAt(0).toUpperCase() + tok.slice(1);
    })
    .join(" ");
  return s || raw;
}

/** If we only stored the leaf hub id, map common leaves to full hub ids in catalog. */
function tryExpandMetalHub(leaf: string): string {
  // displayNameForHub already falls back to prettyNameFromHub on unknown full ids.
  // Prefer lmstudio-community/leaf which matches our catalog.
  if (leaf.includes("/")) return leaf;
  return `lmstudio-community/${leaf}`;
}

/** Extra humanization on top of metal prettyNameFromHub. */
function improvePrettyMetalName(name: string): string {
  let s = name
    .replace(/\bIT\b/gi, "")
    .replace(/\bQAT\b/gi, "QAT")
    .replace(/\b(\d+(?:\.\d+)?)[mM]\b/g, "$1M")
    .replace(/\b(\d+(?:\.\d+)?)[bB]\b/g, "$1B")
    .replace(/\s+/g, " ")
    .trim();
  // "Gemma 3 270M" style: keep brand digit spacing
  s = s.replace(/\b(Gemma|Qwen|Llama|Phi|LFM)(\d)/gi, "$1 $2");
  return s || name;
}
