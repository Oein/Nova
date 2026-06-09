import { writable } from "svelte/store";
import type { UpdateChannel, UpdateInfo } from "$lib/updater";

const CHANNEL_KEY = "nova:updateChannel";

function initChannel(): UpdateChannel {
  if (typeof localStorage === "undefined") return "release";
  const raw = localStorage.getItem(CHANNEL_KEY);
  if (raw === "beta" || raw === "dev") return raw;
  return "release";
}

export const updateChannel = writable<UpdateChannel>(initChannel());
export const pendingUpdate = writable<UpdateInfo | null>(null);
export const updateChecking = writable<boolean>(false);
export const updateError = writable<string | null>(null);
export const updateDismissed = writable<boolean>(false);

if (typeof localStorage !== "undefined") {
  updateChannel.subscribe((v) => {
    try {
      localStorage.setItem(CHANNEL_KEY, v);
    } catch {
      /* quota */
    }
  });
}
