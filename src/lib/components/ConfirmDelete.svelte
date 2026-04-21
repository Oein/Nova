<script lang="ts">
  import { confirmDelete } from "$lib/stores/confirmDelete";

  function cancel() {
    confirmDelete.set(null);
  }

  async function confirm() {
    const req = $confirmDelete;
    if (!req) return;
    confirmDelete.set(null);
    await req.onConfirm();
  }

  function onKeydown(e: KeyboardEvent) {
    if (!$confirmDelete) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      cancel();
    } else if (e.key === "Enter") {
      e.preventDefault();
      e.stopPropagation();
      void confirm();
    }
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $confirmDelete}
  <div class="backdrop">
    <div class="dialog" role="dialog" aria-modal="true">
      <div class="title">
        {#if $confirmDelete.count === 1}
          Move "{$confirmDelete.sampleTitle}" to trash?
        {:else}
          Move {$confirmDelete.count} notes to trash?
        {/if}
      </div>
      <div class="msg">Trashed notes are kept for 30 days, then permanently removed.</div>
      <div class="actions">
        <button class="secondary" on:click={cancel}>Cancel</button>
        <button class="danger" on:click={confirm}>Move to Trash</button>
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
    padding: 18px 20px 14px;
    min-width: 360px;
    max-width: 480px;
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.4);
  }
  .title {
    font-size: 13px;
    font-weight: 600;
    margin-bottom: 6px;
    color: var(--fg-0);
  }
  .msg {
    font-size: 12px;
    color: var(--fg-2);
    margin-bottom: 14px;
    line-height: 1.4;
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  button {
    padding: 6px 14px;
    font-size: 12px;
    border-radius: 4px;
    cursor: pointer;
    border: 1px solid var(--bg-3);
    background: var(--bg-2);
    color: var(--fg-0);
  }
  button:hover { background: var(--bg-3); }
  button.danger {
    background: #c0392b;
    border-color: #c0392b;
    color: white;
  }
  button.danger:hover { filter: brightness(1.15); }
</style>
