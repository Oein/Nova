// Word-range selection for double-click.
//
// Classifies characters into three buckets — word, whitespace, other — and
// expands in both directions as long as the class stays the same. This
// matches the behavior users expect from macOS / Sublime / VS Code:
//   double-click on "foo"   → selects foo
//   double-click on spaces  → selects the whitespace run
//   double-click on "+="    → selects the punctuation run (+=)
//
// Word class covers ASCII alphanumerics + underscore plus any Unicode
// letter/number (so CJK / Hangul / Cyrillic / Arabic all work). We use
// property escapes (`\p{L}`, `\p{N}`) with the `u` flag, which all modern
// WebKit / WebView2 runtimes support.

export type CharClass = "word" | "ws" | "other";

const WORD_RE = /[\p{L}\p{N}_]/u;

export function charClass(ch: string | undefined): CharClass {
  if (!ch) return "other";
  if (ch === " " || ch === "\t") return "ws";
  return WORD_RE.test(ch) ? "word" : "other";
}

// Returns the [start, end) column range of the run containing `col`. If
// `col` sits past the end of the line we back up one to grab the trailing
// cluster (so clicking on the empty space after a word still selects the
// word). An empty line yields {start:0,end:0} — caller should treat that
// as "nothing to select."
//
// `col` is in UTF-16 code units (matches how the rest of the editor
// addresses columns). The routine is grapheme-naive: a cluster like
// "é" composed of e + combining acute will split at the combining mark,
// but since the combining mark still classifies as word/other it sticks
// to its base. Emoji sequences don't participate in double-click-select
// in a meaningful way for users, so we don't bother with Intl.Segmenter.
export function wordAt(line: string, col: number): { start: number; end: number } {
  if (line.length === 0) return { start: 0, end: 0 };
  const i = Math.min(col, line.length - 1);
  const cls = charClass(line[i]);
  let start = i;
  while (start > 0 && charClass(line[start - 1]) === cls) start--;
  let end = i + 1;
  while (end < line.length && charClass(line[end]) === cls) end++;
  return { start, end };
}
