import { writable } from "svelte/store";

export interface EditorStatus {
  line: number;
  col: number;
  selectionChars: number;
  /** Selection char count excluding whitespace (spaces, tabs, line breaks). */
  selectionCharsNoWs: number;
}

export const editorStatus = writable<EditorStatus | null>(null);
