# ios

Native SwiftUI app + a Foundation-only core package.

## Build

Requires Xcode 15+ and [XcodeGen](https://github.com/yonsm/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate      # reads project.yml → AnyProvCode.xcodeproj
open AnyProvCode.xcodeproj
```

The app target depends on the local `AnyProvCore` Swift package plus
**mlx-swift-lm** (and Hugging Face tokenizer/hub packages) for on-device
Metal chat.

### On-device Metal (chat only)

Local models use [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
They appear under **Settings → On-device (Metal)** and only in the **chat**
model picker — coding sessions never use them
(`ProviderID.localMetal.supportsCodingAgent == false`).

First CLI build may need:

```bash
# Once per machine (Xcode 16+): Metal shader compiler for mlx-swift Cmlx
xcodebuild -downloadComponent MetalToolchain

# Trust SPM build plugins (mlx-swift ships a Linux CudaBuild plugin)
xcodebuild -project AnyProvCode.xcodeproj -scheme AnyProvCode \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation -skipMacroValidation \
  build
```

In the Xcode UI, accept the package plugin / macro prompts when first
resolving packages. Weights download from Hugging Face on first chat with
an enabled model.

## AnyProvCore (buildable/testable without Xcode)

`AnyProvCore` is Foundation-only (no SwiftUI), so it builds and tests with the
Swift toolchain alone:

```bash
cd AnyProvCore
swift build
swift test             # provider parsing + protocol Codable round-trips
```

It contains:

- `Providers/` — `ModelProvider` clients for all seven providers and
  `ModelCatalog` for concurrent model listing.
- `GitHub/` — Device Flow OAuth + PAT and repository listing.
- `Server/` — the WebSocket client and Codable protocol types mirroring
  `desktop-server/src/protocol.ts`.
- `Keychain/` — the `SecretStore` abstraction (Keychain impl lives in the app).

## App structure (`App/Sources`)

| Area | Screens |
|------|---------|
| `Features/Home` | composer: suggestions, repo chip, model + permission pills, send |
| `Features/ModelPicker` | Select model + Effort |
| `Features/Environments` | Choose environment + New cloud environment form |
| `Features/Repositories` | searchable repository picker |
| `Features/Session` | coding transcript: assistant text, tool cards, diffs, Create PR |
| `Features/Settings` | provider keys, GitHub linking, server pairing |
| `DesignSystem` | dark theme tokens + reusable components |

Deployment target iOS 17.
