import { writable, type Writable } from "svelte/store";
import { workspacePath } from "./workspace";

function loadCollapsed(workspace: string | null): Set<string> {
  if (!workspace || typeof localStorage === "undefined") return new Set();
  try {
    const raw = localStorage.getItem(`collapsedGroups:${workspace}`);
    if (!raw) return new Set();
    const arr = JSON.parse(raw) as string[];
    return new Set(arr);
  } catch {
    return new Set();
  }
}

function saveCollapsed(workspace: string | null, s: Set<string>): void {
  if (!workspace || typeof localStorage === "undefined") return;
  localStorage.setItem(`collapsedGroups:${workspace}`, JSON.stringify([...s]));
}

export const collapsedGroups: Writable<Set<string>> = writable(new Set());

let currentWorkspace: string | null = null;
workspacePath.subscribe((p) => {
  currentWorkspace = p;
  collapsedGroups.set(loadCollapsed(p));
});

collapsedGroups.subscribe((s) => {
  saveCollapsed(currentWorkspace, s);
});

export function toggleGroup(key: string): void {
  collapsedGroups.update((s) => {
    const n = new Set(s);
    if (n.has(key)) n.delete(key);
    else n.add(key);
    return n;
  });
}

export const selectedNoteIds: Writable<Set<string>> = writable(new Set());
export const selectionAnchor: Writable<string | null> = writable(null);

export const toastMessage = writable<string | null>(null);
let toastTimer: ReturnType<typeof setTimeout> | null = null;
export function toast(msg: string, ms = 3000): void {
  toastMessage.set(msg);
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastMessage.set(null), ms);
}
