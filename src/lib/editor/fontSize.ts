import { writable } from "svelte/store";

const KEY = "nova:editorFontSize";
const DEFAULT = 13;
const MIN = 8;
const MAX = 48;

function initial(): number {
  if (typeof localStorage === "undefined") return DEFAULT;
  const raw = localStorage.getItem(KEY);
  const n = raw == null ? NaN : Number(raw);
  return Number.isFinite(n) && n >= MIN && n <= MAX ? n : DEFAULT;
}

export const editorFontSize = writable<number>(initial());

if (typeof localStorage !== "undefined") {
  editorFontSize.subscribe((v) => {
    try {
      localStorage.setItem(KEY, String(v));
    } catch {}
  });
}

export function zoomIn(): void {
  editorFontSize.update((v) => Math.min(MAX, v + 1));
}
export function zoomOut(): void {
  editorFontSize.update((v) => Math.max(MIN, v - 1));
}
export function zoomReset(): void {
  editorFontSize.set(DEFAULT);
}
