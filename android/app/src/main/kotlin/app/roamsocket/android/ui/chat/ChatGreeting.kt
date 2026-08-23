package app.roamsocket.android.ui.chat

import java.util.Calendar

/**
 * Time-of-day empty-state greetings for the chat tab. Phrases rotate by
 * hour (and day) so the home screen doesn't always say the same thing.
 *
 * Pure port of `ios/.../ChatView.swift → ChatGreeting`. The phrases match
 * the iOS copy verbatim so the two apps feel like the same product on
 * first launch.
 */
object ChatGreeting {

    private enum class Period {
        LateNight,    // 0–4
        EarlyMorning, // 5–8
        Morning,      // 9–11
        Afternoon,    // 12–16
        Evening,      // 17–20
        Night,        // 21–23
    }

    private fun periodOf(calendar: Calendar): Period {
        return when (calendar.get(Calendar.HOUR_OF_DAY)) {
            in 0..4 -> Period.LateNight
            in 5..8 -> Period.EarlyMorning
            in 9..11 -> Period.Morning
            in 12..16 -> Period.Afternoon
            in 17..20 -> Period.Evening
            else -> Period.Night
        }
    }

    private val Period.phrases: List<String>
        get() = when (this) {
            Period.LateNight -> listOf(
                "Still up? The bugs never sleep either.",
                "Midnight oil: officially lit.",
                "Quiet hours. Loud ideas.",
                "3 a.m. is a perfectly normal time to ship.",
                "The CI ghosts are friendlier at this hour.",
                "Coffee optional. Courage required.",
                "Night shift for code that dreams in stack traces.",
                "Only the terminal and the moon are online.",
            )
            Period.EarlyMorning -> listOf(
                "Good morning. Let's invent something small.",
                "Fresh day, clean branch, questionable coffee.",
                "Boot sequence complete. What's first?",
                "Sunrise commits hit different.",
                "The early bird gets the green build.",
                "Stretch, hydrate, then refactor.",
                "Morning brain: surprisingly good at naming things.",
                "Warming up the compilers… and the optimism.",
            )
            Period.Morning -> listOf(
                "Ready when you are.",
                "Inbox zero can wait. Ideas can't.",
                "What are we building today?",
                "Mid-morning is prime time for clever hacks.",
                "Plotting greatness between meetings.",
                "Let's turn that half-baked thought into a PR.",
                "Your cursor is blinking. So is destiny.",
                "Ship small, ship often, ship with flair.",
            )
            Period.Afternoon -> listOf(
                "Afternoon check-in. How's the stack feeling?",
                "Post-lunch productivity? We can make it happen.",
                "The day is half over. The fun is not.",
                "Time for a spicy little feature.",
                "If it compiles, we celebrate. If not, we learn.",
                "Standing by for your next brilliant digression.",
                "Let's make the afternoon count for something mergeable.",
                "Snack break over. Idea break starts now.",
            )
            Period.Evening -> listOf(
                "Clocking in for the evening shift.",
                "Golden hour for golden code.",
                "Evening mode: fewer meetings, more commits.",
                "The day wind-down… or the real work begins.",
                "Twilight and type errors—classic combo.",
                "Let's close a loop before dinner.",
                "Side project energy detected.",
                "Soft light. Sharp diffs.",
            )
            Period.Night -> listOf(
                "Night mode engaged. What shall we cook up?",
                "Stars out. Bugs in. Your move.",
                "The perfect hour for a reckless rewrite.",
                "Quiet keyboard. Loud ambition.",
                "One more feature before the night ends.",
                "Let's leave tomorrow's self a nicer codebase.",
                "Dark theme. Bright ideas.",
                "Last call for elegant solutions.",
            )
        }

    /**
     * Stable-but-rotating pick: changes each hour, and shifts day-to-day.
     *
     * Mirrors the iOS `ChatGreeting.phrase(at:)` seeding but uses
     * `dayOfYear * 7` instead of `dayOfYear * 24` so the same hour
     * actually rotates to a different line on consecutive days. The
     * original iOS multiplier happens to be a multiple of every pool
     * size (8), which would lock the index to the same line every
     * day. 7 is co-prime with 8 and keeps the rotation evenly
     * distributed across the 8 phrases.
     */
    fun phrase(now: Long = System.currentTimeMillis()): String {
        val calendar = Calendar.getInstance().apply { timeInMillis = now }
        val period = periodOf(calendar)
        val phrases = period.phrases
        if (phrases.isEmpty()) return "Ready when you are."

        val hour = calendar.get(Calendar.HOUR_OF_DAY)
        val dayOfYear = calendar.get(Calendar.DAY_OF_YEAR)
        val year = calendar.get(Calendar.YEAR)
        val seed = year * 1000 + dayOfYear * 7 + hour
        val index = Math.floorMod(seed, phrases.size)
        return phrases[index]
    }
}
