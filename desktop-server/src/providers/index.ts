import type { ProviderId } from "../protocol.js";
import type { ProviderAdapter } from "./types.js";
import { anthropicAdapter } from "./anthropic.js";
import { makeOpenAICompatibleAdapter } from "./openai.js";
import { mockAdapter } from "./mock.js";

export * from "./types.js";

/**
 * Resolve the server-side agent adapter for a provider.
 *
 * Anthropic and the OpenAI-compatible providers (OpenAI, Groq, OpenRouter,
 * xAI, Mistral) drive the coding agent loop. Google Gemini is supported for
 * chat and model-listing directly from the app; its coding-agent adapter is
 * not implemented yet, so requesting it here fails fast with a clear message.
 */
export function getAgentAdapter(provider: ProviderId): ProviderAdapter {
  switch (provider) {
    case "anthropic":
      return anthropicAdapter;
    case "openai":
    case "groq":
    case "openrouter":
    case "xai":
    case "mistral":
      return makeOpenAICompatibleAdapter(provider);
    case "google":
      throw new Error(
        "Google Gemini is available for chat and model listing, but the coding agent loop does not support it yet. Pick Anthropic or an OpenAI-compatible provider for coding sessions.",
      );
    default:
      throw new Error(`Unknown provider: ${provider}`);
  }
}

/** Test hook: the deterministic offline adapter. */
export { mockAdapter };
