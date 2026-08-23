package app.roamsocket.core.chats

import kotlinx.serialization.Serializable

/**
 * How long an incognito chat keeps its transcript before it is forgotten.
 *
 * Mirrors the iOS `IncognitoLifetime` enum
 * (`ios/App/Sources/Features/Chats/ChatHistory.swift`). The Android
 * `IncognitoChatSheet` and the auto-prune in [ChatHistoryRepository]
 * consume the same five cases so the two apps forget chats on the
 * same schedule.
 *
 * Persisted as the lowercase raw value (e.g. `"one_hour"`) on
 * [ChatHistoryItem.incognitoLifetime]. Unknown values fail decoding
 * by design — new cases must be added here, not silently swallowed.
 */
@Serializable
public enum class IncognitoLifetime {
    /** Deleted the moment the user leaves the chat (or relaunches). */
    ON_EXIT,

    /** Forget 1 hour after the last message. */
    ONE_HOUR,

    /** Forget 6 hours after the last message. */
    SIX_HOURS,

    /** Forget 12 hours after the last message. */
    TWELVE_HOURS,

    /** Forget 24 hours after the last message. */
    TWENTY_FOUR_HOURS;

    /**
     * Countdown length in seconds, or `null` when the chat dies on
     * exit and never gets a timestamp. Callers should treat `null`
     * as "no timer; forget when the user navigates away".
     */
    public val timeIntervalSeconds: Long?
        get() = when (this) {
            ON_EXIT -> null
            ONE_HOUR -> 60L * 60L
            SIX_HOURS -> 6L * 60L * 60L
            TWELVE_HOURS -> 12L * 60L * 60L
            TWENTY_FOUR_HOURS -> 24L * 60L * 60L
        }

    /** Short title for the picker row. Matches the iOS copy. */
    public val pickerTitle: String
        get() = when (this) {
            ON_EXIT -> "When you exit the chat"
            ONE_HOUR -> "1 hour"
            SIX_HOURS -> "6 hours"
            TWELVE_HOURS -> "12 hours"
            TWENTY_FOUR_HOURS -> "24 hours"
        }

    /** Detail subline under the title. */
    public val pickerDetail: String
        get() = when (this) {
            ON_EXIT -> "Transcript dies the moment you leave."
            ONE_HOUR -> "Transcript deleted 1 hour after your last message."
            SIX_HOURS -> "Transcript deleted 6 hours after your last message."
            TWELVE_HOURS -> "Transcript deleted 12 hours after your last message."
            TWENTY_FOUR_HOURS -> "Transcript deleted 24 hours after your last message."
        }

    /** Wire format used when persisting [ChatHistoryItem.incognitoLifetime]. */
    public val rawValue: String
        get() = when (this) {
            ON_EXIT -> "on_exit"
            ONE_HOUR -> "one_hour"
            SIX_HOURS -> "six_hours"
            TWELVE_HOURS -> "twelve_hours"
            TWENTY_FOUR_HOURS -> "twenty_four_hours"
        }

    public companion object {
        /** Reverse lookup for the on-disk representation. */
        public fun fromRawValue(raw: String?): IncognitoLifetime? = when (raw) {
            null -> null
            "on_exit" -> ON_EXIT
            "one_hour" -> ONE_HOUR
            "six_hours" -> SIX_HOURS
            "twelve_hours" -> TWELVE_HOURS
            "twenty_four_hours" -> TWENTY_FOUR_HOURS
            else -> null
        }
    }
}
