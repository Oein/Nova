import { writable } from "svelte/store";
import type { OpenTab } from "../types";
import type { Buffer } from "../editor/buffer/Buffer";

export const openTabs = writable<OpenTab[]>([]);
export const activeTabId = writable<string | null>(null);
export const dirtyTabs = writable<Set<string>>(new Set());

// Buffers are non-serializable, so kept outside the Svelte store.
const buffers = new Map<string, Buffer>();

export function registerBuffer(id: string, buf: Buffer): void {
  buffers.set(id, buf);
}

export function getBuffer(id: string): Buffer | undefined {
  return buffers.get(id);
}

export function dropBuffer(id: string): void {
  buffers.delete(id);
}

export function setTabTitle(id: string, title: string): void {
  openTabs.update((list) => {
    const i = list.findIndex((t) => t.id === id);
    if (i < 0 || list[i].title === title) return list;
    const next = [...list];
    next[i] = { ...next[i], title };
    return next;
  });
}

export function markDirty(id: string, dirty: boolean): void {
  dirtyTabs.update((s) => {
    const n = new Set(s);
    if (dirty) n.add(id);
    else n.delete(id);
    return n;
  });
}
