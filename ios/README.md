# ios

Native SwiftUI app + a Foundation-only core package.

## Build

Requires Xcode 15+ and [XcodeGen](https://github.com/yonsm/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate      # reads project.yml → RoamSocket.xcodeproj
open RoamSocket.xcodeproj
```

The app target depends on the local `AnyProvCore` Swift package plus
**mlx-swift-lm** (and Hugging Face tokenizer/hub packages) for on-device
Metal chat.

### On-device chat models

**Apple Intelligence** (Foundation Models) appears in the model picker when the
device supports it (iOS 26+ with Apple Intelligence enabled). Chat only —
coding sessions never use it (`ProviderID.appleFoundation.supportsCodingAgent == false`).

**Metal (MLX)** on the phone uses [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
Phone weights appear under **Settings → On-device (Metal)** and in the **chat**
model picker. **Coding** sessions list Metal models installed on the paired
**desktop** instead (`GET /metal/models`), because phone and desktop stores
may not match.

First CLI build may need:

```bash
# Once per machine (Xcode 16+): Metal shader compiler for mlx-swift Cmlx
xcodebuild -downloadComponent MetalToolchain

# Trust SPM build plugins (mlx-swift ships a Linux CudaBuild plugin)
xcodebuild -project RoamSocket.xcodeproj -scheme RoamSocket \
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

- `Providers/` — `ModelProvider` clients for built-in cloud + on-device
  providers and `ModelCatalog` for concurrent model listing.
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
