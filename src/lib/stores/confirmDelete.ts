import { writable } from "svelte/store";

export interface ConfirmDeleteRequest {
  count: number;
  sampleTitle: string;
  onConfirm: () => void | Promise<void>;
}

export const confirmDelete = writable<ConfirmDeleteRequest | null>(null);
