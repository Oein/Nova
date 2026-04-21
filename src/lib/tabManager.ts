import { get } from "svelte/store";
import { ipc } from "./ipc";
import {
  openTabs,
  activeTabId,
  dirtyTabs,
  registerBuffer,
  getBuffer,
  dropBuffer,
  markDirty,
} from "./stores/tabs";
import { confirmClose } from "./stores/confirmClose";
import { RopeBuffer } from "./editor/buffer/RopeBuffer";
import { notes, upsertNote, workspacePath, touchNote, removeNote } from "./stores/workspace";
import { toast, selectedNoteIds, selectionAnchor } from "./stores/ui";
import type { OpenTab, SessionTab } from "./types";
import {
  attachBufferAutosave,
  detachBufferAutosave,
  markTabDiskContent,
  saveTabStateImmediate,
  scheduleSessionFlush,
} from "./sessionManager";

function titleOf(id: string): string {
  return get(notes).find((n) => n.id === id)?.title ?? "Untitled";
}

const LAST_WORKSPACE_KEY = "sublime-clone:lastWorkspace";

export async function loadWorkspace(path: string): Promise<void> {
  const { root, notes: list, session } = await ipc.openWorkspace(path);
  workspacePath.set(root);
  if (typeof localStorage !== "undefined") {
    try { localStorage.setItem(LAST_WORKSPACE_KEY, root); } catch {}
  }
  notes.set(list);
  // Close any existing tabs (switching workspaces).
  const existing = get(openTabs).map((t) => t.id);
  for (const id of existing) {
    dropBuffer(id);
  }
  openTabs.set([]);
  activeTabId.set(null);
  // Restore session tabs in order.
  for (const st of session.tabs) {
    try {
      await openNoteFromSession(st);
    } catch (err) {
      console.error("restore tab failed", st.noteId, err);
    }
  }
  if (session.activeTab) {
    activeTabId.set(session.activeTab);
  }
}

async function openNoteFromSession(st: SessionTab): Promise<void> {
  const meta = get(notes).find((n) => n.id === st.noteId);
  if (!meta) return; // note was deleted since session saved
  const disk = await ipc.readNote(st.noteId);
  const initial = st.unsavedContent ?? disk.content;
  const buf = RopeBuffer.fromString(initial, st.noteId, disk.mtimeMs);
  if (st.undoLog) {
    try {
      buf.restore(JSON.parse(st.undoLog));
    } catch {
      // corrupt undo log — ignore, keep buffer with just content
    }
  }
  registerBuffer(st.noteId, buf);
  const tab: OpenTab = {
    id: st.noteId,
    title: meta.title,
    mode: "rope",
    mtimeMs: disk.mtimeMs,
    initialCursor: { line: st.cursorLine, col: st.cursorCol },
    initialScroll: st.scrollTop,
  };
  openTabs.update((t) => [...t, tab]);
  attachBufferAutosave(st.noteId, buf, disk.content);
}

export async function openNote(id: string): Promise<void> {
  if (get(openTabs).some((t) => t.id === id)) {
    activeTabId.set(id);
    return;
  }
  try {
    const disk = await ipc.readNote(id);
    const buf = RopeBuffer.fromString(disk.content, id, disk.mtimeMs);
    registerBuffer(id, buf);
    const tab: OpenTab = {
      id,
      title: titleOf(id),
      mode: "rope",
      mtimeMs: disk.mtimeMs,
    };
    openTabs.update((t) => [...t, tab]);
    activeTabId.set(id);
    attachBufferAutosave(id, buf, disk.content);
  } catch (err) {
    console.error(err);
    toast("Failed to open note");
  }
}

export async function ensureWorkspace(): Promise<boolean> {
  if (get(workspacePath)) return true;
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(LAST_WORKSPACE_KEY);
    if (saved) {
      try {
        await loadWorkspace(saved);
        return true;
      } catch (err) {
        console.error("restore last workspace failed", err);
      }
    }
  }
  const picked = await ipc.pickWorkspace();
  if (!picked) return false;
  await loadWorkspace(picked);
  return true;
}

export async function createAndOpenNote(): Promise<void> {
  if (!(await ensureWorkspace())) return;
  const note = await ipc.createNote();
  upsertNote(note);
  const buf = RopeBuffer.fromString("", note.id, note.mtimeMs);
  registerBuffer(note.id, buf);
  const tab: OpenTab = {
    id: note.id,
    title: note.title,
    mode: "rope",
    mtimeMs: note.mtimeMs,
  };
  openTabs.update((t) => [...t, tab]);
  activeTabId.set(note.id);
  attachBufferAutosave(note.id, buf, "");
  scheduleSessionFlush();
}

export async function saveTab(id: string): Promise<boolean> {
  const buf = getBuffer(id);
  if (!buf || !(buf instanceof RopeBuffer)) return false;
  const tab = get(openTabs).find((t) => t.id === id);
  if (!tab) return false;
  try {
    const content = buf.toString();
    const note = await ipc.writeNote(id, content, tab.mtimeMs);
    touchNote(note.id, note.title, note.mtimeMs, note.size);
    openTabs.update((t) =>
      t.map((x) =>
        x.id === id ? { ...x, title: note.title, mtimeMs: note.mtimeMs } : x,
      ),
    );
    buf.markSaved(note.mtimeMs);
    markTabDiskContent(id, content);
    await saveTabStateImmediate(id, { clearUnsaved: true });
    toast("Saved");
    return true;
  } catch (err) {
    console.error(err);
    toast("Save failed");
    return false;
  }
}

export async function saveActive(): Promise<void> {
  const id = get(activeTabId);
  if (!id) return;
  await saveTab(id);
}

async function closeTabForce(id: string): Promise<void> {
  detachBufferAutosave(id);
  dropBuffer(id);
  openTabs.update((t) => t.filter((x) => x.id !== id));
  markDirty(id, false);
  if (get(activeTabId) === id) {
    const remaining = get(openTabs);
    const nextId = remaining[remaining.length - 1]?.id ?? null;
    activeTabId.set(nextId);
  }
  try {
    await ipc.removeTabState(id);
  } catch (err) {
    console.error("remove tab state failed", err);
  }
}

export async function deleteNotes(ids: string[]): Promise<void> {
  const openIds = new Set(get(openTabs).map((t) => t.id));
  for (const id of ids) {
    if (openIds.has(id)) {
      await closeTabForce(id);
    }
    try {
      await ipc.deleteNote(id);
      removeNote(id);
    } catch (err) {
      console.error("delete note failed", id, err);
      toast("Failed to delete note");
    }
  }
  selectedNoteIds.set(new Set());
  selectionAnchor.set(null);
  scheduleSessionFlush();
}

export async function closeNoteTab(id: string): Promise<void> {
  if (get(dirtyTabs).has(id)) {
    const tab = get(openTabs).find((t) => t.id === id);
    confirmClose.set({
      id,
      title: tab?.title ?? "Untitled",
      onSave: async () => {
        const ok = await saveTab(id);
        if (ok) await closeTabForce(id);
      },
      onDiscard: () => closeTabForce(id),
    });
    return;
  }
  await closeTabForce(id);
}
