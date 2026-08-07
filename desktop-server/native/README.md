# Native helpers

## `apc-foundation-cli` (macOS)

Runs **Apple Intelligence** (Foundation Models) for RoamSocket **Lightweight Tasks**
(chat titles, artifact names, short summaries) from the Electron app.

### Requirements

- macOS 26+ with Apple Intelligence enabled
- Xcode 26+ / Swift toolchain that includes `FoundationModels`

### Build

```bash
cd desktop-server/native
swiftc -O -o apc-foundation-cli apc-foundation-cli.swift
mkdir -p ~/.roamsocket/bin
cp apc-foundation-cli ~/.roamsocket/bin/
chmod +x ~/.roamsocket/bin/apc-foundation-cli
```

On first Lightweight Task that needs Foundation, the Electron main process also
tries `swiftc` automatically when the source file is present.

### Protocol

**stdin** (JSON):

```json
{ "system": "…", "user": "…", "maxTokens": 48 }
```

**stdout** (one JSON line):

```json
{ "ok": true, "text": "…" }
```

or `{ "ok": false, "error": "…" }`.

Windows and Linux never use this binary — they use a **linked model** from Settings → Lightweight Tasks.
