import Foundation
import AnyProvCore

/// Tool definitions + dispatch for the phone-driven E2B agent
/// loop. The runner calls Claude with these tools; Claude
/// responds with `tool_use` blocks; the runner executes each
/// tool against the live e2b sandbox via `DirectE2BClient` and
/// returns the result as a `tool_result` block. The loop
/// continues until Claude responds with `end_turn` or hits the
/// step limit.
public actor E2bSessionRunner {
    let client: DirectE2BClient
    let anthropic: AnthropicClient
    /// Step limit to avoid runaway loops. Each Claude response
    /// that includes tool calls counts as one step; each
    /// end_turn ends the loop.
    let maxSteps: Int

    public init(
        e2b: DirectE2BClient,
        anthropic: AnthropicClient,
        maxSteps: Int = 12,
    ) {
        self.client = e2b
        self.anthropic = anthropic
        self.maxSteps = maxSteps
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
        `\(repoFullName)` on branch `\(branch)`. You have shell
        access, can read and write files in the sandbox, and can
        run `git` to commit, push, and open pull requests.

        Workflow:
        1. Use `run_shell` to inspect the working tree (e.g.
           `ls -la`, `git status`, `git log -5`).
        2. Make changes with `write_file` (full file content) or
           `edit_file` (find/replace on a single occurrence).
        3. Verify your changes with `run_shell` (e.g. `python -m
           pytest`, `npm test`, `cargo check`).
        4. When the change is good, use `git_commit` then
           `git_push` then `create_pr`. The user has a GitHub
           token configured in the iOS app, which the runner
           forwards for you.

        Be concise. Prefer running tests over guessing. Do not
        create files outside the repo root. The user can see
        every command and file change you make; you don't need
        to re-explain them.
        """
    }

    /// One step in the agent loop. The `onEvent` closure is
    /// invoked with transcript updates as the loop progresses
    /// so the UI can stream.
    public func step(
        system: String,
        history: inout [AnthropicClient.Message],
        sandboxId: String,
        sandboxAccessToken: String?,
        onEvent: @Sendable (StepEvent) -> Void,
    ) async throws -> StepResult {
        let tools = Self.tools
        let response = try await anthropic.send(
            system: system,
            messages: history,
            tools: tools,
        )
        // Surface the per-step token usage to the UI so it can
        // surface a running total.
        if let usage = response.usage {
            onEvent(.usageRecorded(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            ))
        }
        // Record the assistant's content blocks in the history
        // so the next request includes them.
        history.append(.init(role: "assistant", content: response.content))

        // Did Claude ask for any tool calls? If not, we're done.
        let toolUses = response.content.compactMap { c -> AnthropicClient.Message.Content? in
            if case let .toolUse(id, name, input) = c { return .toolUse(id: id, name: name, input: input) }
            return nil
        }
        guard !toolUses.isEmpty else {
            return .finished
        }
        // Cap the loop. Each "step" is one round-trip; we burn
        // one per tool batch.
        if history.filter({ $0.role == "assistant" }).count >= maxSteps {
            return .hitStepLimit
        }
        // Execute each tool call, then collect the results
        // into a single `user` message so the next request has
        // all results in one place.
        var toolResults: [AnthropicClient.Message.Content] = []
        for call in toolUses {
            guard case let .toolUse(id, name, input) = call else { continue }
            onEvent(.toolCallStarted(id: id, name: name, input: input))
            let (output, isError) = await runTool(
                name: name,
                input: input,
                sandboxId: sandboxId,
                sandboxAccessToken: sandboxAccessToken,
            )
            onEvent(.toolCallFinished(id: id, name: name, output: output, isError: isError))
            toolResults.append(.toolResult(toolUseId: id, content: output, isError: isError))
        }
        history.append(.init(role: "user", content: toolResults))
        return .continued
    }

    // MARK: - Tools

    public enum StepResult: Sendable, Equatable {
        case continued
        case finished
        case hitStepLimit
    }

    public enum StepEvent: Sendable {
        case toolCallStarted(id: String, name: String, input: AnyJSON)
        case toolCallFinished(id: String, name: String, output: String, isError: Bool)
        case usageRecorded(inputTokens: Int, outputTokens: Int)
    }

    /// The tool definitions Claude sees. Names + descriptions
    /// matter — Claude uses them to decide when to call.
    public static let tools: [AnthropicClient.Tool] = [
        .init(
            name: "run_shell",
            description: "Run a shell command inside the sandbox. Returns stdout, stderr, and the exit code. Use this for builds, tests, and git operations.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to run. Use shell syntax; e.g. `ls -la`, `pytest -q`, `git status`."),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ]),
        ),
        .init(
            name: "read_file",
            description: "Read a UTF-8 text file from the sandbox. Returns the file contents. Use this before editing a file to see its current shape.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the file, e.g. /code/src/main.py."),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ]),
        ),
        .init(
            name: "write_file",
            description: "Write a UTF-8 text file. Creates parent directories as needed. Use this to create new files or to fully replace an existing file's content.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the file."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The new file content."),
                    ]),
                ]),
                "required": .array([.string("path"), .string("content")]),
            ]),
        ),
        .init(
            name: "edit_file",
            description: "Apply a single-occurrence find/replace to a UTF-8 text file. Returns an error if the find string isn't present or appears more than once. Prefer this over write_file when changing a small piece of an existing file.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the file."),
                    ]),
                    "find": .object([
                        "type": .string("string"),
                        "description": .string("The exact text to find. Must appear exactly once in the file."),
                    ]),
                    "replace": .object([
                        "type": .string("string"),
                        "description": .string("The replacement text."),
                    ]),
                ]),
                "required": .array([.string("path"), .string("find"), .string("replace")]),
            ]),
        ),
        .init(
            name: "git_commit",
            description: "Stage all changes in the current sandbox working tree and commit with the given message. Returns the new commit SHA. The user's GitHub token is forwarded for the push later.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The commit message. First line is the subject; rest is the body."),
                    ]),
                ]),
                "required": .array([.string("message")]),
            ]),
        ),
        .init(
            name: "git_push",
            description: "Push the current branch to origin. Uses the user's GitHub token. Returns the upstream URL on success.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "setUpstream": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to set the upstream (-u). Default true for the first push on a new branch."),
                    ]),
                ]),
                "required": .array([]),
            ]),
        ),
        .init(
            name: "create_pr",
            description: "Open a pull request via the GitHub API. Title and body are required. The head branch is the current sandbox branch; base defaults to the repo's default branch (usually `main`). Uses the user's GitHub token.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("PR title."),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("PR body / description."),
                    ]),
                    "base": .object([
                        "type": .string("string"),
                        "description": .string("Base branch. Defaults to `main` if omitted."),
                    ]),
                ]),
                "required": .array([.string("title"), .string("body")]),
            ]),
        ),
    ]

    // MARK: - Dispatch

    private func runTool(
        name: String,
        input: AnyJSON,
        sandboxId: String,
        sandboxAccessToken: String?,
    ) async -> (String, Bool) {
        switch name {
        case "run_shell":
            return await runShellTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
        case "read_file":
            return await readFileTool(input: input, sandboxId: sandboxId, sandboxAccessToken: sandboxAccessToken)
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
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private func runShellTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let command = input.stringValue(for: "command") else {
            return ("missing 'command' field", true)
        }
        do {
            let result = try await client.runShell(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                command: command,
                cwd: "/code",
            )
            let text = "exit \(result.exitCode)\n--- stdout ---\n\(result.stdout)\n--- stderr ---\n\(result.stderr)"
            return (text, !result.ok)
        } catch {
            return ("run_shell failed: \(error.localizedDescription)", true)
        }
    }

    private func readFileTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path") else {
            return ("missing 'path' field", true)
        }
        do {
            let contents = try await client.readFile(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                path: path,
            )
            return (contents, false)
        } catch {
            return ("read_file failed: \(error.localizedDescription)", true)
        }
    }

    private func writeFileTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path") else {
            return ("missing 'path' field", true)
        }
        guard let content = input.stringValue(for: "content") else {
            return ("missing 'content' field", true)
        }
        do {
            try await client.writeFile(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                path: path,
                content: content,
            )
            return ("wrote \(path)", false)
        } catch {
            return ("write_file failed: \(error.localizedDescription)", true)
        }
    }

    private func editFileTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let path = input.stringValue(for: "path"),
              let find = input.stringValue(for: "find"),
              let replace = input.stringValue(for: "replace") else {
            return ("missing required fields (path, find, replace)", true)
        }
        do {
            let current = try await client.readFile(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, path: path
            )
            // Count occurrences; require exactly one.
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
            try await client.writeFile(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, path: path, content: updated
            )
            // Build a minimal unified diff in Swift. Each output
            // line starts with `+`, `-`, or ` ` so the ToolCard
            // can colour it without parsing. We only emit the
            // changed region, not the full context — good enough
            // for the chat view to give a feel for the change.
            let diff = Self.miniDiff(find: find, replace: replace, contextLines: 2)
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
    private static func miniDiff(find: String, replace: String, contextLines: Int) -> String {
        let oldLines = find.components(separatedBy: "\n")
        let newLines = replace.components(separatedBy: "\n")
        var out: [String] = ["@@ -\(oldLines.count) +\(newLines.count) @@"]
        for line in oldLines {
            out.append("-\(line)")
        }
        for line in newLines {
            out.append("+\(line)")
        }
        // Hard-cap the diff so the tool card stays usable. The
        // last line is replaced with a hint.
        if out.count > 200 {
            out = Array(out.prefix(199))
            out.append("… (diff truncated, see file in the sandbox for full content)")
        }
        return out.joined(separator: "\n")
    }

    private func gitCommitTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let message = input.stringValue(for: "message") else {
            return ("missing 'message' field", true)
        }
        do {
            // Use a single shell run so we can pipe; set up the
            // author from the user's GitHub identity via env.
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
            let raw = try await client.exec(
                sandboxId: sandboxId,
                accessToken: sandboxAccessToken,
                code: script,
            )
            return (raw, false)
        } catch {
            return ("git_commit failed: \(error.localizedDescription)", true)
        }
    }

    private func gitPushTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        do {
            // -u on first push, plain push on subsequent.
            let setUpstream = input.boolValue(for: "setUpstream") ?? true
            let script = """
            import subprocess
            r = subprocess.run(
                ["git", "push", "origin", "HEAD"] + (["-u"] if \(setUpstream ? "True" : "False") else []),
                capture_output=True, text=True, cwd="/code",
            )
            print(r.stdout, end="")
            print(r.stderr, end="")
            if r.returncode != 0:
                raise SystemExit(r.returncode)
            """
            let raw = try await client.exec(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, code: script,
            )
            return (raw, false)
        } catch {
            return ("git_push failed: \(error.localizedDescription)", true)
        }
    }

    private func createPrTool(input: AnyJSON, sandboxId: String, sandboxAccessToken: String?) async -> (String, Bool) {
        guard let title = input.stringValue(for: "title"),
              let body = input.stringValue(for: "body") else {
            return ("missing required fields (title, body)", true)
        }
        let base = input.stringValue(for: "base") ?? "main"
        do {
            // `gh` is the simplest path: it reads the user's auth
            // from env. We bake the token into a one-shot env
            // file the script can read.
            let script = """
            import os, subprocess, json
            token = os.environ.get("GITHUB_TOKEN", "")
            os.environ["GH_TOKEN"] = token
            r = subprocess.run(
                [
                    "gh", "pr", "create",
                    "--title", \(escapePythonForInline(title)),
                    "--body", \(escapePythonForInline(body)),
                    "--base", \(escapePythonForInline(base)),
                    "--head", os.environ.get("BRANCH", ""),
                    "--repo", os.environ.get("REPO", ""),
                ],
                capture_output=True, text=True, cwd="/code",
                env={**os.environ, "GH_TOKEN": token} if token else None,
            )
            print(r.stdout, end="")
            print(r.stderr, end="")
            if r.returncode != 0:
                raise SystemExit(r.returncode)
            """
            let raw = try await client.exec(
                sandboxId: sandboxId, accessToken: sandboxAccessToken, code: script,
            )
            return (raw, false)
        } catch {
            return ("create_pr failed: \(error.localizedDescription)", true)
        }
    }

    private func escapePythonForInline(_ value: String) -> String {
        PythonQuote.escape(value)
    }
}

// MARK: - AnyJSON helper accessors

extension AnyJSON {
    /// Best-effort access to a string field inside an object.
    /// Returns nil if the root isn't an object, the field is
    /// missing, or the value isn't a string.
    public func stringValue(for key: String) -> String? {
        guard case let .object(dict) = self else { return nil }
        guard case let .string(s) = dict[key] else { return nil }
        return s
    }

    public func boolValue(for key: String) -> Bool? {
        guard case let .object(dict) = self else { return nil }
        guard case let .bool(b) = dict[key] else { return nil }
        return b
    }

    public func intValue(for key: String) -> Int? {
        guard case let .object(dict) = self else { return nil }
        guard case let .int(i) = dict[key] else { return nil }
        return i
    }
}
