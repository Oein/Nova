export interface Pos {
  line: number;
  col: number;
}

export type Edit =
  | { kind: "insert"; at: Pos; text: string }
  | { kind: "delete"; from: Pos; to: Pos };

export type BufferChange =
  | { kind: "replace"; fromLine: number; toLine: number; newLineCount: number }
  | { kind: "ready" };

export interface Buffer {
  readonly editable: boolean;
  readonly lineCount: number;
  getLine(lineIndex: number): string;
  subscribe(fn: (c: BufferChange) => void): () => void;
  applyEdit(edit: Edit): void;
  /** Returns the post-edit caret position, or null if nothing was undone. */
  undo(): Pos | null;
  /** Returns the post-edit caret position, or null if nothing was redone. */
  redo(): Pos | null;
  toString(): string;
}

export class ReadOnlyError extends Error {
  constructor() {
    super("buffer is read-only");
  }
}
