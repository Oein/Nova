import type { Buffer, BufferChange, Edit, Pos } from "./Buffer";

/// Each group is a list of edits that, when applied in array order, undo
/// (or redo) one user-visible action. A single keystroke becomes a one-edit
/// group; a typing burst coalesces into a multi-edit group.
export interface RopeSnapshot {
  undoStack: Edit[][];
  redoStack: Edit[][];
}

/**
 * RopeBuffer — an editable buffer for small files (≤ 16 MB).
 *
 * Implementation note: "rope" here is spiritual. The concrete data structure is
 * a flat array of lines (`lines: string[]`). Inserts/deletes mutate at most the
 * few affected lines. For ≤16 MB (≈200k lines worst case) this is O(k) per
 * local edit where k = lines touched, which is sub-millisecond in practice.
 * The Buffer interface hides this so the layer can be swapped for a real tree
 * rope later without touching the renderer.
 */
export class RopeBuffer implements Buffer {
  readonly editable = true;

  private lines: string[];
  private listeners = new Set<(c: BufferChange) => void>();
  // Stack of undo groups. Each group is the list of inverse edits to apply
  // (in array order) to revert one user-visible action.
  private undoStack: Edit[][] = [];
  private redoStack: Edit[][] = [];
  // Open coalescing group. Built up in recording order; reversed on flush so
  // the stored group undoes the burst in last-first order.
  private txGroup: Edit[] | null = null;
  private txExpires = 0;
  private readonly coalesceMs = 500;
  private path: string;
  private _mtimeMs: number;

  private constructor(path: string, text: string, mtimeMs: number) {
    this.path = path;
    this._mtimeMs = mtimeMs;
    this.lines = splitLines(text);
  }

  static fromString(text: string, path = "mem://scratch", mtimeMs = Date.now()): RopeBuffer {
    return new RopeBuffer(path, text, mtimeMs);
  }

  serialize(): RopeSnapshot {
    this.flushTx();
    return {
      undoStack: this.undoStack.map(cloneGroup),
      redoStack: this.redoStack.map(cloneGroup),
    };
  }

  restore(snapshot: RopeSnapshot): void {
    this.flushTx();
    this.undoStack = (snapshot.undoStack ?? []).map(normalizeGroup);
    this.redoStack = (snapshot.redoStack ?? []).map(normalizeGroup);
  }

  get lineCount(): number {
    return this.lines.length;
  }

  get mtimeMs(): number {
    return this._mtimeMs;
  }

  getLine(i: number): string {
    return this.lines[i] ?? "";
  }

  subscribe(fn: (c: BufferChange) => void): () => void {
    this.listeners.add(fn);
    fn({ kind: "ready" });
    return () => {
      this.listeners.delete(fn);
    };
  }

  private emit(change: BufferChange) {
    this.listeners.forEach((l) => l(change));
  }

  applyEdit(edit: Edit): void {
    const inverse = this.applyEditInternal(edit);
    this.recordUndo(inverse);
    this.redoStack.length = 0;
  }

  private applyEditInternal(edit: Edit): Edit {
    if (edit.kind === "insert") {
      return this.insertAt(edit.at, edit.text);
    } else {
      return this.deleteRange(edit.from, edit.to);
    }
  }

  private insertAt(at: Pos, text: string): Edit {
    const clamped = this.clampPos(at);
    const { line, col } = clamped;
    const inserted = splitLines(text);
    const current = this.lines[line] ?? "";
    const before = current.slice(0, col);
    const after = current.slice(col);
    let endLine = line;
    let endCol = col + text.length;

    if (inserted.length === 1) {
      this.lines[line] = before + inserted[0] + after;
      endCol = col + inserted[0].length;
      this.emit({ kind: "replace", fromLine: line, toLine: line + 1, newLineCount: 1 });
    } else {
      const newLines = [...inserted];
      newLines[0] = before + newLines[0];
      const lastIdx = newLines.length - 1;
      endCol = newLines[lastIdx].length;
      newLines[lastIdx] = newLines[lastIdx] + after;
      this.lines.splice(line, 1, ...newLines);
      endLine = line + lastIdx;
      this.emit({
        kind: "replace",
        fromLine: line,
        toLine: line + 1,
        newLineCount: newLines.length,
      });
    }

    return {
      kind: "delete",
      from: clamped,
      to: { line: endLine, col: endCol },
    };
  }

  private deleteRange(from: Pos, to: Pos): Edit {
    const [a, b] = orderedPositions(this.clampPos(from), this.clampPos(to));
    if (a.line === b.line && a.col === b.col) {
      return { kind: "insert", at: a, text: "" };
    }
    const deletedText = this.sliceText(a, b);
    if (a.line === b.line) {
      const ln = this.lines[a.line];
      this.lines[a.line] = ln.slice(0, a.col) + ln.slice(b.col);
      this.emit({ kind: "replace", fromLine: a.line, toLine: a.line + 1, newLineCount: 1 });
    } else {
      const head = this.lines[a.line].slice(0, a.col);
      const tail = this.lines[b.line].slice(b.col);
      const spanLen = b.line - a.line + 1;
      this.lines.splice(a.line, spanLen, head + tail);
      this.emit({
        kind: "replace",
        fromLine: a.line,
        toLine: b.line + 1,
        newLineCount: 1,
      });
    }
    return { kind: "insert", at: a, text: deletedText };
  }

  sliceText(a: Pos, b: Pos): string {
    if (a.line === b.line) return this.lines[a.line].slice(a.col, b.col);
    const out: string[] = [this.lines[a.line].slice(a.col)];
    for (let i = a.line + 1; i < b.line; i++) out.push(this.lines[i]);
    out.push(this.lines[b.line].slice(0, b.col));
    return out.join("\n");
  }

  clampPos(p: Pos): Pos {
    const line = Math.max(0, Math.min(this.lines.length - 1, p.line));
    const col = Math.max(0, Math.min((this.lines[line] ?? "").length, p.col));
    return { line, col };
  }

  private recordUndo(inverse: Edit) {
    const now = Date.now();
    const last = this.txGroup?.[this.txGroup.length - 1];
    if (this.txGroup && last && now < this.txExpires && canCoalesce(last, inverse)) {
      this.txGroup.push(inverse);
      this.txExpires = now + this.coalesceMs;
    } else {
      this.flushTx();
      this.txGroup = [inverse];
      this.txExpires = now + this.coalesceMs;
    }
  }

  private flushTx() {
    if (this.txGroup && this.txGroup.length > 0) {
      // Inverses were recorded in insertion order; to replay them as a
      // single undo step we apply them last-first.
      this.undoStack.push(this.txGroup.slice().reverse());
    }
    this.txGroup = null;
    this.txExpires = 0;
  }

  undo(): Pos | null {
    this.flushTx();
    const group = this.undoStack.pop();
    if (!group || group.length === 0) return null;
    const redoGroup: Edit[] = [];
    let cursor: Pos | null = null;
    for (const edit of group) {
      redoGroup.push(this.applyEditInternal(edit));
      cursor = caretAfter(edit);
    }
    // Flip order so redo replays the user's original sequence head-first.
    this.redoStack.push(redoGroup.reverse());
    return cursor;
  }

  redo(): Pos | null {
    this.flushTx();
    const group = this.redoStack.pop();
    if (!group || group.length === 0) return null;
    const undoGroup: Edit[] = [];
    let cursor: Pos | null = null;
    for (const edit of group) {
      undoGroup.push(this.applyEditInternal(edit));
      cursor = caretAfter(edit);
    }
    this.undoStack.push(undoGroup.reverse());
    return cursor;
  }

  toString(): string {
    return this.lines.join("\n");
  }

  markSaved(mtimeMs: number) {
    this._mtimeMs = mtimeMs;
    this.flushTx();
  }
}

export function splitLines(text: string): string[] {
  if (text === "") return [""];
  // Split on \n but keep empty trailing element logic: "a\n" -> ["a", ""]
  return text.split("\n");
}

function orderedPositions(a: Pos, b: Pos): [Pos, Pos] {
  if (a.line < b.line || (a.line === b.line && a.col <= b.col)) return [a, b];
  return [b, a];
}

function cloneEdit(e: Edit): Edit {
  if (e.kind === "insert") return { kind: "insert", at: { ...e.at }, text: e.text };
  return { kind: "delete", from: { ...e.from }, to: { ...e.to } };
}

function cloneGroup(g: Edit[]): Edit[] {
  return g.map(cloneEdit);
}

/// Tolerates pre-v2 snapshots that stored a flat `Edit[]`. Pre-v2 entries
/// lose their coalescing granularity but stay individually undoable.
function normalizeGroup(g: Edit[] | Edit): Edit[] {
  if (Array.isArray(g)) return g.map(cloneEdit);
  return [cloneEdit(g)];
}

function caretAfter(applied: Edit): Pos {
  if (applied.kind === "delete") return { ...applied.from };
  // Re-insert: caret lands at end of the re-inserted text.
  const lines = applied.text.split("\n");
  if (lines.length === 1) return { line: applied.at.line, col: applied.at.col + applied.text.length };
  return {
    line: applied.at.line + lines.length - 1,
    col: lines[lines.length - 1].length,
  };
}

function canCoalesce(first: Edit, next: Edit): boolean {
  // Coalesce only pure single-char inserts/deletes on the same line
  if (first.kind !== next.kind) return false;
  if (first.kind === "delete" && next.kind === "delete") {
    const a = first.to;
    const b = next.to;
    return a.line === b.line && Math.abs(a.col - b.col) <= 1;
  }
  if (first.kind === "insert" && next.kind === "insert") {
    // when coalescing inverse edits, both are `insert` (re-inserting)
    const a = first.at;
    const b = next.at;
    return a.line === b.line && Math.abs(a.col - b.col) <= 1;
  }
  return false;
}
