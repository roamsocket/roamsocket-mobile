# e2b envd `process.Process/Start` — Wire Format & Quirks

**Scope:** How the iOS `DirectE2BClient` actually talks to an e2b sandbox to
clone a repo and run a user command. Read this before changing
`ios/AnyProvCore/Sources/AnyProvCore/Sandboxes/DirectE2BClient.swift` or
its Android twin.

**Conventions:** Same as `provider-response-quirks.md` — *Documented*,
*Empirical*, *Parser-dependent*.

---

## TL;DR

* Use the `base` template. envd listens on port **49983** of the
  sandbox (`https://49983-{sandboxId}.e2b.dev`). The default in the
  e2b JS SDK is `base`; the code-interpreter template is a different
  beast (see §3).
* The `process.Process/Start` RPC is the canonical way to run a
  shell command. The official SDK wraps `bash -l -c "<cmd>"` in a
  `ProcessConfig` and POSTs it.
* Wire format is **Connect-RPC streaming JSON**: a 5-byte envelope
  per message (`1` byte flags + `4` bytes big-endian length), with
  the JSON payload after the envelope. Content-Type
  `application/connect+json`. Request body is a single enveloped
  message; response is a stream of enveloped messages ending with a
  flag-`0x02` (end-of-stream) envelope.
* **Do not** use the code-interpreter template's `/execute` endpoint
  to run shell-style logic. The Jupyter kernel wraps your code in a
  temp file (`<numeric>.py`) and the kernel's auto-indent logic
  prepends env-var code indented to match your first non-empty line.
  This was the source of the "invalid syntax on line 3" reports
  against the old phone-originated run path. (See §3.)

---

## 1. Endpoints

| Concern | Value | Source |
| --- | --- | --- |
| Sandbox create / delete / list | `https://api.e2b.dev/sandboxes[/{id}]` | Documented in e2b REST API |
| envd host (per-sandbox) | `https://49983-{sandboxId}.e2b.dev` | e2b JS SDK `Sandbox` class: `protected readonly envdPort = 49983` |
| Process start RPC | `POST {envd-host}/process.Process/Start` | Documented in e2b API reference; same path used by JS / Python SDKs |
| Sandbox default template | `base` | e2b JS SDK: `protected static readonly defaultTemplate: string = 'base'` |
| Sandbox timeout hard cap | 1 hour (`3_600_000` ms) on hobby | Documented in e2b SDK comments |

Auth: `X-API-Key: <e2b key>` for `/sandboxes`; `X-Access-Token: <token>`
for follow-up calls *into* a specific sandbox. The `X-Access-Token` is
returned in the `X-Access-Token` response header of `POST /sandboxes`
when the sandbox is secured.

---

## 2. Connect-RPC streaming wire format

For `POST {envd-host}/process.Process/Start`:

* Headers
  * `Content-Type: application/connect+json`
  * `Connect-Protocol-Version: 1`
  * `X-Access-Token: …` (if the sandbox is secured)
* Request body
  * A single **Enveloped-Message**: `1` byte flags (always `0` for
    request bodies) + `4` bytes big-endian uint32 message length +
    JSON `StartRequest` payload.
* Response (chunked transfer, `HTTP/1.1` works without HTTP/2)
  * Stream of **Enveloped-Message**s. The last one has flags
    `0x02` (end-of-stream) and a `{}` body.
  * Normal data envelopes have flags `0` and a JSON `StartResponse`
    payload of the form (captured live 2026-09-01, envd 0.6.10 on
    `base`):
    ```json
    {"event": {"start": {"pid": 2003}}}
    {"event": {"data":  {"stdout": "aGVsbG8tZnJvbS1lbnZkCg=="}}}
    {"event": {"data":  {"stderr": "PHNvbWUgdGV4dD4K"}}}
    {"event": {"end":   {"exited": true, "status": "exit status 0"}}}
    ```

Source: Connect protocol spec
(<https://connectrpc.com/docs/protocol/>), connect-go `envelope.go`
(`prefix[0] = flags; binary.BigEndian.PutUint32(prefix[1:5], size)`),
and the e2b Python SDK's `_ProtoJSONCodec` (confirms JSON encoding
matches `useBinaryFormat: false` in the JS SDK).

### Two traps the docs and SDK abstraction hide

1. **The `data` event has no `output` wrapper.** The proto source
   shows `Data { oneof output { … } }`, but the JSON envelope puts
   the stream field (`stdout` / `stderr` / `pty`) directly under
   `event.data`. We accept both shapes so a future envd release with
   the wrapper doesn't break us.
2. **The `end` event is `{"exited": true, "status": "exit status N"}`
   (or `"signal: N"` for signalled processes), NOT `exitCode: N`.**
   The e2b Python SDK converts this string into an `int` (with
   signalled codes negated) inside `CommandResult`; the JS SDK does
   the same in `AsyncCommandHandle`. If you go straight off the
   wire you have to parse it yourself — see
   `ConnectEnvelope.parseExitStatus` for the regex-free version.

### Sandbox creation timeout is in *seconds*

`POST /sandboxes` body: `{"templateID": "base", "timeout": 300}`.
`timeout` is the sandbox lifetime, in **seconds**, with a hard cap
of `3_600` (1 hour). Sending milliseconds — e.g. `300_000` —
silently fails the request with `400 Timeout cannot be greater
than 1 hours`. The e2b Python SDK's public surface uses
`timeoutMs`, but it converts before sending.

### Envelope helpers in `DirectE2BClient.swift`

* `ConnectEnvelope.wrap(_:)` writes a request envelope: `[flags=0] [4-byte
  big-endian length] [payload]`.
* `ConnectEnvelope.stream(_:)` reads `URLSession.AsyncBytes` byte-by-byte,
  accumulates into a `Data` buffer, and pops one envelope at a time
  until the `end-of-stream` flag is seen. Each envelope is decoded to an
  `Event` (`start` / `data` / `end`) and surfaced via an
  `AsyncThrowingStream`.

### Shell payload

The e2b Python SDK builds a `StartRequest` like:

```kotlin
ProcessConfig(
    cmd = "/bin/bash",
    args = listOf("-l", "-c", cmd),
    // envs and cwd are optional
)
```

`-l` makes bash a login shell, so `.bash_profile` / `PATH` are set up
as on a real interactive session. The whole script goes in the
`cmd` field; envd passes it through to `execve`.

---

## 3. Why we no longer use the code-interpreter template

The previous `DirectE2BClient` (both iOS and Android) created a
`code-interpreter-beta` sandbox and POSTed a Python shim to its
`/execute` endpoint. The shim was supposed to:

1. `git clone` the repo,
2. `git fetch` + `git checkout` the requested branch,
3. `subprocess.Popen` the user command and tag every stdout/stderr
   line as `STDOUT:…` / `STDERR:…`,
4. emit a final `EXIT:<code>` so the iOS client could parse it back.

This is what users were seeing as **"Sandbox is up but the repo
clone failed: E2B stream: pre-clone: invalid response — invalid
syntax (`3161051163.py`, line 3)"**. The root causes are stacked:

* **Wire mismatch.** The code-interpreter's actual response is
  JSON — one `{"text": "…"}` per stdout line, one
  `{"name": "…", "value": "…", "traceback": "…"}` per error, plus a
  trailing `{"type": "end_of_execution"}` (see
  `code-interpreter/template/server/stream.py`). Our client was
  expecting the custom `STDOUT:` / `STDERR:` / `EXIT:` line format
  the shim was *supposed* to produce. The two never agreed.
* **Python parse failure.** Even when the shim ran, the Jupyter
  kernel's auto-indent path in `messaging.py`
  (`_get_code_indentation` + `_indent_code_with_level`) prepended
  env-var code indented to match the first non-empty line of the
  submitted script. The prepended snippet was
  `import os; os.environ['KEY'] = 'value'`, and any env var whose
  value contained a single quote would corrupt the resulting
  Python source. The kernel reported the failure as
  `File "<numeric>.py", line 3\n    def emit(stream, line):\n…\nSyntaxError: invalid syntax`.
* **Silent hang.** Because the shim never reached the `EXIT:`
  print, our parser never saw an exit line. The run fell through
  to "Sandbox stream ended without an exit code" and was reported
  as a clone failure even when the user's repo was fine.

Switching to envd's `process.Process/Start` avoids all three: no
Python, no Jupyter kernel wrapping, no custom wire format. The
`bash -l -c "<script>"` payload is plain text and the response
follows the documented Connect-RPC shape.

---

## 4. Empirically verified

* Envelope shape (1 byte flags + 4 bytes big-endian length) confirmed
  against `connect-go/envelope.go` (the reference Connect
  implementation).
* `base` template + `envdPort = 49983` confirmed against
  `packages/js-sdk/src/sandbox/index.ts` (`envdPort`, `defaultTemplate`).
* `process.Process/Start` request shape (`ProcessConfig{cmd, args,
  envs, cwd}`) confirmed against
  `packages/python-sdk/e2b/sandbox_async/commands/command.py`
  (`_start`).
* Python-on-code-interpreter auto-indent failure mode confirmed
  against `code-interpreter/template/server/messaging.py` lines
  around `_get_code_indentation` / `_indent_code_with_level` /
  `_set_env_var_snippet`.
* Live capture (envd 0.6.10, sandbox `i0zfplt6vp2znhcj3kna6a`,
  2026-09-01): the response byte sequence and JSON shapes shown
  in §2 came from a real `base` sandbox. The captured byte stream
  is pinned by `testDecodesCapturedEnvdStream` in
  `ios/AnyProvCore/Tests/AnyProvCoreTests/DirectE2BClientTests.swift`,
  so a future envd refactor that changes either the envelope or
  the JSON shape will fail the test loudly.
* The `POST /sandboxes` `timeout` field is in seconds, confirmed
  by `400 Timeout cannot be greater than 1 hours` when sending
  `300_000`.
