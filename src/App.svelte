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
  import { spotlightOpen } from "$lib/stores/spotlight";
  import { measureMetrics, metrics } from "$lib/editor/measure";
  import { editorFontSize, zoomIn, zoomOut, zoomReset } from "$lib/editor/fontSize";
  import { startSessionAutoflush } from "$lib/sessionManager";
  import { createAndOpenNote, closeNoteTab, deleteNotes } from "$lib/tabManager";
  import { activeTabId, openTabs } from "$lib/stores/tabs";
  import { toast, selectedNoteIds } from "$lib/stores/ui";
  import { notes } from "$lib/stores/workspace";
  import { confirmDelete } from "$lib/stores/confirmDelete";
  import { get } from "svelte/store";

  let stopAutoflush: (() => void) | null = null;

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
    if (e.key === "k" || e.key === "K") {
      e.preventDefault();
      e.stopPropagation();
      spotlightOpen.update((v) => !v);
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

  let stopFontSub: (() => void) | null = null;
  onMount(() => {
    stopFontSub = editorFontSize.subscribe((fs) => measureMetrics(fs));
    stopAutoflush = startSessionAutoflush();
    window.addEventListener("keydown", onGlobalKey, true);
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
    if (stopFontSub) stopFontSub();
    window.removeEventListener("keydown", onGlobalKey, true);
  });
</script>

<div class="shell">
  <div class="layout">
    <Sidebar />
    <div class="divider" />
    <EditorPane />
  </div>
  <BottomBar />
</div>
<Toast />
<ConfirmClose />
<ConfirmDelete />
<TrashPanel />
<Spotlight />

<style>
  .shell {
    display: flex;
    flex-direction: column;
    height: 100vh;
    width: 100vw;
  }
  .layout {
    display: grid;
    grid-template-columns: 260px 1px 1fr;
    flex: 1;
    min-height: 0;
  }
  .divider {
    background: var(--bg-3);
  }
</style>
