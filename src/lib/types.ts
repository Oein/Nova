export interface FileEntry {
  path: string;
  name: string;
  size: number;
  mtimeMs: number;
}

export interface Note {
  id: string;
  title: string;
  createdMs: number;
  mtimeMs: number;
  size: number;
}

export interface TrashedNote {
  id: string;
  title: string;
  deletedAtMs: number;
  size: number;
}

export interface SnippetParts {
  before: string;
  matched: string;
  after: string;
  prefixEllipsis: boolean;
  suffixEllipsis: boolean;
}

export interface SearchHit {
  id: string;
  title: string;
  mtimeMs: number;
  score: number;
  snippet: SnippetParts | null;
}

export interface NoteContent {
  id: string;
  content: string;
  mtimeMs: number;
  size: number;
}

export interface SessionTab {
  noteId: string;
  position: number;
  cursorLine: number;
  cursorCol: number;
  scrollTop: number;
  unsavedContent: string | null;
  undoLog: string | null;
}

export interface Session {
  tabs: SessionTab[];
  activeTab: string | null;
}

export interface OpenWorkspaceResult {
  root: string;
  notes: Note[];
  session: Session;
}

export interface FileRead {
  content: string;
  size: number;
  mtimeMs: number;
  encoding: "utf8" | "utf8-lossy";
}

export interface LargeFileHandle {
  path: string;
  size: number;
  totalLines: number;
  sparseIndexStride: number;
}

export type FsEvent =
  | { kind: "modified"; path: string; mtimeMs: number; size: number }
  | { kind: "created"; path: string; mtimeMs: number; size: number }
  | { kind: "removed"; path: string }
  | { kind: "renamed"; from: string; to: string; mtimeMs: number; size: number };

export const MB = 1024 * 1024;
export const GB = 1024 * MB;
export const SMALL_FILE_LIMIT = 16 * MB;
export const HARD_LIMIT = 1 * GB;

export type TabMode = "rope" | "paged";

export interface OpenTab {
  id: string;
  title: string;
  mode: TabMode;
  mtimeMs: number;
  initialCursor?: { line: number; col: number };
  initialScroll?: number;
}

export interface Group {
  key: string;
  label: string;
  count: number;
  entries: Note[];
}
