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
 * Hard-break on grapheme boundaries — no word-aware breaking in v1. If a
 * single grapheme is wider than `maxPx`, it still occupies its own row (we
 * never split a cluster).
 */
export function computeWrapStarts(line: string, maxPx: number, m: WrapMetrics): number[] {
  if (maxPx <= 0 || line.length === 0) return [0];
  const tabPx = m.tabSize * m.chWidth;
  const starts = [0];
  let x = 0;
  for (const g of graphemes(line)) {
    const cw =
      g.text === "\t"
        ? (Math.floor(x / tabPx) + 1) * tabPx - x
        : g.text.length > 1
          ? m.cjkWidth
          : graphemeCellPx(g.text, m);
    if (x > 0 && x + cw > maxPx) {
      starts.push(g.col);
      x = cw;
    } else {
      x += cw;
    }
  }
  return starts;
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
