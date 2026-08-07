/**
 * Cool blue-grey theme tokens — must match iOS Theme.swift and renderer CSS.
 */
export const THEME = {
  background: "#0B0D10",
  surface: "#14181D",
  surfaceElevated: "#1B2026",
  field: "#0E1216",
  textPrimary: "#E8ECF1",
  textSecondary: "#9AA3AD",
  textTertiary: "#6B727B",
  accent: "#6AA9FF",
  separator: "#262C34",
  ok: "#5DD39E",
  warn: "#F0C674",
  err: "#EF6F6C",
} as const;

export type ThemeToken = keyof typeof THEME;
