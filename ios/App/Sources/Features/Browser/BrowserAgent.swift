import Foundation
import AnyProvCore

/// Talks to the selected chat model to turn a user goal (plus the current
/// page context) into a `BrowserPlan`. The model is instructed to always
/// respond with a plan — it is never allowed to claim an action happened
/// without a corresponding step, which is what lets the UI guarantee
/// "plan, then approve" before anything actually runs in the web view.
enum BrowserAgent {
    struct PlanError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let allowedKinds = "navigate, click, type, scroll, back, forward, reload, wait, extract"

    private static func systemPrompt() -> String {
        """
        You are a careful browsing assistant embedded in a web browser. You can \
        propose actions but you can NEVER execute anything yourself — the app only \
        runs a step after the human taps Approve. Because of that, you must always \
        respond with a short plan broken into discrete steps, even for a single action, \
        and you must never claim a page was visited, a button was clicked, or a form was \
        submitted unless that exact action is one of the steps you are proposing.

        Respond with ONLY minified JSON, no prose, no markdown fences, matching:
        {"goal":"<one sentence restating what you'll accomplish>",
         "steps":[{"kind":"<\(allowedKinds)>","target":"<url, element hint, or direction/seconds>","value":"<text to type, or null>","description":"<one plain-language sentence a non-technical user can approve>"}]}

        Rules:
        - "kind" must be exactly one of: \(allowedKinds).
        - "navigate" needs a full URL in "target".
        - "click" needs a short hint in "target" describing the visible label/text of the element (e.g. "Sign in button"), not a CSS selector unless you are certain of it.
        - "type" needs a hint in "target" (e.g. "search box", "email field") and the literal text to enter in "value"; add a trailing step describing submission if a form should be submitted (use another "type" or a "click" step for the submit button).
        - "scroll" target is "up" or "down".
        - "wait" target is a whole number of seconds (used sparingly, e.g. after submitting a search). The driver already waits for the page to fully settle (readyState complete + network quiet + a minimum paint delay) after every action, so you do NOT need to insert "wait" steps just because a page is JavaScript-heavy — only use "wait" when you genuinely need extra time for an animation, redirect, or external system to finish.
        - "extract" means "read the resulting page and summarize for the user" — use it as the final step whenever you need to report back what happened.
        - Keep plans short: 1-6 steps. Never invent data you weren't given (login credentials, payment details, personal info) — if the task needs a secret you don't have, stop and add a single step explaining what's missing instead of guessing.
        - Never mark a task complete in "description" text; describe intent ("Search for X"), not outcome ("Searched for X").
        """
    }

    /// Shared page-grounding block reused by both the initial plan prompt
    /// and the after-every-step re-analysis prompt.
    private static func pageContextLines(_ context: BrowserPageContext?) -> [String] {
        guard let context else {
            return ["No page is loaded yet. If the request needs a specific site, start with a \"navigate\" step."]
        }
        var lines = [
            "Current page URL: \(context.url)",
            "Current page title: \(context.title)",
        ]
        if !context.textSnippet.isEmpty {
            lines.append("Visible page text (truncated): \(context.textSnippet.prefix(6000))")
        } else {
            lines.append("Visible page text: (empty — the page may still be loading, may require JavaScript that hasn't finished, or may be a consent/interstitial page)")
        }
        if !context.links.isEmpty {
            let sample = context.links.prefix(30).map { "- \($0.label)" }.joined(separator: "\n")
            lines.append("Prominent clickable elements on the page:\n\(sample)")
        }
        return lines
    }

    private static func userPrompt(goal: String, context: BrowserPageContext?) -> String {
        var lines: [String] = ["User request: \(goal)"]
        lines.append(contentsOf: pageContextLines(context))
        lines.append("Respond with the JSON plan now.")
        return lines.joined(separator: "\n\n")
    }

    /// Ask the model for a plan. Throws `PlanError` on missing model/key or
    /// unparsable output so the caller can show a friendly message.
    static func requestPlan(
        goal: String,
        context: BrowserPageContext?,
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> BrowserPlan {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let messages = [
            ProviderChatMessage(role: .system, content: systemPrompt()),
            ProviderChatMessage(role: .user, content: userPrompt(goal: goal, context: context)),
        ]
        let raw: String
        do {
            raw = try await provider.chat(model: model.modelID, apiKey: apiKey, messages: messages, effort: nil)
        } catch {
            throw PlanError(message: error.localizedDescription)
        }
        return try parsePlan(raw, fallbackGoal: goal)
    }

    /// What the model decides after seeing the outcome of the step(s) run
    /// so far: either the task is done, or here are the next step(s) —
    /// usually one, but see `nextStepSystemPrompt` for when it may batch
    /// several mechanical actions (e.g. checking a row of checkboxes) into
    /// one combined approval instead of asking again after every single one.
    struct NextStepDecision {
        let done: Bool
        /// If `done`, a one-sentence outcome; otherwise a brief status note.
        let summary: String
        /// Empty iff `done` is true.
        let steps: [BrowserStep]
    }

    private static func nextStepSystemPrompt() -> String {
        """
        You are a careful browsing assistant mid-task. You are re-evaluating \
        after every action instead of blindly following a fixed script, because \
        the page may not have changed the way anyone expected. You can NEVER \
        execute anything yourself — the app only runs the step(s) you propose \
        after the human approves them, as a group if you propose more than one.

        You will be given: the original goal, every step already executed (with \
        its outcome), and a fresh snapshot of the current page. Decide exactly one of:
        - The goal is now accomplished, or it cannot be accomplished — respond \
        with "done": true, "steps": [], and a one-sentence "summary" of the actual outcome.
        - More is needed — respond with "done": false, a brief "summary" of where \
        things stand, and a "steps" array describing what to do next.

        Respond with ONLY minified JSON, no prose, no markdown fences, matching one of:
        {"done": false, "summary": "<brief status>", "steps": [{"kind":"<\(allowedKinds)>","target":"<url, element hint, or direction/seconds>","value":"<text to type, or null>","description":"<one plain-language sentence a non-technical user can approve>"}]}
        {"done": true, "summary": "<one sentence describing what was actually accomplished>", "steps": []}

        Normally "steps" should have exactly one entry. You may include several \
        entries at once ONLY when they are clearly mechanical repeats of the same \
        kind of action on elements that are already visible right now and do NOT \
        depend on each other's outcome — for example, checking several checkboxes \
        in a row, clicking multiple "remove"/"delete" buttons already listed on \
        screen, or filling in a few form fields that are all on screen together. \
        Do NOT batch a step whose target only exists after an earlier step in the \
        same batch runs — e.g. never bundle "click search" together with "click \
        the first result", since the result list doesn't exist until the search \
        happens. If a later action depends on seeing the outcome of an earlier \
        one, propose only the steps that are safe to run blind right now and wait \
        to be asked again for the rest.

        Use the same per-step rules as before: "kind" is exactly one of \(allowedKinds); \
        "navigate" needs a full URL; "click"/"type" need a short visible-label hint, \
        never a guessed CSS selector; "type" needs the literal text in "value"; \
        "scroll" target is "up"/"down"; "wait" target is whole seconds; "extract" \
        means read-and-summarize. Never claim in any "description" that the action \
        already happened — describe intent, not outcome. If the last step failed or \
        the page doesn't show what was expected, do not just repeat the exact same \
        action — adapt: try a different element description, scroll to find it, or \
        explain in "summary" (with "done": true) what's blocking progress if you're \
        truly stuck.
        """
    }

    private static func nextStepUserPrompt(
        goal: String,
        completedSteps: [BrowserStep],
        context: BrowserPageContext?
    ) -> String {
        var lines: [String] = ["Original goal: \(goal)"]
        if completedSteps.isEmpty {
            lines.append("No steps have run yet.")
        } else {
            let history = completedSteps.enumerated().map { index, step -> String in
                let outcome: String
                switch step.status {
                case .done: outcome = "succeeded"
                case .failed: outcome = "FAILED"
                case .denied: outcome = "denied by the user"
                default: outcome = step.status.rawValue
                }
                let note = step.resultNote.map { " — \($0)" } ?? ""
                return "\(index + 1). [\(step.kind.rawValue)] \(step.description) -> \(outcome)\(note)"
            }.joined(separator: "\n")
            lines.append("Steps already executed:\n\(history)")
        }
        lines.append(contentsOf: pageContextLines(context))
        lines.append("Decide the next step now (or declare done).")
        return lines.joined(separator: "\n\n")
    }

    /// Re-analyze the live page after a step has run and decide what to do
    /// next — this is what lets the agent adapt in real time instead of
    /// trusting a plan that may already be stale.
    static func requestNextStep(
        goal: String,
        completedSteps: [BrowserStep],
        context: BrowserPageContext?,
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> NextStepDecision {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let messages = [
            ProviderChatMessage(role: .system, content: nextStepSystemPrompt()),
            ProviderChatMessage(
                role: .user,
                content: nextStepUserPrompt(goal: goal, completedSteps: completedSteps, context: context)
            ),
        ]
        let raw: String
        do {
            raw = try await provider.chat(model: model.modelID, apiKey: apiKey, messages: messages, effort: nil)
        } catch {
            throw PlanError(message: error.localizedDescription)
        }
        return try parseNextStepDecision(raw)
    }

    private static func chatSystemPrompt(hasWebResults: Bool) -> String {
        var prompt = """
        You are a helpful assistant embedded in a web browser. You can see the \
        current page's URL, title, and visible text, and you answer questions \
        about it conversationally.

        You must NEVER propose browser actions, steps, or plans. You have no \
        ability to click, type, navigate, or otherwise change the page — if the \
        user asks you to do something on the page, explain what you found and \
        suggest how they could do it themselves, but do not invent an action \
        plan. If the page doesn't contain what's needed to answer, say so \
        plainly and suggest what to check or search for. Answer in plain prose \
        only, no JSON.
        """
        if hasWebResults {
            prompt += "\n\nYou also have live web search results provided below. Use them to answer when the page content is thin, empty, or doesn't contain the answer the user is looking for. Cite sources inline with markdown links when you use a fact from the search results."
        }
        return prompt
    }

    private static func chatUserPrompt(prompt: String, context: BrowserPageContext?, webSearchBlock: String?) -> String {
        var lines: [String] = ["User: \(prompt)"]
        lines.append(contentsOf: pageContextLines(context))
        if let block = webSearchBlock, !block.isEmpty {
            lines.append(block)
        }
        lines.append("Answer the user's question about the current page in plain prose.")
        return lines.joined(separator: "\n\n")
    }

    /// Ask the model about the current page. Unlike `requestPlan` this never
    /// returns steps — the model is told it cannot act, so the page is never
    /// touched in Ask mode. When `webSearchBlock` is provided (because the
    /// page snapshot was thin), it gives the model live web results so it
    /// can still answer with curated content instead of falling back to
    /// stale training data. `history` carries prior Ask-mode turns so
    /// follow-up questions keep conversational context; only the latest turn
    /// gets a fresh page snapshot (captured at submit time).
    static func chatAboutPage(
        prompt: String,
        context: BrowserPageContext?,
        webSearchBlock: String? = nil,
        history: [ProviderChatMessage] = [],
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> String {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        var messages: [ProviderChatMessage] = [
            ProviderChatMessage(role: .system, content: chatSystemPrompt(hasWebResults: webSearchBlock != nil))
        ]
        messages.append(contentsOf: history)
        messages.append(
            ProviderChatMessage(role: .user, content: chatUserPrompt(prompt: prompt, context: context, webSearchBlock: webSearchBlock))
        )
        do {
            return try await provider.chat(model: model.modelID, apiKey: apiKey, messages: messages, effort: nil)
        } catch {
            throw PlanError(message: error.localizedDescription)
        }
    }

    static func parseNextStepDecision(_ raw: String) throws -> NextStepDecision {
        guard let jsonSubstring = extractJSONObject(from: raw),
              let data = jsonSubstring.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PlanError(message: "The model didn't return a next-step decision I could parse.")
        }
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let done = obj["done"] as? Bool ?? false
        if done {
            return NextStepDecision(done: true, summary: summary.isEmpty ? "Done." : summary, steps: [])
        }
        // Tolerant of either "steps": [...] (the documented contract) or a
        // single "step": {...} object, in case the model reverts to the
        // older singular shape despite instructions.
        let rawStepEntries: [[String: Any]]
        if let many = obj["steps"] as? [[String: Any]] {
            rawStepEntries = many
        } else if let single = obj["step"] as? [String: Any] {
            rawStepEntries = [single]
        } else {
            rawStepEntries = []
        }
        let steps: [BrowserStep] = rawStepEntries.compactMap { entry in
            guard let kindRaw = entry["kind"] as? String,
                  let kind = BrowserStep.Kind(rawValue: kindRaw)
            else { return nil }
            let description = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserStep(
                kind: kind,
                target: entry["target"] as? String,
                value: entry["value"] as? String,
                description: (description?.isEmpty == false ? description! : "\(kind.rawValue.capitalized) step")
            )
        }
        guard !steps.isEmpty else {
            throw PlanError(message: "The model's next step was missing or used an unsupported action.")
        }
        return NextStepDecision(done: false, summary: summary, steps: steps)
    }

    /// Tolerant JSON parsing: models sometimes wrap JSON in prose or code
    /// fences despite instructions, so we grab the first {...} block.
    static func parsePlan(_ raw: String, fallbackGoal: String) throws -> BrowserPlan {
        guard let jsonSubstring = extractJSONObject(from: raw),
              let data = jsonSubstring.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PlanError(message: "The model didn't return a plan I could parse. Try rephrasing your request.")
        }
        let goal = (obj["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSteps = obj["steps"] as? [[String: Any]] ?? []
        guard !rawSteps.isEmpty else {
            throw PlanError(message: "The model didn't propose any steps. Try rephrasing your request.")
        }
        let steps: [BrowserStep] = rawSteps.compactMap { entry in
            guard let kindRaw = entry["kind"] as? String,
                  let kind = BrowserStep.Kind(rawValue: kindRaw)
            else { return nil }
            let description = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserStep(
                kind: kind,
                target: entry["target"] as? String,
                value: entry["value"] as? String,
                description: (description?.isEmpty == false ? description! : "\(kind.rawValue.capitalized) step")
            )
        }
        guard !steps.isEmpty else {
            throw PlanError(message: "The model's plan used actions I don't support. Try rephrasing your request.")
        }
        return BrowserPlan(goal: (goal?.isEmpty == false ? goal! : fallbackGoal), steps: steps)
    }

    private static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = start
        while i < raw.endIndex {
            let c = raw[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = raw.index(after: i)
        }
        guard let end else { return nil }
        return String(raw[start...end])
    }
}
