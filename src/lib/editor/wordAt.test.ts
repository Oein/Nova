import { describe, expect, it } from "vitest";
import { charClass, wordAt } from "./wordAt";

describe("charClass", () => {
  it("classifies ASCII letters/digits/underscore as word", () => {
    for (const ch of ["a", "Z", "0", "9", "_"]) {
      expect(charClass(ch)).toBe("word");
    }
  });
  it("classifies space and tab as ws", () => {
    expect(charClass(" ")).toBe("ws");
    expect(charClass("\t")).toBe("ws");
  });
  it("classifies punctuation as other", () => {
    for (const ch of [".", ",", "+", "=", "(", ")", "!", "?"]) {
      expect(charClass(ch)).toBe("other");
    }
  });
  it("classifies CJK / Hangul as word", () => {
    expect(charClass("가")).toBe("word");
    expect(charClass("漢")).toBe("word");
    expect(charClass("あ")).toBe("word");
  });
});

describe("wordAt", () => {
  it("returns the ASCII word under the cursor", () => {
    const line = "foo bar baz";
    expect(wordAt(line, 0)).toEqual({ start: 0, end: 3 });
    expect(wordAt(line, 2)).toEqual({ start: 0, end: 3 });
    expect(wordAt(line, 4)).toEqual({ start: 4, end: 7 });
    expect(wordAt(line, 10)).toEqual({ start: 8, end: 11 });
  });

  it("selects whitespace runs", () => {
    const line = "foo   bar";
    expect(wordAt(line, 3)).toEqual({ start: 3, end: 6 });
    expect(wordAt(line, 4)).toEqual({ start: 3, end: 6 });
  });

  it("selects punctuation runs", () => {
    const line = "x += 1";
    expect(wordAt(line, 2)).toEqual({ start: 2, end: 4 });
    expect(wordAt(line, 3)).toEqual({ start: 2, end: 4 });
  });

  it("handles clicks past end of line by grabbing the trailing cluster", () => {
    const line = "hello";
    expect(wordAt(line, 99)).toEqual({ start: 0, end: 5 });
  });

  it("returns empty range on empty line", () => {
    expect(wordAt("", 0)).toEqual({ start: 0, end: 0 });
    expect(wordAt("", 5)).toEqual({ start: 0, end: 0 });
  });

  it("groups CJK characters into a word", () => {
    const line = "안녕 world";
    expect(wordAt(line, 0)).toEqual({ start: 0, end: 2 });
    expect(wordAt(line, 1)).toEqual({ start: 0, end: 2 });
    expect(wordAt(line, 3)).toEqual({ start: 3, end: 8 });
  });

  it("treats underscore as part of the word", () => {
    const line = "my_var = 1";
    expect(wordAt(line, 0)).toEqual({ start: 0, end: 6 });
    expect(wordAt(line, 3)).toEqual({ start: 0, end: 6 });
  });
});
