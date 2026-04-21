<script lang="ts">
  import { confirmClose } from "$lib/stores/confirmClose";

  function cancel() {
    confirmClose.set(null);
  }

  async function save() {
    const req = $confirmClose;
    if (!req) return;
    confirmClose.set(null);
    await req.onSave();
  }

  async function discard() {
    const req = $confirmClose;
    if (!req) return;
    confirmClose.set(null);
    await req.onDiscard();
  }

  function onKeydown(e: KeyboardEvent) {
    if (!$confirmClose) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      cancel();
    } else if (e.key === "Enter") {
      e.preventDefault();
      e.stopPropagation();
      void save();
    }
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $confirmClose}
  <div class="backdrop">
    <div class="dialog" role="dialog" aria-modal="true">
      <div class="title">Save changes to "{$confirmClose.title}"?</div>
      <div class="msg">Your changes will be lost if you don't save them.</div>
      <div class="actions">
        <button class="secondary" on:click={discard}>Don't Save</button>
        <button class="secondary" on:click={cancel}>Cancel</button>
        <button class="primary" on:click={save}>Save</button>
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
  button.primary {
    background: var(--accent);
    border-color: var(--accent);
    color: white;
  }
  button.primary:hover { filter: brightness(1.1); }
</style>
