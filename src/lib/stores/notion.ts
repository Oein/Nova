import { get, writable } from "svelte/store";
import { ipc } from "../ipc";
import { notes } from "./workspace";
import { openTabs } from "./tabs";
import { toast } from "./ui";
import { flushDirtyTabs, reloadTabFromDisk } from "../tabManager";
import type {
  BulkResolvePolicy,
  BulkResolveResult,
  ConflictResolution,
  NotionConfigView,
  NotionConflict,
  NotionConflictDetail,
  SyncProgress,
  SyncReport,
} from "../types";

/** `null` until the first load, so the settings UI can show a placeholder
 *  rather than flashing "disconnected". */
export const notionConfig = writable<NotionConfigView | null>(null);
export const syncState = writable<"idle" | "syncing" | "error">("idle");
export const syncProgress = writable<SyncProgress | null>(null);
export const syncError = writable<string | null>(null);
export const lastReport = writable<SyncReport | null>(null);
export const conflicts = writable<NotionConflict[]>([]);
export const conflictPanelOpen = writable(false);
export const activeConflict = writable<NotionConflictDetail | null>(null);

export function errorMessage(err: unknown): string {
  // Tauri serializes AppError to its Display string, so errors arrive as
  // plain strings rather than Error instances.
  if (typeof err === "string") return err;
  if (err instanceof Error) return err.message;
  return String(err);
}

export async function loadNotionConfig(): Promise<NotionConfigView | null> {
  try {
    const cfg = await ipc.notionGetConfig();
    notionConfig.set(cfg);
    return cfg;
  } catch (err) {
    // No workspace open yet is the normal case at boot, not something to
    // bother the user about.
    console.debug("notion config unavailable", err);
    notionConfig.set(null);
    return null;
  }
}

export async function refreshConflicts(): Promise<void> {
  try {
    conflicts.set(await ipc.notionListConflicts());
  } catch (err) {
    console.error("list conflicts failed", err);
  }
}

/**
 * Runs a sync end to end.
 *
 * Flushes dirty buffers first — the engine treats the file on disk as the only
 * truth, so an unsaved edit would read as "no local change" and lose to the
 * remote. Returns `null` when a sync was already running or the config isn't
 * usable yet.
 *
 * `silent` suppresses the success toast (used by the timer and the boot sync);
 * failures always surface.
 */
export async function runSync(
  opts: { silent?: boolean } = {},
): Promise<SyncReport | null> {
  if (get(syncState) === "syncing") return null;
  const cfg = get(notionConfig);
  if (!cfg?.enabled || !cfg.tokenSet || !cfg.databaseId) return null;

  syncState.set("syncing");
  syncError.set(null);
  syncProgress.set(null);
  try {
    await flushDirtyTabs();
    const report = await ipc.notionSync(false);
    lastReport.set(report);
    // The summary is only a count; the reasons live on the items. Log them so
    // a background sync's failures are recoverable from devtools too, not just
    // from the settings panel.
    for (const item of report.items) {
      if (item.severity === "error") {
        console.error(`notion sync: ${item.title} — ${item.message ?? item.kind}`);
      } else if (item.severity === "warn") {
        console.warn(`notion sync: ${item.title} — ${item.message ?? item.kind}`);
      }
    }
    await Promise.all([loadNotionConfig(), refreshConflicts(), applyChanges(report)]);
    syncState.set("idle");
    if (!opts.silent) toast(summarize(report));
    else if (report.conflicts > 0) toast(`Notion: ${report.conflicts} conflict(s) need review`);
    return report;
  } catch (err) {
    const message = errorMessage(err);
    // A concurrent trigger isn't a failure — just let the running one finish.
    if (message.includes("already running")) {
      syncState.set("idle");
      return null;
    }
    console.error("notion sync failed", err);
    syncError.set(message);
    syncState.set("error");
    if (!opts.silent) toast(`Notion sync failed: ${message}`);
    return null;
  }
}

export function summarize(report: SyncReport): string {
  if (report.cancelled) return "Notion sync cancelled";
  const parts: string[] = [];
  if (report.pulled) parts.push(`${report.pulled} pulled`);
  if (report.pushed) parts.push(`${report.pushed} pushed`);
  if (report.createdLocal) parts.push(`${report.createdLocal} new here`);
  if (report.createdRemote) parts.push(`${report.createdRemote} new in Notion`);
  if (report.trashedLocal) parts.push(`${report.trashedLocal} trashed`);
  if (report.archivedRemote) parts.push(`${report.archivedRemote} archived`);
  if (report.conflicts) parts.push(`${report.conflicts} conflict(s)`);
  if (report.blocked) parts.push(`${report.blocked} blocked`);
  if (report.errors) parts.push(`${report.errors} failed`);
  if (parts.length === 0) return "Notion: up to date";
  const suffix = report.errors || report.blocked ? " — see Settings for details" : "";
  return `Notion: ${parts.join(", ")}${suffix}`;
}

/** Pulls the note list back into the sidebar and refreshes any open tab whose
 *  file the sync rewrote. */
export async function applyChanges(report: { changedNoteIds: string[] }): Promise<void> {
  await refreshNotes();
  if (report.changedNoteIds.length === 0) return;
  const open = new Set(get(openTabs).map((t) => t.id));
  for (const id of report.changedNoteIds) {
    if (open.has(id)) await reloadTabFromDisk(id);
  }
}

export async function refreshNotes(): Promise<void> {
  try {
    notes.set(await ipc.listNotes());
  } catch (err) {
    console.error("refresh notes failed", err);
  }
}

export async function openConflict(noteId: string): Promise<void> {
  try {
    activeConflict.set(await ipc.notionGetConflict(noteId));
  } catch (err) {
    console.error("load conflict failed", err);
    activeConflict.set(null);
  }
}

export async function resolve(
  noteId: string,
  resolution: ConflictResolution,
): Promise<boolean> {
  try {
    await ipc.notionResolveConflict(noteId, resolution);
    activeConflict.set(null);
    await Promise.all([
      refreshConflicts(),
      loadNotionConfig(),
      applyChanges({ changedNoteIds: [noteId] }),
    ]);
    toast("Conflict resolved");
    return true;
  } catch (err) {
    console.error("resolve conflict failed", err);
    toast(`Could not resolve: ${errorMessage(err)}`);
    return false;
  }
}

/**
 * Applies one answer to every outstanding conflict.
 *
 * Each conflict is resolved independently on the backend, so a failure part-way
 * leaves the rest resolved and the failed ones still listed for a retry.
 */
export async function resolveAll(
  policy: BulkResolvePolicy,
): Promise<BulkResolveResult | null> {
  try {
    const out = await ipc.notionResolveAll(policy);
    activeConflict.set(null);
    await Promise.all([
      refreshConflicts(),
      loadNotionConfig(),
      applyChanges(out),
    ]);
    for (const e of out.errors) {
      console.error(`notion resolve: ${e.title} — ${e.message ?? "failed"}`);
    }
    toast(
      out.failed > 0
        ? `Resolved ${out.resolved}, ${out.failed} failed — see Settings`
        : `Resolved ${out.resolved} conflict(s)`,
    );
    return out;
  } catch (err) {
    console.error("bulk resolve failed", err);
    toast(`Could not resolve: ${errorMessage(err)}`);
    return null;
  }
}

export async function updateConfig(
  patch: Parameters<typeof ipc.notionSetConfig>[0],
): Promise<NotionConfigView | null> {
  try {
    const cfg = await ipc.notionSetConfig(patch);
    notionConfig.set(cfg);
    return cfg;
  } catch (err) {
    toast(`Could not save Notion settings: ${errorMessage(err)}`);
    return null;
  }
}
