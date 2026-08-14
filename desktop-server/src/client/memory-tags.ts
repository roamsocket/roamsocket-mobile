/**
 * Streaming parser for `<memory>` tags emitted by the model in chat replies.
 *
 * Tags look like:
 *   <memory action="add" category="you" title="Profile" summary="..." details="..." />
 *   <memory action="forget" target="Verizon" />
 *   <memory action="rename" target="Profile" value="About me" />
 *   <memory action="set_summary" target="Profile" value="..." />
 *   <memory action="set_details" target="Profile" value="a|b|c" />
 *
 * The parser is stateful so it works on token streams where a single tag can
 * be split across multiple chunks. It strips matched tags from the visible
 * reply text and emits a MemoryAction for each complete tag.
 *
 * Code blocks (fenced ``` or inline `…`) are NOT touched — tags inside them
 * are treated as visible text.
 */

export type MemoryAction =
  | {
      kind: "add";
      category: "you" | "topic" | "area";
      title: string;
      summary: string;
      details: string[];
    }
  | { kind: "forget"; target: string }
  | { kind: "rename"; target: string; value: string }
  | { kind: "set_summary"; target: string; value: string }
  | { kind: "set_details"; target: string; value: string[] };

export interface MemoryParseResult {
  /** Visible text with all matched tags removed. */
  text: string;
  /** Complete memory actions parsed from this chunk. */
  actions: MemoryAction[];
  /**
   * Internal buffer remainder after the last complete tag — typically empty,
   * or a partial `<memory ...` tail when the tag is split across chunks.
   * Debug-only; callers should ignore this and just keep calling `push` with
   * the next chunk.
   */
  pending: string;
}

interface MutableState {
  /** Cumulative text since the last `flush`. */
  buffer: string;
}

const TAG_OPEN = "<memory";
const TAG_SELFCLOSE = "/>";

/** Cheap attribute parser. Pulls name="value" pairs from inside a tag. */
function parseAttrs(tagBody: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([a-zA-Z_][\w-]*)\s*=\s*"([^"]*)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(tagBody)) !== null) {
    const key = m[1];
    const val = m[2];
    if (key && val !== undefined) out[key.toLowerCase()] = val;
  }
  return out;
}

/**
 * Find the next `<memory` that is NOT inside a code span. Returns the index
 * of the `<` or -1 if not found. `from` is the buffer start index.
 *
 * Only well-formed openers count:
 *   - `<memory ` (followed by whitespace, opening attributes)
 *   - `<memory/` (self-closing with no attributes)
 * `<memory>` (no attributes, no self-close) is NOT a valid opener — it's
 * just text. `<memoryx` is also not a match (a word that happens to start
 * with `<memory`).
 */
function findTagStartOutsideCode(buffer: string, from: number): number {
  let i = from;
  while (i < buffer.length) {
    const idx = buffer.indexOf(TAG_OPEN, i);
    if (idx < 0) return -1;
    const next = buffer.charAt(idx + TAG_OPEN.length);
    const isTag = next === "" || next === "/" || /\s/.test(next);
    if (isTag && !isInsideUnclosedCodeFence(buffer, idx)) {
      return idx;
    }
    i = idx + 1;
  }
  return -1;
}

function isInsideUnclosedCodeFence(buffer: string, pos: number): boolean {
  // Count triple-backtick fences before pos. If odd, we're inside a block.
  // Inline ` single ` is harder; we approximate by counting single backticks
  // in the current line up to pos. If odd, we're inside an inline span.
  // The model is told not to emit tags inside code, so this is a belt-and-
  // suspenders safety net.
  const before = buffer.slice(0, pos);
  const fenceMatches = before.match(/```/g);
  if (fenceMatches && fenceMatches.length % 2 === 1) return true;
  // Inline: count single backticks on the current line.
  const lineStart = before.lastIndexOf("\n") + 1;
  const line = before.slice(lineStart);
  const inlineBackticks = (line.match(/`/g) || []).length;
  return inlineBackticks % 2 === 1;
}

/**
 * Find the matching `/>` for a tag starting at `start`. Only self-closing
 * tags are recognized — `<memory>...</memory>` wrappers without the slash
 * are treated as plain text. Returns the index just past `/>`, or -1 if
 * the tag is not yet complete.
 */
function findTagEnd(buffer: string, start: number): number {
  const selfClose = buffer.indexOf(TAG_SELFCLOSE, start);
  if (selfClose < 0) return -1;
  return selfClose + TAG_SELFCLOSE.length;
}

function buildAction(attrs: Record<string, string>): MemoryAction | null {
  const action = (attrs["action"] || "").toLowerCase();
  if (!action) return null;
  switch (action) {
    case "add": {
      const category = (attrs["category"] || "you").toLowerCase();
      if (category !== "you" && category !== "topic" && category !== "area") return null;
      const details = (attrs["details"] || "")
        .split("|")
        .map((s) => s.trim())
        .filter(Boolean);
      return {
        kind: "add",
        category,
        title: (attrs["title"] || "Profile").trim() || "Profile",
        summary: (attrs["summary"] || "").trim(),
        details,
      };
    }
    case "forget": {
      const target = (attrs["target"] || "").trim();
      if (!target) return null;
      return { kind: "forget", target };
    }
    case "rename": {
      const target = (attrs["target"] || "").trim();
      const value = (attrs["value"] || "").trim();
      if (!target || !value) return null;
      return { kind: "rename", target, value };
    }
    case "set_summary": {
      const target = (attrs["target"] || "").trim();
      const value = (attrs["value"] || "").trim();
      if (!target) return null;
      return { kind: "set_summary", target, value };
    }
    case "set_details": {
      const target = (attrs["target"] || "").trim();
      const value = (attrs["value"] || "")
        .split("|")
        .map((s) => s.trim())
        .filter(Boolean);
      if (!target) return null;
      return { kind: "set_details", target, value };
    }
    default:
      return null;
  }
}

export class MemoryTagParser {
  private state: MutableState = { buffer: "" };

  /** Feed a chunk of assistant text. Returns visible text + complete actions. */
  push(chunk: string): MemoryParseResult {
    this.state.buffer += chunk;
    return this.drain();
  }

  private drain(): MemoryParseResult {
    const actions: MemoryAction[] = [];
    let visible = "";
    let cursor = 0;
    while (cursor < this.state.buffer.length) {
      const tagStart = findTagStartOutsideCode(this.state.buffer, cursor);
      if (tagStart < 0) {
        // No more tags in buffer. Visible text is everything from cursor to
        // the safe-suffix boundary (so we don't accidentally split a tag).
        const tail = this.state.buffer.slice(cursor);
        const safe = safeBoundary(tail);
        visible += tail.slice(0, safe);
        cursor += safe;
        break;
      }
      // We found a tag opener. We can only safely emit text BEFORE it if we
      // also reach a complete tag close. Otherwise the next chunk might
      // continue the tag, and re-emitting the prefix would duplicate it.
      // So: when the tag is incomplete, hold both the prefix and the tag
      // for the next chunk.
      const tagEnd = findTagEnd(this.state.buffer, tagStart);
      if (tagEnd < 0) {
        break;
      }
      // Emit the text between cursor and tagStart.
      visible += this.state.buffer.slice(cursor, tagStart);
      const tagRaw = this.state.buffer.slice(tagStart, tagEnd);
      const tagBody = tagRaw.replace(/^<memory/i, "").replace(/\/?>$/, "");
      const action = buildAction(parseAttrs(tagBody));
      if (action) actions.push(action);
      cursor = tagEnd;
    }
    this.state.buffer = this.state.buffer.slice(cursor);
    return { text: visible, actions, pending: this.state.buffer };
  }

  /** End of stream: emit trailing safe visible text, drop any unclosed tag. */
  end(): MemoryParseResult {
    const tail = this.state.buffer;
    // Find any unclosed `<memory` opener in the tail. If found, treat
    // everything from that point onwards as a partial tag and trim it.
    let cutAt = tail.length;
    let searchFrom = 0;
    while (searchFrom < tail.length) {
      const idx = findTagStartOutsideCode(tail, searchFrom);
      if (idx < 0) break;
      const end = findTagEnd(tail, idx);
      if (end < 0) {
        cutAt = idx;
        break;
      }
      searchFrom = end;
    }
    const text = tail.slice(0, cutAt);
    this.state.buffer = "";
    return { text, actions: [], pending: "" };
  }
}

/**
 * Returns the index of the last position in `s` that is safely outside any
 * partial `<memory` opener. We retain at most `TAG_OPEN.length - 1` chars of
 * the tail so a tag split across chunks isn't mistakenly rendered as text.
 */
function safeBoundary(s: string): number {
  // Look for the last `<` and check if a partial tag opener is in progress.
  const lastLT = s.lastIndexOf("<");
  if (lastLT < 0) return s.length;
  const tail = s.slice(lastLT);
  if (tail.length >= TAG_OPEN.length) return s.length;
  // The tail is shorter than `<memory`. Check if it COULD be the start of one.
  const head = TAG_OPEN.slice(0, tail.length);
  if (tail.toLowerCase() === head.toLowerCase()) {
    return lastLT;
  }
  return s.length;
}
