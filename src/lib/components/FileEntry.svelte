<script lang="ts">
  import type { Note } from "$lib/types";

  export let entry: Note;
  export let active: boolean;
  export let selected: boolean;
  export let dirty: boolean;
  export let onClick: (id: string, e: MouseEvent) => void;
  export let onContextMenu: (id: string, e: MouseEvent) => void;
</script>

<li>
  <button
    class="entry"
    class:active
    class:selected
    on:click={(e) => onClick(entry.id, e)}
    on:contextmenu|preventDefault={(e) => onContextMenu(entry.id, e)}
    data-note-id={entry.id}
    title={entry.title}
  >
    {#if dirty}<span class="dirty-dot" aria-label="unsaved">●</span>{/if}
    <span class="name">{entry.title}</span>
  </button>
</li>

<style>
  .entry {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    background: transparent;
    border: none;
    padding: 3px 10px 3px 20px;
    color: var(--fg-0);
    font-size: 12px;
    text-align: left;
    cursor: pointer;
    border-radius: 0;
  }
  .entry:hover { background: var(--bg-2); }
  .entry.selected { background: var(--bg-3); }
  .entry.active { background: var(--accent-dim); color: white; }
  .name {
    flex: 1;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .dirty-dot { color: var(--dirty); font-size: 10px; }
</style>
