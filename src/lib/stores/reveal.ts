import { writable } from "svelte/store";

// A pending request to reveal (scroll to + select) the first occurrence of
// `query` inside the note `id`. Set when the user opens a note from the
// Spotlight (Cmd+K) search so the editor jumps to the matched text instead
// of landing at the top. The active Editor consumes it — on fresh mount and
// via a live subscription (when the note is already open) — then clears it.
export interface RevealRequest {
  id: string;
  query: string;
}

export const revealRequest = writable<RevealRequest | null>(null);
