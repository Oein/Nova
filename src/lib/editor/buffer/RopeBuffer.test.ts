import { describe, it, expect } from "vitest";
import { RopeBuffer, splitLines } from "./RopeBuffer";
import type { BufferChange } from "./Buffer";

describe("splitLines", () => {
  it("empty string is a single empty line", () => {
    expect(splitLines("")).toEqual([""]);
  });
  it("trailing newline yields a trailing empty line", () => {
    expect(splitLines("a\n")).toEqual(["a", ""]);
  });
  it("no newline is one line", () => {
    expect(splitLines("abc")).toEqual(["abc"]);
  });
  it("multiple newlines", () => {
    expect(splitLines("a\nb\nc")).toEqual(["a", "b", "c"]);
  });
});

describe("RopeBuffer basic ops", () => {
  it("round-trips text", () => {
    const b = RopeBuffer.fromString("hello\nworld\n");
    expect(b.toString()).toBe("hello\nworld\n");
    expect(b.lineCount).toBe(3); // "hello", "world", ""
    expect(b.getLine(0)).toBe("hello");
    expect(b.getLine(1)).toBe("world");
    expect(b.getLine(2)).toBe("");
  });

  it("insert in the middle of a line", () => {
    const b = RopeBuffer.fromString("hello");
    b.applyEdit({ kind: "insert", at: { line: 0, col: 5 }, text: " world" });
    expect(b.toString()).toBe("hello world");
  });

  it("insert newlines creates new lines", () => {
    const b = RopeBuffer.fromString("ac");
    b.applyEdit({ kind: "insert", at: { line: 0, col: 1 }, text: "\nb\n" });
    expect(b.toString()).toBe("a\nb\nc");
    expect(b.lineCount).toBe(3);
  });

  it("delete within a line", () => {
    const b = RopeBuffer.fromString("hello");
    b.applyEdit({
      kind: "delete",
      from: { line: 0, col: 1 },
      to: { line: 0, col: 4 },
    });
    expect(b.toString()).toBe("ho");
  });

  it("delete across lines", () => {
    const b = RopeBuffer.fromString("abc\ndef\nghi");
    b.applyEdit({
      kind: "delete",
      from: { line: 0, col: 1 },
      to: { line: 2, col: 2 },
    });
    expect(b.toString()).toBe("ai");
  });

  it("delete reversed range is normalized", () => {
    const b = RopeBuffer.fromString("hello");
    b.applyEdit({
      kind: "delete",
      from: { line: 0, col: 4 },
      to: { line: 0, col: 1 },
    });
    expect(b.toString()).toBe("ho");
  });

  it("clamps out-of-range positions", () => {
    const b = RopeBuffer.fromString("hi");
    b.applyEdit({ kind: "insert", at: { line: 999, col: 999 }, text: "!" });
    expect(b.toString()).toBe("hi!");
  });
});

describe("RopeBuffer change notifications", () => {
  it("subscribe fires 'ready' immediately", () => {
    const b = RopeBuffer.fromString("x");
    const events: BufferChange[] = [];
    const unsub = b.subscribe((c) => events.push(c));
    expect(events[0]).toEqual({ kind: "ready" });
    unsub();
  });

  it("insert fires replace with correct span", () => {
    const b = RopeBuffer.fromString("a\nb");
    const events: BufferChange[] = [];
    b.subscribe((c) => events.push(c));
    b.applyEdit({ kind: "insert", at: { line: 0, col: 1 }, text: "Z" });
    const replace = events.find((e) => e.kind === "replace");
    expect(replace).toEqual({ kind: "replace", fromLine: 0, toLine: 1, newLineCount: 1 });
  });
});

describe("RopeBuffer undo/redo", () => {
  it("undo reverses an insert", () => {
    const b = RopeBuffer.fromString("x");
    b.applyEdit({ kind: "insert", at: { line: 0, col: 1 }, text: "y" });
    expect(b.toString()).toBe("xy");
    expect(b.undo()).toEqual({ line: 0, col: 1 });
    expect(b.toString()).toBe("x");
  });

  it("redo re-applies an undone edit", () => {
    const b = RopeBuffer.fromString("x");
    b.applyEdit({ kind: "insert", at: { line: 0, col: 1 }, text: "y" });
    b.undo();
    expect(b.redo()).toEqual({ line: 0, col: 2 });
    expect(b.toString()).toBe("xy");
  });

  it("new edit clears redo stack", () => {
    const b = RopeBuffer.fromString("");
    b.applyEdit({ kind: "insert", at: { line: 0, col: 0 }, text: "a" });
    b.undo();
    b.applyEdit({ kind: "insert", at: { line: 0, col: 0 }, text: "b" });
    expect(b.redo()).toBeNull();
    expect(b.toString()).toBe("b");
  });

  it("undo on empty stack returns null", () => {
    const b = RopeBuffer.fromString("x");
    expect(b.undo()).toBeNull();
  });

  it("coalesced typing burst undoes as a single step", () => {
    const b = RopeBuffer.fromString("");
    for (const ch of "hello") {
      const line = 0;
      const col = b.getLine(0).length;
      b.applyEdit({ kind: "insert", at: { line, col }, text: ch });
    }
    expect(b.toString()).toBe("hello");
    expect(b.undo()).toEqual({ line: 0, col: 0 });
    expect(b.toString()).toBe("");
  });

  it("coalesced burst redoes in original order", () => {
    const b = RopeBuffer.fromString("");
    for (const ch of "abc") {
      b.applyEdit({
        kind: "insert",
        at: { line: 0, col: b.getLine(0).length },
        text: ch,
      });
    }
    b.undo();
    expect(b.toString()).toBe("");
    b.redo();
    expect(b.toString()).toBe("abc");
  });

  it("separate bursts are separate undo steps", () => {
    const b = RopeBuffer.fromString("");
    for (const ch of "abc") {
      b.applyEdit({
        kind: "insert",
        at: { line: 0, col: b.getLine(0).length },
        text: ch,
      });
    }
    // Force the first group closed before the next burst by sliding the clock.
    const base = Date.now();
    const origNow = Date.now;
    try {
      Date.now = () => base + 1000;
      for (const ch of "xyz") {
        b.applyEdit({
          kind: "insert",
          at: { line: 0, col: b.getLine(0).length },
          text: ch,
        });
      }
    } finally {
      Date.now = origNow;
    }
    expect(b.toString()).toBe("abcxyz");
    b.undo();
    expect(b.toString()).toBe("abc");
    b.undo();
    expect(b.toString()).toBe("");
  });
});

describe("RopeBuffer fuzz — random edits match reference implementation", () => {
  it("10000 random insert/delete ops stay in sync with a naïve string ref", () => {
    const seed = 12345;
    let s = 0xdead_beef ^ seed;
    const rand = () => {
      // xorshift32
      s ^= s << 13;
      s ^= s >>> 17;
      s ^= s << 5;
      return ((s >>> 0) % 1_000_000) / 1_000_000;
    };
    const chars = "ab\nXY";
    const b = RopeBuffer.fromString("");
    let ref = "";
    for (let i = 0; i < 10000; i++) {
      const insert = rand() < 0.65 || ref.length === 0;
      if (insert) {
        const at = Math.floor(rand() * (ref.length + 1));
        const n = 1 + Math.floor(rand() * 4);
        let text = "";
        for (let k = 0; k < n; k++) text += chars[Math.floor(rand() * chars.length)];
        const pos = offsetToPos(ref, at);
        b.applyEdit({ kind: "insert", at: pos, text });
        ref = ref.slice(0, at) + text + ref.slice(at);
      } else {
        const a = Math.floor(rand() * ref.length);
        const bb = Math.min(ref.length, a + 1 + Math.floor(rand() * 5));
        b.applyEdit({
          kind: "delete",
          from: offsetToPos(ref, a),
          to: offsetToPos(ref, bb),
        });
        ref = ref.slice(0, a) + ref.slice(bb);
      }
      if (i % 250 === 0) {
        expect(b.toString()).toBe(ref);
      }
    }
    expect(b.toString()).toBe(ref);
  });
});

function offsetToPos(text: string, offset: number): { line: number; col: number } {
  let line = 0;
  let col = 0;
  for (let i = 0; i < offset; i++) {
    if (text[i] === "\n") {
      line++;
      col = 0;
    } else {
      col++;
    }
  }
  return { line, col };
}
