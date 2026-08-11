/**
 * Pure cursor/editing helpers for the TUI composer line.
 * Terminal-friendly word jumps (non-whitespace runs), line start/end, insert/delete.
 */

export interface ComposerEdit {
  text: string;
  cursor: number;
}

export function clampCursor(text: string, cursor: number): number {
  if (cursor < 0) return 0;
  if (cursor > text.length) return text.length;
  return cursor;
}

export function moveCharLeft(cursor: number): number {
  return Math.max(0, cursor - 1);
}

export function moveCharRight(text: string, cursor: number): number {
  return Math.min(text.length, cursor + 1);
}

export function moveLineStart(): number {
  return 0;
}

export function moveLineEnd(text: string): number {
  return text.length;
}

/**
 * Jump to the start of the previous word (Option/Alt+Left, Meta+b, Ctrl+Left).
 * Skips trailing whitespace left of the cursor, then the word before it.
 */
export function moveWordLeft(text: string, cursor: number): number {
  let i = clampCursor(text, cursor);
  while (i > 0 && isSpace(text[i - 1]!)) i -= 1;
  while (i > 0 && !isSpace(text[i - 1]!)) i -= 1;
  return i;
}

/**
 * Jump past the current/next word (Option/Alt+Right, Meta+f, Ctrl+Right).
 * Skips non-space under/after the cursor, then following whitespace.
 */
export function moveWordRight(text: string, cursor: number): number {
  let i = clampCursor(text, cursor);
  const n = text.length;
  while (i < n && !isSpace(text[i]!)) i += 1;
  while (i < n && isSpace(text[i]!)) i += 1;
  return i;
}

export function insertText(text: string, cursor: number, chunk: string): ComposerEdit {
  const c = clampCursor(text, cursor);
  if (!chunk) return { text, cursor: c };
  return {
    text: text.slice(0, c) + chunk + text.slice(c),
    cursor: c + chunk.length,
  };
}

/** Delete the grapheme/code unit immediately before the cursor (Backspace). */
export function deleteBackward(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  if (c === 0) return { text, cursor: 0 };
  return {
    text: text.slice(0, c - 1) + text.slice(c),
    cursor: c - 1,
  };
}

/** Delete the grapheme/code unit at the cursor (Delete / Ctrl+d). */
export function deleteForward(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  if (c >= text.length) return { text, cursor: c };
  return {
    text: text.slice(0, c) + text.slice(c + 1),
    cursor: c,
  };
}

/** Delete from cursor back through the previous word (Option+Backspace / Ctrl+w). */
export function deleteWordBackward(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  const start = moveWordLeft(text, c);
  return {
    text: text.slice(0, start) + text.slice(c),
    cursor: start,
  };
}

/** Delete from cursor through the end of the next word (Option+Delete / Meta+d). */
export function deleteWordForward(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  const end = moveWordRight(text, c);
  return {
    text: text.slice(0, c) + text.slice(end),
    cursor: c,
  };
}

/** Kill from cursor to end of line (Ctrl+k). */
export function deleteToLineEnd(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  return { text: text.slice(0, c), cursor: c };
}

/** Kill from start of line to cursor (Ctrl+u). */
export function deleteToLineStart(text: string, cursor: number): ComposerEdit {
  const c = clampCursor(text, cursor);
  return { text: text.slice(c), cursor: 0 };
}

function isSpace(ch: string): boolean {
  return /\s/.test(ch);
}
