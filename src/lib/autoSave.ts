import { get } from "svelte/store";
import { dirtyTabs } from "./stores/tabs";
import { saveTab } from "./tabManager";
import { autoSaveEnabled, autoSaveIntervalSec } from "./stores/settings";

// Periodic disk auto-save. Distinct from the session autoflush in
// sessionManager.ts (which persists cursor/scroll/unsaved buffer to the DB so
// edits survive a crash) — this writes dirty notes out to their actual files
// on a user-configurable interval, the same as hitting Cmd+S, just quietly.

let timer: ReturnType<typeof setInterval> | null = null;
// Guards against overlapping ticks: a slow write shouldn't pile up behind the
// next interval fire.
let running = false;

async function runAutoSave(): Promise<void> {
  if (running) return;
  const ids = [...get(dirtyTabs)];
  if (ids.length === 0) return;
  running = true;
  try {
    for (const id of ids) {
      // Re-check on each iteration: a manual save (or close) between scheduling
      // and now may have cleaned/removed this tab.
      if (!get(dirtyTabs).has(id)) continue;
      // Silent — no "Saved" toast spam every interval. saveTab still surfaces
      // failures, which are rare and worth knowing about.
      await saveTab(id, { silent: true });
    }
  } finally {
    running = false;
  }
}

function clearTimer(): void {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

function reschedule(enabled: boolean, intervalSec: number): void {
  clearTimer();
  if (!enabled) return;
  const ms = Math.max(1, intervalSec) * 1000;
  timer = setInterval(() => {
    void runAutoSave();
  }, ms);
}

/**
 * Start the auto-save loop. Re-arms whenever the enabled flag or interval
 * changes. Returns a stop function that tears down subscriptions and clears
 * the timer.
 */
export function startAutoSave(): () => void {
  let enabled = get(autoSaveEnabled);
  let intervalSec = get(autoSaveIntervalSec);
  // Svelte stores fire synchronously on subscribe; skip reacting until both
  // initial values are captured, then arm once.
  let ready = false;
  const apply = () => reschedule(enabled, intervalSec);

  const unsubEnabled = autoSaveEnabled.subscribe((v) => {
    enabled = v;
    if (ready) apply();
  });
  const unsubInterval = autoSaveIntervalSec.subscribe((v) => {
    intervalSec = v;
    if (ready) apply();
  });

  ready = true;
  apply();

  return () => {
    unsubEnabled();
    unsubInterval();
    clearTimer();
  };
}

// Exposed for unit tests only.
export const __testing = { runAutoSave, reschedule, clearTimer };
