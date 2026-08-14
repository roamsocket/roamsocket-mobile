# Contributing to RoamSocket

Thanks for helping build RoamSocket. This guide is short on purpose — the
real invariants live in **[AGENTS.md](./AGENTS.md)**. Read it before opening
a PR.

## Quick checklist

Before opening a PR, every box below should be tickable. If any is red, the PR
isn't ready.

- [ ] **Read [AGENTS.md](./AGENTS.md)** end to end if you haven't touched this
      area before
- [ ] **Protocol changes** updated the TS schema **and** Swift Codable **and**
      `docs/protocol.md` (never one-sided)
- [ ] **iOS structural changes** (new Swift file, edited `project.yml`) ran
      `npm run xcodegen` and committed the regenerated `.xcodeproj`
- [ ] **No secrets, no build output, no `node_modules/`** in the diff
- [ ] **Verification passes:**
      ```bash
      npm run typecheck:server      # TypeScript
      cd ios/AnyProvCore && swift test   # Foundation package
      npm run smoke                 # only if you touched the server / protocol
      ```
- [ ] **Commit messages** are complete sentences, explain *why* for protocol,
      security, or theme changes

## Code style

- TypeScript/JS: **Biome** at the root (`npm run lint` / `npm run format`).
  Two-space indent, single quotes, semicolons, LF line endings.
- Swift: **SwiftFormat** (`brew install swiftformat`, then
  `npm run format:swift`). Four-space indent, max line length 120.
- See `.editorconfig` for cross-editor defaults.

> Lint/format enforcement at the repo level is being rolled in — the baseline
> configs are present but not yet wired to CI. Help finishing that is welcome.

## Where to work

| Area | Primary paths |
|------|---------------|
| iOS app UI | `ios/App/Sources/Features/...` |
| Reusable Swift | `ios/AnyProvCore/Sources/AnyProvCore/...` (no Xcode needed) |
| Desktop server | `desktop-server/src/...` |
| Wire protocol | `desktop-server/src/protocol.ts` (canonical) + Swift mirror + `docs/protocol.md` |
| Theme | `ios/App/Sources/DesignSystem/Theme.swift` + `desktop-server/src/renderer/styles.css` |
| Marketplace | `desktop-server/src/marketplace/` + iOS `AnyProvCore/Marketplace` |

## Research notes

If you discover something non-obvious (a provider quirk, a Swift gotcha, a
build trap), write it under **`.research/`** with sources and link it from
`AGENTS.md`'s research table. Don't scatter `.md` notes at the repo root.

## Things that will get your PR closed fast

- Renamed a protocol field on only one side
- Added a Swift file under `ios/App/Sources` without regenerating the Xcode project
- Bumped theme tokens without updating both iOS and Electron
- Logged an API key or token (even partially)
- Hand-edited `ios/RoamSocket.xcodeproj` instead of `project.yml`

## Questions?

Open an issue or ask in a PR. The repo is actively maintained by
[@roamsocket-ai](https://github.com/roamsocket-ai).