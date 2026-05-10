// Bridge between the native macOS menu (defined in src-tauri/src/lib.rs)
// and the frontend. When the user picks a menu item (or hits its
// accelerator — on macOS the OS intercepts accelerators before the
// webview sees them), the Rust side emits "menu:action" with a string
// id. We fan that out via a Svelte store so the app layer and the
// active editor can both listen.
import { writable } from "svelte/store";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type MenuActionId =
  | "file:new-note"
  | "file:save"
  | "file:close-tab"
  | "edit:undo"
  | "edit:redo"
  | "edit:select-all"
  | "edit:find"
  | "edit:replace"
  | "view:toggle-sidebar"
  | "view:spotlight"
  | "view:zoom-in"
  | "view:zoom-out"
  | "view:zoom-reset"
  | "tab:next"
  | "tab:prev";

// Subscribers get a fresh object on every emit (the `seq` counter ensures
// repeated actions still fire even when the action id is identical).
export type MenuEvent = { action: MenuActionId; seq: number };

let seq = 0;
export const menuAction = writable<MenuEvent | null>(null);

export function fireMenuAction(action: MenuActionId): void {
  menuAction.set({ action, seq: ++seq });
}

// Called once at app bootstrap. The Tauri invoke layer is only available
// under the packaged runtime; in mock/web mode this is a no-op.
export async function initMenuBridge(): Promise<UnlistenFn | null> {
  try {
    return await listen<string>("menu:action", (ev) => {
      fireMenuAction(ev.payload as MenuActionId);
    });
  } catch {
    // `listen` throws when the Tauri IPC isn't wired up (e.g. plain vite
    // dev without the shell). Silently degrade — the in-app keybindings
    // still work there.
    return null;
  }
}
