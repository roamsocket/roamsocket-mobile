package app.roamsocket.android.ui.browser

import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelProvider
import app.roamsocket.core.providers.ProviderChatMessage
import app.roamsocket.core.providers.ProviderError
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Talks to the selected chat model to turn a user goal (plus the current
 * page context) into a [BrowserPlan].
 *
 * The model is instructed to always respond with a plan — it is never
 * allowed to claim an action happened without a corresponding step, which
 * is what lets the UI guarantee "plan, then approve" before anything
 * actually runs in the web view.
 *
 * Mirrors the iOS `BrowserAgent` enum (`ios/App/Sources/Features/Browser/`)
 * so the wire shape matches one-for-one.
 */
object BrowserAgent {

    private const val ALLOWED_KINDS = "navigate, click, type, scroll, back, forward, reload, wait, extract, dismiss_consent"

    /** Visible-text threshold below which we attach a page screenshot. */
    const val IMAGE_FALLBACK_TEXT_THRESHOLD: Int = 200

    /**
     * Errors surfaced by the agent. We wrap the raw `ProviderError` so the
     * UI can show the underlying reason without parsing the network body
     * itself.
     */
    sealed class PlanError(message: String) : RuntimeException(message) {
        class Decoding(detail: String) : PlanError("Failed to decode plan: $detail")
        class Provider(cause: Throwable) : PlanError(cause.message ?: "Provider error")
    }

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
    }

    // MARK: - Public API

    /**
     * Ask the model to turn [goal] (+ [context]) into a [BrowserPlan].
     * [attachedImageBytes] is the optional JPEG/PNG bytes the caller
     * captured from the page (see [BrowserTabActions.captureContext]
     * for the heuristic that decides when to attach an image).
     */
    suspend fun requestPlan(
        goal: String,
        context: BrowserPageContext,
        attachedImageBytes: ByteArray?,
        attachedImageMime: String,
        model: AIModel,
        apiKey: String,
        provider: ModelProvider,
    ): BrowserPlan {
        val messages = buildList {
            add(ProviderChatMessage(role = ProviderChatMessage.Role.SYSTEM, content = systemPrompt()))
            // Add the image hint as part of the user message so the model
            // knows the picture is attached (mirrors iOS: "page-image-attached").
            val contextText = buildString {
                append("Goal: ").append(goal).append('\n')
                if (attachedImageBytes != null) {
                    append("(page-image-attached: yes)\n")
                }
                append("Current page:\n")
                append("URL: ").append(context.url).append('\n')
                append("Title: ").append(context.title).append('\n')
                if (context.links.isNotEmpty()) {
                    append("Prominent clickable elements:\n")
                    for (link in context.links.take(40)) {
                        append("- ").append(link.label)
                        if (link.href.isNotEmpty()) append(" -> ").append(link.href)
                        append('\n')
                    }
                }
                if (context.textSnippet.isNotEmpty()) {
                    append("Visible text (truncated):\n").append(context.textSnippet.take(4000))
                }
            }
            add(
                ProviderChatMessage(
                    role = ProviderChatMessage.Role.USER,
                    content = contextText,
                    images = if (attachedImageBytes != null) {
                        listOf(
                            ProviderChatMessage.ImageAttachment(
                                mimeType = attachedImageMime,
                                base64Data = android.util.Base64.encodeToString(attachedImageBytes, android.util.Base64.NO_WRAP),
                            ),
                        )
                    } else emptyList(),
                ),
            )
        }
        val raw = callModel(messages, model, apiKey, provider)
        return parsePlan(raw)
    }

    /**
     * Ask the model a free-form question about [context] (Ask mode). The
     * model is told to never propose actions in this mode.
     */
    suspend fun askAboutPage(
        question: String,
        context: BrowserPageContext,
        history: List<BrowserChatMessage>,
        model: AIModel,
        apiKey: String,
        provider: ModelProvider,
    ): String {
        val messages = buildList {
            add(ProviderChatMessage(role = ProviderChatMessage.Role.SYSTEM, content = askSystemPrompt()))
            // Compact history → keep only the last 6 turns to bound token use.
            history.takeLast(6).forEach { msg ->
                val role = when (msg.role) {
                    BrowserChatMessage.Role.USER -> ProviderChatMessage.Role.USER
                    BrowserChatMessage.Role.ASSISTANT -> ProviderChatMessage.Role.ASSISTANT
                }
                add(ProviderChatMessage(role = role, content = msg.content))
            }
            val userText = buildString {
                append("Question: ").append(question).append('\n')
                append("Current page:\n")
                append("URL: ").append(context.url).append('\n')
                append("Title: ").append(context.title).append('\n')
                if (context.links.isNotEmpty()) {
                    append("Prominent clickable elements:\n")
                    for (link in context.links.take(20)) {
                        append("- ").append(link.label)
                        if (link.href.isNotEmpty()) append(" -> ").append(link.href)
                        append('\n')
                    }
                }
                if (context.textSnippet.isNotEmpty()) {
                    append("Visible text (truncated):\n").append(context.textSnippet.take(4000))
                }
            }
            add(ProviderChatMessage(role = ProviderChatMessage.Role.USER, content = userText))
        }
        return callModel(messages, model, apiKey, provider)
    }

    // MARK: - Provider dispatch

    private suspend fun callModel(
        messages: List<ProviderChatMessage>,
        model: AIModel,
        apiKey: String,
        provider: ModelProvider,
    ): String {
        return try {
            provider.chat(model = model.modelID, apiKey = apiKey, messages = messages, effort = null)
        } catch (e: ProviderError) {
            throw PlanError.Provider(e)
        } catch (e: Throwable) {
            throw PlanError.Provider(e)
        }
    }

    // MARK: - Plan parsing

    /**
     * Parse a model response into a [BrowserPlan]. Exposed at `internal`
     * visibility (rather than `private`) so unit tests in the same module
     * can exercise the JSON contract directly without going through a
     * network round-trip.
     */
    internal fun parsePlan(raw: String): BrowserPlan {
        // The model is told to return ONLY minified JSON, but real models
        // sometimes wrap it in ``` fences. Strip a generous fence envelope
        // before parsing.
        val cleaned = stripCodeFence(raw)
        val obj = try {
            json.parseToJsonElement(cleaned).jsonObject
        } catch (e: Throwable) {
            throw PlanError.Decoding("not JSON: ${e.message}")
        }
        val goal = (obj["goal"] as? JsonPrimitive)?.contentOrNull()?.trim().orEmpty()
        val stepsArray = obj["steps"] as? JsonArray
            ?: throw PlanError.Decoding("missing 'steps' array")
        val steps = stepsArray.mapNotNull { element ->
            val stepObj = element as? JsonObject ?: return@mapNotNull null
            parseStep(stepObj)
        }
        if (steps.isEmpty()) throw PlanError.Decoding("plan had no valid steps")
        return BrowserPlan(goal = goal.ifEmpty { "Browser plan" }, steps = steps)
    }

    private fun parseStep(obj: JsonObject): BrowserStep? {
        val kindStr = (obj["kind"] as? JsonPrimitive)?.contentOrNull()?.trim() ?: return null
        val kind = when (kindStr) {
            "navigate" -> BrowserStep.Kind.NAVIGATE
            "click" -> BrowserStep.Kind.CLICK
            "type" -> BrowserStep.Kind.TYPE
            "scroll" -> BrowserStep.Kind.SCROLL
            "back" -> BrowserStep.Kind.BACK
            "forward" -> BrowserStep.Kind.FORWARD
            "reload" -> BrowserStep.Kind.RELOAD
            "wait" -> BrowserStep.Kind.WAIT
            "extract" -> BrowserStep.Kind.EXTRACT
            "dismiss_consent" -> BrowserStep.Kind.DISMISS_CONSENT
            else -> return null
        }
        val target = (obj["target"] as? JsonPrimitive)?.contentOrNull()?.takeIf { it.isNotEmpty() }
        val value = (obj["value"] as? JsonPrimitive)?.contentOrNull()?.takeIf { it.isNotEmpty() }
        val description = (obj["description"] as? JsonPrimitive)?.contentOrNull()?.trim()
            ?: return null
        if (description.isEmpty()) return null
        return BrowserStep(kind = kind, target = target, value = value, description = description)
    }

    private fun stripCodeFence(raw: String): String {
        val trimmed = raw.trim()
        // ```json ... ``` or ``` ... ```
        if (trimmed.startsWith("```")) {
            val firstNewline = trimmed.indexOf('\n')
            val lastFence = trimmed.lastIndexOf("```")
            if (firstNewline in 1 until lastFence) {
                return trimmed.substring(firstNewline + 1, lastFence).trim()
            }
        }
        return trimmed
    }

    private fun JsonPrimitive.contentOrNull(): String? = if (isString) content else content

    // MARK: - Prompts

    private fun systemPrompt(): String = """
        You are a careful browsing assistant embedded in a web browser. You can propose actions but you can NEVER execute anything yourself — the app only runs a step after the human taps Approve. Because of that, you must always respond with a short plan broken into discrete steps, even for a single action, and you must never claim a page was visited, a button was clicked, or a form was submitted unless that exact action is one of the steps you are proposing.

        Respond with ONLY minified JSON, no prose, no markdown fences, matching:
        {"goal":"<one sentence restating what you'll accomplish>",
         "steps":[{"kind":"<${ALLOWED_KINDS}>","target":"<url, element hint, or direction/seconds>","value":"<text to type, or null>","description":"<one plain-language sentence a non-technical user can approve>"}]}

        Rules:
        - "kind" must be exactly one of: ${ALLOWED_KINDS}.
        - "navigate" needs a full URL in "target".
        - "click" needs a short hint in "target" describing the visible label/text of the element (e.g. "Sign in button"), not a CSS selector unless you are certain of it.
        - "type" needs a hint in "target" (e.g. "search box", "email field") and the literal text to enter in "value"; add a trailing step describing submission if a form should be submitted (use another "type" or a "click" step for the submit button).
        - "scroll" target is "up" or "down".
        - "wait" target is a whole number of seconds (used sparingly, e.g. after submitting a search).
        - "extract" means "read the resulting page and summarize for the user" — use it as the final step whenever you need to report back what happened.
        - "dismiss_consent" gets the cookie/privacy banner out of the way. Use it as the FIRST step whenever the page text is dominated by consent language.
        - Keep plans short: 1-6 steps. Never invent data you weren't given.
        - Never mark a task complete in "description" text; describe intent ("Search for X"), not outcome.

        Anti-loop rules:
        - Before adding a "scroll" step, scan the "Prominent clickable elements" list for the target you need. If it's there, click/type it directly — do not scroll "just in case".
        - Do not include more than one "scroll" step in a row.
    """.trimIndent()

    private fun askSystemPrompt(): String = """
        You are a helpful assistant answering questions about a web page the user is currently looking at. Be concise and grounded in the page content provided. If the page text is not enough, say so honestly. Do not propose any browser actions — just answer in prose.
    """.trimIndent()

    // MARK: - Heuristics

    /**
     * True when the page text looks like it's mostly cookie/consent
     * *dialog* copy rather than real content.
     */
    fun looksLikeConsentPage(text: String): Boolean {
        if (text.isEmpty()) return false
        val lower = text.lowercase()
        val markers = listOf(
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
        )
        var hits = 0
        for (m in markers) if (lower.contains(m)) hits++
        return hits >= 2
    }
}
