## Summary

<!-- One or two sentences. What does this PR do, and why? -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that changes existing behavior)
- [ ] Refactor / docs / no behavior change
- [ ] Agent-authored (run by an AI coding agent — see [AGENTS.md](./AGENTS.md))

## Areas touched

- [ ] iOS app (`ios/App/Sources`)
- [ ] AnyProvCore (`ios/AnyProvCore`)
- [ ] Desktop server (`desktop-server/src`)
- [ ] Wire protocol (`desktop-server/src/protocol.ts` + Swift mirror + `docs/protocol.md`)
- [ ] Theme / shared UI
- [ ] Marketplace / Skills / MCP
- [ ] Docs only

## Protocol changes (if applicable)

A protocol change is **not one-sided**. All three must update together:

- [ ] `desktop-server/src/protocol.ts`
- [ ] `ios/AnyProvCore/.../Server/Protocol.swift`
- [ ] `docs/protocol.md`

## Verification

Run the smallest relevant check from [AGENTS.md](./AGENTS.md#verification-checklist-before-claiming-done) and paste the result:

```bash
# which command(s) did you run, and what happened?
```

- [ ] `npm run typecheck:server`
- [ ] `cd ios/AnyProvCore && swift test`
- [ ] `npm run smoke` (if protocol / server / tools touched)
- [ ] `npm run xcodegen` (if iOS sources / `project.yml` changed)
- [ ] Other (describe)

## Checklist

- [ ] Read [AGENTS.md](./AGENTS.md) before opening this PR
- [ ] No secrets, tokens, or `.env` files in the diff
- [ ] No build output (`ios/build/`, `desktop-server/out/`, `desktop-server/.vite/`, `node_modules/`)
- [ ] New Swift files: Xcode project regenerated and committed
- [ ] Commit messages are complete sentences