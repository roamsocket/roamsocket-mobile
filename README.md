# RoamSocket

An open-source, native **iOS** AI client, plus a **desktop companion server**
that runs the coding agent.

- **Chat** talks to each provider's `/v1` REST API directly from the app with
  your own API key — no server required. Includes on-device Metal (MLX) models
  and Apple Intelligence (Foundation Models) on supported devices.
- **Coding** pairs the app with a desktop server over WebSocket. The server
  clones your GitHub repo, runs the agent loop, executes tools (bash / file
  edits / git), streams tool calls and diffs back to the phone, and opens a
  pull request.
- **Vision** captures photos and runs on-device VLM analysis (MLXVLM) or sends
  images to cloud providers for multimodal reasoning.
- **Voice chat** uses on-device speech recognition and neural TTS for live
  conversations with the model.
- **Study** mode scans questions from photos or text and creates flashcard
  decks for spaced repetition.

## Architecture

```
CHAT     iOS app ──API key──▶ api.anthropic.com/v1/messages, api.openai.com/v1/…
                              (+ Google, Groq, OpenRouter, xAI, Mistral, MiniMax)
       ──on-device──▶ Metal (MLX) models, Apple Intelligence (Foundation Models)

VISION   iOS app ──camera──▶ on-device VLM (MLXVLM) or cloud multimodal

VOICE    iOS app ──dictation──▶ chat ──TTS──▶ neural speech

CODE     iOS app ──WebSocket──▶ desktop server ──▶ git clone / bash / edits / PR
                              └─▶ desktop Metal (MLX) models for coding
```

## Repository layout

| Path | What |
|------|------|
| `ios/App/Sources` | SwiftUI app: Chat, Vision, Voice, Code, Study, Artifacts, Skills, Settings |
| `ios/AnyProvCore` | Foundation-only Swift package: providers, GitHub, WebSocket protocol, skills, marketplace |
| `ios/Widgets` | Widget extension (Live Activities, Control Center widgets) |
| `ios/Shared` | Code shared between app and widget extension |
| `ios/project.yml` | XcodeGen spec that generates the Xcode project |
| `desktop-server` | Node + TypeScript: CLI/TUI, headless server, Electron app, agent loop, tools, git |
| `docs/protocol.md` | The app ↔ server wire protocol |
| `landing/` | Pointer to the marketing site repo ([roamsocket-site](https://github.com/roamsocket/roamsocket-site)) |
| `marketplace/` | Pointer to the official marketplace repo ([roamsocket-marketplace](https://github.com/roamsocket-ai/roamsocket-marketplace)) |
| `AGENTS.md` | Instructions for AI coding agents (architecture, commands, invariants) |
| `CLAUDE.md` | Agent workflow notes (hooks, verification defaults) |

## Quick start

### 1. Desktop server

Requires **Node.js 20+**. The first install may compile native deps (`node-pty`);
you need a working C/C++ toolchain (Xcode CLT on macOS, build-essential on Linux).

```bash
cd desktop-server
npm install
npm run dev              # coding agent TUI + server (Ink)
# or: APC_MOCK=1 npm run dev   # offline agent, no API key needed
```

The TUI status bar shows model, permission mode, listen port, and the **pairing
code** for the iOS app. Slash commands: `/help` `/clear` `/model` `/permission`
`/keys` `/pair` `/server` `/goal` `/quit`.

Verify it end-to-end without any API key or GitHub:

```bash
npm run smoke       # clones a local repo, runs the mock agent, opens a "PR"
```

Run as a native desktop app (Electron + built-in client UI):

```bash
npm run electron:dev       # hot-reload dev
npm run electron:package   # package the app for the current platform
npm run make               # build distributable installers (.dmg/.exe/.zip)
```

Headless server only (no TUI):

```bash
roamsocket --serve-only
```

### 2. iOS app

Requires a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonsm/XcodeGen).

```bash
cd ios
xcodegen generate          # creates RoamSocket.xcodeproj
open RoamSocket.xcodeproj
```

Run on a simulator or device (iOS 17+), then in **Settings**:

1. Add one or more **provider API keys** (Anthropic, OpenAI, Google, Groq,
   OpenRouter, xAI, Mistral, MiniMax). Tap *Refresh models* to load them.
2. **On-device (Metal)** — download MLX models for offline chat (Settings →
   On-device (Metal)). Apple Intelligence appears automatically on supported
   devices (iOS 26+).
3. **Link GitHub** — paste a personal access token, or set an OAuth app client
   id and use Device Flow.
4. **Pair with a server** — enter the desktop server's address and the pairing
   code it printed, or scan the QR code.

Then pick a repository and model on the home screen, describe a task, and send.

### 3. Landing page (Cloudflare)

The marketing site lives in a separate repo: **[roamsocket/roamsocket-site](https://github.com/roamsocket/roamsocket-site)**.

```bash
git clone https://github.com/roamsocket/roamsocket-site.git
cd roamsocket-site
npm install
npm run dev          # local preview (Wrangler)
npx wrangler login   # once
npm run deploy       # https://roamsocket.<account>.workers.dev
```

See that repo's README for custom domains and Git-connected builds.

## Providers

| Provider | Models endpoint | Chat | Coding agent |
|----------|-----------------|------|--------------|
| Anthropic | `GET /v1/models` | ✅ | ✅ streaming tool-use |
| OpenAI | `GET /v1/models` | ✅ | ✅ |
| Groq / OpenRouter / xAI / Mistral / MiniMax | `GET /v1/models` (OpenAI-compatible) | ✅ | ✅ |
| Google Gemini | `GET /v1beta/models` | ✅ | chat/listing only |
| Apple Intelligence | Foundation Models framework | ✅ | chat only (iOS 26+) |
| Metal (MLX) | on-device / desktop | ✅ | ✅ (desktop only) |
| Custom endpoints | user-defined | ✅ | ✅ (OpenAI or Anthropic API style) |

## Features

### iOS app

- **Chat composer** with suggestions, repo chip, model + permission pills, streaming
- **Chat history** with smart titles and project organization
- **Vision mode** — camera capture, zoom, on-device VLM analysis (MLXVLM), prompt presets
- **Voice chat** — live dictation, neural TTS, edge-free TTS fallback
- **Study mode** — scan questions from photos/text, create flashcard decks, spaced repetition
- **Coding sessions** — streaming tool calls, diffs, file browser, terminal, PR creation
- **On-device Metal** — MLX models for offline chat, crash reporting, download manager
- **Apple Intelligence** — Foundation Models integration (iOS 26+)
- **Skills + MCP** — browse marketplace, install skills, manage MCP servers
- **Artifacts** — generated content viewer
- **Live Activities** — show model progress on Lock Screen / Dynamic Island
- **Widgets** — Control Center quick actions, Lock Screen widgets
- **App Intents** — Siri, Shortcuts, Action Button, Control Center
- **Deep links** — `roamsocket://` URLs for chat, code, vision
- **HealthKit** — share Apple Health data with the assistant (opt-in)
- **Bonjour discovery** — auto-find desktop servers on the LAN

### Desktop server

- **CLI/TUI** — Ink-based coding agent with streaming, permissions, slash commands
- **Headless server** — WebSocket pairing server for iOS app
- **Electron app** — full desktop client with sidebar, chat, code, settings
- **Agent loop** — tool-use loop with bash, file read/write/edit, glob
- **Git integration** — clone, branch, commit, push, diff, PR creation
- **Skills/MCP sync** — git-based skill and MCP server management
- **Metal/MLX store** — download, manage, and run on-device models for coding
- **Tunnels** — Cloudflare quick tunnel, ngrok, localtunnel, bore for remote access
- **Bonjour/mDNS** — advertise server on LAN (`_roamsocket._tcp`)
- **Goal tracking** — `/goal` slash command with auto-evaluation
- **Task checklist** — agent-maintained working list
- **Terminal** — PTY access to session workdir
- **File browser** — list, read, write files in session workdir
- **Port listing** — show listening ports in session workdir

## Notes

- API keys and tokens are stored in the iOS **Keychain**. The desktop server
  receives a provider key only for the duration of a coding session and a
  GitHub token only to clone/push; neither is written to disk.
- The app allows cleartext to the desktop server on your **local network**
  (`http`/`ws`); tighten `NSAppTransportSecurity` before any App Store build.
- On-device Metal models use the **Metal** framework and require iOS 17+ with
  the increased default stack size (set in `project.yml`).
- Desktop Metal models are listed via `GET /metal/models` and used for coding
  sessions; phone Metal weights are for chat only.
- The marketplace catalog lives in a separate repo
  ([roamsocket-marketplace](https://github.com/roamsocket-ai/roamsocket-marketplace))
  so connectors, skills, plugins, and Metal recommendations can update without
  an app release.

## License

MIT
