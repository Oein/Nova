import type {
  Note,
  NoteContent,
  OpenWorkspaceResult,
  SearchHit,
  Session,
  SessionTab,
  TrashedNote,
} from "./types";

const MOCK = import.meta.env.VITE_BACKEND === "mock";

interface Backend {
  pickWorkspace(): Promise<string | null>;
  openWorkspace(path: string): Promise<OpenWorkspaceResult>;
  listNotes(): Promise<Note[]>;
  createNote(): Promise<Note>;
  readNote(id: string): Promise<NoteContent>;
  writeNote(
    id: string,
    content: string,
    expectedMtimeMs: number | null,
  ): Promise<Note>;
  deleteNote(id: string): Promise<void>;
  listTrashedNotes(): Promise<TrashedNote[]>;
  restoreNote(id: string): Promise<Note>;
  purgeTrashedNote(id: string): Promise<void>;
  searchNotes(query: string, limit?: number): Promise<SearchHit[]>;
  getSession(): Promise<Session>;
  saveSession(session: Session): Promise<void>;
  saveTabState(tab: SessionTab): Promise<void>;
  setActiveTab(active: string | null): Promise<void>;
  removeTabState(id: string): Promise<void>;
  revealNote(id: string): Promise<void>;
}

async function loadTauriBackend(): Promise<Backend> {
  const { invoke } = await import("@tauri-apps/api/core");
  const { open } = await import("@tauri-apps/plugin-dialog");
  return {
    pickWorkspace: async () => {
      const res = await open({ directory: true, multiple: false });
      return typeof res === "string" ? res : null;
    },
    openWorkspace: (path) => invoke("open_workspace", { path }),
    listNotes: () => invoke("list_notes"),
    createNote: () => invoke("create_note"),
    readNote: (id) => invoke("read_note", { id }),
    writeNote: (id, content, expectedMtimeMs) =>
      invoke("write_note", { id, content, expectedMtimeMs }),
    deleteNote: (id) => invoke("delete_note", { id }),
    listTrashedNotes: () => invoke("list_trashed_notes"),
    restoreNote: (id) => invoke("restore_note", { id }),
    purgeTrashedNote: (id) => invoke("purge_trashed_note", { id }),
    searchNotes: (query, limit) => invoke("search_notes", { query, limit: limit ?? null }),
    getSession: () => invoke("get_session"),
    saveSession: (session) => invoke("save_session", { session }),
    saveTabState: (tab) => invoke("save_tab_state", { tab }),
    setActiveTab: (active) => invoke("set_active_tab", { active }),
    removeTabState: (id) => invoke("remove_tab_state", { id }),
    revealNote: (id) => invoke("reveal_note", { id }),
  };
}

async function loadMockBackend(): Promise<Backend> {
  const mod = await import("./mock/backend");
  return mod.mockBackend;
}

let backendPromise: Promise<Backend> | null = null;
function getBackend(): Promise<Backend> {
  if (!backendPromise) backendPromise = MOCK ? loadMockBackend() : loadTauriBackend();
  return backendPromise;
}

export const ipc: Backend = {
  pickWorkspace: async () => (await getBackend()).pickWorkspace(),
  openWorkspace: async (p) => (await getBackend()).openWorkspace(p),
  listNotes: async () => (await getBackend()).listNotes(),
  createNote: async () => (await getBackend()).createNote(),
  readNote: async (id) => (await getBackend()).readNote(id),
  writeNote: async (id, c, m) => (await getBackend()).writeNote(id, c, m),
  deleteNote: async (id) => (await getBackend()).deleteNote(id),
  listTrashedNotes: async () => (await getBackend()).listTrashedNotes(),
  restoreNote: async (id) => (await getBackend()).restoreNote(id),
  purgeTrashedNote: async (id) => (await getBackend()).purgeTrashedNote(id),
  searchNotes: async (q, l) => (await getBackend()).searchNotes(q, l),
  getSession: async () => (await getBackend()).getSession(),
  saveSession: async (s) => (await getBackend()).saveSession(s),
  saveTabState: async (t) => (await getBackend()).saveTabState(t),
  setActiveTab: async (a) => (await getBackend()).setActiveTab(a),
  removeTabState: async (i) => (await getBackend()).removeTabState(i),
  revealNote: async (i) => (await getBackend()).revealNote(i),
};

export const isMock = MOCK;
