<script lang="ts">
  import { onMount } from "svelte";
  import { get } from "svelte/store";
  import { ipc } from "$lib/ipc";
  import { workspacePath, notes } from "$lib/stores/workspace";
  import { activeTabId } from "$lib/stores/tabs";
  import { toast, collapsedGroups, selectedNoteIds, selectionAnchor } from "$lib/stores/ui";
  import { openNote, createAndOpenNote, loadWorkspace, deleteNotes } from "$lib/tabManager";
  import { confirmDelete } from "$lib/stores/confirmDelete";
  import { openContextMenu } from "$lib/stores/contextMenu";
  import DateGroup from "./DateGroup.svelte";
  import { sortedGroups } from "$lib/stores/workspace";

  async function chooseWorkspace() {
    const picked = await ipc.pickWorkspace();
    if (!picked) return;
    try {
      await loadWorkspace(picked);
    } catch (err) {
      console.error(err);
      toast("Failed to open workspace");
    }
  }

  async function newNote() {
    try {
      await createAndOpenNote();
    } catch (err) {
      console.error(err);
      toast("Failed to create note");
    }
  }

  // Flat ordered list of the note ids currently visible in the sidebar
  // (skips entries inside collapsed groups). Drives shift+click ranges.
  $: visibleIds = $sortedGroups
    .filter((g) => !$collapsedGroups.has(g.key))
    .flatMap((g) => g.entries.map((e) => e.id));

  function handleEntryClick(id: string, e: MouseEvent) {
    const mod = e.metaKey || e.ctrlKey;
    const shift = e.shiftKey;
    if (shift) {
      const anchor = get(selectionAnchor) ?? id;
      const ai = visibleIds.indexOf(anchor);
      const bi = visibleIds.indexOf(id);
      if (ai >= 0 && bi >= 0) {
        const [lo, hi] = ai <= bi ? [ai, bi] : [bi, ai];
        selectedNoteIds.set(new Set(visibleIds.slice(lo, hi + 1)));
      } else {
        selectedNoteIds.set(new Set([id]));
      }
      return;
    }
    if (mod) {
      selectedNoteIds.update((s) => {
        const n = new Set(s);
        if (n.has(id)) n.delete(id);
        else n.add(id);
        return n;
      });
      selectionAnchor.set(id);
      return;
    }
    selectedNoteIds.set(new Set([id]));
    selectionAnchor.set(id);
    void openNote(id);
  }

  // Right-click on a note row: open a floating menu with Reveal-in-Finder +
  // Delete. If the row is already part of a multi-selection, act on the whole
  // group; otherwise treat the right-clicked row as the target.
  function handleEntryContextMenu(id: string, e: MouseEvent) {
    const current = get(selectedNoteIds);
    const targets = current.has(id) && current.size > 1 ? [...current] : [id];
    if (!current.has(id)) {
      selectedNoteIds.set(new Set([id]));
      selectionAnchor.set(id);
    }
    const list = get(notes);
    const sample = list.find((n) => n.id === targets[0])?.title ?? "Untitled";
    const singular = targets.length === 1;
    openContextMenu(e.clientX, e.clientY, [
      {
        label: "Finder에서 보기",
        disabled: !singular,
        onSelect: async () => {
          try {
            await ipc.revealNote(id);
          } catch (err) {
            console.error(err);
            toast("Failed to reveal in Finder");
          }
        },
      },
      {
        label: singular ? "삭제" : `삭제 (${targets.length}개)`,
        danger: true,
        onSelect: () => {
          confirmDelete.set({
            count: targets.length,
            sampleTitle: sample,
            onConfirm: () => deleteNotes(targets),
          });
        },
      },
    ]);
  }

  let scrolling = false;
  let scrollTimer: ReturnType<typeof setTimeout> | null = null;

  function onScroll() {
    scrolling = true;
    if (scrollTimer !== null) clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => {
      scrolling = false;
      scrollTimer = null;
    }, 1200);
  }

  onMount(() => {
    if (import.meta.env.VITE_BACKEND === "mock") {
      ipc.pickWorkspace().then((p) => {
        if (p) void loadWorkspace(p);
      });
      return;
    }
    const saved = localStorage.getItem("sublime-clone:lastWorkspace");
    if (saved) {
      loadWorkspace(saved).catch((err) => {
        console.error("restore last workspace failed", err);
      });
    }
  });
</script>

<aside>
  <header>
    <div class="actions">
      <button class="icon" on:click={newNote} title="New note" aria-label="New note">+</button>
      <button on:click={chooseWorkspace} title="Open workspace">Open…</button>
    </div>
  </header>

  {#if !$workspacePath}
    <div class="empty">No workspace opened</div>
  {:else}
    <div class="folder-label" title={$workspacePath}>{$workspacePath}</div>
    <div class="groups" class:scrolling on:scroll={onScroll}>
      {#if $notes.length === 0}
        <div class="empty-notes">No notes yet — click + to create one.</div>
      {:else}
        {#each $sortedGroups as g (g.key)}
          <DateGroup
            group={g}
            activeId={$activeTabId}
            onEntryClick={handleEntryClick}
            onEntryContextMenu={handleEntryContextMenu}
          />
        {/each}
      {/if}
    </div>
  {/if}
</aside>

<style>
  aside {
    background: var(--bg-1);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    height: 100%;
    min-height: 0;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 10px;
    border-bottom: 1px solid var(--bg-3);
  }
  .actions { display: flex; gap: 4px; margin-left: auto; }
  header button {
    font-size: 11px;
    padding: 2px 8px;
  }
  header button.icon {
    width: 22px;
    height: 22px;
    padding: 0;
    font-size: 14px;
    line-height: 1;
  }
  .folder-label {
    padding: 6px 10px;
    color: var(--fg-2);
    font-size: 11px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    border-bottom: 1px solid var(--bg-2);
  }
  .groups {
    flex: 1;
    overflow-y: auto;
    padding: 4px 0;
    scrollbar-width: thin;
    scrollbar-color: transparent transparent;
  }
  .groups::-webkit-scrollbar {
    width: 5px;
  }
  .groups::-webkit-scrollbar-thumb {
    background: transparent;
    border-radius: 3px;
    transition: background 0.25s ease;
  }
  .groups:hover::-webkit-scrollbar-thumb,
  .groups.scrolling::-webkit-scrollbar-thumb {
    background: rgba(80, 87, 99, 0.6);
  }
  .groups:hover {
    scrollbar-color: rgba(80, 87, 99, 0.6) transparent;
  }
  .groups.scrolling {
    scrollbar-color: rgba(80, 87, 99, 0.6) transparent;
  }
  .empty, .empty-notes {
    padding: 20px;
    text-align: center;
    color: var(--fg-2);
    font-size: 12px;
  }
</style>
