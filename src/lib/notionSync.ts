import { get } from "svelte/store";
import { isMock } from "./ipc";
import { workspacePath } from "./stores/workspace";
import {
  applyChanges,
  loadNotionConfig,
  notionConfig,
  refreshConflicts,
  runSync,
  syncProgress,
} from "./stores/notion";
import type { SyncProgress } from "./types";

// Background Notion sync: the periodic timer, the one-shot on workspace open,
// and the backend event subscriptions. Mirrors the shape of autoSave.ts —
// re-arming on config change, guarding against overlapping runs — but the
// interval lives in workspace.db rather than localStorage, because a Notion
// connection belongs to a workspace, not to the app.

let timer: ReturnType<typeof setInterval> | null = null;
/** Ensures the "sync when the app opens" pass runs once per workspace, not
 *  once per config change. */
let startupDoneFor: string | null = null;
/** Delay before the boot sync so it doesn't compete with session restore. */
const STARTUP_DELAY_MS = 2000;
let startupTimer: ReturnType<typeof setTimeout> | null = null;

function clearTimer(): void {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

function clearStartup(): void {
  if (startupTimer) {
    clearTimeout(startupTimer);
    startupTimer = null;
  }
}

function reschedule(enabled: boolean, intervalSec: number): void {
  clearTimer();
  if (!enabled) return;
  // The backend clamps this too; guard here so a bad stored value can't spin.
  const ms = Math.max(60, intervalSec) * 1000;
  timer = setInterval(() => {
    void runSync({ silent: true });
  }, ms);
}

/** Re-reads the config for the current workspace and arms the timer and the
 *  one-shot startup sync accordingly. */
async function applyConfig(path: string | null): Promise<void> {
  clearTimer();
  clearStartup();
  if (!path) {
    startupDoneFor = null;
    return;
  }
  const cfg = await loadNotionConfig();
  await refreshConflicts();
  if (!cfg?.enabled || !cfg.tokenSet || !cfg.databaseId) return;

  reschedule(cfg.autoSync, cfg.intervalSec);
  if (cfg.syncOnStart && startupDoneFor !== path) {
    startupDoneFor = path;
    startupTimer = setTimeout(() => {
      void runSync({ silent: true });
    }, STARTUP_DELAY_MS);
  }
}

/**
 * Starts the background sync machinery. Returns a stop function that tears
 * down subscriptions, timers and event listeners.
 */
export function startNotionSync(): () => void {
  let currentPath = get(workspacePath);
  const unsubPath = workspacePath.subscribe((p) => {
    currentPath = p;
    void applyConfig(p);
  });

  // Re-arm when the user changes the interval or toggles auto-sync in
  // Settings. The path subscription above covers workspace switches.
  let lastKey = "";
  const unsubCfg = notionConfig.subscribe((cfg) => {
    const key = cfg
      ? `${cfg.enabled}|${cfg.tokenSet}|${cfg.databaseId}|${cfg.autoSync}|${cfg.intervalSec}`
      : "";
    if (key === lastKey) return;
    lastKey = key;
    if (!cfg?.enabled || !cfg.tokenSet || !cfg.databaseId) {
      clearTimer();
      return;
    }
    reschedule(cfg.autoSync, cfg.intervalSec);
  });

  let unlisten: Array<() => void> = [];
  if (!isMock) {
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      unlisten.push(
        await listen<SyncProgress>("notion:progress", (e) => {
          // The backend sends a final tick with done === total; clearing on it
          // keeps the status bar from getting stuck at 100%.
          syncProgress.set(e.payload.total > 0 && e.payload.done < e.payload.total ? e.payload : null);
        }),
      );
      unlisten.push(
        await listen<string[]>("notion:changed", (e) => {
          void applyChanges({ changedNoteIds: e.payload ?? [] });
        }),
      );
    })();
  }

  void applyConfig(currentPath);

  return () => {
    unsubPath();
    unsubCfg();
    clearTimer();
    clearStartup();
    for (const off of unlisten) off();
    unlisten = [];
  };
}

// Exposed for unit tests only.
export const __testing = {
  reschedule,
  clearTimer,
  clearStartup,
  applyConfig,
  resetStartup: () => {
    startupDoneFor = null;
  },
  hasTimer: () => timer !== null,
  hasStartupTimer: () => startupTimer !== null,
};
