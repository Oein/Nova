import { writable } from "svelte/store";

// User-facing application settings. Persisted to localStorage so they survive
// restarts, mirroring the pattern used by editorFontSize / sidebar stores.
const ENABLED_KEY = "nova:autoSaveEnabled";
const INTERVAL_KEY = "nova:autoSaveIntervalSec";

// Interval is stored in whole seconds. The clamp range keeps the timer from
// hammering the disk (too low) or being effectively off (too high).
export const AUTOSAVE_MIN_SEC = 5;
export const AUTOSAVE_MAX_SEC = 3600;
export const AUTOSAVE_DEFAULT_SEC = 30;

// Preset choices surfaced in the Settings dialog. Custom values typed in still
// work — these are just the common ones.
export const AUTOSAVE_PRESETS: { label: string; sec: number }[] = [
  { label: "5 seconds", sec: 5 },
  { label: "10 seconds", sec: 10 },
  { label: "30 seconds", sec: 30 },
  { label: "1 minute", sec: 60 },
  { label: "2 minutes", sec: 120 },
  { label: "5 minutes", sec: 300 },
  { label: "10 minutes", sec: 600 },
];

export function clampInterval(sec: number): number {
  if (!Number.isFinite(sec)) return AUTOSAVE_DEFAULT_SEC;
  return Math.max(AUTOSAVE_MIN_SEC, Math.min(AUTOSAVE_MAX_SEC, Math.round(sec)));
}

function initEnabled(): boolean {
  if (typeof localStorage === "undefined") return true;
  const raw = localStorage.getItem(ENABLED_KEY);
  // Default ON for first-run; only an explicit "0" disables it.
  return raw == null ? true : raw === "1";
}

function initInterval(): number {
  if (typeof localStorage === "undefined") return AUTOSAVE_DEFAULT_SEC;
  const raw = localStorage.getItem(INTERVAL_KEY);
  const n = raw == null ? NaN : Number(raw);
  return Number.isFinite(n) && n >= AUTOSAVE_MIN_SEC && n <= AUTOSAVE_MAX_SEC
    ? n
    : AUTOSAVE_DEFAULT_SEC;
}

export const autoSaveEnabled = writable<boolean>(initEnabled());
export const autoSaveIntervalSec = writable<number>(initInterval());

// Controls visibility of the Settings modal (opened via Cmd+, the menu, or the
// bottom-bar gear).
export const settingsOpen = writable<boolean>(false);

if (typeof localStorage !== "undefined") {
  autoSaveEnabled.subscribe((v) => {
    try {
      localStorage.setItem(ENABLED_KEY, v ? "1" : "0");
    } catch {
      /* quota / SSR */
    }
  });
  autoSaveIntervalSec.subscribe((v) => {
    try {
      localStorage.setItem(INTERVAL_KEY, String(v));
    } catch {
      /* quota / SSR */
    }
  });
}

// Set the interval, clamping out-of-range / non-numeric input to a safe value.
export function setAutoSaveInterval(sec: number): void {
  autoSaveIntervalSec.set(clampInterval(sec));
}
