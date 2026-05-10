import { describe, it, expect } from "vitest";
import { computeWrapStarts, type WrapMetrics } from "./wrap";

// Simple 1px-per-ASCII-char, 2px-per-CJK metrics — makes arithmetic trivial.
const M: WrapMetrics = { chWidth: 1, cjkWidth: 2, tabSize: 4 };

describe("computeWrapStarts — word-aware wrapping", () => {
  it("empty line → single row", () => {
    expect(computeWrapStarts("", 10, M)).toEqual([0]);
  });

  it("line that fits → single row", () => {
    expect(computeWrapStarts("hello", 100, M)).toEqual([0]);
  });

  it("breaks after whitespace rather than mid-word", () => {
    // "foo bar baz" at maxPx=7 — "foo bar" is 7 chars, "baz" is the next word.
    // Break should land at col 8 (start of "baz"), not mid-"bar".
    const starts = computeWrapStarts("foo bar baz", 7, M);
    expect(starts).toEqual([0, 8]);
  });

  it("breaks at multiple word boundaries for long paragraphs", () => {
    // "aa bb cc dd ee" at maxPx=5 →
    //   "aa bb" (5) → break at col 6 → "cc dd" (5) → break at col 12 → "ee"
    const starts = computeWrapStarts("aa bb cc dd ee", 5, M);
    expect(starts).toEqual([0, 6, 12]);
  });

  it("hard-breaks unbroken long strings (no break opportunity)", () => {
    // No whitespace or CJK → falls back to character-level wrap.
    const starts = computeWrapStarts("aaaaaaaaaa", 3, M);
    // Each row holds 3 chars: 0..3, 3..6, 6..9, 9..10
    expect(starts).toEqual([0, 3, 6, 9]);
  });

  it("wraps between CJK characters (no spaces needed)", () => {
    // Each CJK char is 2px wide at cjkWidth=2. maxPx=5 → 2 chars per row
    // (4px), third char overflows → wrap.
    const starts = computeWrapStarts("안녕하세요", 5, M);
    expect(starts).toEqual([0, 2, 4]);
  });

  it("prefers whitespace break over mid-CJK break (Korean compound word)", () => {
    // "한국 시문집을" at maxPx=8 — space is at col 2 (between "한국" and
    // "시문집을"). Without whitespace priority we'd wrap at the LATEST
    // CJK boundary before overflow (mid-"시문집"), splitting the word.
    // With whitespace priority, we wrap at col 3 (after the space), keeping
    // "시문집을" intact on the next row.
    // Widths: '한'=2, '국'=2, ' '=1, '시'=2, '문'=2, '집'=2, '을'=2
    //   Row 0: accumulates to x=7 at col 3 (after '시'); adding '문' → 9 > 8
    //   → wrap at wsCol=3 (not cjkCol=4). Row 1: "시문집을" = 8px, fits.
    const starts = computeWrapStarts("한국 시문집을", 8, M);
    expect(starts).toEqual([0, 3]);
  });

  it("wraps between ASCII and CJK on CJK boundary", () => {
    // "abc안녕" at maxPx=4: "abc" is 3px, next is '안' (2px) → 3+2=5 > 4 →
    // wrap. '안' is a break boundary, so wrap happens before '안' (col 3).
    const starts = computeWrapStarts("abc안녕", 4, M);
    expect(starts).toEqual([0, 3]);
  });

  it("keeps leading graphemes even when they alone overflow", () => {
    // If the very first grapheme of a new row is wider than maxPx, we still
    // put it on that row alone — otherwise we'd loop forever.
    const starts = computeWrapStarts("안녕", 1, M);
    // First char is 2px, maxPx=1, but row starts with it anyway. Second char
    // overflows → new row.
    expect(starts).toEqual([0, 1]);
  });

  it("lets trailing whitespace overflow — wraps after the last space", () => {
    // "foo   bar" at maxPx=5 — "foo" is 3px, then three spaces would take
    // the row to 6px. Per CSS `white-space: normal`, trailing whitespace is
    // allowed to overflow and the wrap lands at the start of "bar" (col 6).
    const starts = computeWrapStarts("foo   bar", 5, M);
    expect(starts).toEqual([0, 6]);
  });

  it("first-row no break opportunity falls through to hard break", () => {
    // "abcdefgh xy" at maxPx=3: no boundary before col 8. "abc"/"def"/"gh "/
    // "xy" — hard breaks in the first word, then soft break after the space.
    const starts = computeWrapStarts("abcdefgh xy", 3, M);
    // 0..3: "abc"; 3..6: "def"; 6: 'g' cw=1, x=1; 7: 'h', x=2; 8: ' ', x=3;
    // 9: 'x' would overflow → break. breakCol was set at col 9 (after space).
    // Result: [0, 3, 6, 9]
    expect(starts).toEqual([0, 3, 6, 9]);
  });

  it("tabs count toward width with tab-stop rounding", () => {
    // tabSize=4, chWidth=1 → one tab at col 0 occupies 4px (rounds to next
    // stop). "a\tb" at maxPx=5 → 'a'(1) + '\t'(3 to reach col 4) + 'b'(1) = 5.
    // Fits on one row.
    expect(computeWrapStarts("a\tb", 5, M)).toEqual([0]);
    // Same line at maxPx=4 → 'a' + '\t' fills the row; 'b' overflows → wrap.
    // But breakCol was set after '\t' (whitespace). Wrap at col 2 = before 'b'.
    expect(computeWrapStarts("a\tb", 4, M)).toEqual([0, 2]);
  });
});
