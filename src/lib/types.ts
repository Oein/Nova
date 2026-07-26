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
  // True while the note exists only because `createAndOpenNote` materialized
  // a placeholder row+file on disk — the user has never explicitly saved it.
  // Cleared on the first successful `saveTab`. If the tab is closed while
  // still `neverSaved`, the note is hard-deleted (bypassing trash) since
  // nothing the user committed would be lost. Not persisted across restarts:
  // a session-restored tab is always treated as "saved" since the disk
  // already holds whatever content we'd restore.
  neverSaved?: boolean;
}

// --- Notion sync -----------------------------------------------------------

/** What the backend is willing to tell us about the stored config. There is
 *  deliberately no `token` field — the PAT lives in workspace.db and never
 *  crosses the IPC boundary once saved. */
export interface NotionConfigView {
  tokenSet: boolean;
  /** Last 4 characters of the stored PAT, so the user can identify it. */
  tokenHint: string;
  databaseId: string | null;
  databaseTitle: string | null;
  titleProp: string;
  /** Name of the Notion `date` property receiving the note's creation time.
   *  `null` means the user hasn't opted in. */
  createdProp: string | null;
  /** Same, for the note's last-modified time. */
  updatedProp: string | null;
  /** Name of a `rich_text` property holding the note's uuid. Gives a page an
   *  identity independent of its title, and lets a lost local mapping be
   *  rebuilt instead of re-importing everything as duplicates. */
  idProp: string | null;
  enabled: boolean;
  syncOnStart: boolean;
  autoSync: boolean;
  intervalSec: number;
  lastSyncMs: number | null;
  lastStatus: string | null;
  conflictCount: number;
}

/** Partial update. Omitted fields keep their stored value — in particular
 *  `token`, which the settings UI only sends when the user types a new one. */
export interface NotionConfigInput {
  token?: string;
  databaseId?: string;
  databaseTitle?: string;
  /** Empty string clears the setting; omitting it leaves it alone. */
  createdProp?: string;
  updatedProp?: string;
  idProp?: string;
  enabled?: boolean;
  syncOnStart?: boolean;
  autoSync?: boolean;
  intervalSec?: number;
}

export interface NotionDbSummary {
  id: string;
  title: string;
  url: string | null;
}

export interface NotionConnectionInfo {
  botName: string;
  workspaceName: string | null;
  databaseTitle: string | null;
  titleProp: string | null;
  pageCount: number | null;
  /** What the first sync will do about the configured timestamp columns. */
  propertyWarnings: string[];
}

export type SyncItemKind =
  | "pulled"
  | "pushed"
  | "created-local"
  | "created-remote"
  | "archived-remote"
  | "trashed-local"
  | "conflict"
  | "blocked"
  | "error";

export interface SyncReportItem {
  noteId: string | null;
  pageId: string | null;
  title: string;
  kind: SyncItemKind;
  severity: "info" | "warn" | "error";
  message: string | null;
}

export interface SyncReport {
  pulled: number;
  pushed: number;
  createdLocal: number;
  createdRemote: number;
  archivedRemote: number;
  trashedLocal: number;
  conflicts: number;
  blocked: number;
  errors: number;
  cancelled: boolean;
  dryRun: boolean;
  items: SyncReportItem[];
  changedNoteIds: string[];
}

export type ConflictKind = "both-changed" | "remote-deleted" | "local-deleted";

export interface NotionConflict {
  noteId: string;
  pageId: string | null;
  kind: ConflictKind;
  localTitle: string | null;
  remoteTitle: string | null;
  detectedMs: number;
}

export interface NotionConflictDetail extends NotionConflict {
  localContent: string | null;
  remoteContent: string | null;
}

export type ConflictResolution =
  | "keepLocal"
  | "keepRemote"
  | "keepBoth"
  | "recreateRemote"
  | "restoreLocal"
  | "acceptRemoteDelete"
  | "acceptLocalDelete";

/** A bulk answer that means the same thing for every conflict kind. */
export type BulkResolvePolicy = "local" | "remote" | "both";

export interface BulkResolveResult {
  resolved: number;
  failed: number;
  cancelled: boolean;
  changedNoteIds: string[];
  errors: SyncReportItem[];
}

export interface SyncProgress {
  done: number;
  total: number;
  current: string;
}

export interface Group {
  key: string;
  label: string;
  count: number;
  entries: Note[];
}
