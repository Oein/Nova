<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import { openTabs, activeTabId, dirtyTabs } from "$lib/stores/tabs";
  import { closeNoteTab } from "$lib/tabManager";

  let tabbarEl: HTMLDivElement;
  let scrollLeft = 0;
  let clientWidth = 0;
  let scrollWidth = 0;

  $: showLeft = scrollLeft > 1;
  $: showRight = scrollWidth - (scrollLeft + clientWidth) > 1;
  $: hasOverflow = scrollWidth > clientWidth + 1;
  $: thumbLeft = scrollWidth > 0 ? (scrollLeft / scrollWidth) * clientWidth : 0;
  $: thumbWidth = scrollWidth > 0 ? Math.max(20, (clientWidth / scrollWidth) * clientWidth) : 0;

  function measure() {
    if (!tabbarEl) return;
    scrollLeft = tabbarEl.scrollLeft;
    clientWidth = tabbarEl.clientWidth;
    scrollWidth = tabbarEl.scrollWidth;
  }

  let ro: ResizeObserver | null = null;
  onMount(() => {
    measure();
    if (typeof ResizeObserver !== "undefined") {
      ro = new ResizeObserver(measure);
      ro.observe(tabbarEl);
    }
  });
  onDestroy(() => {
    ro?.disconnect();
    stopAutoScroll();
  });

  $: if ($openTabs) void tick().then(measure);

  function onWheel(e: WheelEvent) {
    if (!tabbarEl) return;
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      tabbarEl.scrollLeft += e.deltaY;
      e.preventDefault();
    }
  }

  // --- Drag-and-drop reorder ---
  let draggedId: string | null = null;
  let dropIndex: number | null = null;
  let autoScrollRaf: number | null = null;
  let dragClientX = 0;

  const EDGE_ZONE = 60;
  const SCROLL_SPEED = 8;

  function stopAutoScroll() {
    if (autoScrollRaf !== null) {
      cancelAnimationFrame(autoScrollRaf);
      autoScrollRaf = null;
    }
  }

  function autoScrollStep() {
    if (!tabbarEl || draggedId === null) {
      autoScrollRaf = null;
      return;
    }
    const rect = tabbarEl.getBoundingClientRect();
    const distLeft = dragClientX - rect.left;
    const distRight = rect.right - dragClientX;
    if (distLeft < EDGE_ZONE && distLeft >= 0) {
      tabbarEl.scrollLeft -= SCROLL_SPEED * (1 - distLeft / EDGE_ZONE);
    } else if (distRight < EDGE_ZONE && distRight >= 0) {
      tabbarEl.scrollLeft += SCROLL_SPEED * (1 - distRight / EDGE_ZONE);
    }
    measure();
    autoScrollRaf = requestAnimationFrame(autoScrollStep);
  }

  function computeDropIndex(clientX: number): number {
    if (!tabbarEl) return $openTabs.length;
    const tabs = Array.from(tabbarEl.querySelectorAll<HTMLElement>(".tab"));
    for (let i = 0; i < tabs.length; i++) {
      const rect = tabs[i].getBoundingClientRect();
      if (clientX < rect.left + rect.width / 2) return i;
    }
    return tabs.length;
  }

  function onDragStart(e: DragEvent, id: string) {
    draggedId = id;
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", id);
    }
  }

  function onDragOver(e: DragEvent) {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = "move";
    dragClientX = e.clientX;
    dropIndex = computeDropIndex(e.clientX);
    if (autoScrollRaf === null) {
      autoScrollRaf = requestAnimationFrame(autoScrollStep);
    }
  }

  function onDragLeave(e: DragEvent) {
    const rel = e.relatedTarget as Node | null;
    if (!tabbarEl.contains(rel)) {
      dropIndex = null;
      stopAutoScroll();
    }
  }

  function onDrop(e: DragEvent) {
    e.preventDefault();
    stopAutoScroll();
    if (draggedId === null || dropIndex === null) return;
    const id = draggedId;
    const target = dropIndex;
    draggedId = null;
    dropIndex = null;

    openTabs.update((tabs) => {
      const from = tabs.findIndex((t) => t.id === id);
      if (from < 0) return tabs;
      const to = target > from ? target - 1 : target;
      if (to === from) return tabs;
      const next = [...tabs];
      const [tab] = next.splice(from, 1);
      next.splice(to, 0, tab);
      return next;
    });
  }

  function onDragEnd() {
    draggedId = null;
    dropIndex = null;
    stopAutoScroll();
  }
</script>

<div class="tabbar-wrap" class:fade-left={showLeft} class:fade-right={showRight}>
  <div
    class="tabbar"
    bind:this={tabbarEl}
    on:scroll={measure}
    on:wheel={onWheel}
    on:dragover={onDragOver}
    on:dragleave={onDragLeave}
    on:drop={onDrop}
  >
    {#each $openTabs as tab, i (tab.id)}
      {#if dropIndex === i && draggedId !== null && draggedId !== tab.id}
        <div class="drop-indicator" aria-hidden="true" />
      {/if}
      <div
        class="tab"
        class:active={$activeTabId === tab.id}
        class:dragging={draggedId === tab.id}
        draggable="true"
        on:dragstart={(e) => onDragStart(e, tab.id)}
        on:dragend={onDragEnd}
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
    {#if dropIndex === $openTabs.length && draggedId !== null}
      <div class="drop-indicator" aria-hidden="true" />
    {/if}
  </div>
  {#if hasOverflow}
    <div class="scroll-track" aria-hidden="true">
      <div class="thumb" style="left: {thumbLeft}px; width: {thumbWidth}px" />
    </div>
  {/if}
</div>

<style>
  .tabbar-wrap {
    position: relative;
    background: var(--bg-1);
    border-bottom: 1px solid var(--bg-3);
    overflow: hidden;
  }
  .tabbar-wrap::before,
  .tabbar-wrap::after {
    content: "";
    position: absolute;
    top: 0;
    bottom: 0;
    width: 20px;
    pointer-events: none;
    opacity: 0;
    transition: opacity 140ms ease;
    z-index: 2;
  }
  .tabbar-wrap::before {
    left: 0;
    background: linear-gradient(to right, var(--bg-1) 30%, transparent);
  }
  .tabbar-wrap::after {
    right: 0;
    background: linear-gradient(to left, var(--bg-1) 30%, transparent);
  }
  .tabbar-wrap.fade-left::before { opacity: 1; }
  .tabbar-wrap.fade-right::after { opacity: 1; }

  .tabbar {
    display: flex;
    overflow-x: auto;
    overflow-y: hidden;
    min-height: 32px;
    scrollbar-width: none;
  }
  .tabbar::-webkit-scrollbar { display: none; }

  .scroll-track {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 3px;
    pointer-events: none;
    opacity: 0;
    transition: opacity 140ms ease;
    z-index: 3;
  }
  .tabbar-wrap:hover .scroll-track { opacity: 1; }
  .thumb {
    position: absolute;
    top: 0;
    bottom: 0;
    background: var(--fg-2);
    border-radius: 2px;
    opacity: 0.55;
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
    flex-shrink: 0;
    user-select: none;
  }
  .tab:hover { background: var(--bg-2); }
  .tab.active { background: var(--bg-0); color: white; }
  .tab.dragging { opacity: 0.4; }

  .drop-indicator {
    width: 2px;
    align-self: stretch;
    background: var(--accent, #4a9eff);
    border-radius: 1px;
    flex-shrink: 0;
    pointer-events: none;
  }

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
