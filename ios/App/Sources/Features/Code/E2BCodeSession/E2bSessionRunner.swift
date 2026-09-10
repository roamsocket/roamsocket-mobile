import Foundation
import AnyProvCore

/// GitHub context a session was opened with. `create_pr` and
/// `git_push` run from the phone (E2B sandboxes don't guarantee
/// GitHub egress), so the runner needs the token + repo + branch
/// instead of reading env vars inside the sandbox.
public struct GitHubContext: Sendable, Hashable {
    public let token: String?
    public let repoFullName: String
    public let branch: String

    public init(token: String?, repoFullName: String, branch: String) {
        self.token = token
        self.repoFullName = repoFullName
        self.branch = branch
    }
}

/// Orchestrates the chat-driven E2B agent loop. Provider-agnostic
/// via `AgentLLM` — the runner talks to whatever LLM the user
/// picked (Anthropic, OpenAI, Groq, OpenRouter, xAI, Mistral,
/// custom) and dispatches tool calls against the persistent
/// e2b sandbox via `DirectE2BClient`.
///
/// The runner is an actor so the streaming LLM events can be
/// surfaced to the chat view's `@MainActor` context via the
/// `@Sendable` `onEvent` callback.
public actor E2bSessionRunner {
    let e2b: DirectE2BClient
    let agentLLM: AgentLLM
    /// Step limit to avoid runaway loops. Each Claude response
    /// that includes tool calls counts as one step; each
    /// end_turn ends the loop.
    let maxSteps: Int
    /// GitHub credentials + repo context so git push / PR creation
    /// can run from the phone. E2B sandboxes have no guaranteed
    /// network egress to GitHub, so the design doc routes these
    /// through the iOS backend instead of the sandbox shell.
    let github: GitHubContext
    /// Permission mode for the agent's tool calls. Mirrors
    /// the desktop session's `PermissionMode`
    /// (`acceptEdits` / `ask` / `plan`). The mode is
    /// captured at runner init and stays fixed for the
    /// lifetime of the runner — the view sets it on the
    /// session when the user sends a message, so a
    /// mid-run mode swap never lands on a turn already
    /// in flight (the runner can be re-created cheaply).
    let permissionMode: E2bCodeSession.PermissionMode
    /// Closure the runner calls when a mutating tool
    /// fires in `.ask` mode. The closure bridges to the
    /// chat view's permission bar (set the
    /// `pendingPermission` state, wait for Allow/Deny),
    /// and returns the decision. `nil` means the runner
    /// runs every tool without prompting — used by
    /// tests and by the "ask" mode caller that forgets
    /// to wire up the bridge (the runner falls through
    /// and runs the tool, which is safer than hanging).
    let onPermissionRequest: (@Sendable (String, String) async -> Bool)?

    public init(
        e2b: DirectE2BClient,
        agentLLM: AgentLLM,
        github: GitHubContext,
        /// Step limit to avoid runaway loops. Each assistant turn
        /// that includes tool calls counts as one step; each
        /// end_turn ends the loop. Bumped from 12 to 24 to match
        /// the desktop server's `MAX_ROUNDS` (see
        /// `desktop-server/src/agent/loop.ts`) so a long phone-
        /// originated agent run (clone + multi-file edit + test
        /// + commit + push + PR) doesn't get cut off mid-task on
        /// the 13th tool call.
        maxSteps: Int = 24,
        permissionMode: E2bCodeSession.PermissionMode = .acceptEdits,
        onPermissionRequest: (@Sendable (String, String) async -> Bool)? = nil,
    ) {
        self.e2b = e2b
        self.agentLLM = agentLLM
        self.github = github
        self.maxSteps = maxSteps
        self.permissionMode = permissionMode
        self.onPermissionRequest = onPermissionRequest
    }

    // MARK: - Public

    /// System prompt for the agent. The agent is told the
    /// sandbox is fresh, what tools it has, and that it should
    /// work step-by-step. The first user message primes it
    /// with the repo + branch context.
    public static func systemPrompt(repoFullName: String, branch: String) -> String {
        return """
        You are an autonomous coding agent running inside a fresh
        Ubuntu sandbox on e2b.dev. The user is working on the repo
        `\(repoFullName)` on branch `\(branch)`. The repo has
        already been cloned into `/code` and the branch checked
        out, so start with `ls /code` and `git status` rather
        than re-cloning. You have shell access, can read and
        write files in the sandbox, and can run `git` to commit,
        push, and open pull requests.

        Workflow:
        1. Use `run_shell` to inspect the working tree (e.g.
           `ls /code`, `git status`, `git log -5`).
        2. Make changes with `write_file` (full file content) or
           `edit_file` (find/replace on a single occurrence).
        3. Verify your changes with `run_shell` (e.g. `python -m
           pytest`, `npm test`, `cargo check`).
        4. When the change is good, use `git_commit` then
           `git_push` then `create_pr`. The user has a GitHub
           token configured in the iOS app, which the runner
           forwards for you.

        You can keep a short task checklist with the `todos` tool
        (list / add / finish / clear) — it persists in the sandbox
        across messages.

        Be concise. Prefer running tests over guessing. Do not
        create files outside `/code`. The user can see every
        command and file change you make; you don't need to
        re-explain them.
        """
    }

    /// One step in the agent loop. Uses the `AgentLLM.stream`
    /// SSE channel so the agent's text comes in as deltas and
    /// the UI can show a typing indicator.
    ///
    /// The `history` array uses the provider-agnostic
    /// `AgentLLMMessage` type. The runner mutates it to
    /// append the assistant turn after each response, so the
    /// next request has the full context.
    public func step(
        system: String,
        history: inout [AgentLLMMessage],
        sandboxId: String,
        sandboxAccessToken: String?,
        onEvent: @Sendable (StepEvent) -> Void,
    ) async throws -> StepResult {
        let tools = Self.tools
        onEvent(.streamStarted)
        var streamedText: [String] = []
        // Reasoning body (e.g. MiniMax's `<think>…</think>` text).
        // The non-streaming LLM client emits a single
        // `thinkingDelta` after the parser peels the tag open;
        // we thread it onto the final assistant message so the
        // view can render a ThinkingBlock with it.
        var streamedThinking: [String] = []
        // Each tool call: id, name, accumulated input JSON.
        var toolCalls: [(id: String, name: String, inputJSON: String)] = []
        var streamedUsage: (input: Int, output: Int)?

        for try await event in agentLLM.stream(
            system: system,
            messages: history,
            tools: tools,
            // E2B agent responses routinely include a
            // directory tree dump + multi-file code edits
            // + a verbal summary in one turn. The previous
            // 4K cap was hitting the model before the
            // response completed (visible in the Code
            // session as the assistant message cutting off
            // mid-sentence / mid-code-block). 16K is well
            // under MiniMax M3's recommended 131K ceiling
            // and gives the agent room to finish a typical
            // turn without truncation; the runner can always
            // be revisited if a use case needs more.
            maxTokens: 16384
        ) {
            if Task.isCancelled { break }
            switch event {
            case let .textDelta(text):
                streamedText.append(text)
                onEvent(.textDelta(text: text))
            case let .thinkingDelta(text):
                streamedThinking.append(text)
            case let .toolCallStart(id, name, input):
                // The wrapper client already yielded start; we
                // also record the call so we can dispatch it
                // once the input JSON is complete.
                toolCalls.append((id: id, name: name, inputJSON: ""))
                // Stash the initial input (may be empty).
                if case let .object(dict) = input.raw, !dict.isEmpty {
                    let data = try? JSONSerialization.data(withJSONObject: dict.mapValues { $0.value }, options: [.sortedKeys])
                    let str = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    if let last = toolCalls.last, last.id == id {
                        toolCalls[toolCalls.count - 1].inputJSON = str
                    }
                }
            case let .toolCallInputDelta(id, partial):
                if let idx = toolCalls.firstIndex(where: { $0.id == id }) {
                    toolCalls[idx].inputJSON.append(partial)
                }
            case let .toolCallEnd(id):
                if let idx = toolCalls.firstIndex(where: { $0.id == id }) {
                    onEvent(.toolCallStarted(
                        id: id,
                        name: toolCalls[idx].name,
                        input: .init(raw: .object([:]))
                    ))
                }
            case let .usage(input, output):
                streamedUsage = (input, output)
            case .stop:
                break
            }
        }

        if let usage = streamedUsage {
            onEvent(.usageRecorded(
                inputTokens: usage.input,
                outputTokens: usage.output
            ))
        }
        onEvent(.streamFinished(text: streamedText.joined()))

        // Build the final assistant turn: text + tool calls in
        // order, so the next request has the full context.
        var finalContent: String = streamedText.joined()
        // Fold tool calls in as text so the provider-agnostic
        // message history sees them (the wrapper client
        // reconstructs tool calls from streamed events; the
        // history passed back is just the text + a per-tool
        // summary so the model sees what happened).
        if !toolCalls.isEmpty {
            for call in toolCalls {
                finalContent += "\n\n[tool_call: \(call.name) id=\(call.id) input=\(call.inputJSON)]"
            }
        }
        let thinking = streamedThinking.joined()
        // The view should only see the model's prose —
        // `[tool_call: …]` synthesis is internal history
        // (the next turn needs to know what tools ran). The
        // tool card on screen already shows the call's name
        // and result, so duplicating the markup in the chat
        // bubble just makes the transcript hard to read and
        // looks like the agent "printed" the command instead
        // of running it.
        let visibleText = streamedText.joined()
        // The runner is provider-agnostic; it doesn't know how
        // to attach `thoughtProcess` to a specific history row.
        // Emit a dedicated event so the view can stamp the
        // final assistant message with the reasoning body it
        // would otherwise lose when the turn ends.
        if !thinking.isEmpty {
            onEvent(.assistantTurnComplete(
                thinking: thinking,
                text: visibleText
            ))
        }
        history.append(.init(role: .assistant, content: finalContent))

        // If the model returned neither text nor tool calls, the
        // request "succeeded" but produced nothing — usually
        // because the model doesn't actually support the tool-
        // calling wire format we sent (chat-only models).
        // Surfacing this as a thrown error means the view shows
        // a notice instead of silently dropping the turn. The
        // user can swap models rather than re-typing the prompt.
        let trimmed = finalContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if toolCalls.isEmpty && trimmed.isEmpty {
            throw StepError.emptyResponse
        }

        guard !toolCalls.isEmpty else {
            return .finished
        }
        if history.filter({ $0.role == .assistant }).count >= maxSteps {
            return .hitStepLimit
        }
        // Execute each tool call against the sandbox and collect
        // the results into a single user message.
        var toolResults: [AgentLLMMessage] = []
        for call in toolCalls {
            let parsed = parseToolInputJSON(call.inputJSON)
            let input = AgentLLMInput(raw: parsed)
            let (output, isError) = await runTool(
                name: call.name,
                input: input,
                sandboxId: sandboxId,
                sandboxAccessToken: sandboxAccessToken,
            )
            // For the `todos` tool, emit a task-list
            // event so the view's banner + sheet stay in
            // sync. Re-read the file rather than threading
            // the items through the tool's return value
            // (cleaner than a tuple — `runTool` has a
            // single `(output, isError)` shape for every
            // other tool, and the file read is a single
            // sandbox round-trip on the small JSON
            // payload).
            if call.name == "todos" {
                if let items = try? await loadTodos(
                    sandboxId: sandboxId,
                    accessToken: sandboxAccessToken
                ) {
                    onEvent(.taskListUpdated(items: items))
                }
            }
            onEvent(.toolCallFinished(
                id: call.id,
                name: call.name,
                output: output,
                isError: isError
            ))
            let role: AgentLLMMessage.Role = isError ? .user : .user
            let prefix = isError ? "[tool_error] " : "[tool_result] "
            toolResults.append(.init(role: role, content: prefix + output))
        }
        history.append(contentsOf: toolResults)
        return .continued
    }

    // MARK: - Tools

    public enum StepResult: Sendable, Equatable {
        case continued
        case finished
        case hitStepLimit
    }

    /// Errors that surface to the E2B session view as a
    /// transcript notice (via the existing `catch` arm). Kept
    /// narrow on purpose — only the cases the user can act on
    /// (swap models, etc.) belong here.
    public enum StepError: Error, LocalizedError {
        /// The model accepted the request and closed the stream
        /// cleanly but produced no text and no tool calls. The
        /// E2B agent can do nothing useful with an empty turn,
        /// so we surface this instead of silently dropping it.
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "The model returned an empty response. It may not support the tool-calling format the E2B agent uses — try a different model."
            }
        }
    }

    public enum StepEvent: Sendable {
        case toolCallStarted(id: String, name: String, input: AgentLLMInput)
        case toolCallFinished(id: String, name: String, output: String, isError: Bool)
        case usageRecorded(inputTokens: Int, outputTokens: Int)
        /// Fired once at the start of each step so the UI can
        /// show a typing indicator.
        case streamStarted
        /// Fired for each text delta the model streams.
        case textDelta(text: String)
        /// Fired when the model finishes streaming text. The
        /// `text` is the joined full text of the turn.
        case streamFinished(text: String)
        /// Fired when the runner has both the visible text and
        /// the model's reasoning (`<think>…</think>` body) for
        /// the just-completed turn. The view stamps the
        /// existing assistant transcript row with the thinking
        /// so the E2B session renders the same collapsed
        /// ThinkingBlock as the chat composer.
        case assistantTurnComplete(thinking: String, text: String)
        /// Fired after every `todos` tool call (and once at
        /// session start) with the current contents of the
        /// sandbox's `/home/user/todos.json`. Drives the
        /// task-list banner in `E2bSessionView`. Empty
        /// array when the file is missing or empty (the
        /// banner hides in that case).
        case taskListUpdated(items: [String])
    }

    /// The tool definitions Claude (or any OpenAI-compatible
    /// model with tool use) sees. Names + descriptions matter —
    /// the model uses them to decide when to call.
    public static let tools: [AgentLLMTool] = [
        .init(
            name: "run_shell",
            description: "Run a shell command inside the sandbox. Returns stdout, stderr, and the exit code. Use this for builds, tests, and git operations.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "command": .init(
                        type: "string",
                        description: "The shell command to run. Use shell syntax; e.g. `ls -la`, `pytest -q`, `git status`."
                    )
                ],
                required: ["command"]
            )
        ),
        .init(
            name: "read_file",
            description: "Read a UTF-8 text file from the sandbox. Returns the file contents.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "path": .init(
                        type: "string",
                        description: "Absolute path to the file, e.g. /code/src/main.py."
                    )
                ],
                required: ["path"]
            )
        ),
        .init(
            name: "glob",
            description: "Find files inside `/code` matching a glob pattern. Returns up to 500 relative paths, one per line. Use this to discover the project layout before reading or editing files. Patterns use the same syntax as the desktop server's glob tool: `*` matches a single path segment, `**` matches across directories, `?` matches a single character. Examples: `**/*.swift` (every Swift file), `src/**/*.ts`, `*.md`.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "pattern": .init(
                        type: "string",
                        description: "Glob pattern relative to `/code`, e.g. `src/**/*.swift`."
                    )
                ],
                required: ["pattern"]
            )
        ),
        .init(
            name: "write_file",
            description: "Write a UTF-8 text file. Creates parent directories as needed.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "path": .init(
                        type: "string",
                        description: "Absolute path to the file."
                    ),
                    "content": .init(
                        type: "string",
                        description: "The new file content."
                    )
                ],
                required: ["path", "content"]
            )
        ),
        .init(
            name: "edit_file",
            description: "Apply a single-occurrence find/replace to a UTF-8 text file. Returns an error if the find string isn't present or appears more than once.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "path": .init(
                        type: "string",
                        description: "Absolute path to the file."
                    ),
                    "find": .init(
                        type: "string",
                        description: "The exact text to find. Must appear exactly once in the file."
                    ),
                    "replace": .init(
                        type: "string",
                        description: "The replacement text."
                    )
                ],
                required: ["path", "find", "replace"]
            )
        ),
        .init(
            name: "git_commit",
            description: "Stage all changes in the current sandbox working tree and commit with the given message. Returns the new commit SHA.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "message": .init(
                        type: "string",
                        description: "The commit message. First line is the subject; rest is the body."
                    )
                ],
                required: ["message"]
            )
        ),
        .init(
            name: "git_push",
            description: "Push the current branch to origin. Returns the upstream URL on success.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "setUpstream": .init(
                        type: "boolean",
                        description: "Whether to set the upstream (-u). Default true for the first push on a new branch."
                    )
                ],
                required: nil
            )
        ),
        .init(
            name: "create_pr",
            description: "Open a pull request via the GitHub API from the iOS app (the sandbox has no guaranteed GitHub access). Title and body are required. The head branch is the current session branch; base defaults to `main`.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "title": .init(
                        type: "string",
                        description: "PR title."
                    ),
                    "body": .init(
                        type: "string",
                        description: "PR body / description."
                    ),
                    "base": .init(
                        type: "string",
                        description: "Base branch. Defaults to `main` if omitted."
                    )
                ],
                required: ["title", "body"]
            )
        ),
        .init(
            name: "todos",
            description: "Maintain a task checklist for this session. Actions: `list` shows the current list, `add` appends a task, `finish` marks one done by 1-based index, `clear` empties it. The list is stored in the sandbox so it survives across messages.",
            inputSchema: .init(
                type: "object",
                properties: [
                    "action": .init(
                        type: "string",
                        description: "list | add | finish | clear"
                    ),
                    "task": .init(
                        type: "string",
                        description: "The task text for `add`."
                    ),
                    "index": .init(
                        type: "integer",
                        description: "1-based task index for `finish`."
                    )
                ],
                required: ["action"]
            )
        ),
    ]

    // MARK: - Dispatch

    /// Tools whose execution mutates the sandbox working
    /// tree, the Git remote, or the user-visible PR list.
    /// Mirrors the desktop server's `MUTATING_TOOLS` set
    /// (see `desktop-server/src/tools/index.ts`). The
    /// agent loop gates these on the session's permission
    /// mode — `acceptEdits` runs them, `ask` pauses for
    /// the user's Allow / Deny, `plan` describes the
    /// change without executing. Read-only tools
    /// (`read_file`, `glob`) are never gated.
    public static let mutatingTools: Set<String> = [
        "run_shell", "write_file", "edit_file",
        "git_commit", "git_push", "create_pr", "todos",
    ]

    /// One-line summary the permission bar shows for a
    /// tool call awaiting user approval. Mirrors the
    /// desktop's `Tool.summarize(input)` pattern. The
    /// summary is intentionally terse — the bar caps at
    /// one line and the full input is in the upcoming
    /// tool card.
    public static func summarize(tool: String, input: AgentLLMInput) -> String {
        switch tool {
        case "run_shell":
            return "run: \(input.stringValue(for: "command") ?? "")"
        case "write_file":
            return "write: \(input.stringValue(for: "path") ?? "")"
        case "edit_file":
            return "edit: \(input.stringValue(for: "path") ?? "")"
        case "git_commit":
            let message = input.stringValue(for: "message") ?? ""
            let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return "commit: \(firstLine)"
        case "git_push":
            return "push current branch"
        case "create_pr":
            return "PR: \(input.stringValue(for: "title") ?? "")"
        case "todos":
            return "todos \(input.stringValue(for: "action") ?? "list")"
        default:
            return tool
        }
    }

    private func runTool(
        name: String,
        input: AgentLLMInput,
        sandboxId: String,
        sandboxAccessToken: String?,
    ) async -> (String, Bool) {
        // Permission gate. Runs BEFORE the switch so the
        // gating is a single concern, not interleaved
        // with each tool's signature.
        if Self.mutatingTools.contains(name) {
            switch permissionMode {
            case .plan:
                // Plan mode: describe the intent so the
                // model knows the change was described but
                // not applied. The model's next turn can
                // adjust the call before any real mutation.
                return (
                    "[plan mode] `\(name)` described but not executed. "
                    + "Switch to Accept edits (or Ask) and re-send the request to apply.",
                    false
                )
            case .ask:
                // Ask mode: bridge to the chat view's
                // permission bar. Falls through (runs
                // the tool) when no closure is wired up
                // — better to commit a no-op edit than to
                // hang waiting for a UI that isn't there.
                if let request = onPermissionRequest {
                    let summary = Self.summarize(tool: name, input: input)
                    let allowed = await request(name, summary)
                    if !allowed {
                        return ("Denied by user.", true)
                    }
                }
            case .acceptEdits:
                break
            }
        }
        switch name {
        case "run_shell":
            return await runShellTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "read_file":
            return await readFileTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "glob":
            return await globTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "write_file":
            return await writeFileTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "edit_file":
            return await editFileTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "git_commit":
            return await gitCommitTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "git_push":
            return await gitPushTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "create_pr":
            return await createPrTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "todos":
            // Todos returns a tuple so the caller can
            // emit a `taskListUpdated` event with the
            // post-action state (the `runTool` signature
            // only returns `(output, isError)` for
            // every other tool — the todos variant is
            // the exception because its UI side effect
            // is what the user sees in the banner).
            let result = await todosTool(
                input: input,
                sandboxId: sandboxId,
                sandboxAccessToken: sandboxAccessToken
            )
            return (result.output, result.isError)
        default:
            // The paired-desktop agent exposes more capabilities than
            // the phone sandbox. Surface the known ones as friendly
            // "not supported in cloud mode" messages (E2B design doc),
            // and offer the desktop fallback instead of a generic dump.
            let cloudUnsupported = [
                "skills_sync", "skills", "mcp_sync", "mcp", "memory_sync", "memory",
                "connector", "connectors", "terminal", "file_explorer", "port_manager",
                "ports", "tunnel", "tunnels", "goal", "task_list",
            ]
            if cloudUnsupported.contains(name) {
                return (
                    "`\(name)` is not supported in cloud (E2B) mode. "
                        + "Pair a desktop and run the session there if you need this feature.",
                    true
                )
            }
            return ("Unknown tool: \(name)", true)
        }
    }

    private func runShellTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let command = input.stringValue(for: "command") else {
            return ("missing 'command' field", true)
        }
        do {
            let result = try await e2b.runShell(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                command: command,
                cwd: "/code"
            )
            let text = "exit \(result.exitCode)\n--- stdout ---\n\(result.stdout)\n--- stderr ---\n\(result.stderr)"
            return (text, !result.ok)
        } catch {
            return ("run_shell failed: \(error.localizedDescription)", true)
        }
    }

    private func readFileTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path") else {
            return ("missing 'path' field", true)
        }
        do {
            let contents = try await e2b.readFile(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                path: path
            )
            return (contents, false)
        } catch {
            return ("read_file failed: \(error.localizedDescription)", true)
        }
    }

    private func globTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let pattern = input.stringValue(for: "pattern") else {
            return ("missing 'pattern' field", true)
        }
        do {
            let matches = try await e2b.listFiles(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                pattern: pattern,
                cwd: "/code"
            )
            if matches.isEmpty {
                return ("(no matches)", false)
            }
            return (matches.joined(separator: "\n"), false)
        } catch {
            return ("glob failed: \(error.localizedDescription)", true)
        }
    }

    private func writeFileTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path") else {
            return ("missing 'path' field", true)
        }
        guard let content = input.stringValue(for: "content") else {
            return ("missing 'content' field", true)
        }
        do {
            try await e2b.writeFile(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                path: path,
                content: content
            )
            return ("wrote \(path)", false)
        } catch {
            return ("write_file failed: \(error.localizedDescription)", true)
        }
    }

    private func editFileTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path"),
              let find = input.stringValue(for: "find"),
              let replace = input.stringValue(for: "replace") else {
            return ("missing required fields (path, find, replace)", true)
        }
        do {
            let current = try await e2b.readFile(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, path: path
            )
            var searchStart = current.startIndex
            var foundRange: Range<String.Index>? = nil
            var count = 0
            while searchStart < current.endIndex,
                  let r = current.range(of: find, range: searchStart..<current.endIndex) {
                foundRange = r
                count += 1
                searchStart = r.upperBound
            }
            guard count == 1, let r = foundRange else {
                return ("edit_file: 'find' must appear exactly once (found \(count))", true)
            }
            let updated = current.replacingCharacters(in: r, with: replace)
            try await e2b.writeFile(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, path: path, content: updated
            )
            let diff = Self.miniDiff(find: find, replace: replace)
            let header = "edited \(path)"
            return ([header, diff].joined(separator: "\n\n"), false)
        } catch {
            return ("edit_file failed: \(error.localizedDescription)", true)
        }
    }

    /// Minimal context-preserving diff. We have the exact
    /// `find` and `replace` strings, so the only line-level
    /// change is the substitution. Emit ` ` (context), `-`
    /// (removed), `+` (added) lines with a `@@` hunk header.
    /// Truncated to 200 lines so a giant edit doesn't blow up
    /// the tool card.
    private static func miniDiff(find: String, replace: String) -> String {
        let oldLines = find.components(separatedBy: "\n")
        let newLines = replace.components(separatedBy: "\n")
        var out: [String] = ["@@ -\(oldLines.count) +\(newLines.count) @@"]
        for line in oldLines {
            out.append("-\(line)")
        }
        for line in newLines {
            out.append("+\(line)")
        }
        if out.count > 200 {
            out = Array(out.prefix(199))
            out.append("… (diff truncated, see file in the sandbox for full content)")
        }
        return out.joined(separator: "\n")
    }

    private func gitCommitTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let message = input.stringValue(for: "message") else {
            return ("missing 'message' field", true)
        }
        do {
            let script = """
            import subprocess
            def run(*args):
                return subprocess.run(list(args), capture_output=True, text=True, cwd="/code")
            a = run("git", "add", "-A")
            if a.returncode != 0:
                print("git add failed:", a.stderr); return
            c = run("git", "commit", "-m", \(escapePythonForInline(message)))
            if c.returncode != 0:
                print("git commit failed:", c.stderr); return
            sha = run("git", "rev-parse", "HEAD")
            print("commit:", sha.stdout.strip())
            """
            let raw = try await e2b.exec(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                code: script,
            )
            return (raw, false)
        } catch {
            return ("git_commit failed: \(error.localizedDescription)", true)
        }
    }

    private func gitPushTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        do {
            let setUpstream = input.boolValue(for: "setUpstream") ?? true
            // Push straight to the GitHub URL with the user's token
            // embedded, mirroring how the pre-clone authenticates. The
            // sandbox's configured `origin` may point at an
            // unauthenticated https URL (fine for public repos, useless
            // for pushing private ones or new branches).
            var pushTarget = "origin"
            if let token = github.token, !token.isEmpty {
                let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? token
                pushTarget = "https://oauth2:\(encoded)@github.com/\(github.repoFullName).git"
            }
            let script = """
            import subprocess
            remote = \(escapePythonForInline(pushTarget))
            r = subprocess.run(
                ["git", "push", remote, "HEAD"] + (["-u"] if \(setUpstream ? "True" : "False") else []),
                capture_output=True, text=True, cwd="/code",
            )
            print(r.stdout, end="")
            print(r.stderr, end="")
            if r.returncode != 0:
                raise SystemExit(r.returncode)
            """
            let raw = try await e2b.exec(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, code: script,
            )
            return (raw, false)
        } catch {
            return ("git_push failed: \(error.localizedDescription)", true)
        }
    }

    /// Create the PR from the phone via the GitHub REST API. The
    /// previous implementation shelled out to `gh` inside the sandbox
    /// and read `GITHUB_TOKEN` / `REPO` / `BRANCH` env vars that were
    /// never set there — and E2B sandboxes have no guaranteed GitHub
    /// egress. The design doc routes this through the iOS backend.
    private func createPrTool(input: AgentLLMInput, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let title = input.stringValue(for: "title"),
              let body = input.stringValue(for: "body") else {
            return ("missing required fields (title, body)", true)
        }
        let base = input.stringValue(for: "base") ?? "main"
        guard let token = github.token, !token.isEmpty else {
            return (
                "create_pr needs a GitHub token — link GitHub in Settings, then ask me to try again.",
                true
            )
        }
        guard !github.repoFullName.isEmpty, !github.branch.isEmpty else {
            return ("create_pr needs a repo + branch — start the session from a repository.", true)
        }

        var req = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(github.repoFullName)/pulls")!
        )
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "head": github.branch,
            "base": base,
            "body": body,
        ])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return ("create_pr failed: \(error.localizedDescription)", true)
        }
        guard let http = response as? HTTPURLResponse else {
            return ("create_pr failed: non-HTTP response from GitHub.", true)
        }
        if (200..<300).contains(http.statusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = json["html_url"] as? String {
                return ("PR created: \(url)", false)
            }
            return ("PR created.", false)
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let message = DirectE2BError.friendlyMessage(status: http.statusCode, body: bodyText)
        return ("create_pr failed (HTTP \(http.statusCode)): \(message)", true)
    }

    /// Session-scoped task checklist, kept in the sandbox at
    /// `/home/user/todos.json` so it survives across messages and
    /// agent restarts (the runner itself is rebuilt per send). Actions:
    /// list, add, finish (1-based index), clear.
    /// Returns the (output, isError, items) tuple — the
    /// `items` slice is the current task list the view's
    /// banner should display after this call, so the
    /// caller can emit a `taskListUpdated` event without
    /// re-reading the file.
    private func todosTool(
        input: AgentLLMInput,
        sandboxId: String,
        sandboxAccessToken: String?,
    ) async -> (output: String, isError: Bool, items: [String]) {
        let action = input.stringValue(for: "action") ?? "list"
        let todosPath = "/home/user/todos.json"
        var items: [String] = []
        if let raw = try? await e2b.readFile(
            sandboxId: sandboxId, accessToken: sandboxAccessToken, path: todosPath
        ), let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = parsed["items"] as? [String] {
            items = stored
        }
        switch action {
        case "add":
            let task = (input.stringValue(for: "task") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return ("todos add needs a `task` value.", true, items) }
            items.append(task)
        case "finish":
            if let index = input.intValue(for: "index") {
                guard (1...items.count).contains(index) else {
                    return (
                        "todos finish: index \(index) is out of range (list has \(items.count) tasks).",
                        true,
                        items
                    )
                }
                items.remove(at: index - 1)
            } else if let marker = input.stringValue(for: "task"), !marker.isEmpty,
                      let idx = items.firstIndex(where: { $0 == marker }) {
                items.remove(at: idx)
            } else {
                return (
                    "todos finish needs a 1-based `index` (or the exact `task` text).",
                    true,
                    items
                )
            }
        case "clear":
            items = []
        default:
            break // list
        }
        // Persist (best-effort; a failed write still reports the list).
        if let data = try? JSONSerialization.data(withJSONObject: ["items": items]),
           let content = String(data: data, encoding: .utf8) {
            try? await e2b.writeFile(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, path: todosPath, content: content
            )
        }
        if items.isEmpty {
            return ("No pending tasks.", false, items)
        }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return ("Tasks:\n\(list)", false, items)
    }

    /// Read the sandbox's `/home/user/todos.json` and
    /// return the `items` array. Returns `nil` when the
    /// file doesn't exist or fails to parse — the caller
    /// treats that as "no banner change" rather than an
    /// error. Used by the runner's `step` to emit a
    /// `taskListUpdated` event after every `todos` call.
    private func loadTodos(
        sandboxId: String,
        accessToken: String?,
    ) async -> [String]? {
        let todosPath = "/home/user/todos.json"
        guard let raw = try? await e2b.readFile(
            sandboxId: sandboxId, accessToken: accessToken, path: todosPath
        ), let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parsed["items"] as? [String]
    }

    private func escapePythonForInline(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Parse a tool input JSON string into an `AnyJSON` object.
    /// Best-effort — falls back to `.object([:])` on parse failure
    /// so the runner never crashes mid-step.
    private func parseToolInputJSON(_ s: String) -> AnyJSON {
        guard let data = s.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .object([:]) }
        return Self.dictionaryToAnyJSON(parsed)
    }

    private static func dictionaryToAnyJSON(_ dict: [String: Any]) -> AnyJSON {
        var out: [String: AnyJSON] = [:]
        for (k, v) in dict {
            out[k] = anyToAnyJSON(v)
        }
        return .object(out)
    }

    private static func anyToAnyJSON(_ v: Any) -> AnyJSON {
        if v is NSNull { return .nullValue }
        if let b = v as? Bool { return .bool(b) }
        if let i = v as? Int { return .int(i) }
        if let d = v as? Double { return .double(d) }
        if let s = v as? String { return .string(s) }
        if let a = v as? [Any] { return .array(a.map(anyToAnyJSON)) }
        if let o = v as? [String: Any] { return dictionaryToAnyJSON(o) }
        return .nullValue
    }
}
