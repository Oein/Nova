import { graphemes } from "./grapheme";

export interface WrapMetrics {
  chWidth: number;
  cjkWidth: number;
  tabSize: number;
}

/**
 * Compute the set of column positions where visual rows start, for a soft-wrap
 * at `maxPx` pixels. The first entry is always 0. Subsequent entries are column
 * indices (buffer offsets into the line) where a new wrapped row begins.
 *
 * Word-aware with three-tier priority:
 *   1. Whitespace boundary (highest) — wrap after a space/tab. This is the
 *      natural word break and covers Korean/English/Japanese-with-spaces.
 *   2. CJK boundary (fallback) — any Chinese/Japanese/Korean char boundary is
 *      a legal break when no whitespace opportunity exists in this row. Keeps
 *      pure-CJK text (e.g. a long Japanese sentence without spaces) wrappable.
 *   3. Hard grapheme break (last resort) — an unbroken 100-char URL with no
 *      whitespace or CJK anywhere in the row still needs to wrap somewhere.
 *
 * We prefer (1) over (2) so Korean compound words like "시문집" stay intact
 * when the line has spaces elsewhere. A single grapheme wider than `maxPx`
 * still occupies its own row — we never split a cluster.
 */
export function computeWrapStarts(line: string, maxPx: number, m: WrapMetrics): number[] {
  if (maxPx <= 0 || line.length === 0) return [0];
  const tabPx = m.tabSize * m.chWidth;
  const starts = [0];

  let rowStart = 0;
  let x = 0; // cumulative width from rowStart up to (but not including) the current grapheme
  // Two classes of break opportunity, tracked separately so whitespace wins
  // over CJK-boundary. Korean uses spaces between words — we must prefer
  // wrapping at those over splitting mid-syllable-sequence. Pure CJK text
  // (Chinese/Japanese with no spaces) falls through to the CJK break.
  let wsCol = -1; // last whitespace break in this row (high priority)
  let xAtWs = 0;
  let cjkCol = -1; // last CJK-boundary break in this row (low priority)
  let xAtCjk = 0;
  let prevText: string | null = null;

  for (const g of graphemes(line)) {
    const cw =
      g.text === "\t"
        ? (Math.floor(x / tabPx) + 1) * tabPx - x
        : graphemeCellPx(g.text, m);

    // Classify the boundary just before g. Whitespace boundaries (prev is
    // space/tab) are "word-level" breaks — strongly preferred. CJK boundaries
    // (either side is CJK-like) are "character-level" breaks — used only when
    // no whitespace opportunity exists in this row.
    if (prevText !== null && g.col > rowStart) {
      if (isWs(prevText)) {
        wsCol = g.col;
        xAtWs = x;
      } else if (isCjkLike(prevText) || isCjkLike(g.text)) {
        cjkCol = g.col;
        xAtCjk = x;
      }
    }

    if (x + cw > maxPx && x > 0) {
      if (isWs(g.text)) {
        // Whitespace at the end of a row is allowed to overflow — matches
        // CSS `white-space: normal` semantics. The wrap happens AFTER the
        // whitespace, not before it, so trailing spaces cling to the old row.
        x += cw;
        wsCol = g.col + g.text.length;
        xAtWs = x;
      } else if (wsCol > rowStart) {
        // Prefer word-level wrap.
        starts.push(wsCol);
        rowStart = wsCol;
        x = x - xAtWs + cw;
        wsCol = -1;
        xAtWs = 0;
        cjkCol = -1;
        xAtCjk = 0;
      } else if (cjkCol > rowStart) {
        // No space in this row — fall back to CJK-boundary wrap.
        starts.push(cjkCol);
        rowStart = cjkCol;
        x = x - xAtCjk + cw;
        cjkCol = -1;
        xAtCjk = 0;
      } else {
        // No break opportunity at all — hard wrap at the current grapheme.
        starts.push(g.col);
        rowStart = g.col;
        x = cw;
        wsCol = -1;
        xAtWs = 0;
        cjkCol = -1;
        xAtCjk = 0;
      }
    } else {
      x += cw;
    }

    prevText = g.text;
  }
  return starts;
}

function isWs(g: string): boolean {
  return g === " " || g === "\t";
}

// Same CJK ranges `graphemeCellPx` uses for double-width classification.
// Kept as its own predicate so the wrap logic can ask "is this CJK-like?"
// without measuring the pixel width.
function isCjkLike(g: string): boolean {
  if (g.length > 1) return true;
  const code = g.charCodeAt(0);
  if (code < 0x1100) return false;
  return (
    (code >= 0x1100 && code <= 0x115f) ||
    (code >= 0x2e80 && code <= 0x303e) ||
    (code >= 0x3041 && code <= 0x33ff) ||
    (code >= 0x3400 && code <= 0x4dbf) ||
    (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0xa000 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe30 && code <= 0xfe4f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6)
  );
}

function graphemeCellPx(g: string, m: WrapMetrics): number {
  if (g.length > 1) return m.cjkWidth;
  const code = g.charCodeAt(0);
  if (code < 0x1100) return m.chWidth;
  if (
    (code >= 0x1100 && code <= 0x115f) ||
    (code >= 0x2e80 && code <= 0x303e) ||
    (code >= 0x3041 && code <= 0x33ff) ||
    (code >= 0x3400 && code <= 0x4dbf) ||
    (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0xa000 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe30 && code <= 0xfe4f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6)
  ) {
    return m.cjkWidth;
  }
  return m.chWidth;
}

/** Find the sub-row index (within `wrapStarts`) that contains `col`. */
export function subRowAt(wrapStarts: number[], col: number): number {
  let sr = wrapStarts.length - 1;
  while (sr > 0 && wrapStarts[sr] > col) sr--;
  return sr;
}

/**
 * Binary search: find the largest buffer-line index `i` such that
 * `lineYOffset[i] <= visualRow`. `lineYOffset` is a cumulative prefix sum
 * with `lineYOffset[0] === 0` and length `lineCount + 1`.
 */
export function bufferLineAtVisualRow(lineYOffset: number[], visualRow: number): number {
  let lo = 0;
  let hi = lineYOffset.length - 2; // last valid buffer line index
  if (hi < 0) return 0;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (lineYOffset[mid] <= visualRow) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}
