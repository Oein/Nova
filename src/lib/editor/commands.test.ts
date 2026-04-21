import { describe, it, expect } from "vitest";
import { RopeBuffer } from "./buffer/RopeBuffer";
import { applyCommand, INITIAL_CURSOR } from "./commands";
import { primary } from "./selection";

function setup(text: string) {
  const buffer = RopeBuffer.fromString(text);
  const cursor = {
    selections: [{ anchor: { line: 0, col: 0 }, head: { line: 0, col: 0 } }],
    primary: 0,
  };
  return { buffer, cursor };
}

describe("movement commands", () => {
  it("move char right then left", () => {
    const ctx = setup("abc");
    let c = applyCommand(ctx, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head).toEqual({ line: 0, col: 1 });
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: -1, extend: false });
    expect(primary(c).head).toEqual({ line: 0, col: 0 });
  });

  it("char movement crosses line boundary", () => {
    const ctx = setup("ab\ncd");
    let c = applyCommand(ctx, { type: "move_end", extend: false });
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head).toEqual({ line: 1, col: 0 });
  });

  it("shift-arrow extends selection", () => {
    const ctx = setup("abc");
    const c = applyCommand(ctx, { type: "move", by: "char", dir: 1, extend: true });
    expect(primary(c).anchor).toEqual({ line: 0, col: 0 });
    expect(primary(c).head).toEqual({ line: 0, col: 1 });
  });

  it("word jump skips whitespace", () => {
    const ctx = setup("hello  world");
    const c = applyCommand(ctx, { type: "move", by: "word", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(5);
    const c2 = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "word", dir: 1, extend: false });
    expect(primary(c2).head.col).toBe(12);
  });

  it("left arrow on a selection collapses to the left edge", () => {
    const ctx = setup("abcde");
    // Anchor at 4, head at 1 (reversed selection) — left edge is col 1.
    const sel = {
      selections: [{ anchor: { line: 0, col: 4 }, head: { line: 0, col: 1 } }],
      primary: 0,
    };
    const c = applyCommand(
      { buffer: ctx.buffer, cursor: sel },
      { type: "move", by: "char", dir: -1, extend: false },
    );
    expect(primary(c).head).toEqual({ line: 0, col: 1 });
    expect(primary(c).anchor).toEqual({ line: 0, col: 1 });
  });

  it("right arrow on a selection collapses to the right edge", () => {
    const ctx = setup("abcde");
    const sel = {
      selections: [{ anchor: { line: 0, col: 1 }, head: { line: 0, col: 4 } }],
      primary: 0,
    };
    const c = applyCommand(
      { buffer: ctx.buffer, cursor: sel },
      { type: "move", by: "char", dir: 1, extend: false },
    );
    expect(primary(c).head).toEqual({ line: 0, col: 4 });
    expect(primary(c).anchor).toEqual({ line: 0, col: 4 });
  });

  it("arrow keys step over an emoji surrogate pair as one glyph", () => {
    // 🙂 is a surrogate pair — JS string length 2, one visual glyph.
    const ctx = setup("a🙂b");
    // Start at col 0; right once → after `a` (col 1); right again → past emoji
    // (col 3, skipping the low surrogate at col 2); right → past `b` (col 4).
    let c = applyCommand(ctx, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(1);
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(3);
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(4);
    // Left from col 3 should jump back over the pair to col 1, not col 2.
    const back = applyCommand(
      { buffer: ctx.buffer, cursor: { selections: [{ anchor: { line: 0, col: 3 }, head: { line: 0, col: 3 } }], primary: 0 } },
      { type: "move", by: "char", dir: -1, extend: false },
    );
    expect(primary(back).head.col).toBe(1);
  });

  it("backspace on an emoji deletes the whole pair", () => {
    const { buffer, cursor } = setup("a🙂");
    // Move to end (col 3), then backspace should leave "a" not "a\uD83D".
    let c = applyCommand({ buffer, cursor }, { type: "move_end", extend: false });
    expect(primary(c).head.col).toBe(3);
    c = applyCommand({ buffer, cursor: c }, { type: "backspace" });
    expect(buffer.toString()).toBe("a");
    expect(primary(c).head.col).toBe(1);
  });

  it("arrow keys step over ⬛️ (VS-16 sequence) as one glyph", () => {
    // ⬛️ = U+2B1B (BMP, 1 unit) + U+FE0F (VS-16, 1 unit) — NOT a surrogate
    // pair. The grapheme spans 2 UTF-16 code units and must be treated as one.
    const ctx = setup("a⬛\uFE0Fb");
    let c = applyCommand(ctx, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(1); // past 'a'
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(3); // past ⬛️ (skipping the VS-16)
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(4); // past 'b'
    // Left from col 3 must jump back over the whole cluster to col 1.
    const back = applyCommand(
      {
        buffer: ctx.buffer,
        cursor: {
          selections: [{ anchor: { line: 0, col: 3 }, head: { line: 0, col: 3 } }],
          primary: 0,
        },
      },
      { type: "move", by: "char", dir: -1, extend: false },
    );
    expect(primary(back).head.col).toBe(1);
  });

  it("backspace on ⬛️ deletes the whole VS-16 cluster", () => {
    const { buffer, cursor } = setup("a⬛\uFE0F");
    let c = applyCommand({ buffer, cursor }, { type: "move_end", extend: false });
    expect(primary(c).head.col).toBe(3);
    c = applyCommand({ buffer, cursor: c }, { type: "backspace" });
    expect(buffer.toString()).toBe("a");
    expect(primary(c).head.col).toBe(1);
  });

  it("arrow keys step over a regional-indicator flag as one glyph", () => {
    // 🇰🇷 = two regional indicators (U+1F1F0 + U+1F1F7), each a surrogate pair.
    // Flag is 4 UTF-16 code units but one grapheme.
    const ctx = setup("a🇰🇷b");
    let c = applyCommand(ctx, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(1); // past 'a'
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(5); // past the flag (skipping 4 code units)
    c = applyCommand({ ...ctx, cursor: c }, { type: "move", by: "char", dir: 1, extend: false });
    expect(primary(c).head.col).toBe(6); // past 'b'
  });

  it("select all spans the doc", () => {
    const ctx = setup("ab\ncde");
    const c = applyCommand(ctx, { type: "select_all" });
    expect(primary(c).anchor).toEqual({ line: 0, col: 0 });
    expect(primary(c).head).toEqual({ line: 1, col: 3 });
  });
});

describe("edit commands", () => {
  it("insert types text and advances caret", () => {
    const ctx = setup("");
    const c = applyCommand(ctx, { type: "insert", text: "hi" });
    expect(ctx.buffer.toString()).toBe("hi");
    expect(primary(c).head).toEqual({ line: 0, col: 2 });
  });

  it("newline splits the line", () => {
    const { buffer, cursor } = setup("ab");
    let c = applyCommand({ buffer, cursor }, { type: "move", by: "char", dir: 1, extend: false });
    c = applyCommand({ buffer, cursor: c }, { type: "newline" });
    expect(buffer.toString()).toBe("a\nb");
    expect(primary(c).head).toEqual({ line: 1, col: 0 });
  });

  it("backspace at line start joins with previous line", () => {
    const { buffer, cursor } = setup("ab\ncd");
    let c = applyCommand({ buffer, cursor }, { type: "move", by: "line", dir: 1, extend: false });
    c = applyCommand({ buffer, cursor: c }, { type: "move_home", extend: false });
    c = applyCommand({ buffer, cursor: c }, { type: "backspace" });
    expect(buffer.toString()).toBe("abcd");
    expect(primary(c).head).toEqual({ line: 0, col: 2 });
  });

  it("typing with selection replaces it", () => {
    const { buffer, cursor } = setup("hello");
    let c = applyCommand({ buffer, cursor }, { type: "select_all" });
    c = applyCommand({ buffer, cursor: c }, { type: "insert", text: "X" });
    expect(buffer.toString()).toBe("X");
    expect(primary(c).head).toEqual({ line: 0, col: 1 });
  });

  it("undo/redo from command path", () => {
    const { buffer, cursor } = setup("x");
    let c = applyCommand({ buffer, cursor }, { type: "move_end", extend: false });
    c = applyCommand({ buffer, cursor: c }, { type: "insert", text: "y" });
    expect(buffer.toString()).toBe("xy");
    applyCommand({ buffer, cursor: c }, { type: "undo" });
    expect(buffer.toString()).toBe("x");
    applyCommand({ buffer, cursor: c }, { type: "redo" });
    expect(buffer.toString()).toBe("xy");
  });
});

describe("read-only buffer", () => {
  it("insert/backspace are no-ops on non-editable buffer", () => {
    const buffer = new (class {
      editable = false;
      lineCount = 1;
      getLine() {
        return "abc";
      }
      subscribe() {
        return () => {};
      }
      applyEdit() {
        throw new Error("should not be called");
      }
      undo() {
        return null;
      }
      redo() {
        return null;
      }
      toString() {
        return "abc";
      }
    })();
    const cursor = INITIAL_CURSOR;
    const c = applyCommand({ buffer, cursor }, { type: "insert", text: "X" });
    expect(c).toBe(cursor);
  });
});
