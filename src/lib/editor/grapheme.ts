/**
 * Grapheme cluster boundary helpers.
 *
 * A "grapheme cluster" is what a user perceives as one character — e.g.
 * `⬛️` (U+2B1B + VS-16), `🙂` (a surrogate pair), `🇰🇷` (two regional
 * indicators), or `👨‍👩‍👧` (three people joined by ZWJ) each count as a
 * single cluster even though they span multiple UTF-16 code units. Arrows,
 * hit-testing, and backspace all use these helpers so the caret never lands
 * inside a cluster.
 *
 * Uses `Intl.Segmenter` when available (Node 16+, all modern browsers);
 * falls back to UTF-16 surrogate-pair stepping otherwise — that fallback
 * still mis-handles VS/ZWJ/flags, but nothing currently ships without
 * Segmenter support.
 */

type Seg = { segment: string; index: number };

const segmenter: { segment(s: string): Iterable<Seg> } | null = (() => {
  try {
    return typeof Intl !== "undefined" && "Segmenter" in Intl
      ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
      : null;
  } catch {
    return null;
  }
})();

function surrogateNext(s: string, col: number): number {
  const hi = s.charCodeAt(col);
  if (hi >= 0xd800 && hi <= 0xdbff && col + 1 < s.length) {
    const lo = s.charCodeAt(col + 1);
    if (lo >= 0xdc00 && lo <= 0xdfff) return col + 2;
  }
  return col + 1;
}

function surrogatePrev(s: string, col: number): number {
  if (col >= 2) {
    const lo = s.charCodeAt(col - 1);
    const hi = s.charCodeAt(col - 2);
    if (lo >= 0xdc00 && lo <= 0xdfff && hi >= 0xd800 && hi <= 0xdbff) return col - 2;
  }
  return col - 1;
}

/** Next grapheme boundary at or after `col`. */
export function nextGrapheme(s: string, col: number): number {
  if (col >= s.length) return s.length;
  if (!segmenter) return surrogateNext(s, col);
  const it = segmenter.segment(s.slice(col))[Symbol.iterator]();
  const first = it.next();
  if (first.done) return col + 1;
  const len = first.value.segment.length;
  return col + (len > 0 ? len : 1);
}

/** Previous grapheme boundary strictly before `col`. */
export function prevGrapheme(s: string, col: number): number {
  if (col <= 0) return 0;
  if (!segmenter) return surrogatePrev(s, col);
  let lastStart = 0;
  for (const seg of segmenter.segment(s.slice(0, col))) lastStart = seg.index;
  return lastStart;
}

/** Iterate grapheme clusters of `s`, yielding `{col, text}` per cluster. */
export function* graphemes(s: string): Generator<{ col: number; text: string }> {
  if (segmenter) {
    for (const seg of segmenter.segment(s)) {
      yield { col: seg.index, text: seg.segment };
    }
    return;
  }
  let i = 0;
  while (i < s.length) {
    const n = surrogateNext(s, i);
    yield { col: i, text: s.slice(i, n) };
    i = n;
  }
}
