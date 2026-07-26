import type {
  BulkResolvePolicy,
  BulkResolveResult,
  ConflictResolution,
  Note,
  NoteContent,
  NotionConfigInput,
  NotionConfigView,
  NotionConflict,
  NotionConflictDetail,
  NotionConnectionInfo,
  NotionDbSummary,
  OpenWorkspaceResult,
  SearchHit,
  Session,
  SessionTab,
  SyncReport,
  SyncReportItem,
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

// --- Notion sync -----------------------------------------------------------
// The real engine talks to api.notion.com from Rust. Here we replay a fixed
// scenario instead, so e2e can drive the sync UI and the conflict resolver
// deterministically: the first sync pulls one note and raises one conflict.

const PULL_TARGET = "note-2";
const CONFLICT_TARGET = "note-1";
// A second conflict of a different kind, so the bulk resolver has to map more
// than one kind and the "resolve all" bar is reachable (it needs 2+).
const DELETED_CONFLICT_TARGET = "note-3";
const PULLED_BODY = "# Weekly sync\n\nUpdated in Notion.\n";
const REMOTE_CONFLICT_BODY = "# Project ideas\n\nThe Notion version.\n";

function defaultNotionConfig(): NotionConfigView {
  return {
    tokenSet: false,
    tokenHint: "",
    databaseId: null,
    databaseTitle: null,
    titleProp: "Name",
    createdProp: null,
    updatedProp: null,
    idProp: null,
    enabled: false,
    syncOnStart: true,
    autoSync: true,
    intervalSec: 900,
    lastSyncMs: null,
    lastStatus: null,
    conflictCount: 0,
  };
}

let notionConfig = defaultNotionConfig();
const notionConflicts: Map<string, NotionConflictDetail> = new Map();
let notionSynced = false;

function notionView(): NotionConfigView {
  return { ...notionConfig, conflictCount: notionConflicts.size };
}

function emptyReport(): SyncReport {
  return {
    pulled: 0,
    pushed: 0,
    createdLocal: 0,
    createdRemote: 0,
    archivedRemote: 0,
    trashedLocal: 0,
    conflicts: 0,
    blocked: 0,
    errors: 0,
    cancelled: false,
    dryRun: false,
    items: [],
    changedNoteIds: [],
  };
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

  async notionGetConfig(): Promise<NotionConfigView> {
    return notionView();
  },

  async notionSetConfig(config: NotionConfigInput): Promise<NotionConfigView> {
    if (config.token !== undefined) {
      const t = config.token.trim();
      notionConfig.tokenSet = t.length > 0;
      notionConfig.tokenHint = t.slice(-4);
    }
    if (config.databaseId !== undefined) {
      const next = config.databaseId.trim() || null;
      // Repointing at another database invalidates every mapping, same as the
      // real backend.
      if (next !== notionConfig.databaseId) {
        notionConflicts.clear();
        notionSynced = false;
      }
      notionConfig.databaseId = next;
      notionConfig.databaseTitle = next ? "Mock Notes" : null;
    }
    if (config.databaseTitle !== undefined) {
      notionConfig.databaseTitle = config.databaseTitle;
    }
    for (const key of ["createdProp", "updatedProp", "idProp"] as const) {
      if (config[key] !== undefined) {
        notionConfig[key] = config[key]!.trim() || null;
      }
    }
    if (config.enabled !== undefined) notionConfig.enabled = config.enabled;
    if (config.syncOnStart !== undefined) notionConfig.syncOnStart = config.syncOnStart;
    if (config.autoSync !== undefined) notionConfig.autoSync = config.autoSync;
    if (config.intervalSec !== undefined) {
      notionConfig.intervalSec = Math.min(86400, Math.max(60, config.intervalSec));
    }
    return notionView();
  },

  async notionClearToken(): Promise<NotionConfigView> {
    notionConfig.tokenSet = false;
    notionConfig.tokenHint = "";
    notionConfig.enabled = false;
    return notionView();
  },

  async notionTestConnection(
    token?: string | null,
    databaseId?: string | null,
  ): Promise<NotionConnectionInfo> {
    if (!token && !notionConfig.tokenSet) throw new Error("Notion token is not set");
    return {
      botName: "Mock Integration",
      workspaceName: "Mock Workspace",
      databaseTitle: databaseId || notionConfig.databaseId ? "Mock Notes" : null,
      titleProp: "Name",
      pageCount: 3,
      propertyWarnings: [
        notionConfig.createdProp,
        notionConfig.updatedProp,
        notionConfig.idProp,
      ]
        .filter((n): n is string => !!n)
        .map((n) => `"${n}" will be created as a date property.`),
    };
  },

  async notionListDatabases(token?: string | null): Promise<NotionDbSummary[]> {
    if (!token && !notionConfig.tokenSet) throw new Error("Notion token is not set");
    return [
      { id: "mock-db-1", title: "Mock Notes", url: null },
      { id: "mock-db-2", title: "Archive", url: null },
    ];
  },

  async notionSync(dryRun?: boolean): Promise<SyncReport> {
    ensureSeeded();
    if (!notionConfig.databaseId) throw new Error("Notion database is not selected");
    const report = emptyReport();
    report.dryRun = dryRun ?? false;
    notionConfig.lastSyncMs = Date.now();
    if (notionSynced) {
      // A settled workspace: nothing to do, which is what the real engine
      // returns once baselines match.
      notionConfig.lastStatus = "ok";
      return report;
    }

    const item = (
      noteId: string,
      title: string,
      kind: SyncReportItem["kind"],
      severity: SyncReportItem["severity"],
      message: string | null = null,
    ): SyncReportItem => ({ noteId, pageId: `page-${noteId}`, title, kind, severity, message });

    const pulled = notes.get(PULL_TARGET);
    if (pulled) {
      if (!report.dryRun) {
        pulled.content = PULLED_BODY;
        pulled.title = firstLineTitle(PULLED_BODY, "Untitled");
        pulled.size = new TextEncoder().encode(PULLED_BODY).length;
        pulled.mtimeMs = Date.now();
      }
      report.pulled = 1;
      report.changedNoteIds.push(pulled.id);
      report.items.push(item(pulled.id, pulled.title, "pulled", "info"));
    }

    const conflicted = notes.get(CONFLICT_TARGET);
    if (conflicted) {
      if (!report.dryRun) {
        notionConflicts.set(conflicted.id, {
          noteId: conflicted.id,
          pageId: `page-${conflicted.id}`,
          kind: "both-changed",
          localTitle: conflicted.title,
          remoteTitle: firstLineTitle(REMOTE_CONFLICT_BODY, "Untitled"),
          detectedMs: Date.now(),
          localContent: conflicted.content,
          remoteContent: REMOTE_CONFLICT_BODY,
        });
      }
      report.conflicts = 1;
      report.items.push(
        item(
          conflicted.id,
          conflicted.title,
          "conflict",
          "warn",
          "Edited in both Nova and Notion.",
        ),
      );
    }

    const deleted = notes.get(DELETED_CONFLICT_TARGET);
    if (deleted) {
      if (!report.dryRun) {
        notionConflicts.set(deleted.id, {
          noteId: deleted.id,
          pageId: null,
          kind: "remote-deleted",
          localTitle: deleted.title,
          remoteTitle: null,
          detectedMs: Date.now() - 1000,
          localContent: deleted.content,
          remoteContent: null,
        });
      }
      report.conflicts += 1;
      report.items.push(
        item(
          deleted.id,
          deleted.title,
          "conflict",
          "warn",
          "Deleted in Notion but edited in Nova.",
        ),
      );
    }

    if (!report.dryRun) notionSynced = true;
    notionConfig.lastStatus = report.conflicts > 0 ? "partial" : "ok";
    return report;
  },

  async notionCancelSync(): Promise<void> {},

  async notionListConflicts(): Promise<NotionConflict[]> {
    return [...notionConflicts.values()]
      .sort((a, b) => b.detectedMs - a.detectedMs)
      .map(({ localContent: _l, remoteContent: _r, ...summary }) => summary);
  },

  async notionGetConflict(noteId: string): Promise<NotionConflictDetail | null> {
    return notionConflicts.get(noteId) ?? null;
  },

  async notionResolveConflict(
    noteId: string,
    resolution: ConflictResolution,
  ): Promise<void> {
    const conflict = notionConflicts.get(noteId);
    if (!conflict) throw new Error("no such conflict");
    const note = notes.get(noteId);
    if (resolution === "keepRemote" && note && conflict.remoteContent) {
      note.content = conflict.remoteContent;
      note.title = firstLineTitle(conflict.remoteContent, "Untitled");
      note.size = new TextEncoder().encode(conflict.remoteContent).length;
      note.mtimeMs = Date.now();
    } else if (resolution === "keepBoth" && conflict.remoteContent) {
      const id = uuid();
      const content = `# ${conflict.remoteTitle ?? "Untitled"} (Notion)\n\n${conflict.remoteContent}`;
      notes.set(id, {
        id,
        title: firstLineTitle(content, "Untitled"),
        createdMs: Date.now(),
        mtimeMs: Date.now(),
        size: new TextEncoder().encode(content).length,
        content,
        deletedAtMs: null,
      });
    } else if (resolution === "recreateRemote") {
      // Nothing to do in the mock beyond clearing the conflict — the page is
      // recreated backend-side.
    } else if (resolution === "acceptRemoteDelete" && note) {
      note.deletedAtMs = Date.now();
      sessionTabs.delete(noteId);
    }
    notionConflicts.delete(noteId);
  },

  async notionResolveAll(policy: BulkResolvePolicy): Promise<BulkResolveResult> {
    const out: BulkResolveResult = {
      resolved: 0,
      failed: 0,
      cancelled: false,
      changedNoteIds: [],
      errors: [],
    };
    // Mirrors the backend's policy -> resolution mapping.
    const map: Record<BulkResolvePolicy, Record<string, ConflictResolution>> = {
      local: {
        "both-changed": "keepLocal",
        "remote-deleted": "recreateRemote",
        "local-deleted": "restoreLocal",
      },
      remote: {
        "both-changed": "keepRemote",
        "remote-deleted": "acceptRemoteDelete",
        "local-deleted": "acceptLocalDelete",
      },
      both: {
        "both-changed": "keepBoth",
        "remote-deleted": "recreateRemote",
        "local-deleted": "restoreLocal",
      },
    };
    for (const c of [...notionConflicts.values()]) {
      const resolution = map[policy]?.[c.kind];
      if (!resolution) {
        out.failed += 1;
        continue;
      }
      await this.notionResolveConflict(c.noteId, resolution);
      out.resolved += 1;
      out.changedNoteIds.push(c.noteId);
    }
    return out;
  },

  async notionUnlinkNote(noteId: string, _exclude?: boolean): Promise<void> {
    notionConflicts.delete(noteId);
  },
};

function resetNotion() {
  notionConfig = defaultNotionConfig();
  notionConflicts.clear();
  notionSynced = false;
}

export const mockBackendTestHooks = {
  reset() {
    notes.clear();
    sessionTabs.clear();
    activeTabId = null;
    seeded = false;
    resetNotion();
  },
  seed() {
    notes.clear();
    sessionTabs.clear();
    activeTabId = null;
    seeded = false;
    resetNotion();
    ensureSeeded();
  },
  /** Puts the Notion integration into a connected state without going through
   *  the settings UI, so e2e can jump straight to sync behaviour. */
  connectNotion() {
    notionConfig = {
      ...defaultNotionConfig(),
      tokenSet: true,
      tokenHint: "beef",
      databaseId: "mock-db-1",
      databaseTitle: "Mock Notes",
      enabled: true,
      // Off by default so tests drive syncing explicitly.
      syncOnStart: false,
      autoSync: false,
    };
    notionConflicts.clear();
    notionSynced = false;
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
