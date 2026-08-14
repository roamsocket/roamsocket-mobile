# Auto-save memory from chat — implementation plan

Scope: when the user says something in a regular chat that the model identifies as a stable personal fact (name, role, location, preferences, recurring project context), the model emits a structured tag, the client parses it, writes the fact into `UserMemoryStore` automatically, and surfaces an inline "Saved to memory" card in the chat transcript with undo. Memory syncs across iOS and the desktop companion via the existing GitHub-backed repo pattern that skills + MCP already use.

## Wire format

The model emits zero or more tags in its reply. Tags are stripped from the visible reply text; the client persists the resulting mutation and shows a hint card.

```xml
<memory action="add" category="you|topic|area" title="Profile" summary="I work at Verizon" details="I work at Verizon" />
<memory action="forget" target="Verizon" />
<memory action="rename" target="Profile" value="About me" />
<memory action="set_summary" target="Profile" value="Telecom at Verizon" />
<memory action="set_details" target="Profile" value="I work at Verizon|I am a dad|I live in Colorado" />
```

`add` is the common case. `forget` drops matching bullets/details. `rename` / `set_summary` / `set_details` are escape hatches when the model wants to edit an existing entry without adding a duplicate.

The model is instructed to only emit `add` for *stable* personal facts: identity, role, location, recurring preferences, long-running project context. No transient task info, no speculative inferences, no one-off chat details. The model is also told to never emit more than one tag per reply unless the user is doing a deliberate batch ("remember that A, B, and C").

## Protocol layer

The chat-streamed reply is already passing through the existing client→server→client paths. iOS talks to providers directly (BYOK) and the desktop server talks to providers. We parse tags in the same place where streaming text is currently rendered — no protocol wire change needed for iOS BYOK, since the streaming text is the same string the model returns.

For the desktop side, the streamed assistant text is already on the renderer; we parse it there.

The persistence layer (UserMemoryStore) gets a thin extension: a new `ActivityEntry` log of `{ id, timestamp, kind, before, after, source }` written on every auto-save so the user can see and undo the history. The detail screen gets a "Memory activity" section showing recent auto-saves with a "Undo" button each.

## Sync

Mirror the skills/MCP pattern. Add a third sync kind: `memory`.

- **Repo config**: `APC_MEMORY_REPO` (env var on desktop, settings field on iOS). When set, the store syncs on every mutation, last-write-wins by `updatedAt`. Desktop also reads `APC_MEMORY_BRANCH` (default `main`) and `APC_MEMORY_TOKEN` (optional, private repo auth).
- **Wire**: extend the existing `ClientMessage` / `ServerMessage` unions in `desktop-server/src/protocol.ts` and the mirrored Swift `Protocol.swift` with `memorySync([MemoryEntry])`, `memorySyncRequest`, `memoryUpsert(entry)`, `memoryDelete(id)`. Standard pull / push cycle, identical to skills.
- **Storage format on disk**: `memory.json` at repo root, `{ entries: [MemoryEntry] }`. Simple, diff-friendly, single-file write per mutation.
- **Conflict resolution**: last-write-wins on `updatedAt`. Good enough for a private single-user device pair. If you want CRDT later, easy to swap.
- **iOS**: `UserMemorySyncClient` (parallel to `SkillsMCPClient`). Uses a one-shot short-lived WS connection per op, like the skills client.
- **Desktop**: `UserMemorySync` module parallel to `src/skills/sync.ts`. Reads/writes `memory.json`, commits + pushes.

## UI

### In-chat hint

Inline card in the chat transcript at the position of the assistant message that triggered the save. Compact pill:

> ✓ Saved to memory: "I work at Verizon"  •  Undo

If the user is scrolled past the relevant message, the card shows up inline anyway (per-message). Tapping the card expands to show the full fact + a longer "View in memory" link.

### Memory activity log

Inside `ManageMemoryView`, add a new "Activity" section (between the existing entries card and the draft card) that lists recent auto-saves, newest first, each with:

- timestamp
- the fact that was saved
- Undo button (removes the entry if it was newly created, or restores the prior `before` snapshot if it was an update)

Activity entries older than 30 days are pruned on app launch.

## Files I'll touch

- iOS
  - `ios/App/Sources/App/AppState.swift` — no change to `UserMemoryStore` singleton, but a new `MemoryActivity` array on the store
  - `ios/App/Sources/Features/Settings/UserMemoryStore.swift` — add ActivityEntry model, add `recordActivity`, surface activity list, undo helper
  - `ios/App/Sources/Features/Settings/ManageMemoryView.swift` — add Activity card to the manage screen
  - `ios/App/Sources/Features/Chat/ChatViewModel.swift` — system prompt: instruct model on when/how to emit `<memory>` tags; stream parser that splits visible text from tags and applies mutations
  - `ios/App/Sources/Features/Chat/*` — new inline hint card view
  - `ios/AnyProvCore/Sources/AnyProvCore/Sync/MemorySyncClient.swift` — new file, mirror of SkillsMCPClient
  - `ios/AnyProvCore/Sources/AnyProvCore/Server/Protocol.swift` — extend message union with memory sync messages

- Desktop
  - `desktop-server/src/client/memory-sync.ts` — new file, mirror of `src/skills/sync.ts`
  - `desktop-server/src/client/memory-tags.ts` — new file, parser for `<memory>` tags from streamed text
  - `desktop-server/src/renderer/main.ts` — wire tag parser into the chat stream; show inline hint cards
  - `desktop-server/src/renderer/styles.css` — memory hint card styles
  - `desktop-server/src/protocol.ts` — extend message union
  - `desktop-server/src/index.ts` — handle new memory sync messages on the WS server
  - `desktop-server/scripts/client-unit.ts` — new tests: tag parsing, store mutations, sync round-trip

## Acceptance criteria

1. In a regular chat, when the user says "I work at Verizon", the model can emit `<memory action="add" category="you" title="Profile" summary="I work at Verizon" details="I work at Verizon" />`. The visible reply has the tag stripped. A "Saved to memory" card appears inline. The Profile entry now exists in Manage memory.
2. Undo on the card removes the new entry. Undo on an update restores the prior `details`/`summary` snapshot.
3. Activity log in Manage memory shows the last 30 days of auto-saves with per-entry Undo.
4. With `APC_MEMORY_REPO` set on desktop, edits to memory on iOS reach the desktop (after the next iOS sync op) and vice versa. Last-write-wins by `updatedAt`.
5. Model does not auto-save transient task info. A test prompt in `scripts/client-unit.ts` asserts that a chat-like prompt containing "today I need to file a bug report" produces no `<memory>` tag when the system prompt is applied.

## Out of scope (follow-ups)

- CRDT-based conflict resolution
- Server-side background job that periodically re-scans chats for facts (the current model is turn-by-turn, which is fine for the user-explicit "remember this" case but won't catch facts the user drops in passing without the model reacting)
- End-to-end encryption of the memory repo
- Memory export / share to a different AI product (already supported via the existing import sheet)
