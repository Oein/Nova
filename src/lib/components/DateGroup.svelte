<script lang="ts">
  import type { Group } from "$lib/types";
  import { collapsedGroups, toggleGroup, selectedNoteIds } from "$lib/stores/ui";
  import { dirtyTabs } from "$lib/stores/tabs";
  import FileEntry from "./FileEntry.svelte";

  export let group: Group;
  export let activeId: string | null;
  export let onEntryClick: (id: string, e: MouseEvent) => void;

  $: collapsed = $collapsedGroups.has(group.key);
</script>

<section class:collapsed>
  <button class="header" on:click={() => toggleGroup(group.key)} data-group-key={group.key}>
    <span class="chev">{collapsed ? "▸" : "▾"}</span>
    <span class="label">{group.label}</span>
    <span class="count">{group.count}</span>
  </button>
  {#if !collapsed}
    <ul>
      {#each group.entries as e (e.id)}
        <FileEntry
          entry={e}
          active={activeId === e.id}
          selected={$selectedNoteIds.has(e.id)}
          dirty={$dirtyTabs.has(e.id)}
          onClick={onEntryClick}
        />
      {/each}
    </ul>
  {/if}
</section>

<style>
  section { user-select: none; }
  .header {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    background: transparent;
    border: none;
    padding: 4px 10px;
    color: var(--fg-1);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    cursor: pointer;
    text-align: left;
    border-radius: 0;
  }
  .header:hover { background: var(--bg-2); }
  .chev { width: 10px; color: var(--fg-2); }
  .label { flex: 1; }
  .count {
    color: var(--fg-2);
    background: var(--bg-2);
    padding: 0 6px;
    border-radius: 8px;
    font-size: 10px;
  }
  ul { list-style: none; margin: 0; padding: 0; }
</style>
