# `.research/` — version-controlled research notes

Curated, source-cited research that agents (and humans) need to read **before**
editing specific areas of the codebase. Lives in git so it survives agent
sessions and code review.

## How to use

- Read the relevant file **before** you start editing the area it covers.
- Add new findings here (not as `.md` files at the repo root).
- Cite sources. Flag claims as *Documented*, *Empirical*, or *Parser-dependent*
  using the convention from the existing quirks doc.
- Keep entries focused — one topic per file, named in `kebab-case.md`.

## Index

| File | Covers | Read when… |
|------|--------|------------|
| [`provider-response-quirks.md`](./provider-response-quirks.md) | Provider-specific leaks in plain-text SSE output (`<think>`, DeepSeek full-width `｜…｜`, Qwen3 missing-open, etc.) | …you're editing `ios/AnyProvCore/...` chat parsers, `ThinkingExtractor`, or any provider response normalization |
| [`e2b-envd-protocol.md`](./e2b-envd-protocol.md) | e2b envd `process.Process/Start` Connect-RPC wire format + why the phone-originated run path now uses `base`/envd instead of the code-interpreter template | …you're editing `ios/AnyProvCore/Sources/AnyProvCore/Sandboxes/DirectE2BClient.swift` (or its Android twin) |

## Conventions used across these docs

- **Documented** — present in provider docs or model card
- **Empirical** — observed in real streamed output (issues, forum threads, parser bugs)
- **Parser-dependent** — leaks only when the inference server's reasoning/tool
  parser is missing or misconfigured (vLLM, SGLang, Ollama, third-party proxies)

All multi-byte Unicode in patterns (e.g. DeepSeek's full-width `｜`) is preserved
verbatim so it round-trips through editors and source control.