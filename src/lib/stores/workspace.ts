import { writable, derived, type Readable } from "svelte/store";
import type { Group, Note, Session } from "../types";
import { groupByLocalDay } from "../dateGrouping";

export const workspacePath = writable<string | null>(null);
export const notes = writable<Note[]>([]);

export const sortedGroups: Readable<Group[]> = derived(
  notes,
  ($n) => groupByLocalDay($n, new Date()),
);

export const initialSession = writable<Session>({ tabs: [], activeTab: null });

export function upsertNote(n: Note): void {
  notes.update((list) => {
    const i = list.findIndex((x) => x.id === n.id);
    if (i >= 0) {
      const next = [...list];
      next[i] = n;
      return next;
    }
    return [...list, n];
  });
}

export function removeNote(id: string): void {
  notes.update((list) => list.filter((x) => x.id !== id));
}

/** Update the in-memory title without touching mtime/size. Used for live
 *  sidebar/tab updates as the user types before save. */
export function setNoteTitle(id: string, title: string): void {
  notes.update((list) => {
    const i = list.findIndex((x) => x.id === id);
    if (i < 0 || list[i].title === title) return list;
    const next = [...list];
    next[i] = { ...next[i], title };
    return next;
  });
}

export function touchNote(id: string, title: string, mtimeMs: number, size: number): void {
  notes.update((list) => {
    const i = list.findIndex((x) => x.id === id);
    if (i < 0) return list;
    const next = [...list];
    next[i] = { ...next[i], title, mtimeMs, size };
    return next;
  });
}
