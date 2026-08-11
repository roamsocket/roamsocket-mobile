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
        - "wait" target is a whole number of seconds (used sparingly, e.g. after submitting a search).
        - "extract" means "read the resulting page and summarize for the user" — use it as the final step whenever you need to report back what happened.
        - Keep plans short: 1-6 steps. Never invent data you weren't given (login credentials, payment details, personal info) — if the task needs a secret you don't have, stop and add a single step explaining what's missing instead of guessing.
        - Never mark a task complete in "description" text; describe intent ("Search for X"), not outcome ("Searched for X").
        """
    }

    private static func userPrompt(goal: String, context: BrowserPageContext?) -> String {
        var lines: [String] = ["User request: \(goal)"]
        if let context {
            lines.append("Current page URL: \(context.url)")
            lines.append("Current page title: \(context.title)")
            if !context.textSnippet.isEmpty {
                lines.append("Visible page text (truncated): \(context.textSnippet.prefix(2000))")
            }
            if !context.links.isEmpty {
                let sample = context.links.prefix(30).map { "- \($0.label)" }.joined(separator: "\n")
                lines.append("Prominent clickable elements on the page:\n\(sample)")
            }
        } else {
            lines.append("No page is loaded yet. If the request needs a specific site, start with a \"navigate\" step.")
        }
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
