# RoamSocket Android

Native Android client for RoamSocket. Mirrors the iOS app and the desktop
server's wire protocol. Built with **Jetpack Compose** + **Material 3** on
**Kotlin 2.0** / **AGP 8.7** / **Gradle 8.10.2**, targeting Android 8.0+
(API 26, compileSdk 34).

## Modules

| Module | Role | Depends on Android? |
|--------|------|---------------------|
| `app` | UI: Compose screens, `MainActivity`, `Application`, theme, resources | Yes |
| `RoamSocketCore` | Pure-Kotlin (JVM): wire protocol, providers, GitHub client | **No** — `kotlin.test` on the JVM |

The split mirrors `ios/App/Sources` vs `ios/AnyProvCore`. Anything that can
be unit-tested on the JVM lives in `RoamSocketCore`; anything that touches
`Context`, `Activity`, or Compose stays in `app`.

## Quickstart

Prereqs: JDK 17 (`brew install --cask temurin@17` or `winget install Microsoft.OpenJDK.17`),
Android SDK with `platforms;android-34` + `build-tools;34.0.0` installed.
Generate `android/local.properties` with `sdk.dir=/path/to/Android/Sdk` (gitignored).

```bash
cd android
./gradlew :RoamSocketCore:test     # protocol + provider unit tests (JVM)
./gradlew assembleDebug           # build app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug            # install to a connected device/emulator
```

## Wire protocol

`RoamSocketCore/protocol/` mirrors `desktop-server/src/protocol.ts` and
`ios/AnyProvCore/.../Server/Protocol.swift`. The Kotlin sealed classes use
`@JsonClassDiscriminator("type")` so JSON matches the Zod-emitted shape
exactly. When changing a message, update all three implementations and
`docs/protocol.md` in the same PR — see AGENTS.md "Critical invariants".

## Port status (incremental)

| Area | Status |
|------|--------|
| Project skeleton, build, manifest, theme | ✅ foundation |
| Wire protocol (TS / Swift / Kotlin) | ✅ complete (port #1) |
| Provider chat (Anthropic, OpenAI, …) | ⏳ next PR |
| Code session (server-paired WebSocket) | ⏳ |
| Settings / GitHub / pairing | ⏳ |
| Skills / Marketplace | ⏳ |
| Voice, Vision, HealthKit (iOS-only features) | 🚫 no Android equivalent — skipped |

iOS-only features (Metal/MLX on-device LLM, Apple HealthKit, Bonjour, ARKit)
have no direct Android equivalent. Their corresponding Android slots are
left empty rather than half-ported.

## Style

- Compose-first UI, no XML layouts except for the launcher icon theme.
- System fonts only (matches the "no web fonts" rule from the Electron shell).
- Theme tokens in `app/.../ui/theme/Color.kt` mirror the iOS `Theme.swift` —
  do not introduce a second palette.
- `kotlinx.serialization` for JSON; `OkHttp` for HTTP and WebSocket.
