package app.roamsocket.android.ui.browser

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/**
 * A single automated browser action proposed by the AI. Steps are always
 * shown to the user before they run — see [BrowserApprovalGranularity].
 *
 * Mirrors `ios/App/Sources/Features/Browser/BrowserModels.swift` so the
 * Android UI surface is structurally identical to iOS.
 */
@Serializable
data class BrowserStep(
    val id: String = UUID.randomUUID().toString(),
    val kind: Kind,
    /**
     * URL for [Kind.NAVIGATE]; a text/selector hint for [Kind.CLICK]/[Kind.TYPE];
     * a direction ("up"/"down") for [Kind.SCROLL]; seconds for [Kind.WAIT].
     */
    val target: String? = null,
    /** Text to type for [Kind.TYPE]. Unused otherwise. */
    val value: String? = null,
    /**
     * Human-readable explanation of *why* this step is being proposed,
     * shown verbatim in the approval card.
     */
    val description: String,
    val status: Status = Status.PENDING,
    /** Short result note filled in after the step runs (or fails). */
    val resultNote: String? = null,
) {
    @Serializable
    enum class Kind {
        @kotlinx.serialization.SerialName("navigate") NAVIGATE,
        @kotlinx.serialization.SerialName("click") CLICK,
        @kotlinx.serialization.SerialName("type") TYPE,
        @kotlinx.serialization.SerialName("scroll") SCROLL,
        @kotlinx.serialization.SerialName("back") BACK,
        @kotlinx.serialization.SerialName("forward") FORWARD,
        @kotlinx.serialization.SerialName("reload") RELOAD,
        @kotlinx.serialization.SerialName("wait") WAIT,
        @kotlinx.serialization.SerialName("extract") EXTRACT,
        /**
         * Tries to dismiss whatever cookie/consent banner is covering the page
         * before doing anything else. Privacy-first: Reject all → Reject →
         * Accept only-essential → Accept all. Falls back to clicking the
         * topmost visible fixed-position button if no labelled consent copy
         * is found.
         */
        @kotlinx.serialization.SerialName("dismiss_consent") DISMISS_CONSENT,
        ;

        /** SF Symbol equivalent for the kind. Maps to Material icon names. */
        val materialIcon: String
            get() = when (this) {
                NAVIGATE -> "arrow_forward"
                CLICK -> "touch_app"
                TYPE -> "keyboard"
                SCROLL -> "swap_vert"
                BACK -> "chevron_left"
                FORWARD -> "chevron_right"
                RELOAD -> "refresh"
                WAIT -> "schedule"
                EXTRACT -> "find_in_page"
                DISMISS_CONSENT -> "block"
            }

        /** Only "read" actions may ever run without a pause; every kind is
         * still gated by the plan/approve flow before the first execution. */
        val isReadOnly: Boolean get() = this == EXTRACT
    }

    @Serializable
    enum class Status {
        PENDING,
        APPROVED,
        DENIED,
        RUNNING,
        DONE,
        FAILED,
    }
}

/**
 * A plan proposed by the AI in response to one prompt: a restated goal plus
 * the ordered steps it wants permission to run. Nothing in [steps] executes
 * until the user approves — either the whole plan at once, or one step at a
 * time — which is why this always renders before any browser action happens.
 */
data class BrowserPlan(
    val id: String = UUID.randomUUID().toString(),
    val goal: String,
    val steps: List<BrowserStep>,
    val createdAt: Long = System.currentTimeMillis(),
)

/** What the AI prompt bar does with the user's text. */
enum class BrowserPromptMode {
    /** Ask questions about the current page — the model answers in prose
     * grounded in the live page and never proposes actions. */
    ASK,

    /** Turn the request into an action plan to review and approve. */
    ACT,
    ;

    val title: String
        get() = when (this) {
            ASK -> "Ask"
            ACT -> "Do"
        }
}

/** How much the user has to bless before the agent moves on to the next step. */
@Serializable
enum class BrowserApprovalGranularity {
    /** One tap approves every step in the plan; steps still run one at a
     * time and stop immediately if any of them fails. */
    BULK,

    /** Every step pauses for an individual Allow/Deny before it runs. */
    STEP_BY_STEP,
    ;

    val title: String
        get() = when (this) {
            BULK -> "Approve all at once"
            STEP_BY_STEP -> "Approve each step"
        }

    val subtitle: String
        get() = when (this) {
            BULK -> "Review the full plan, then run it in one go."
            STEP_BY_STEP -> "Confirm every action before it happens."
        }
}

/**
 * A snapshot of the current page handed to the model so it can plan against
 * real content instead of guessing blindly.
 */
data class BrowserPageContext(
    val url: String,
    val title: String,
    /** Trimmed visible text (first ~4000 chars) for grounding. */
    val textSnippet: String,
    /** `label -> href` pairs for the most prominent links/buttons on the page. */
    val links: List<BrowserPageLink>,
)

data class BrowserPageLink(
    val label: String,
    val href: String,
)

@Serializable
data class BrowserBookmark(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val url: String,
    val createdAt: Long = System.currentTimeMillis(),
)

@Serializable
data class BrowserHistoryEntry(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val url: String,
    val visitedAt: Long = System.currentTimeMillis(),
)

/** A single turn in the browser's Ask-mode conversation about the current page. */
data class BrowserChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: Role,
    /** Raw assistant text may include `<think>` tags; the UI peels them
     * before display and before feeding them back as history. */
    var content: String,
    /** True when this assistant reply was supplemented with live web search
     * that returned at least one hit. Renders as a quiet grey "Searched
     * the web for more context" pill under the assistant message. */
    val searchedWeb: Boolean = false,
    /** Set when the Ask-mode web-search fallback ran and returned zero hits. */
    val webSearchEmpty: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
) {
    enum class Role { USER, ASSISTANT }
}

/**
 * Lightweight container for an in-flight step execution. Holds the raw JS
 * arguments captured at the moment of approval so a re-paint of the plan
 * list (e.g. after a long re-analysis call) doesn't drift away from what
 * the user actually authorized.
 */
data class BrowserStepExecution(
    val step: BrowserStep,
    val value: String? = step.value,
    val target: String? = step.target,
)

/**
 * Normalizes whatever the user typed in the address/prompt bar into a URL:
 * bare domains get `https://` prefixed, anything else falls back to a search.
 */
object BrowserAddressResolver {
    /**
     * @return the URL the address bar should load, or `null` if the input
     * was blank.
     */
    fun resolve(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        // Already has a scheme → trust it.
        if (looksLikeUrl(trimmed)) return trimmed
        // Bare host (no scheme, no spaces, contains a dot) → https://
        if (looksLikeHost(trimmed)) return "https://$trimmed"
        // Anything else → Google search.
        val q = java.net.URLEncoder.encode(trimmed, "UTF-8")
        return "https://www.google.com/search?q=$q"
    }

    private fun looksLikeUrl(s: String): Boolean {
        // Has a scheme like http:// https:// ftp:// etc. Be lenient and
        // accept anything that starts with a letter+colon.
        if (s.length < 4) return false
        val colon = s.indexOf(':')
        if (colon <= 0) return false
        // Scheme must be only letters and start with a letter.
        for (i in 0 until colon) {
            val c = s[i]
            if (!((c in 'a'..'z') || (c in 'A'..'Z') || (i > 0 && (c in '0'..'9' || c == '+' || c == '-' || c == '.')))) {
                return false
            }
        }
        return s.substring(colon + 1).startsWith("//") || s.substring(colon + 1).isEmpty()
    }

    private fun looksLikeHost(s: String): Boolean {
        if (s.contains(' ')) return false
        if (!s.contains('.')) return false
        val disallowed = setOf('!', '?', ',', ';', ':', '\'', '"', '(', ')', '[', ']', '{', '}')
        return s.none { it in disallowed }
    }
}
