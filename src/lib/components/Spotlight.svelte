<script lang="ts">
  import { tick } from "svelte";
  import { get } from "svelte/store";
  import { ipc } from "$lib/ipc";
  import { spotlightOpen } from "$lib/stores/spotlight";
  import { openNote } from "$lib/tabManager";
  import { openTabs, getBuffer } from "$lib/stores/tabs";
  import { toast } from "$lib/stores/ui";
  import type { SearchHit, OpenTab } from "$lib/types";

  let query = "";
  let inputEl: HTMLInputElement | null = null;
  let hits: SearchHit[] = [];
  let selected = 0;
  let loading = false;
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  // Monotonic request id — late responses from a prior query are ignored
  // when a newer query has already started.
  let reqSeq = 0;

  function close() {
    spotlightOpen.set(false);
    query = "";
    hits = [];
    selected = 0;
  }

  $: if ($spotlightOpen) {
    void tick().then(() => inputEl?.focus());
  }

  function scheduleSearch() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(runSearch, 120);
  }

  // Build a SearchHit from an open tab's live buffer content so unsaved edits
  // are searchable. Plain case-insensitive substring — fine for English and
  // fully-typed Korean; partial-jamo still falls through to the backend FTS
  // for closed notes.
  function buildLiveHit(tab: OpenTab, q: string): SearchHit | null {
    const buf = getBuffer(tab.id);
    if (!buf) return null;
    const content = buf.toString();
    const pos = content.toLowerCase().indexOf(q.toLowerCase());
    if (pos === -1) return null;
    const CTX = 40;
    const start = Math.max(0, pos - CTX);
    const end = Math.min(content.length, pos + q.length + CTX);
    return {
      id: tab.id,
      title: tab.title || "Untitled",
      mtimeMs: tab.mtimeMs,
      score: 0,
      snippet: {
        prefixEllipsis: start > 0,
        suffixEllipsis: end < content.length,
        before: content.slice(start, pos),
        matched: content.slice(pos, pos + q.length),
        after: content.slice(pos + q.length, end),
      },
    };
  }

  async function runSearch() {
    const q = query.trim();
    if (!q) {
      hits = [];
      loading = false;
      return;
    }
    const mySeq = ++reqSeq;
    loading = true;
    try {
      const res = await ipc.searchNotes(q, 30);
      if (mySeq !== reqSeq) return;
      // For any tab currently open, trust its live content over the FTS index
      // so unsaved edits surface (and stale saved matches don't).
      const tabs = get(openTabs);
      const openIds = new Set(tabs.map((t) => t.id));
      const liveHits: SearchHit[] = [];
      for (const tab of tabs) {
        const h = buildLiveHit(tab, q);
        if (h) liveHits.push(h);
      }
      const backendFiltered = res.filter((h) => !openIds.has(h.id));
      hits = [...liveHits, ...backendFiltered].slice(0, 30);
      selected = 0;
    } catch (err) {
      if (mySeq !== reqSeq) return;
      console.error("search failed", err);
      toast("Search failed");
      hits = [];
    } finally {
      if (mySeq === reqSeq) loading = false;
    }
  }

  async function openSelected() {
    const hit = hits[selected];
    if (!hit) return;
    close();
    try {
      await openNote(hit.id);
    } catch (err) {
      console.error(err);
      toast("Failed to open note");
    }
  }

  function onInput() {
    scheduleSearch();
  }

  function onInputKey(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (hits.length) selected = (selected + 1) % hits.length;
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (hits.length) selected = (selected - 1 + hits.length) % hits.length;
    } else if (e.key === "Enter") {
      e.preventDefault();
      void openSelected();
    }
  }

  function onKeydown(e: KeyboardEvent) {
    if (!$spotlightOpen) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $spotlightOpen}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="backdrop" on:click={close} role="presentation">
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-noninteractive-element-interactions -->
    <div
      class="panel"
      role="dialog"
      aria-modal="true"
      aria-label="Spotlight"
      on:click|stopPropagation
      on:keydown|stopPropagation
    >
      <input
        bind:this={inputEl}
        bind:value={query}
        on:input={onInput}
        on:keydown={onInputKey}
        type="text"
        placeholder="Search notes…"
        spellcheck="false"
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
      />
      <div class="results">
        {#if !query.trim()}
          <div class="empty">Type to search titles and body.</div>
        {:else if loading && hits.length === 0}
          <div class="empty">Searching…</div>
        {:else if hits.length === 0}
          <div class="empty">No matches.</div>
        {:else}
          <ul>
            {#each hits as h, i (h.id)}
              <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-noninteractive-element-interactions -->
              <li
                class:active={i === selected}
                on:click={() => {
                  selected = i;
                  void openSelected();
                }}
                on:mousemove={() => (selected = i)}
                role="option"
                aria-selected={i === selected}
              >
                <span class="note-title">{h.title || "Untitled"}</span>
                {#if h.snippet}
                  <span class="snippet">
                    {#if h.snippet.prefixEllipsis}…{/if}{h.snippet.before}<mark
                      >{h.snippet.matched}</mark
                    >{h.snippet.after}{#if h.snippet.suffixEllipsis}…{/if}
                  </span>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.35);
    display: flex;
    justify-content: center;
    padding-top: 15vh;
    z-index: 1100;
  }
  .panel {
    width: min(560px, 90vw);
    max-height: 60vh;
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 8px;
    box-shadow: 0 24px 80px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  input {
    font-size: 16px;
    padding: 14px 16px;
    border: none;
    outline: none;
    background: transparent;
    color: var(--fg-0);
    border-bottom: 1px solid var(--bg-2);
    font-family: inherit;
  }
  .results {
    flex: 1;
    overflow-y: auto;
    min-height: 80px;
  }
  .empty {
    padding: 28px 16px;
    text-align: center;
    color: var(--fg-2);
    font-size: 12px;
  }
  ul {
    list-style: none;
    margin: 0;
    padding: 4px 0;
  }
  li {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 6px 16px;
    font-size: 13px;
    color: var(--fg-0);
    cursor: pointer;
  }
  li.active {
    background: var(--accent, #3b82f6);
    color: white;
  }
  .note-title {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .snippet {
    font-size: 11px;
    color: var(--fg-2);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  li.active .snippet {
    color: rgba(255, 255, 255, 0.85);
  }
  .snippet mark {
    background: rgba(255, 215, 0, 0.35);
    color: inherit;
    padding: 0 1px;
    border-radius: 2px;
  }
  li.active .snippet mark {
    background: rgba(255, 255, 255, 0.35);
  }
</style>
