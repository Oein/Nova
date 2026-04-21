import type { Pos } from "./buffer/Buffer";

export interface Selection {
  anchor: Pos;
  head: Pos;
}

export interface CursorState {
  selections: Selection[];
  primary: number;
}

export const INITIAL_CURSOR: CursorState = {
  selections: [{ anchor: { line: 0, col: 0 }, head: { line: 0, col: 0 } }],
  primary: 0,
};

export function isEmpty(sel: Selection): boolean {
  return sel.anchor.line === sel.head.line && sel.anchor.col === sel.head.col;
}

export function ordered(sel: Selection): { from: Pos; to: Pos } {
  const { anchor, head } = sel;
  if (
    anchor.line < head.line ||
    (anchor.line === head.line && anchor.col <= head.col)
  ) {
    return { from: anchor, to: head };
  }
  return { from: head, to: anchor };
}

export function primary(c: CursorState): Selection {
  return c.selections[c.primary] ?? c.selections[0];
}

export function withPrimary(c: CursorState, s: Selection): CursorState {
  const sels = [...c.selections];
  sels[c.primary] = s;
  return { ...c, selections: sels };
}
