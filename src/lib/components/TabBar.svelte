<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import { openTabs, activeTabId, dirtyTabs } from "$lib/stores/tabs";
  import { closeNoteTab } from "$lib/tabManager";

  let tabbarEl: HTMLDivElement;
  let scrollLeft = 0;
  let clientWidth = 0;
  let scrollWidth = 0;

  // Fade gradients on the left/right edges hint that there's more content
  // scrolled out of view — a calmer affordance than a full scrollbar.
  $: showLeft = scrollLeft > 1;
  $: showRight = scrollWidth - (scrollLeft + clientWidth) > 1;
  $: hasOverflow = scrollWidth > clientWidth + 1;
  // Custom thumb that mirrors native scrollbar position. Visual-only
  // (pointer-events: none) — dragging isn't supported; users scroll via
  // wheel/trackpad. The 20-px minimum width keeps the thumb graspable
  // visually even when very many tabs are open.
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
  });

  // Recompute fade/thumb state whenever the tab list mutates.
  $: if ($openTabs) void tick().then(measure);

  // A plain vertical wheel (trackpad/mouse) should scroll the tab strip
  // horizontally — the tabbar has no vertical axis to scroll.
  function onWheel(e: WheelEvent) {
    if (!tabbarEl) return;
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      tabbarEl.scrollLeft += e.deltaY;
      e.preventDefault();
    }
  }
</script>

<div class="tabbar-wrap" class:fade-left={showLeft} class:fade-right={showRight}>
  <div class="tabbar" bind:this={tabbarEl} on:scroll={measure} on:wheel={onWheel}>
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
    scrollbar-width: none; /* Firefox */
  }
  .tabbar::-webkit-scrollbar {
    /* Hide native scrollbar — never squish the tab strip. The fade
       gradients above plus the custom thumb below convey scroll state. */
    display: none;
  }

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
