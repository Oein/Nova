import { get } from "svelte/store";
import { ipc } from "./ipc";
import {
  openTabs,
  activeTabId,
  dirtyTabs,
  getBuffer,
  markDirty,
  setTabTitle,
} from "./stores/tabs";
import { setNoteTitle } from "./stores/workspace";
import { firstLineTitle } from "./title";
import { RopeBuffer } from "./editor/buffer/RopeBuffer";
import type { SessionTab } from "./types";

interface TabRuntimeState {
  cursorLine: number;
  cursorCol: number;
  scrollTop: number;
  // Cached latest content from the buffer so we can write it to the session
  // even if the user hasn't explicitly hit save.
  lastContent: string;
  diskContent: string;
}

const runtime = new Map<string, TabRuntimeState>();
const bufferUnsubs = new Map<string, () => void>();
const tabSaveTimers = new Map<string, ReturnType<typeof setTimeout>>();
const TAB_SAVE_DEBOUNCE_MS = 300;

let sessionFlushTimer: ReturnType<typeof setTimeout> | null = null;
const SESSION_FLUSH_DEBOUNCE_MS = 200;

export function attachBufferAutosave(
  id: string,
  buf: RopeBuffer,
  diskContent?: string,
): void {
  detachBufferAutosave(id);
  const current = buf.toString();
  runtime.set(id, {
    cursorLine: 0,
    cursorCol: 0,
    scrollTop: 0,
    lastContent: current,
    diskContent: diskContent ?? current,
  });
  updateDirty(id);
  // Seed the tab/sidebar title from the initial buffer content so restored
  // sessions with unsaved edits show the live title right away.
  const initialTitle = firstLineTitle(current);
  setTabTitle(id, initialTitle);
  setNoteTitle(id, initialTitle);
  const unsub = buf.subscribe((change) => {
    if (change.kind === "ready") return;
    const state = runtime.get(id);
    if (!state) return;
    state.lastContent = buf.toString();
    // Live title reflection — in-memory only; filename is unchanged until save.
    const title = firstLineTitle(state.lastContent);
    setTabTitle(id, title);
    setNoteTitle(id, title);
    updateDirty(id);
    scheduleTabSave(id);
  });
  bufferUnsubs.set(id, unsub);
}

function updateDirty(id: string): void {
  const s = runtime.get(id);
  if (!s) return;
  markDirty(id, s.lastContent !== s.diskContent);
}

export function detachBufferAutosave(id: string): void {
  const unsub = bufferUnsubs.get(id);
  if (unsub) unsub();
  bufferUnsubs.delete(id);
  const timer = tabSaveTimers.get(id);
  if (timer) clearTimeout(timer);
  tabSaveTimers.delete(id);
  runtime.delete(id);
}

export function getTabRuntime(
  id: string,
): { cursorLine: number; cursorCol: number; scrollTop: number } | null {
  const s = runtime.get(id);
  if (!s) return null;
  return { cursorLine: s.cursorLine, cursorCol: s.cursorCol, scrollTop: s.scrollTop };
}

export function updateCursor(id: string, line: number, col: number): void {
  const s = runtime.get(id);
  if (!s) return;
  if (s.cursorLine === line && s.cursorCol === col) return;
  s.cursorLine = line;
  s.cursorCol = col;
  scheduleTabSave(id);
}

export function updateScroll(id: string, top: number): void {
  const s = runtime.get(id);
  if (!s) return;
  if (s.scrollTop === top) return;
  s.scrollTop = top;
  scheduleTabSave(id);
}

/**
 * Mark the current buffer content as matching what's on disk — called right
 * after a successful save. After this, the tab is "clean" and we write
 * `unsavedContent: null` to the DB.
 */
export function markTabDiskContent(id: string, content: string): void {
  const s = runtime.get(id);
  if (!s) return;
  s.diskContent = content;
  updateDirty(id);
}

function scheduleTabSave(id: string): void {
  const existing = tabSaveTimers.get(id);
  if (existing) clearTimeout(existing);
  const t = setTimeout(() => {
    tabSaveTimers.delete(id);
    void persistTabState(id);
  }, TAB_SAVE_DEBOUNCE_MS);
  tabSaveTimers.set(id, t);
}

async function buildTabPayload(id: string, clearUnsaved = false): Promise<SessionTab | null> {
  const s = runtime.get(id);
  if (!s) return null;
  const tabs = get(openTabs);
  const position = tabs.findIndex((t) => t.id === id);
  if (position < 0) return null;
  const buf = getBuffer(id);
  const undoLog =
    buf instanceof RopeBuffer ? JSON.stringify(buf.serialize()) : null;
  const unsavedContent =
    clearUnsaved || s.lastContent === s.diskContent ? null : s.lastContent;
  return {
    noteId: id,
    position,
    cursorLine: s.cursorLine,
    cursorCol: s.cursorCol,
    scrollTop: s.scrollTop,
    unsavedContent,
    undoLog,
  };
}

async function persistTabState(id: string): Promise<void> {
  const payload = await buildTabPayload(id);
  if (!payload) return;
  try {
    await ipc.saveTabState(payload);
  } catch (err) {
    console.error("saveTabState failed", err);
  }
}

export async function saveTabStateImmediate(
  id: string,
  opts: { clearUnsaved?: boolean } = {},
): Promise<void> {
  const pendingTimer = tabSaveTimers.get(id);
  if (pendingTimer) {
    clearTimeout(pendingTimer);
    tabSaveTimers.delete(id);
  }
  if (opts.clearUnsaved) {
    const s = runtime.get(id);
    if (s) {
      s.diskContent = s.lastContent;
      updateDirty(id);
    }
  }
  const payload = await buildTabPayload(id, opts.clearUnsaved);
  if (!payload) return;
  try {
    await ipc.saveTabState(payload);
  } catch (err) {
    console.error("saveTabState failed", err);
  }
}

export function scheduleSessionFlush(): void {
  if (sessionFlushTimer) clearTimeout(sessionFlushTimer);
  sessionFlushTimer = setTimeout(() => {
    sessionFlushTimer = null;
    void flushSessionNow();
  }, SESSION_FLUSH_DEBOUNCE_MS);
}

export async function flushSessionNow(): Promise<void> {
  const tabs = get(openTabs);
  const active = get(activeTabId);
  const payloads: SessionTab[] = [];
  for (let i = 0; i < tabs.length; i++) {
    const id = tabs[i].id;
    const p = await buildTabPayload(id);
    if (p) {
      p.position = i;
      payloads.push(p);
    }
  }
  try {
    await ipc.saveSession({ tabs: payloads, activeTab: active });
  } catch (err) {
    console.error("saveSession failed", err);
  }
}

export function startSessionAutoflush(): () => void {
  const unsubTabs = openTabs.subscribe(() => scheduleSessionFlush());
  const unsubActive = activeTabId.subscribe((id) => {
    void ipc.setActiveTab(id).catch((err) => console.error(err));
  });
  const unsubDirty = dirtyTabs.subscribe(() => {}); // placeholder; dirty is derived
  const onBeforeUnload = () => {
    // Best effort: fire-and-forget. Browsers can't reliably await this.
    for (const id of runtime.keys()) {
      void saveTabStateImmediate(id);
    }
    void flushSessionNow();
  };
  if (typeof window !== "undefined") {
    window.addEventListener("beforeunload", onBeforeUnload);
  }
  return () => {
    unsubTabs();
    unsubActive();
    unsubDirty();
    if (typeof window !== "undefined") {
      window.removeEventListener("beforeunload", onBeforeUnload);
    }
  };
}
