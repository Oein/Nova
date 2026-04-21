<script lang="ts">
  import { openTabs, activeTabId, dirtyTabs } from "$lib/stores/tabs";
  import { closeNoteTab } from "$lib/tabManager";
</script>

<div class="tabbar">
  {#each $openTabs as tab (tab.id)}
    <div
      class="tab"
      class:active={$activeTabId === tab.id}
      on:click={() => activeTabId.set(tab.id)}
      on:keydown={(e) => e.key === "Enter" && activeTabId.set(tab.id)}
      role="button"
      tabindex="0"
    >
      {#if $dirtyTabs.has(tab.id)}<span class="dot">●</span>{/if}
      <span class="name">{tab.title}</span>
      {#if tab.mode === "paged"}<span class="mode" title="Read-only — large file">RO</span>{/if}
      <button class="close" on:click|stopPropagation={() => closeNoteTab(tab.id)} aria-label="Close">×</button>
    </div>
  {/each}
</div>

<style>
  .tabbar {
    display: flex;
    overflow-x: auto;
    background: var(--bg-1);
    border-bottom: 1px solid var(--bg-3);
    min-height: 32px;
  }
  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-right: 1px solid var(--bg-3);
    cursor: pointer;
    background: var(--bg-1);
    font-size: 12px;
    white-space: nowrap;
  }
  .tab:hover { background: var(--bg-2); }
  .tab.active { background: var(--bg-0); color: white; }
  .dot { color: var(--dirty); font-size: 10px; }
  .mode {
    background: var(--bg-3);
    color: var(--fg-1);
    border-radius: 3px;
    padding: 1px 4px;
    font-size: 9px;
    letter-spacing: 0.5px;
  }
  .close {
    background: transparent;
    border: none;
    color: var(--fg-2);
    font-size: 14px;
    line-height: 1;
    padding: 0 2px;
    border-radius: 3px;
    cursor: pointer;
  }
  .close:hover { background: var(--bg-3); color: var(--fg-0); }
  .name {
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
  }
</style>
