<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import Sidebar from "$lib/components/Sidebar.svelte";
  import EditorPane from "$lib/components/EditorPane.svelte";
  import Toast from "$lib/components/Toast.svelte";
  import ConfirmClose from "$lib/components/ConfirmClose.svelte";
  import ConfirmDelete from "$lib/components/ConfirmDelete.svelte";
  import BottomBar from "$lib/components/BottomBar.svelte";
  import TrashPanel from "$lib/components/TrashPanel.svelte";
  import Spotlight from "$lib/components/Spotlight.svelte";
  import ContextMenu from "$lib/components/ContextMenu.svelte";
  import Settings from "$lib/components/Settings.svelte";
  import NotionConflicts from "$lib/components/NotionConflicts.svelte";
  import UpdateBanner from "$lib/components/UpdateBanner.svelte";
  import { spotlightOpen } from "$lib/stores/spotlight";
  import { settingsOpen } from "$lib/stores/settings";
  import { startAutoSave } from "$lib/autoSave";
  import { startNotionSync } from "$lib/notionSync";
  import { measureMetrics, metrics } from "$lib/editor/measure";
  import { editorFontSize, zoomIn, zoomOut, zoomReset } from "$lib/editor/fontSize";
  import {
    sidebarWidth,
    sidebarCollapsed,
    toggleSidebar,
    SIDEBAR_MIN,
    SIDEBAR_MAX,
  } from "$lib/stores/sidebar";
  import { startSessionAutoflush } from "$lib/sessionManager";
  import { createAndOpenNote, closeNoteTab, deleteNotes } from "$lib/tabManager";
  import { activeTabId, openTabs } from "$lib/stores/tabs";
  import { toast, selectedNoteIds } from "$lib/stores/ui";
  import { notes } from "$lib/stores/workspace";
  import { confirmDelete } from "$lib/stores/confirmDelete";
  import { initMenuBridge, menuAction } from "$lib/menu";
  import { get } from "svelte/store";
  import { fetchLatestUpdate } from "$lib/updater";
  import { pendingUpdate, updateChannel } from "$lib/stores/update";

  let stopAutoflush: (() => void) | null = null;
  let stopAutoSave: (() => void) | null = null;
  let stopNotionSync: (() => void) | null = null;
  let stopMenuBridge: (() => void) | null = null;
  let stopMenuSub: (() => void) | null = null;

  function cycleTab(dir: 1 | -1) {
    const tabs = get(openTabs);
    if (tabs.length === 0) return;
    const current = get(activeTabId);
    const idx = tabs.findIndex((t) => t.id === current);
    const next = tabs[((idx < 0 ? 0 : idx) + dir + tabs.length) % tabs.length];
    activeTabId.set(next.id);
  }

  function onGlobalKey(e: KeyboardEvent) {
    if (e.ctrlKey && !e.metaKey && !e.altKey && e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      cycleTab(e.shiftKey ? -1 : 1);
      return;
    }
    const mod = e.metaKey || e.ctrlKey;
    // Cmd+A: let the editor handle it when focus is in a text input. In any
    // other context, swallow it so the browser doesn't select the sidebar.
    if (mod && !e.shiftKey && !e.altKey && (e.key === "a" || e.key === "A")) {
      const t = e.target as HTMLElement | null;
      const isTextTarget =
        !!t &&
        (t.tagName === "INPUT" ||
          t.tagName === "TEXTAREA" ||
          (t as HTMLElement).isContentEditable);
      if (!isTextTarget) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
    }
    // Zoom: allow with or without shift so both Cmd+= and Cmd++ work.
    if (mod && !e.altKey) {
      const k = e.key;
      if (k === "=" || k === "+") {
        e.preventDefault();
        e.stopPropagation();
        zoomIn();
        return;
      }
      if (k === "-" || k === "_") {
        e.preventDefault();
        e.stopPropagation();
        zoomOut();
        return;
      }
      if (k === "0") {
        e.preventDefault();
        e.stopPropagation();
        zoomReset();
        return;
      }
    }
    if (!mod || e.shiftKey || e.altKey) return;
    if (e.key === "b" || e.key === "B") {
      e.preventDefault();
      e.stopPropagation();
      toggleSidebar();
      return;
    }
    if (e.key === "k" || e.key === "K") {
      e.preventDefault();
      e.stopPropagation();
      spotlightOpen.update((v) => !v);
      return;
    }
    if (e.key === ",") {
      // Cmd/Ctrl+, — open Settings. On macOS the native menu also fires this
      // via "app:settings"; this keydown path covers the web/dev runtime.
      e.preventDefault();
      e.stopPropagation();
      settingsOpen.set(true);
      return;
    }
    if (e.key === "Backspace") {
      const sel = get(selectedNoteIds);
      if (sel.size === 0) return;
      e.preventDefault();
      e.stopPropagation();
      const ids = [...sel];
      const list = get(notes);
      const sample = list.find((n) => n.id === ids[0])?.title ?? "Untitled";
      confirmDelete.set({
        count: ids.length,
        sampleTitle: sample,
        onConfirm: () => deleteNotes(ids),
      });
      return;
    }
    if (e.key === "n" || e.key === "N") {
      e.preventDefault();
      e.stopPropagation();
      createAndOpenNote().catch((err) => {
        console.error(err);
        toast("Failed to create note");
      });
      return;
    }
    if (e.key === "w" || e.key === "W") {
      const id = get(activeTabId);
      if (!id) return;
      e.preventDefault();
      e.stopPropagation();
      closeNoteTab(id).catch((err) => {
        console.error(err);
        toast("Failed to close tab");
      });
    }
  }

  // Drag-to-resize sidebar. Dragging past the minimum collapses the sidebar;
  // once collapsed, the user can reopen via the edge peek, a click on the
  // resizer remnant, or Cmd+B.
  let resizing = false;
  function onResizeStart(e: MouseEvent) {
    if (e.button !== 0) return;
    e.preventDefault();
    resizing = true;
    const startX = e.clientX;
    const startW = get(sidebarWidth);
    const move = (ev: MouseEvent) => {
      const w = startW + (ev.clientX - startX);
      if (w < SIDEBAR_MIN - 40) {
        sidebarCollapsed.set(true);
      } else {
        sidebarCollapsed.set(false);
        sidebarWidth.set(Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, w)));
      }
    };
    const up = () => {
      resizing = false;
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  }

  // Peek-on-hover: when collapsed, hovering near the left edge floats the
  // sidebar in as an overlay. A small grace timeout on mouseleave prevents
  // jitter when moving between the edge trigger and the floating panel.
  let peeking = false;
  let peekTimer: ReturnType<typeof setTimeout> | null = null;
  function onPeekEnter() {
    if (peekTimer) {
      clearTimeout(peekTimer);
      peekTimer = null;
    }
    peeking = true;
  }
  function onPeekLeave() {
    if (peekTimer) clearTimeout(peekTimer);
    peekTimer = setTimeout(() => {
      peeking = false;
      peekTimer = null;
    }, 140);
  }

  // App-level menu actions. Editor-scoped items (save / undo / redo /
  // select-all) are handled inside Editor.svelte, which subscribes to the
  // same store.
  function handleMenuAction(action: string) {
    switch (action) {
      case "app:settings":
        settingsOpen.set(true);
        return;
      case "view:toggle-sidebar":
        toggleSidebar();
        return;
      case "view:spotlight":
        spotlightOpen.update((v) => !v);
        return;
      case "view:zoom-in":
        zoomIn();
        return;
      case "view:zoom-out":
        zoomOut();
        return;
      case "view:zoom-reset":
        zoomReset();
        return;
      case "file:new-note":
        createAndOpenNote().catch((err) => {
          console.error(err);
          toast("Failed to create note");
        });
        return;
      case "file:close-tab": {
        const id = get(activeTabId);
        if (!id) return;
        closeNoteTab(id).catch((err) => {
          console.error(err);
          toast("Failed to close tab");
        });
        return;
      }
      case "tab:next":
        cycleTab(1);
        return;
      case "tab:prev":
        cycleTab(-1);
        return;
    }
  }

  let stopFontSub: (() => void) | null = null;
  onMount(() => {
    stopFontSub = editorFontSize.subscribe((fs) => measureMetrics(fs));
    stopAutoflush = startSessionAutoflush();
    stopAutoSave = startAutoSave();
    // Loads the workspace's Notion config, arms the periodic sync, and (if
    // enabled) schedules the one-shot sync a couple of seconds after boot.
    stopNotionSync = startNotionSync();
    // Subscribe to menu events. Skip the initial null value the store
    // starts at; only act on each new emit.
    stopMenuSub = menuAction.subscribe((ev) => {
      if (ev) handleMenuAction(ev.action);
    });
    initMenuBridge().then((unlisten) => {
      stopMenuBridge = unlisten;
    });
    window.addEventListener("keydown", onGlobalKey, true);
    // Check for updates in the background; failures are silently ignored.
    fetchLatestUpdate(get(updateChannel))
      .then((info) => { if (info) pendingUpdate.set(info); })
      .catch(() => {});
    // In the packaged WKWebView the monospace probe sometimes measures while
    // fonts are still being substituted, producing an inflated chWidth that
    // pushes the caret past the real glyph advance. Re-measure once fonts are
    // ready and again on the next frame for safety.
    const remeasure = () => measureMetrics(get(editorFontSize));
    const fonts = (document as Document & { fonts?: FontFaceSet }).fonts;
    if (fonts?.ready) fonts.ready.then(remeasure).catch(() => {});
    requestAnimationFrame(() => requestAnimationFrame(remeasure));
  });

  // Keep CSS vars in sync so the editor CSS (font-size, line-height) picks up
  // zoom changes without each component re-subscribing.
  $: if (typeof document !== "undefined") {
    document.documentElement.style.setProperty("--editor-font-size", `${$editorFontSize}px`);
    document.documentElement.style.setProperty("--editor-row-height", `${$metrics.rowHeight}px`);
  }

  onDestroy(() => {
    if (stopAutoflush) stopAutoflush();
    if (stopAutoSave) stopAutoSave();
    if (stopNotionSync) stopNotionSync();
    if (stopFontSub) stopFontSub();
    if (stopMenuSub) stopMenuSub();
    if (stopMenuBridge) stopMenuBridge();
    window.removeEventListener("keydown", onGlobalKey, true);
  });
</script>

<div class="shell">
  <div
    class="layout"
    class:collapsed={$sidebarCollapsed}
    class:peeking
    class:resizing
    style="--sidebar-w: {$sidebarWidth}px"
  >
    <!-- svelte-ignore a11y-no-static-element-interactions -->
    <div
      class="sidebar-slot"
      on:mouseenter={$sidebarCollapsed ? onPeekEnter : undefined}
      on:mouseleave={$sidebarCollapsed ? onPeekLeave : undefined}
    >
      <Sidebar />
    </div>
    <!-- svelte-ignore a11y-no-static-element-interactions a11y-no-noninteractive-element-interactions -->
    <div
      class="resizer"
      on:mousedown={onResizeStart}
      on:dblclick={toggleSidebar}
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize sidebar"
      title="Drag to resize · double-click to toggle"
    />
    <div class="editor-slot">
      <EditorPane />
    </div>
    {#if $sidebarCollapsed}
      <!-- svelte-ignore a11y-no-static-element-interactions -->
      <div
        class="edge-trigger"
        on:mouseenter={onPeekEnter}
        on:mouseleave={onPeekLeave}
      />
    {/if}
  </div>
  <BottomBar />
</div>
<Toast />
<ConfirmClose />
<ConfirmDelete />
<TrashPanel />
<Spotlight />
<ContextMenu />
<Settings />
<NotionConflicts />
<UpdateBanner />

<style>
  .shell {
    display: flex;
    flex-direction: column;
    height: 100vh;
    width: 100vw;
  }
  .layout {
    display: grid;
    grid-template-columns: var(--sidebar-w) 4px 1fr;
    flex: 1;
    min-height: 0;
    position: relative;
    /* Smooth collapse/expand. The editor's ResizeObserver sees the
       growing cell width tick-by-tick during the animation and re-wraps
       on each frame, so the text reflows in sync with the sidebar. */
    transition: grid-template-columns 180ms cubic-bezier(0.4, 0, 0.2, 1);
  }
  .layout.resizing {
    /* Drag-resize must track the pointer 1:1 — easing would feel laggy. */
    transition: none;
  }
  .layout.collapsed {
    /* Sidebar + resizer collapse out of the grid; editor takes the whole
       width. The sidebar-slot still exists (peek overlays it). */
    grid-template-columns: 0 0 1fr;
  }
  .sidebar-slot {
    grid-column: 1;
    overflow: hidden;
    display: flex;
    min-width: 0;
    opacity: 1;
    /* Opacity fades sync with width. Visibility flips instantly on the
       way *in* (so content is interactive as soon as it starts appearing)
       but is delayed on the way out — see the .collapsed rule. */
    transition: opacity 160ms ease, visibility 0s linear;
  }
  .sidebar-slot > :global(*) {
    width: 100%;
  }
  .layout.collapsed .sidebar-slot {
    /* Keep the slot in the grid (width forced to 0 by the template) so the
       editor-slot stays in column 3. Fade out via opacity; delay the
       visibility:hidden so the fade is actually visible. */
    opacity: 0;
    visibility: hidden;
    transition: opacity 140ms ease, visibility 0s 140ms linear;
  }
  .layout.resizing .sidebar-slot {
    /* During pointer-drag, fade shouldn't lag the pointer either. */
    transition: none;
  }
  .layout.collapsed.peeking .sidebar-slot {
    visibility: visible;
    opacity: 1;
    display: flex;
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: var(--sidebar-w);
    z-index: 30;
    box-shadow: 6px 0 20px rgba(0, 0, 0, 0.4);
    background: var(--bg-1);
    animation: peek-in 140ms ease;
  }
  @keyframes peek-in {
    from {
      transform: translateX(-6px);
      opacity: 0.6;
    }
    to {
      transform: translateX(0);
      opacity: 1;
    }
  }
  .resizer {
    grid-column: 2;
    background: var(--bg-3);
    cursor: col-resize;
    transition: background 120ms;
  }
  .resizer:hover,
  .layout.resizing .resizer {
    background: var(--accent, #3b82f6);
  }
  .layout.collapsed .resizer {
    /* Track collapses to 0 width; hide the handle but keep the grid cell
       reserved so the editor-slot stays in column 3. */
    visibility: hidden;
    pointer-events: none;
  }
  .editor-slot {
    grid-column: 3;
    min-width: 0;
    min-height: 0;
    display: flex;
  }
  .editor-slot > :global(*) {
    flex: 1;
    min-width: 0;
  }
  .edge-trigger {
    /* Invisible 6-px hotspot on the left edge; triggers the peek overlay. */
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 6px;
    z-index: 20;
  }
</style>
