import type { ApiStyle, ProviderId } from '../protocol.js';
import type { ProviderAdapter } from './types.js';
import { anthropicAdapter, makeAnthropicAdapter } from './anthropic.js';
import { makeOpenAICompatibleAdapter } from './openai.js';
import { isMetalProviderId, metalAgentAdapter } from './metal.js';
import { mockAdapter } from './mock.js';

export * from './types.js';
export { isMetalProviderId, metalAgentAdapter } from './metal.js';

export interface AgentAdapterOptions {
  /** Override host for custom / proxy endpoints (e.g. http://localhost:11434/v1). */
  baseUrl?: string;
  /** Request shape when using a custom base URL. Defaults to openai. */
  apiStyle?: ApiStyle;
}

/**
 * Resolve the server-side agent adapter for a provider.
 *
 * Anthropic and the OpenAI-compatible providers (OpenAI, Groq, OpenRouter,
 * xAI, Mistral, MiniMax) drive the coding agent loop. Desktop Metal (`localMetal` /
 * `local-metal`) uses the on-device MLX runtime with a text tool-call protocol.
 * Custom endpoints (`custom:…` or any provider with `baseUrl`) use `apiStyle`
 * to pick the wire format. Google Gemini is chat/listing only from the app
 * for now.
 */
export function getAgentAdapter(
  provider: ProviderId,
  opts: AgentAdapterOptions = {}
): ProviderAdapter {
  // Metal never uses a custom cloud base URL — weights live on this machine.
  if (isMetalProviderId(provider)) {
    return metalAgentAdapter;
  }

  const baseUrl = opts.baseUrl?.replace(/\/+$/, '');
  const style: ApiStyle = opts.apiStyle ?? (provider === 'anthropic' ? 'anthropic' : 'openai');

  // Custom / proxy host wins over built-in defaults.
  if (baseUrl) {
    if (style === 'anthropic') {
      return makeAnthropicAdapter(provider, baseUrl);
    }
    return makeOpenAICompatibleAdapter(provider, baseUrl);
  }

  switch (provider) {
    case 'anthropic':
      return anthropicAdapter;
    case 'openai':
    case 'groq':
    case 'openrouter':
    case 'xai':
    case 'mistral':
    case 'minimax':
      return makeOpenAICompatibleAdapter(provider);
    case 'google':
      throw new Error(
        'Google Gemini is available for chat and model listing, but the coding agent loop does not support it yet. Pick Anthropic or an OpenAI-compatible provider for coding sessions.'
      );
    default:
      if (provider.startsWith('custom:')) {
        throw new Error(
          `Custom provider "${provider}" needs a baseUrl on the model selection (set in the iOS custom provider settings).`
        );
      }
      throw new Error(`Unknown provider: ${provider}`);
  }
}

/** Test hook: the deterministic offline adapter. */
export { mockAdapter };
