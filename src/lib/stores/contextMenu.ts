// Lightweight singleton context-menu store.
//
// Components that want a right-click menu call `openContextMenu(x, y, items)`.
// A single <ContextMenu /> mounted at the root of the app subscribes, renders
// the menu at the requested position, and closes itself on outside-click,
// Escape, scroll, or any item selection.
//
// Deliberately NOT a native OS menu — those would need a Tauri round-trip
// and wouldn't match the app's visual style.

import { writable } from "svelte/store";

export interface ContextMenuItem {
  label: string;
  onSelect: () => void | Promise<void>;
  danger?: boolean; // styled red (e.g. Delete)
  disabled?: boolean;
}

export interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
}

export const contextMenu = writable<ContextMenuState | null>(null);

export function openContextMenu(x: number, y: number, items: ContextMenuItem[]): void {
  contextMenu.set({ x, y, items });
}

export function closeContextMenu(): void {
  contextMenu.set(null);
}
