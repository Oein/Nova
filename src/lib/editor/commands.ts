import type { Buffer, Pos } from "./buffer/Buffer";
import { nextGrapheme, prevGrapheme } from "./grapheme";
import {
  INITIAL_CURSOR,
  isEmpty,
  ordered,
  primary,
  withPrimary,
  type CursorState,
  type Selection,
} from "./selection";

export type Command =
  | { type: "move"; by: "char" | "word" | "line"; dir: -1 | 1; extend: boolean }
  | { type: "move_home"; extend: boolean }
  | { type: "move_end"; extend: boolean }
  | { type: "move_doc_edge"; dir: -1 | 1; extend: boolean }
  | { type: "page"; dir: -1 | 1; extend: boolean; pageLines: number }
  | { type: "insert"; text: string }
  | { type: "newline" }
  | { type: "backspace" }
  | { type: "delete" }
  | { type: "dedent" }
  | { type: "select_all" }
  | { type: "undo" }
  | { type: "redo" };

export interface EditorCtx {
  buffer: Buffer;
  cursor: CursorState;
}

function wordBoundary(line: string, col: number, dir: -1 | 1): number {
  if (line.length === 0) return 0;
  let i = col;
  if (dir === 1) {
    while (i < line.length && isWs(line[i])) i++;
    while (i < line.length && !isWs(line[i])) i++;
  } else {
    i = Math.max(0, i - 1);
    while (i > 0 && isWs(line[i])) i--;
    while (i > 0 && !isWs(line[i - 1])) i--;
  }
  return i;
}
function isWs(c: string): boolean {
  return c === " " || c === "\t";
}

export function applyCommand(ctx: EditorCtx, cmd: Command): CursorState {
  const { buffer } = ctx;
  const editable = buffer.editable;
  const sel = primary(ctx.cursor);

  switch (cmd.type) {
    case "move": {
      // Non-extending horizontal char move on a non-empty selection collapses
      // to the left or right edge of the selection instead of stepping from
      // the head. Matches macOS / Sublime / VSCode.
      if (cmd.by === "char" && !cmd.extend && !isEmpty(sel)) {
        const { from, to } = ordered(sel);
        const head = cmd.dir === -1 ? from : to;
        return withPrimary(ctx.cursor, { anchor: head, head });
      }
      let head = sel.head;
      if (cmd.by === "char") head = moveChar(buffer, head, cmd.dir);
      else if (cmd.by === "word") head = moveWord(buffer, head, cmd.dir);
      else head = moveLine(buffer, head, cmd.dir);
      return withPrimary(
        ctx.cursor,
        cmd.extend ? { anchor: sel.anchor, head } : { anchor: head, head },
      );
    }
    case "move_home": {
      const head = { line: sel.head.line, col: 0 };
      return withPrimary(
        ctx.cursor,
        cmd.extend ? { anchor: sel.anchor, head } : { anchor: head, head },
      );
    }
    case "move_end": {
      const head = { line: sel.head.line, col: buffer.getLine(sel.head.line).length };
      return withPrimary(
        ctx.cursor,
        cmd.extend ? { anchor: sel.anchor, head } : { anchor: head, head },
      );
    }
    case "move_doc_edge": {
      const head: Pos =
        cmd.dir === 1
          ? { line: buffer.lineCount - 1, col: buffer.getLine(buffer.lineCount - 1).length }
          : { line: 0, col: 0 };
      return withPrimary(
        ctx.cursor,
        cmd.extend ? { anchor: sel.anchor, head } : { anchor: head, head },
      );
    }
    case "page": {
      const dest = Math.max(
        0,
        Math.min(buffer.lineCount - 1, sel.head.line + cmd.dir * cmd.pageLines),
      );
      const head = { line: dest, col: Math.min(sel.head.col, buffer.getLine(dest).length) };
      return withPrimary(
        ctx.cursor,
        cmd.extend ? { anchor: sel.anchor, head } : { anchor: head, head },
      );
    }
    case "insert": {
      if (!editable) return ctx.cursor;
      return doInsert(ctx, sel, cmd.text);
    }
    case "newline": {
      if (!editable) return ctx.cursor;
      return doInsert(ctx, sel, "\n");
    }
    case "backspace": {
      if (!editable) return ctx.cursor;
      if (!isEmpty(sel)) {
        const { from, to } = ordered(sel);
        buffer.applyEdit({ kind: "delete", from, to });
        return withPrimary(ctx.cursor, { anchor: from, head: from });
      }
      const left = moveChar(buffer, sel.head, -1);
      if (left.line === sel.head.line && left.col === sel.head.col) return ctx.cursor;
      buffer.applyEdit({ kind: "delete", from: left, to: sel.head });
      return withPrimary(ctx.cursor, { anchor: left, head: left });
    }
    case "delete": {
      if (!editable) return ctx.cursor;
      if (!isEmpty(sel)) {
        const { from, to } = ordered(sel);
        buffer.applyEdit({ kind: "delete", from, to });
        return withPrimary(ctx.cursor, { anchor: from, head: from });
      }
      const right = moveChar(buffer, sel.head, 1);
      if (right.line === sel.head.line && right.col === sel.head.col) return ctx.cursor;
      buffer.applyEdit({ kind: "delete", from: sel.head, to: right });
      return ctx.cursor;
    }
    case "dedent": {
      if (!editable) return ctx.cursor;
      const minLine = Math.min(sel.anchor.line, sel.head.line);
      const maxLine = Math.max(sel.anchor.line, sel.head.line);
      // Track which lines actually had a tab removed so we can adjust col.
      const removed = new Array<boolean>(maxLine - minLine + 1).fill(false);
      // Delete in reverse so earlier-line offsets are still valid when we reach them.
      for (let l = maxLine; l >= minLine; l--) {
        if (buffer.getLine(l).startsWith("\t")) {
          buffer.applyEdit({ kind: "delete", from: { line: l, col: 0 }, to: { line: l, col: 1 } });
          removed[l - minLine] = true;
        }
      }
      const adjustPos = (p: Pos): Pos => {
        if (p.line < minLine || p.line > maxLine) return p;
        if (!removed[p.line - minLine]) return p;
        return { line: p.line, col: Math.max(0, p.col - 1) };
      };
      return withPrimary(ctx.cursor, {
        anchor: adjustPos(sel.anchor),
        head: adjustPos(sel.head),
      });
    }
    case "select_all": {
      const lastLine = buffer.lineCount - 1;
      return withPrimary(ctx.cursor, {
        anchor: { line: 0, col: 0 },
        head: { line: lastLine, col: buffer.getLine(lastLine).length },
      });
    }
    case "undo": {
      if (!editable) return ctx.cursor;
      const pos = buffer.undo();
      if (!pos) return clampCursor(ctx.cursor, buffer);
      return withPrimary(ctx.cursor, { anchor: pos, head: pos });
    }
    case "redo": {
      if (!editable) return ctx.cursor;
      const pos = buffer.redo();
      if (!pos) return clampCursor(ctx.cursor, buffer);
      return withPrimary(ctx.cursor, { anchor: pos, head: pos });
    }
  }
  return ctx.cursor;
}

function doInsert(ctx: EditorCtx, sel: Selection, text: string): CursorState {
  const { buffer } = ctx;
  if (!isEmpty(sel)) {
    const { from, to } = ordered(sel);
    buffer.applyEdit({ kind: "delete", from, to });
    buffer.applyEdit({ kind: "insert", at: from, text });
    const nh = advancePosByText(from, text);
    return withPrimary(ctx.cursor, { anchor: nh, head: nh });
  }
  buffer.applyEdit({ kind: "insert", at: sel.head, text });
  const nh = advancePosByText(sel.head, text);
  return withPrimary(ctx.cursor, { anchor: nh, head: nh });
}

function advancePosByText(p: Pos, text: string): Pos {
  if (!text.includes("\n")) return { line: p.line, col: p.col + text.length };
  const lines = text.split("\n");
  return {
    line: p.line + lines.length - 1,
    col: lines[lines.length - 1].length,
  };
}

// Character step that treats one grapheme cluster as one move — so arrows and
// backspace skip over emoji surrogate pairs, VS-16 sequences (⬛️), ZWJ
// sequences (👨‍👩‍👧), regional-indicator flag pairs, and combining marks
// as a single visual glyph.
function moveChar(buffer: Buffer, p: Pos, dir: -1 | 1): Pos {
  if (dir === 1) {
    const lineText = buffer.getLine(p.line);
    if (p.col < lineText.length) {
      return { line: p.line, col: nextGrapheme(lineText, p.col) };
    }
    if (p.line < buffer.lineCount - 1) return { line: p.line + 1, col: 0 };
    return p;
  } else {
    if (p.col > 0) {
      const lineText = buffer.getLine(p.line);
      return { line: p.line, col: prevGrapheme(lineText, p.col) };
    }
    if (p.line > 0) return { line: p.line - 1, col: buffer.getLine(p.line - 1).length };
    return p;
  }
}

function moveWord(buffer: Buffer, p: Pos, dir: -1 | 1): Pos {
  const line = buffer.getLine(p.line);
  if (dir === 1 && p.col >= line.length) return moveChar(buffer, p, 1);
  if (dir === -1 && p.col === 0) return moveChar(buffer, p, -1);
  return { line: p.line, col: wordBoundary(line, p.col, dir) };
}

function moveLine(buffer: Buffer, p: Pos, dir: -1 | 1): Pos {
  const target = Math.max(0, Math.min(buffer.lineCount - 1, p.line + dir));
  return { line: target, col: Math.min(p.col, buffer.getLine(target).length) };
}

function clampCursor(cursor: CursorState, buffer: Buffer): CursorState {
  const clamp = (p: Pos): Pos => {
    const line = Math.max(0, Math.min(buffer.lineCount - 1, p.line));
    return { line, col: Math.max(0, Math.min(buffer.getLine(line).length, p.col)) };
  };
  return {
    ...cursor,
    selections: cursor.selections.map((s) => ({ anchor: clamp(s.anchor), head: clamp(s.head) })),
  };
}

export function keymap(e: KeyboardEvent, pageLines: number): Command | null {
  const meta = e.metaKey || e.ctrlKey;
  const shift = e.shiftKey;
  const alt = e.altKey;
  const k = e.key;

  if (meta && !shift && !alt) {
    if (k === "z") return { type: "undo" };
    if (k === "a") return { type: "select_all" };
    if (k === "ArrowLeft") return { type: "move_home", extend: false };
    if (k === "ArrowRight") return { type: "move_end", extend: false };
    if (k === "ArrowUp") return { type: "move_doc_edge", dir: -1, extend: false };
    if (k === "ArrowDown") return { type: "move_doc_edge", dir: 1, extend: false };
  }
  if (meta && shift && !alt) {
    if (k === "z" || k === "Z") return { type: "redo" };
    if (k === "ArrowLeft") return { type: "move_home", extend: true };
    if (k === "ArrowRight") return { type: "move_end", extend: true };
    if (k === "ArrowUp") return { type: "move_doc_edge", dir: -1, extend: true };
    if (k === "ArrowDown") return { type: "move_doc_edge", dir: 1, extend: true };
  }
  if (alt && !meta) {
    if (k === "ArrowLeft") return { type: "move", by: "word", dir: -1, extend: shift };
    if (k === "ArrowRight") return { type: "move", by: "word", dir: 1, extend: shift };
  }
  if (!meta && !alt) {
    if (k === "ArrowLeft") return { type: "move", by: "char", dir: -1, extend: shift };
    if (k === "ArrowRight") return { type: "move", by: "char", dir: 1, extend: shift };
    if (k === "ArrowUp") return { type: "move", by: "line", dir: -1, extend: shift };
    if (k === "ArrowDown") return { type: "move", by: "line", dir: 1, extend: shift };
    if (k === "Home") return { type: "move_home", extend: shift };
    if (k === "End") return { type: "move_end", extend: shift };
    if (k === "PageUp") return { type: "page", dir: -1, extend: shift, pageLines };
    if (k === "PageDown") return { type: "page", dir: 1, extend: shift, pageLines };
    if (k === "Backspace") return { type: "backspace" };
    if (k === "Delete") return { type: "delete" };
    if (k === "Enter") return { type: "newline" };
    if (k === "Tab") return { type: "insert", text: "\t" };
  }
  return null;
}

export { INITIAL_CURSOR };
