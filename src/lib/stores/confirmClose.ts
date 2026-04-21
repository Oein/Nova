import { writable } from "svelte/store";

export interface ConfirmCloseRequest {
  id: string;
  title: string;
  onSave: () => void | Promise<void>;
  onDiscard: () => void | Promise<void>;
}

export const confirmClose = writable<ConfirmCloseRequest | null>(null);
