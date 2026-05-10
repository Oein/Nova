import type {
  Note,
  NoteContent,
  OpenWorkspaceResult,
  SearchHit,
  Session,
  SessionTab,
  TrashedNote,
} from "../types";
import { seedFixtures, ROOT, firstLineTitle } from "./fixtures";

interface MockNote {
  id: string;
  title: string;
  createdMs: number;
  mtimeMs: number;
  size: number;
  content: string;
  deletedAtMs: number | null;
}

const notes: Map<string, MockNote> = new Map();
const sessionTabs: Map<string, SessionTab> = new Map();
let activeTabId: string | null = null;
let seeded = false;

function ensureSeeded() {
  if (!seeded) {
    seedFixtures((n) => notes.set(n.id, { ...n, deletedAtMs: null }));
    seeded = true;
  }
}

function activeNotes(): MockNote[] {
  return [...notes.values()].filter((n) => n.deletedAtMs == null);
}

function toNote(n: MockNote): Note {
  return {
    id: n.id,
    title: n.title,
    createdMs: n.createdMs,
    mtimeMs: n.mtimeMs,
    size: n.size,
  };
}

let uuidCounter = 1000;
function uuid(): string {
  uuidCounter += 1;
  return `note-${uuidCounter}`;
}

export const mockBackend = {
  async pickWorkspace(): Promise<string | null> {
    ensureSeeded();
    return ROOT;
  },

  async openWorkspace(_path: string): Promise<OpenWorkspaceResult> {
    ensureSeeded();
    return {
      root: ROOT,
      notes: activeNotes().map(toNote),
      session: {
        tabs: [...sessionTabs.values()].sort((a, b) => a.position - b.position),
        activeTab: activeTabId,
      },
    };
  },

  async listNotes(): Promise<Note[]> {
    ensureSeeded();
    return activeNotes().map(toNote);
  },

  async createNote(): Promise<Note> {
    ensureSeeded();
    const id = uuid();
    const now = Date.now();
    const n: MockNote = {
      id,
      title: "Untitled",
      createdMs: now,
      mtimeMs: now,
      size: 0,
      content: "",
      deletedAtMs: null,
    };
    notes.set(id, n);
    return toNote(n);
  },

  async readNote(id: string): Promise<NoteContent> {
    ensureSeeded();
    const n = notes.get(id);
    if (!n) throw new Error("note not found: " + id);
    return {
      id: n.id,
      content: n.content,
      mtimeMs: n.mtimeMs,
      size: n.size,
    };
  },

  async writeNote(
    id: string,
    content: string,
    expectedMtimeMs: number | null,
  ): Promise<Note> {
    ensureSeeded();
    const n = notes.get(id);
    if (!n) throw new Error("note not found: " + id);
    if (expectedMtimeMs != null && expectedMtimeMs !== n.mtimeMs) {
      throw new Error("mtime mismatch");
    }
    n.content = content;
    n.size = new TextEncoder().encode(content).length;
    n.mtimeMs = Date.now();
    n.title = firstLineTitle(content, "Untitled");
    return toNote(n);
  },

  async deleteNote(id: string): Promise<void> {
    ensureSeeded();
    const n = notes.get(id);
    if (!n) return;
    n.deletedAtMs = Date.now();
    sessionTabs.delete(id);
  },

  async hardDeleteNote(id: string): Promise<void> {
    ensureSeeded();
    notes.delete(id);
    sessionTabs.delete(id);
  },

  async listTrashedNotes(): Promise<TrashedNote[]> {
    ensureSeeded();
    return [...notes.values()]
      .filter((n) => n.deletedAtMs != null)
      .sort((a, b) => (b.deletedAtMs ?? 0) - (a.deletedAtMs ?? 0))
      .map((n) => ({
        id: n.id,
        title: n.title,
        deletedAtMs: n.deletedAtMs ?? 0,
        size: n.size,
      }));
  },

  async restoreNote(id: string): Promise<Note> {
    ensureSeeded();
    const n = notes.get(id);
    if (!n) throw new Error("note not found: " + id);
    n.deletedAtMs = null;
    n.mtimeMs = Date.now();
    return toNote(n);
  },

  async purgeTrashedNote(id: string): Promise<void> {
    ensureSeeded();
    notes.delete(id);
    sessionTabs.delete(id);
  },

  async searchNotes(query: string, limit?: number): Promise<SearchHit[]> {
    ensureSeeded();
    const q = query.toLowerCase().trim();
    if (q.length < 2) return [];
    const ctx = 30;
    const hits: SearchHit[] = [];
    for (const n of activeNotes()) {
      const title = n.title.toLowerCase();
      const body = n.content.toLowerCase();
      const titleHit = title.includes(q);
      const bodyIdx = body.indexOf(q);
      const bodyHit = bodyIdx >= 0;
      if (!titleHit && !bodyHit) continue;
      let snippet: SearchHit["snippet"] = null;
      if (bodyHit) {
        const start = Math.max(0, bodyIdx - ctx);
        const end = Math.min(n.content.length, bodyIdx + q.length + ctx);
        const clean = (s: string) => s.replace(/[\n\r\t]/g, " ");
        snippet = {
          before: clean(n.content.slice(start, bodyIdx)),
          matched: clean(n.content.slice(bodyIdx, bodyIdx + q.length)),
          after: clean(n.content.slice(bodyIdx + q.length, end)),
          prefixEllipsis: start > 0,
          suffixEllipsis: end < n.content.length,
        };
      }
      hits.push({
        id: n.id,
        title: n.title,
        mtimeMs: n.mtimeMs,
        score: titleHit ? -10 : -1,
        snippet,
      });
    }
    hits.sort((a, b) => a.score - b.score);
    return hits.slice(0, limit ?? 30);
  },

  async getSession(): Promise<Session> {
    ensureSeeded();
    return {
      tabs: [...sessionTabs.values()].sort((a, b) => a.position - b.position),
      activeTab: activeTabId,
    };
  },

  async saveSession(session: Session): Promise<void> {
    sessionTabs.clear();
    for (const t of session.tabs) sessionTabs.set(t.noteId, t);
    activeTabId = session.activeTab;
  },

  async saveTabState(tab: SessionTab): Promise<void> {
    sessionTabs.set(tab.noteId, tab);
  },

  async setActiveTab(active: string | null): Promise<void> {
    activeTabId = active;
  },

  async removeTabState(id: string): Promise<void> {
    sessionTabs.delete(id);
  },

  async revealNote(_id: string): Promise<void> {
    // Mock backend doesn't have a real filesystem — no-op so UI flows work.
  },
};

export const mockBackendTestHooks = {
  reset() {
    notes.clear();
    sessionTabs.clear();
    activeTabId = null;
    seeded = false;
  },
  seed() {
    notes.clear();
    sessionTabs.clear();
    activeTabId = null;
    seeded = false;
    ensureSeeded();
  },
  getNote(id: string): MockNote | undefined {
    return notes.get(id);
  },
  listIds(): string[] {
    return [...notes.keys()];
  },
  touch(id: string, mtimeMs?: number) {
    const n = notes.get(id);
    if (!n) throw new Error("not found: " + id);
    n.mtimeMs = mtimeMs ?? Date.now();
  },
  seedSessionTab(tab: SessionTab) {
    sessionTabs.set(tab.noteId, tab);
  },
  setActive(id: string | null) {
    activeTabId = id;
  },
  getSessionSnapshot(): Session {
    return {
      tabs: [...sessionTabs.values()].sort((a, b) => a.position - b.position),
      activeTab: activeTabId,
    };
  },
};

if (typeof window !== "undefined") {
  (window as unknown as { __mock: typeof mockBackendTestHooks }).__mock =
    mockBackendTestHooks;
}
