import { writable } from "svelte/store";

export interface EditorStatus {
  line: number;
  col: number;
  selectionChars: number;
}

export const editorStatus = writable<EditorStatus | null>(null);
