<script lang="ts">
  import { onDestroy } from "svelte";
  import { contextMenu, closeContextMenu } from "$lib/stores/contextMenu";

  let menuEl: HTMLDivElement | null = null;
  let menuW = 0;
  let menuH = 0;

  // Re-measure on every open so the position-clamp logic below stays accurate
  // even if items vary. Done in an action so we don't race against layout.
  function measure(node: HTMLDivElement) {
    menuEl = node;
    const rect = node.getBoundingClientRect();
    menuW = rect.width;
    menuH = rect.height;
    return {
      destroy() {
        menuEl = null;
      },
    };
  }

  // Clamp the requested (x, y) into the viewport so a menu opened near the
  // edge doesn't get clipped or scroll the page.
  $: clamped = (() => {
    if (!$contextMenu) return { x: 0, y: 0 };
    const { x, y } = $contextMenu;
    if (typeof window === "undefined") return { x, y };
    const w = menuW || 200;
    const h = menuH || 100;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    return {
      x: Math.min(x, vw - w - 4),
      y: Math.min(y, vh - h - 4),
    };
  })();

  // Outside-click + scroll + Escape all dismiss.
  function onWindowMouseDown(e: MouseEvent) {
    if (!menuEl) return;
    if (!menuEl.contains(e.target as Node)) closeContextMenu();
  }
  function onWindowKey(e: KeyboardEvent) {
    if (e.key === "Escape") closeContextMenu();
  }
  function onWindowScroll() {
    closeContextMenu();
  }

  $: if ($contextMenu) {
    // Bind on next tick to avoid the original right-click event triggering
    // an immediate dismissal on its own bubbling.
    setTimeout(() => {
      window.addEventListener("mousedown", onWindowMouseDown, true);
      window.addEventListener("keydown", onWindowKey, true);
      window.addEventListener("scroll", onWindowScroll, true);
    }, 0);
  } else {
    window.removeEventListener("mousedown", onWindowMouseDown, true);
    window.removeEventListener("keydown", onWindowKey, true);
    window.removeEventListener("scroll", onWindowScroll, true);
  }

  onDestroy(() => {
    window.removeEventListener("mousedown", onWindowMouseDown, true);
    window.removeEventListener("keydown", onWindowKey, true);
    window.removeEventListener("scroll", onWindowScroll, true);
  });

  async function pick(item: import("$lib/stores/contextMenu").ContextMenuItem) {
    if (item.disabled) return;
    closeContextMenu();
    await item.onSelect();
  }
</script>

{#if $contextMenu}
  <div
    class="ctxmenu"
    role="menu"
    use:measure
    style="left: {clamped.x}px; top: {clamped.y}px"
  >
    {#each $contextMenu.items as item, i (i)}
      <button
        type="button"
        role="menuitem"
        class="item"
        class:danger={item.danger}
        disabled={item.disabled}
        on:click={() => pick(item)}
      >
        {item.label}
      </button>
    {/each}
  </div>
{/if}

<style>
  .ctxmenu {
    position: fixed;
    z-index: 1000;
    min-width: 180px;
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 6px;
    padding: 4px;
    box-shadow:
      0 12px 32px rgba(0, 0, 0, 0.4),
      0 2px 8px rgba(0, 0, 0, 0.3);
    font-size: 12px;
    color: var(--fg-0);
    user-select: none;
    /* Defeat the editor's I-beam if the menu happens to overlap the editor. */
    cursor: default;
  }
  .item {
    display: block;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    padding: 6px 10px;
    color: inherit;
    font-size: inherit;
    border-radius: 4px;
    cursor: pointer;
  }
  .item:hover:not(:disabled) {
    background: var(--accent-dim, #2a4365);
    color: white;
  }
  .item.danger {
    color: var(--dirty, #f87171);
  }
  .item.danger:hover:not(:disabled) {
    background: var(--dirty, #ef4444);
    color: white;
  }
  .item:disabled {
    opacity: 0.5;
    cursor: default;
  }
</style>
