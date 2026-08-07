/**
 * Time-of-day empty-state greetings (ported from iOS ChatGreeting).
 */
export type GreetingPeriod =
  | "lateNight"
  | "earlyMorning"
  | "morning"
  | "afternoon"
  | "evening"
  | "night";

const PHRASES: Record<GreetingPeriod, string[]> = {
  lateNight: [
    "Still up? The bugs never sleep either.",
    "Midnight oil: officially lit.",
    "Quiet hours. Loud ideas.",
    "3 a.m. is a perfectly normal time to ship.",
    "The CI ghosts are friendlier at this hour.",
    "Coffee optional. Courage required.",
    "Night shift for code that dreams in stack traces.",
    "Only the terminal and the moon are online.",
  ],
  earlyMorning: [
    "Good morning. Let’s invent something small.",
    "Fresh day, clean branch, questionable coffee.",
    "Boot sequence complete. What’s first?",
    "Sunrise commits hit different.",
    "The early bird gets the green build.",
    "Stretch, hydrate, then refactor.",
    "Morning brain: surprisingly good at naming things.",
    "Warming up the compilers… and the optimism.",
  ],
  morning: [
    "Ready when you are.",
    "Inbox zero can wait. Ideas can’t.",
    "What are we building today?",
    "Mid-morning is prime time for clever hacks.",
    "Plotting greatness between meetings.",
    "Let’s turn that half-baked thought into a PR.",
    "Your cursor is blinking. So is destiny.",
    "Ship small, ship often, ship with flair.",
  ],
  afternoon: [
    "Afternoon check-in. How’s the stack feeling?",
    "Post-lunch productivity? We can make it happen.",
    "The day is half over. The fun is not.",
    "Time for a spicy little feature.",
    "If it compiles, we celebrate. If not, we learn.",
    "Standing by for your next brilliant digression.",
    "Let’s make the afternoon count for something mergeable.",
    "Snack break over. Idea break starts now.",
  ],
  evening: [
    "Clocking in for the evening shift.",
    "Golden hour for golden code.",
    "Evening mode: fewer meetings, more commits.",
    "The day wind-down… or the real work begins.",
    "Twilight and type errors—classic combo.",
    "Let’s close a loop before dinner.",
    "Side project energy detected.",
    "Soft light. Sharp diffs.",
  ],
  night: [
    "Night mode engaged. What shall we cook up?",
    "Stars out. Bugs in. Your move.",
    "The perfect hour for a reckless rewrite.",
    "Quiet keyboard. Loud ambition.",
    "One more feature before the night ends.",
    "Let’s leave tomorrow’s self a nicer codebase.",
    "Dark theme. Bright ideas.",
    "Last call for elegant solutions.",
  ],
};

export function greetingPeriodAt(date: Date = new Date()): GreetingPeriod {
  const hour = date.getHours();
  if (hour < 5) return "lateNight";
  if (hour < 9) return "earlyMorning";
  if (hour < 12) return "morning";
  if (hour < 17) return "afternoon";
  if (hour < 21) return "evening";
  return "night";
}

/** Stable-but-rotating pick: changes each hour and day. */
export function greetingPhrase(at: Date = new Date()): string {
  const period = greetingPeriodAt(at);
  const phrases = PHRASES[period];
  if (phrases.length === 0) return "Ready when you are.";

  const start = new Date(at.getFullYear(), 0, 0);
  const dayOfYear = Math.floor((at.getTime() - start.getTime()) / 86_400_000);
  const seed = at.getFullYear() * 1000 + dayOfYear * 24 + at.getHours();
  return phrases[Math.abs(seed) % phrases.length]!;
}

export function allGreetingPhrases(): string[] {
  return Object.values(PHRASES).flat();
}
