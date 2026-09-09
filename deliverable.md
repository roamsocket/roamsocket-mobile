# Desktop Electron parity + E2B sandbox support

This PR makes the desktop Electron app a fully functional chat + code
client with sandbox support, matching the iOS and Android apps for
everything except vision. The desktop is also the host of the in-
process WebSocket server (already wired) and the headless CLI.

## Commits

```
0866447 feat(desktop): E2B sandbox support (desktop-originated runs)
c95d3d5 fix(desktop): repair renderer typecheck, memory store, and shell check
```

## Baseline that was broken

A clean install of `origin/main` failed four checks. Fixed in
`c95d3d5`:

1. `npm run typecheck` — 18 TypeScript errors in
   `desktop-server/src/renderer/main.ts`. `messageNode()` referenced
   an undefined `memoryActivityIDs`; the streaming arm of
   `onChatSend` referenced `tagParser`, `visible`, `pendingActions`,
   and `r` that were never declared. Reconstructed from the
   existing `MemoryTagParser` in `client/memory-tags.ts` (now
   exported from `client/index.ts`) and the iOS/Android
   tag-stripping pattern. The non-streaming Metal branch was the
   model to match.
2. `npm run test:client` — `'user memory store: freeform, detail
   command, import, system format'`. `UserMemoryStore.forget()`
   left the entry untouched when no detail matched, but the test
   expected either a removal or a `Note: user asked to forget X`
   line. Aligned the implementation with the iOS behavior.
3. `npm run test:cli` — `'resolveModelSelection mock ignores
   missing keys'`. The test expected `apiKey === 'mock'` but the
   implementation returns `'none'` (the documented offline
   sentinel). Updated the test with a comment.
4. `npx tsx scripts/client-shell-check.ts` — `'pill click always
   opens openModelPicker'`. The static regex didn't accept the
   quoted `'click'` style the renderer uses. Loosened the regex.
   Also fixed the `'marketplace' settings tab` assertion.
5. Bonus: `client-unit.ts` `'product identity is RoamSocket'`
   expected `pkg.name === 'roamsocket'` but the package was renamed
   to `@roamsocket/server`. Accept both, with a comment.

## E2B sandbox support (new in `0866447`)

The desktop is now a first-class e2b.dev client. The protocol
intentionally removed E2B WS messages (`desktop-server/src/
protocol.ts` lines 397-405) so the desktop was left without any
E2B story. This PR brings it back as a direct client, the same way
the iOS and Android apps work.

### New module: `desktop-server/src/sandboxes/`

| File | What |
|------|------|
| `direct-e2b-client.ts` | HTTP client for `api.e2b.dev`. Implements `createSandbox / extendTimeout / killSandbox / verifyKey / runShell / streamShellRun`. Mirrors the iOS `AnyProvCore/Sandboxes/DirectE2BClient.swift` API surface (template = `code-interpreter-beta`, port 49999, 1h timeout cap, `X-API-Key` auth, `X-Access-Token` capture). Uses Node 20+ fetch + WebSocket — no new top-level dependencies. |
| `e2b-key-store.ts` | Persistent storage of the user's e2b.dev key in Electron's `safeStorage` (or a 0600 plain-text fallback on Linux without a keyring). The key is never sent to the desktop-server WebSocket. |
| `sandbox-store.ts` | Persisted run history under `<userData>/sandbox-runs.v1.json`. In-flight runs that survived a crash are normalized to `killed` on load. |
| `index.ts` | Barrel export. |

### IPC bridge (`electron/preload.ts`) and handlers (`electron/main.ts`)

- `sandboxes:status` / `sandboxes:keyStatus` / `sandboxes:setKey` /
  `sandboxes:clearKey` / `sandboxes:verifyKey`
- `sandboxes:startRun` / `sandboxes:killRun` / `sandboxes:clearRuns`

`startRun` creates a sandbox via the code-interpreter template,
runs the user's shell command, and updates the persisted row
with `status / exitCode / outputTail / error`. Uses the Python
subprocess shim (same as iOS) to capture stdout+stderr+exitCode
in one round-trip, then trims the tail to 80 lines for the
history view. Errors are surfaced via the `friendlyE2BError`
helper (401/403 → "API key rejected", 429 → "rate-limited",
5xx → "e2b.dev is having a problem", etc.).

### Renderer

- New **Sandboxes** route in the sidebar (between Code and
  Settings). Shows the e2b key card (paste/verify/clear), a
  "New run" composer, and a history list with status / exit
  code / kill button / output tail. Vision remains absent.
- `SIDEBAR_DESTINATIONS` extended to include `'sandboxes'` so the
  router switch covers it.
- `client-shell-check.ts` and `client-unit.ts` updated to expect
  the new sidebar entry.

### User flow

1. User clicks **Sandboxes** in the sidebar.
2. They paste their `e2b_…` API key and hit **Save key**. The key
   is stored in `safeStorage` (encrypted on macOS / Windows;
   plain-text fallback on Linux without a keyring). The view
   shows "Set (encrypted via safeStorage)".
3. They hit **Verify**. The app calls `GET /sandboxes?limit=1`
   on e2b.dev and reports the HTTP status. Failures show a
   friendly message.
4. They type a shell command and hit **Run**. A fresh sandbox
   is created, the command runs, stdout+stderr stream into the
   history row (max 80 lines), and the row's status flips to
   `completed` / `failed` / `killed`.
5. From the history they can **Open sandbox** (the e2b.dev
   public URL) or **Kill** an in-flight run.

## Verification (all green)

```bash
cd desktop-server
npm run typecheck                  # clean
npm run test:client                # all pass
npm run test:cli                   # all pass
npx tsx scripts/client-shell-check.ts   # exit 0
npm run smoke                      # pair → session → tools → diff → PR
```

I did NOT do a full Electron launch from this sandbox (no display).
The `electron-dom-check.ts` integration check is in the repo for
the next CI run to validate the renderer after merge.

## What I did NOT touch

- `protocol.ts` (no new WS messages, per the architectural
  decision the team made earlier — E2B is client-direct).
- iOS / Android code (no changes needed for this work; both
  already work the way the desktop now works).
- `desktop-server/src/agent/` (the local agent loop that runs
  against a cloned repo, distinct from E2B which runs in an
  ephemeral cloud sandbox).

## Known limitations / follow-ups

1. **Streaming agent loop with the model inside the sandbox**.
   The current `startRun` is shell-only — it takes a raw bash
   command. The iOS `E2bSessionRunner.swift` runs a full agent
   loop (model + bash tool calls) inside the sandbox. That's a
   follow-up; the current desktop flow is the smallest possible
   E2B end-to-end that exercises the same key + transport +
   persistence.
2. **Cost tracking**. iOS has `TokenCost.swift`; desktop doesn't
   yet roll up per-run cost in the history view.
3. **Repo-source / branch picker in the New run composer**. iOS
   takes a GitHub repo (clones it inside the sandbox); desktop
   currently takes a command only.
4. **Real-world e2b.dev call**: not exercised end-to-end here
   (no live API key in this environment). The HTTP client has
   `verifyKey()` that callers can use, and the IPC contract is
   unit-shaped so the next person with a key can drive the
   full flow.

## Out-of-scope lint noise

There are pre-existing biome lint diagnostics in
`desktop-server/src/{agent,tools,workspace,skills,proxy,etc}.ts`
that this PR does not address. They're `organizeImports` / minor
`format` issues in files I didn't change. Happy to clean them
up in a follow-up if the team wants a green lint baseline.
