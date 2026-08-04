# code-mobile-ai

An open-source, native **iOS** clone of the Claude Code mobile experience, plus
a **desktop companion server** that actually runs code.

- **Chat** talks to each provider's `/v1` REST API directly from the app with
  your own API key — no server required.
- **Coding** pairs the app with a small desktop server over a WebSocket. The
  server clones your GitHub repo, runs the agent loop, executes tools
  (bash / file edits / git), streams tool calls and diffs back to the phone,
  and opens a pull request.

> Status: first milestone — the Claude Code clone (composer, pickers, coding
> session) and the desktop server. The general chat UI is next.

## Architecture

```
CHAT   iOS app ──API key──▶ api.anthropic.com/v1/messages, api.openai.com/v1/…
                            (+ Google, Groq, OpenRouter, xAI, Mistral)

CODE   iOS app ──WebSocket──▶ desktop server ──▶ git clone / bash / edits / PR
```

## Repository layout

| Path | What |
|------|------|
| `ios/App` | SwiftUI app (composer, model/env/repo pickers, coding session, settings) |
| `ios/MobileAICore` | Foundation-only Swift package: provider clients, GitHub, WebSocket protocol |
| `ios/project.yml` | XcodeGen spec that generates the Xcode project |
| `desktop-server` | Node + TypeScript server: pairing, tools, git, agent loop |
| `docs/protocol.md` | The app ↔ server wire protocol |

## Quick start

### 1. Desktop server

```bash
cd desktop-server
npm install
npm start           # prints a pairing code + QR
# or: CMAI_MOCK=1 npm start   # offline agent, no API key needed
```

Verify it end-to-end without any API key or GitHub:

```bash
npm run smoke       # clones a local repo, runs the mock agent, opens a "PR"
```

### 2. iOS app

Requires a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonsm/XcodeGen).

```bash
cd ios
xcodegen generate          # creates CodeMobileAI.xcodeproj
open CodeMobileAI.xcodeproj
```

Run on a simulator or device, then in **Settings**:

1. Add one or more **provider API keys** (Anthropic, OpenAI, Google, Groq,
   OpenRouter, xAI, Mistral). Tap *Refresh models* to load them.
2. **Link GitHub** — paste a personal access token, or set an OAuth app client
   id and use Device Flow.
3. **Pair with a server** — enter the desktop server's address and the pairing
   code it printed.

Then pick a repository and model on the home screen, describe a task, and send.

## Providers

| Provider | Models endpoint | Coding agent |
|----------|-----------------|--------------|
| Anthropic | `GET /v1/models` | ✅ streaming tool-use |
| OpenAI | `GET /v1/models` | ✅ |
| Groq / OpenRouter / xAI / Mistral | `GET /v1/models` (OpenAI-compatible) | ✅ |
| Google Gemini | `GET /v1beta/models` | chat/listing only (agent support pending) |

## Notes

- API keys and tokens are stored in the iOS **Keychain**. The desktop server
  receives a provider key only for the duration of a coding session and a
  GitHub token only to clone/push; neither is written to disk.
- The app allows cleartext to the desktop server on your **local network**
  (`http`/`ws`); tighten `NSAppTransportSecurity` before any App Store build.
- Native SwiftUI was chosen so a Metal-backed on-device model runtime can be
  added later.

## License

MIT
