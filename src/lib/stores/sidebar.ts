import { writable } from "svelte/store";

const WIDTH_KEY = "nova:sidebarWidth";
const COLLAPSED_KEY = "nova:sidebarCollapsed";

export const SIDEBAR_MIN = 160;
export const SIDEBAR_MAX = 600;
const DEFAULT = 260;

function initWidth(): number {
  if (typeof localStorage === "undefined") return DEFAULT;
  const raw = localStorage.getItem(WIDTH_KEY);
  const n = raw == null ? NaN : Number(raw);
  return Number.isFinite(n) && n >= SIDEBAR_MIN && n <= SIDEBAR_MAX ? n : DEFAULT;
}

function initCollapsed(): boolean {
  if (typeof localStorage === "undefined") return false;
  return localStorage.getItem(COLLAPSED_KEY) === "1";
}

export const sidebarWidth = writable<number>(initWidth());
export const sidebarCollapsed = writable<boolean>(initCollapsed());

if (typeof localStorage !== "undefined") {
  sidebarWidth.subscribe((v) => {
    try {
      localStorage.setItem(WIDTH_KEY, String(v));
    } catch {
      /* quota / SSR */
    }
  });
  sidebarCollapsed.subscribe((v) => {
    try {
      localStorage.setItem(COLLAPSED_KEY, v ? "1" : "0");
    } catch {
      /* quota / SSR */
    }
  });
}

export function toggleSidebar(): void {
  sidebarCollapsed.update((v) => !v);
}
