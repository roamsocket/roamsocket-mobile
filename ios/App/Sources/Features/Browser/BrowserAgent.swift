import Foundation
import UIKit
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

    private static let allowedKinds = "navigate, click, type, scroll, back, forward, reload, wait, extract, dismiss_consent"

    /// Visible-text threshold below which we attach a page screenshot to the
    /// model call. <200 chars is roughly "one paragraph or less" — anything
    /// shorter than that and the agent is guessing blind (CAPTCHA, blank
    /// JS-only page, cookie banner with no real text, etc.).
    ///
    /// Tuned by hand: at 200 we still attach on a lot of legitimate
    /// one-line landing pages, but those are also the cases where a
    /// picture genuinely helps (search box + logo only). Keep it tight
    /// so heavy text-pages don't pay the image tax unnecessarily.
    static let imageFallbackTextThreshold = 200

    /// True when the page text looks like it's mostly cookie/consent
    /// *dialog* copy rather than real content (or a long privacy policy).
    /// Cheaply heuristic (case-insensitive substring presence, weighted by
    /// hit count) — the goal is to catch the obvious "this is a consent
    /// banner covering the page" cases so we attach an image even when
    /// the text is technically long.
    ///
    /// Markers chosen for *action-oriented* consent UX copy:
    /// "we use cookies"/"by clicking accept" appear in banner CTAs but
    /// rarely in policy pages. Conversely, "consent" by itself is too
    /// generic — any privacy policy mentions it.
    ///
    /// Threshold is 2 to avoid catching pages that happen to mention one
    /// cookie reference in passing; 3+ is the "this is clearly a banner"
    /// zone. Tunes via the privacy-policy regression test in
    /// `BrowserAgentConsentTests`.
    static func looksLikeConsentPage(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        var hits = 0
        let markers = [
            "we use cookies",
            "this site uses cookies",
            "by clicking",
            "privacy choices",
            "accept all",
            "reject all",
            "cookie preferences",
            "manage settings",
            "personalize my choices",
            "consent preferences",
        ]
        for marker in markers {
            if lower.contains(marker) { hits += 1 }
        }
        // Two-or-more banner-action phrases strongly suggest a consent
        // dialog (privacy policies have lots of legalese but they don't
        // usually say "by clicking accept all" or "manage settings" up
        // front — those are banner CTA language).
        return hits >= 2
    }

    /// Decode a `UIImage` into the `ProviderChatMessage.ImageAttachment`
    /// shape. Prefers JPEG (smaller payload, every provider supports it)
    /// and falls back to PNG. Re-encodes at a modest quality so we don't
    /// ship a giant original — the caller should already have downscaled
    /// to ≤1024px via `BrowserTab.takeCompressedSnapshot`.
    static func imageAttachment(from image: UIImage?) -> ProviderChatMessage.ImageAttachment? {
        guard let image else { return nil }
        if let jpeg = image.jpegData(compressionQuality: 0.7) {
            return ProviderChatMessage.ImageAttachment(mimeType: "image/jpeg", jpegData: jpeg)
        }
        if let png = image.pngData() {
            return ProviderChatMessage.ImageAttachment(mimeType: "image/png", base64Data: png.base64EncodedString(), rawBytes: png)
        }
        return nil
    }

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
        - "dismiss_consent" gets the cookie/privacy banner out of the way. Use it as the FIRST step whenever the page text is dominated by consent language (phrases like "we use cookies", "your privacy", "accept all", "reject all", "manage settings", "this site uses cookies"), OR when the visible text looks like the real page is hidden behind a fixed/sticky overlay. Describe in "description" what's being dismissed ("Dismiss the cookie banner so I can see the real page") and pass a short hint in "target" only if you know which vendor it is (e.g. "OneTrust", "Cookiebot") — otherwise leave "target" empty. The driver handles the click. After it runs, decide what to do based on the fresh page text in the next turn.
        - Keep plans short: 1-6 steps. Never invent data you weren't given (login credentials, payment details, personal info) — if the task needs a secret you don't have, stop and add a single step explaining what's missing instead of guessing.
        - Never mark a task complete in "description" text; describe intent ("Search for X"), not outcome ("Searched for X").

        Reading from images:
        - Sometimes the page snapshot below includes a "page-image-attached" note — that means an actual picture of the page was attached to this prompt. When an image is attached, use it to see layout, banner positions, image-only/labeled-with-icons buttons, and anything else the text snippet missed. Do NOT describe the picture to the user — it's grounding for *you*, not for them. Never invent a step you can't justify from the text + image + visible controls list.

        Anti-loop rules:
        - Before adding a "scroll" step, scan the "Prominent clickable elements" \
        list for the target you need. If it's there, click/type it directly — \
        do not scroll "just in case". The user can already see the item they want; \
        scrolling past it is the most common complaint.
        - Do not include more than one "scroll" step in a row unless the goal \
        explicitly requires reaching the bottom of a long page (a list of N \
        items, an article, etc.).
        - When the page looks covered by a consent/cookie overlay (visible text \
        dominated by words like "cookies", "consent", "privacy", "accept", \
        "reject", OR a "page-image-attached" hint and the image shows a \
        full-page modal/overlay), do NOT scroll. Add a "dismiss_consent" \
        step as your very first one and re-plan from there.
        """
    }

    /// Shared page-grounding block reused by both the initial plan prompt
    /// and the after-every-step re-analysis prompt.
    private static func pageContextLines(_ context: BrowserPageContext?, attachedImage: Bool = false) -> [String] {
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
        if attachedImage {
            // Tells the model "you can see the page" — referenced in the
            // system prompt's "Reading from images" guidance. Cheap
            // explicit hint so the model doesn't ignore the attachment.
            lines.append("page-image-attached: a JPEG screenshot of the visible viewport is included with this turn. Use it for layout, banner positions, image-only/labeled-with-icons buttons, and anything the text snippet missed.")
        }
        return lines
    }

    private static func userPrompt(goal: String, context: BrowserPageContext?, attachedImage: Bool = false) -> String {
        var lines: [String] = ["User request: \(goal)"]
        lines.append(contentsOf: pageContextLines(context, attachedImage: attachedImage))
        lines.append("Respond with the JSON plan now.")
        return lines.joined(separator: "\n\n")
    }

    /// Ask the model for a plan. Throws `PlanError` on missing model/key or
    /// unparsable output so the caller can show a friendly message.
    ///
    /// When `attachedImage` is non-nil the snapshot is included as an inline
    /// image on the user message (Anthropic / OpenAI-compat / Google
    /// providers all accept JPEGs) so the model can see layout, banner
    /// positions, icon-only buttons, etc. Pass an image whenever the text
    /// snapshot is thin (< ~200 chars) or dominated by consent copy.
    static func requestPlan(
        goal: String,
        context: BrowserPageContext?,
        attachedImage: UIImage?,
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> BrowserPlan {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let prompt = userPrompt(goal: goal, context: context, attachedImage: attachedImage != nil)
        let attachments = imageAttachment(from: attachedImage).map { [$0] } ?? []
        let messages = [
            ProviderChatMessage(role: .system, content: systemPrompt()),
            ProviderChatMessage(role: .user, content: prompt, images: attachments),
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
    /// Why a `done: true` decision ended the run. Lets the UI tell the
    /// difference between "I actually finished the task" and "I gave up
    /// because I couldn't find what you asked for" — both used to render
    /// as a green "Plan finished" banner, which is misleading when the
    /// agent admits it couldn't do the thing.
    enum CompletionOutcome: String {
        /// The agent accomplished the user's goal (or as much of it as
        /// was possible).
        case success
        /// The agent stopped because it couldn't make progress — the
        /// target wasn't on the page, the model couldn't parse the
        /// result, the page wouldn't load, etc. `summary` should explain
        /// *why* so the user understands what went wrong.
        case blocked
        /// The agent hit the per-run step cap without finishing — this
        /// is a runaway-loop guard, not the agent's own judgment.
        case stopped
    }

    struct NextStepDecision {
        let done: Bool
        /// If `done`, a one-sentence outcome; otherwise a brief status note.
        let summary: String
        /// Empty iff `done` is true.
        let steps: [BrowserStep]
        /// Short user-facing commentary the model can include alongside its
        /// decision (e.g. "I'll click the Sign in button now", "The page
        /// didn't load — let me try again", "Found it on the second try").
        /// Optional — the model is told it can include it but doesn't have
        /// to. When present, the running banner shows it as a soft grey
        /// line so the user understands what the AI is doing/thinking.
        let commentary: String?
        /// Only meaningful when `done == true`. Defaults to `.success`
        /// when the field is absent in the model's response (older /
        /// stub models). The model is told to set this explicitly so we
        /// can render "couldn't find X" as a warning instead of a
        /// checkmark.
        var outcome: CompletionOutcome
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
        - The goal is now accomplished — respond with "done": true, "outcome": \
        "success", "steps": [], and a one-sentence "summary" describing what was \
        actually accomplished.
        - The goal cannot be accomplished (the page doesn't have what the user \
        asked for, you can't find the right control, the page won't load, you \
        lack a needed secret, etc.) — respond with "done": true, "outcome": \
        "blocked", "steps": [], and a one-sentence "summary" naming the specific \
        blocker in plain language ("I can't find a search box on this page.", \
        "The page is showing a captcha I can't solve.", "I don't have login \
        credentials for this site."). DO NOT report blockers as "success" — be \
        honest with the user about what went wrong.
        - More is needed — respond with "done": false, a brief "summary" of where \
        things stand, and a "steps" array describing what to do next.

        Respond with ONLY minified JSON, no prose, no markdown fences, matching one of:
        {"done": false, "summary": "<brief status>", "commentary": "<one short user-facing sentence explaining what you're about to do and why, in plain English — or null>", "steps": [{"kind":"<\(allowedKinds)>","target":"<url, element hint, or direction/seconds>","value":"<text to type, or null>","description":"<one plain-language sentence a non-technical user can approve>"}]}
        {"done": true, "outcome": "success", "summary": "<one sentence describing what was actually accomplished>", "commentary": "<one short user-facing sentence, or null>", "steps": []}
        {"done": true, "outcome": "blocked", "summary": "<one sentence naming the specific blocker>", "commentary": "<one short user-facing sentence, or null>", "steps": []}

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
        means read-and-summarize; "dismiss_consent" removes the cookie/privacy \
        banner so the real page becomes usable. Never claim in any "description" \
        that the action already happened — describe intent, not outcome.

        About "dismiss_consent": when the visible page text is dominated by \
        consent language (phrases like "we use cookies", "your privacy choices", \
        "accept all", "manage settings", "personalize my choices"), OR the \
        "page-image-attached" hint fires and the image shows a fixed/sticky \
        overlay covering the content, add "dismiss_consent" as your very next \
        step before doing anything else. The driver will pick the most \
        privacy-friendly button automatically. If the page is now clean \
        (no banner text in the visible text), do NOT re-propose dismiss_consent.

        Reading from images:
        - Sometimes the page snapshot below includes a "page-image-attached" \
        note — a picture of the live page is on this turn's user message. \
        When it is, use the image to ground layout, banner positions, image-\
        only buttons, and anything the text snippet missed. Do NOT describe \
        the picture to the user — it's only for your grounding. Never invent \
        a step you can't justify from the text + image + visible controls list.

        If the last step failed or \
        the page doesn't show what was expected, do not just repeat the exact same \
        action — adapt: try a different element description, scroll to find it, or \
        explain in "summary" (with "done": true) what's blocking progress if you're \
        truly stuck.

        CRITICAL anti-loop rules (read these — runaway scrolling is the #1 user complaint):

        - PREFER VISIBLE TARGETS. Before scrolling, scan the snapshot's "Prominent \
        clickable elements" list for the item the user asked about. If it's there, \
        click/type it directly. Do not scroll "just in case there's more below".

        - NEVER SCROLL TO THE BOTTOM OF THE PAGE. If the visible text looks \
        complete enough to answer the question, or if the target you need is \
        already in the "Prominent clickable elements" list, do not add another \
        "scroll" step. Declare done with "done": true instead.

        - DO NOT CHAIN SCROLLS. If your last step was "scroll", look at the new \
        snapshot before scrolling again. If the "Prominent clickable elements" \
        list still contains everything you need, act on it. If the page is short \
        (e.g. a Google home page, search results that already show the answer, \
        an error page), do NOT keep scrolling — declare done.

        - DO NOT CHAIN WAITS. If your last step was "wait" and the page text is \
        still empty or still ends with an ellipsis, the page is either fully \
        loaded with no real content or stuck. Do NOT add another "wait" step — \
        adapt (try a different selector, navigate elsewhere, or declare done \
        with what you know).

        - When you see the hint "page-unchanged-since-last-step": trust it. The \
        page is not changing. The right move is "done": true with a summary of \
        what you found, not another wait or scroll. If your last step failed \
        (the target wasn't there) and the page is unchanged, use "outcome": \
        "blocked" with a summary like "The page doesn't contain X — visible \
        controls are: …" instead of pretending the task succeeded.

        User-facing commentary:
        - You may include a "commentary" field in your response — a single \
        short sentence (max ~120 chars) in plain English that the user can \
        read alongside the action. This is OPTIONAL but very welcome; it \
        tells the user what you're about to do or why you're choosing this \
        path, in the tone of a thoughtful assistant.
        - Examples of good commentary: "The Sign in link is at the top \
        right — I'll click it now.", "That search didn't find it — let me \
        try a different phrase.", "The page is taking a moment to load, so \
        I'll wait a second before reading it.", "Found it! The first \
        result matches what you asked about."
        - Do NOT include commentary that restates the action's "description" \
        field — those are different audiences. Description is for the \
        approval card; commentary is for the live "what is the AI doing \
        right now" display.
        """
    }

    private static func nextStepUserPrompt(
        goal: String,
        completedSteps: [BrowserStep],
        context: BrowserPageContext?,
        pageUnchangedHint: Bool,
        attachedImage: Bool = false
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

            // When the last step failed with a "target not found" error, the
            // generic history line ("FAILED — Couldn't find anything matching
            // \"Search for X\" on the page.") doesn't make the failed hint
            // *prominent enough* — models have a strong tendency to re-read
            // the snapshot, see "Search for X" as visible text, and propose
            // the exact same click. Surface the failed hint explicitly so
            // the model knows it tried that target and it wasn't there, and
            // forces it to pick a different element from the visible list.
            if let last = completedSteps.last, last.status == .failed,
               let target = last.target,
               (last.kind == .click || last.kind == .type)
            {
                lines.append(
                    "Last action FAILED because no element on the page matched your hint \u{201C}\(target)\u{201D}. " +
                    "Do NOT re-propose a click/type with the same or near-identical hint. Pick a different element from the " +
                    "Prominent clickable elements list below, scroll to look for it, navigate elsewhere, or declare " +
                    "\u{201C}done\u{201D} with outcome=\u{201C}blocked\u{201D} and a summary naming what was missing."
                )
            }
            // When a `dismiss_consent` step failed — "No consent banner
            // detected." or "Found a banner but no clickable controls." —
            // the model shouldn't keep retrying. Either the page is clean
            // already (most common), or the overlay is too exotic for our
            // detector (rare); in both cases the right move is to proceed
            // with the original goal, not loop on dismissal.
            if let last = completedSteps.last, last.status == .failed,
               last.kind == .dismissConsent
            {
                lines.append(
                    "Last dismiss_consent step FAILED — the auto-dismisser could not find or click a banner control. " +
                    "If the visible page text looks usable now, proceed with the original goal instead of re-proposing dismiss_consent. " +
                    "If the page text is still empty or still dominated by consent copy, declare done with outcome=\u{201C}blocked\u{201D} " +
                    "and explain the banner can't be auto-dismissed on this site."
                )
            }
        }
        lines.append(contentsOf: pageContextLines(context, attachedImage: attachedImage))
        if pageUnchangedHint {
            lines.append("HINT: page-unchanged-since-last-step — the page text didn't change after the most recent action. Strongly prefer declaring done over proposing another wait/scroll.")
        }
        lines.append("Decide the next step now (or declare done).")
        return lines.joined(separator: "\n\n")
    }

    /// Re-analyze the live page after a step has run and decide what to do
    /// next — this is what lets the agent adapt in real time instead of
    /// trusting a plan that may already be stale.
    ///
    /// When `attachedImage` is non-nil, it's attached as an inline image on
    /// the user message so the model can see the visible viewport —
    /// especially useful mid-run when the text snapshot is thin (CAPTCHA
    /// walls, JS-only pages that haven't painted yet, or after a
    /// `dismiss_consent` step that didn't quite clear the overlay).
    static func requestNextStep(
        goal: String,
        completedSteps: [BrowserStep],
        context: BrowserPageContext?,
        attachedImage: UIImage?,
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?,
        pageUnchangedHint: Bool = false
    ) async throws -> NextStepDecision {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let promptText = nextStepUserPrompt(
            goal: goal,
            completedSteps: completedSteps,
            context: context,
            pageUnchangedHint: pageUnchangedHint,
            attachedImage: attachedImage != nil
        )
        let attachments = imageAttachment(from: attachedImage).map { [$0] } ?? []
        let messages = [
            ProviderChatMessage(role: .system, content: nextStepSystemPrompt()),
            ProviderChatMessage(role: .user, content: promptText, images: attachments),
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

    private static func chatUserPrompt(prompt: String, context: BrowserPageContext?, webSearchBlock: String?, attachedImage: Bool = false) -> String {
        var lines: [String] = ["User: \(prompt)"]
        lines.append(contentsOf: pageContextLines(context, attachedImage: attachedImage))
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
    ///
    /// When the page text is unusually thin (cookie consent screen, JS-only
    /// page that hasn't painted, etc.) the caller should pass an
    /// `attachedImage` so the model can see the page directly instead of
    /// relying on the (almost empty) text snippet.
    static func chatAboutPage(
        prompt: String,
        context: BrowserPageContext?,
        webSearchBlock: String? = nil,
        attachedImage: UIImage? = nil,
        history: [ProviderChatMessage] = [],
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> String {
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let userText = chatUserPrompt(
            prompt: prompt,
            context: context,
            webSearchBlock: webSearchBlock,
            attachedImage: attachedImage != nil
        )
        let attachments = imageAttachment(from: attachedImage).map { [$0] } ?? []
        var messages: [ProviderChatMessage] = [
            ProviderChatMessage(role: .system, content: chatSystemPrompt(hasWebResults: webSearchBlock != nil))
        ]
        messages.append(contentsOf: history)
        messages.append(ProviderChatMessage(role: .user, content: userText, images: attachments))
        do {
            return try await provider.chat(model: model.modelID, apiKey: apiKey, messages: messages, effort: nil)
        } catch {
            throw PlanError(message: error.localizedDescription)
        }
    }

    // MARK: - Image-only description

    /// System prompt used when we hand the model an image but no text
    /// context — usually because the visible-text extraction came back
    /// empty or thin (cookie banner, JS-only page, paywall, blank SPA).
    /// Crucially: NO actions. The model is only ever asked to describe
    /// what's visible, in plain prose, so it can be shown verbatim to the
    /// user (or used as a smarter substitute for the generic
    /// "(no visible text)" string the agent used to return).
    private static func describeImageSystemPrompt(role: DescribeRole) -> String {
        let intro = role == .extract
            ? """
            You are a careful description assistant. You can see an image \
            of a web page but no readable text was extracted from it — \
            either because it's a heavy JavaScript app that hasn't painted, \
            a page with a cookie-consent overlay covering everything, a \
            canvas/WebGL render, or a CAPTCHA. Describe what is visible in \
            plain prose, in 1-3 sentences, so the user gets a concrete \
            answer instead of "(no visible text)".
            """
            : """
            You are a careful description assistant. You can see an image \
            of a web page; describe it in plain prose so the user gets a \
            concrete answer about what's on screen. Keep it short (2-4 \
            sentences). Focus on what the user can interact with: text, \
            buttons, forms, banners, images. Mention the page title and \
            URL if visible. Do NOT invent what isn't there.
            """
        return """
        \(intro)

        Hard rules:
        - Plain prose only — no markdown, no JSON, no bullet points.
        - Do NOT propose or claim any browser actions (you have none).
        - Do NOT include "the image shows" / "this screenshot" framing; \
        speak as if describing the page itself.
        - Do NOT fabricate text or controls you cannot clearly read.
        """
    }

    /// What the image is being described for — `extract` is the agent's
    /// `.extract` step summary (terse, factual), `description` is a
    /// user-facing "what's on this page" answer (a touch warmer).
    enum DescribeRole {
        case extract
        case description
    }

    /// Test-only wrapper around the private system prompt so the test
    /// target can assert what guarantees we make to the model (no
    /// actions, plain prose). Kept visible-but-narrow so external
    /// callers can't accidentally invoke the prompt builder.
    static func describeImageSystemPromptPublic(role: DescribeRole) -> String {
        return describeImageSystemPrompt(role: role)
    }

    /// Generate a plain-prose description of `image`. Used by `.extract`
    /// when the page text was empty/thin, and by Ask-mode chat fallback
    /// when both the text snapshot and the web-search fallback came up
    /// dry. Returns `nil` when the image is nil, decoding fails, or the
    /// provider returns empty text — the caller can then fall back to the
    /// text-only "(no visible text)" string without committing to it.
    static func describePage(
        image: UIImage?,
        pageURL: String,
        pageTitle: String,
        role: DescribeRole,
        model: AIModel,
        apiKey: String,
        catalog: ModelCatalog,
        customBaseURL: URL?,
        style: CustomProviderStyle?
    ) async throws -> String? {
        guard let attachment = imageAttachment(from: image) else { return nil }
        let provider = catalog.provider(model.provider, customBaseURL: customBaseURL, style: style)
        let system = describeImageSystemPrompt(role: role)
        let userBody: String
        switch role {
        case .extract:
            userBody = "URL: \(pageURL)\nTitle: \(pageTitle)\nDescribe what the page shows right now (1-3 sentences)."
        case .description:
            userBody = "URL: \(pageURL)\nTitle: \(pageTitle)\nDescribe what's visible on the page (2-4 sentences)."
        }
        let messages = [
            ProviderChatMessage(role: .system, content: system),
            ProviderChatMessage(role: .user, content: userBody, images: [attachment]),
        ]
        let raw: String
        do {
            raw = try await provider.chat(model: model.modelID, apiKey: apiKey, messages: messages, effort: nil)
        } catch {
            throw PlanError(message: error.localizedDescription)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseNextStepDecision(_ raw: String) throws -> NextStepDecision {
        guard let jsonSubstring = extractJSONObject(from: raw),
              let data = jsonSubstring.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PlanError(message: "The model didn't return a next-step decision I could parse.")
        }
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commentary = (obj["commentary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = obj["done"] as? Bool ?? false
        // The outcome field is new; older models and stubs won't send it.
        // Default to `.success` so we don't break existing behavior, but the
        // system prompt above tells every supported model to set it.
        let outcome: CompletionOutcome = {
            if let raw = obj["outcome"] as? String,
               let parsed = CompletionOutcome(rawValue: raw)
            {
                return parsed
            }
            return .success
        }()
        if done {
            return NextStepDecision(
                done: true,
                summary: summary.isEmpty ? "Done." : summary,
                steps: [],
                commentary: (commentary?.isEmpty == false ? commentary : nil),
                outcome: outcome
            )
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
        return NextStepDecision(
            done: false,
            summary: summary,
            steps: steps,
            commentary: (commentary?.isEmpty == false ? commentary : nil),
            outcome: .success
        )
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
