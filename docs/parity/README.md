# Cross-platform parity fixtures

Shared JSON fixtures that pin behavior both cores must implement identically:

- **iOS** — `ios/AnyProvCore` (Swift, XCTest)
- **Android** — `android/RoamSocketCore` (Kotlin, JUnit)

Each fixture is a JSON document with an `op` (the operation to run) and
`cases` (inputs + the exact expected output). Both sides load the **same
files** from this directory and assert byte-identical results, so a change
to one core that silently diverges from the other fails a test instead of
shipping.

## Layout

```
docs/parity/
├── README.md                    ← this file
├── protocol-cases.json          ← wire-protocol encode/decode fixtures
├── model-cases.json             ← display-name prettifier + vision heuristics
└── env-cases.json               ← .env parsing
```

## Fixture format

```json
{
  "op": "decode_server_message",          // which operation both cores implement
  "cases": [
    {
      "name": "model_status loading",
      "input": "{\"type\":\"model_status\",...}",
      "expected": { ... normalized expectation ... }
    }
  ]
}
```

`expected` is written in a **normalized** form (plain JSON objects with a
`kind` discriminator), not in either platform's native types. Each runner
maps its decoded value into that normalized form before comparing, so the
expectation is truly platform-neutral.

## Operations

| op | exercises | normalized expectation |
|----|-----------|------------------------|
| `decode_server_message` | ServerMessage decoding | `{ "kind": "<case>", ...fields }` or `{ "kind": "error" }` on decode failure |
| `encode_client_message` | ClientMessage encoding | the exact JSON object the encoder must emit (subset compare on both sides) |
| `parse_env` | EnvironmentConfig.parseEnv | `{ "vars": { ... } }` |
| `prettify_display_name` | AIModel display-name prettifier | `{ "name": "..." }` |
| `vision_heuristic` | vision-capability heuristic | `{ "vision": true/false }` |

## Adding a case

1. Add the case to the relevant JSON file in **this directory**.
2. Make sure the Swift runner and the Kotlin runner both handle the op
   (they are deliberately boring switch statements over `op`).
3. Run both suites — see below. If the two platforms disagree, fix the
   implementation, never the fixture (unless the fixture itself was wrong
   on both sides).

## Running

```bash
# iOS
cd ios/AnyProvCore && swift test --filter ParityTests

# Android
cd android && ./gradlew :RoamSocketCore:test --tests '*ParityTest*'
```

`npm run verify` runs both suites as part of the full check.
