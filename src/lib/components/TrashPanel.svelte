<script lang="ts">
  import { ipc } from "$lib/ipc";
  import { trashPanelOpen } from "$lib/stores/trashPanel";
  import { upsertNote } from "$lib/stores/workspace";
  import { toast } from "$lib/stores/ui";
  import type { TrashedNote } from "$lib/types";

  let items: TrashedNote[] = [];
  let loading = false;

  async function refresh() {
    loading = true;
    try {
      items = await ipc.listTrashedNotes();
    } catch (err) {
      console.error(err);
      toast("Failed to load trash");
    } finally {
      loading = false;
    }
  }

  $: if ($trashPanelOpen) void refresh();

  function close() {
    trashPanelOpen.set(false);
  }

  async function restore(id: string) {
    try {
      const note = await ipc.restoreNote(id);
      upsertNote(note);
      await refresh();
      toast("Restored");
    } catch (err) {
      console.error(err);
      toast("Restore failed");
    }
  }

  async function purge(id: string) {
    try {
      await ipc.purgeTrashedNote(id);
      await refresh();
      toast("Deleted permanently");
    } catch (err) {
      console.error(err);
      toast("Delete failed");
    }
  }

  function daysLeft(deletedAtMs: number): number {
    const end = deletedAtMs + 30 * 24 * 60 * 60 * 1000;
    return Math.max(0, Math.ceil((end - Date.now()) / (24 * 60 * 60 * 1000)));
  }

  function onKeydown(e: KeyboardEvent) {
    if (!$trashPanelOpen) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $trashPanelOpen}
  <!-- svelte-ignore a11y-click-events-have-key-events -->
  <!-- svelte-ignore a11y-no-static-element-interactions -->
  <div class="backdrop" on:click={close} role="presentation">
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-noninteractive-element-interactions -->
    <div
      class="dialog"
      role="dialog"
      aria-modal="true"
      aria-label="Trash"
      on:click|stopPropagation
      on:keydown|stopPropagation
    >
      <header>
        <span class="title">Trash</span>
        <button class="close" on:click={close} aria-label="Close">×</button>
      </header>
      <div class="body">
        {#if loading}
          <div class="empty">Loading…</div>
        {:else if items.length === 0}
          <div class="empty">Trash is empty.</div>
        {:else}
          <div class="hint">Trashed notes are kept for 30 days.</div>
          <ul>
            {#each items as n (n.id)}
              <li>
                <div class="meta">
                  <div class="note-title">{n.title || "Untitled"}</div>
                  <div class="sub">{daysLeft(n.deletedAtMs)} days left</div>
                </div>
                <div class="actions">
                  <button on:click={() => restore(n.id)}>Restore</button>
                  <button class="danger" on:click={() => purge(n.id)}>
                    Delete
                  </button>
                </div>
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: grid;
    place-items: center;
    z-index: 1000;
  }
  .dialog {
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 6px;
    min-width: 420px;
    max-width: 560px;
    max-height: 70vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.4);
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    border-bottom: 1px solid var(--bg-3);
  }
  .title {
    font-size: 13px;
    font-weight: 600;
    color: var(--fg-0);
  }
  .close {
    background: transparent;
    border: none;
    color: var(--fg-2);
    font-size: 18px;
    cursor: pointer;
    line-height: 1;
    padding: 0 4px;
  }
  .close:hover { color: var(--fg-0); }
  .body {
    padding: 10px 14px 14px;
    overflow-y: auto;
  }
  .hint {
    font-size: 11px;
    color: var(--fg-2);
    margin-bottom: 8px;
  }
  .empty {
    padding: 24px;
    text-align: center;
    color: var(--fg-2);
    font-size: 12px;
  }
  ul {
    list-style: none;
    padding: 0;
    margin: 0;
  }
  li {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 6px 4px;
    border-bottom: 1px solid var(--bg-2);
  }
  li:last-child { border-bottom: none; }
  .meta { min-width: 0; flex: 1; }
  .note-title {
    font-size: 12px;
    color: var(--fg-0);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .sub {
    font-size: 10px;
    color: var(--fg-2);
    margin-top: 2px;
  }
  .actions { display: flex; gap: 6px; }
  button {
    padding: 3px 10px;
    font-size: 11px;
    border-radius: 3px;
    cursor: pointer;
    border: 1px solid var(--bg-3);
    background: var(--bg-2);
    color: var(--fg-0);
  }
  button:hover { background: var(--bg-3); }
  button.danger {
    background: transparent;
    border-color: var(--bg-3);
    color: #e57373;
  }
  button.danger:hover {
    background: rgba(192, 57, 43, 0.2);
  }
</style>
