<script lang="ts">
  import {
    activeConflict,
    conflictPanelOpen,
    conflicts,
    openConflict,
    refreshConflicts,
    resolve,
    resolveAll,
  } from "$lib/stores/notion";
  import type {
    BulkResolvePolicy,
    ConflictKind,
    ConflictResolution,
  } from "$lib/types";

  let selected: string | null = null;
  let busy = false;
  /** The bulk policy awaiting confirmation. Bulk actions touch every conflict
   *  at once, so they ask before firing rather than offering an undo. */
  let pendingBulk: BulkResolvePolicy | null = null;

  const BULK: Array<{ policy: BulkResolvePolicy; label: string; hint: string }> = [
    {
      policy: "local",
      label: "Keep Nova everywhere",
      hint: "Nova's version wins; notes deleted in Notion are recreated there.",
    },
    {
      policy: "remote",
      label: "Use Notion everywhere",
      hint: "Notion's version wins, including its deletions.",
    },
    {
      policy: "both",
      label: "Keep everything",
      hint: "Nothing is discarded: differing pages are kept as a second note, and no deletion is applied.",
    },
  ];

  /** Fires the pending bulk choice. Reading the variable here rather than in
   *  the template keeps TS narrowing out of Svelte's parser. */
  function confirmBulk() {
    if (pendingBulk) void applyBulk(pendingBulk);
  }

  async function applyBulk(policy: BulkResolvePolicy) {
    if (busy) return;
    busy = true;
    pendingBulk = null;
    try {
      await resolveAll(policy);
      selected = null;
      await onOpen();
      if ($conflicts.length === 0) close();
    } finally {
      busy = false;
    }
  }

  $: if ($conflictPanelOpen) void onOpen();

  async function onOpen() {
    await refreshConflicts();
    // Keep the current selection if it survived; otherwise show the newest.
    const list = $conflicts;
    if (!selected || !list.some((c) => c.noteId === selected)) {
      selected = list[0]?.noteId ?? null;
    }
    if (selected) await openConflict(selected);
  }

  async function select(noteId: string) {
    selected = noteId;
    await openConflict(noteId);
  }

  function close() {
    conflictPanelOpen.set(false);
    activeConflict.set(null);
    pendingBulk = null;
  }

  async function apply(resolution: ConflictResolution) {
    if (!selected || busy) return;
    busy = true;
    try {
      const ok = await resolve(selected, resolution);
      if (ok) {
        selected = null;
        await onOpen();
        if ($conflicts.length === 0) close();
      }
    } finally {
      busy = false;
    }
  }

  const KIND_LABEL: Record<ConflictKind, string> = {
    "both-changed": "Edited on both sides",
    "remote-deleted": "Deleted in Notion",
    "local-deleted": "Deleted in Nova",
  };

  /** Options depend on what actually happened — offering "keep both" for a
   *  deletion would be meaningless. */
  function choices(kind: ConflictKind): Array<{
    resolution: ConflictResolution;
    label: string;
    danger?: boolean;
  }> {
    switch (kind) {
      case "remote-deleted":
        return [
          { resolution: "recreateRemote", label: "Recreate in Notion" },
          { resolution: "acceptRemoteDelete", label: "Delete here too", danger: true },
        ];
      case "local-deleted":
        return [
          { resolution: "restoreLocal", label: "Restore in Nova" },
          { resolution: "acceptLocalDelete", label: "Delete in Notion too", danger: true },
        ];
      default:
        return [
          { resolution: "keepLocal", label: "Keep Nova version" },
          { resolution: "keepRemote", label: "Use Notion version" },
          { resolution: "keepBoth", label: "Keep both" },
        ];
    }
  }

  /** Line-level diff marks: a line is highlighted when the other side has no
   *  identical line left to pair it with. Cheap, and enough to spot what moved
   *  without pulling in a diff library. */
  function marks(mine: string, theirs: string): Array<{ text: string; changed: boolean }> {
    const pool = new Map<string, number>();
    for (const l of theirs.split("\n")) pool.set(l, (pool.get(l) ?? 0) + 1);
    return mine.split("\n").map((text) => {
      const n = pool.get(text) ?? 0;
      if (n > 0) {
        pool.set(text, n - 1);
        return { text, changed: false };
      }
      return { text, changed: true };
    });
  }

  $: detail = $activeConflict;
  $: localLines = detail ? marks(detail.localContent ?? "", detail.remoteContent ?? "") : [];
  $: remoteLines = detail ? marks(detail.remoteContent ?? "", detail.localContent ?? "") : [];

  function onKeydown(e: KeyboardEvent) {
    if (!$conflictPanelOpen) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  }

  function formatTime(ms: number): string {
    return new Date(ms).toLocaleString();
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $conflictPanelOpen}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="backdrop" on:click={close} role="presentation">
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-noninteractive-element-interactions -->
    <div
      class="dialog"
      role="dialog"
      aria-modal="true"
      aria-label="Notion conflicts"
      on:click|stopPropagation
      on:keydown|stopPropagation
      data-testid="notion-conflicts"
    >
      <header>
        <span class="title">Notion conflicts</span>
        <button class="close" on:click={close} aria-label="Close">×</button>
      </header>

      {#if $conflicts.length === 0}
        <div class="empty">No conflicts. Everything is in sync.</div>
      {:else}
        {#if $conflicts.length > 1}
          <div class="bulk" data-testid="notion-bulk">
            {#if pendingBulk}
              {@const choice = BULK.find((b) => b.policy === pendingBulk)}
              <span class="bulk-confirm">
                Apply <b>{choice?.label}</b> to all {$conflicts.length} conflicts?
                <span class="bulk-hint">{choice?.hint}</span>
              </span>
              <button
                class="danger"
                disabled={busy}
                on:click={confirmBulk}
                data-testid="notion-bulk-confirm"
              >
                {busy ? "Applying…" : "Apply to all"}
              </button>
              <button disabled={busy} on:click={() => (pendingBulk = null)}>Cancel</button>
            {:else}
              <span class="bulk-label">Resolve all {$conflicts.length}:</span>
              {#each BULK as b (b.policy)}
                <button
                  title={b.hint}
                  disabled={busy}
                  on:click={() => (pendingBulk = b.policy)}
                  data-policy={b.policy}
                >
                  {b.label}
                </button>
              {/each}
            {/if}
          </div>
        {/if}
        <div class="body">
          <ul class="list">
            {#each $conflicts as c (c.noteId)}
              <li>
                <button
                  class="entry"
                  class:active={c.noteId === selected}
                  on:click={() => select(c.noteId)}
                  data-note-id={c.noteId}
                >
                  <span class="entry-title">
                    {c.localTitle ?? c.remoteTitle ?? "Untitled"}
                  </span>
                  <span class="badge">{KIND_LABEL[c.kind]}</span>
                  <span class="when">{formatTime(c.detectedMs)}</span>
                </button>
              </li>
            {/each}
          </ul>

          <div class="detail">
            {#if !detail}
              <div class="empty">Select a conflict.</div>
            {:else}
              <div class="panes">
                <div class="pane">
                  <div class="pane-head">In Nova</div>
                  {#if detail.localContent == null}
                    <div class="gone">Deleted here.</div>
                  {:else}
                    <pre data-testid="conflict-local">{#each localLines as l}<span
                          class:changed={l.changed}>{l.text}
</span>{/each}</pre>
                  {/if}
                </div>
                <div class="pane">
                  <div class="pane-head">In Notion</div>
                  {#if detail.remoteContent == null}
                    <div class="gone">Deleted there.</div>
                  {:else}
                    <pre data-testid="conflict-remote">{#each remoteLines as l}<span
                          class:changed={l.changed}>{l.text}
</span>{/each}</pre>
                  {/if}
                </div>
              </div>

              <div class="actions">
                {#each choices(detail.kind) as c (c.resolution)}
                  <button
                    class:danger={c.danger}
                    disabled={busy}
                    on:click={() => apply(c.resolution)}
                    data-resolution={c.resolution}
                  >
                    {c.label}
                  </button>
                {/each}
              </div>
              <p class="note">
                Nothing is changed until you choose. Until then this note is left
                out of syncing.
              </p>
            {/if}
          </div>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: grid;
    place-items: center;
    z-index: 1200;
  }
  .dialog {
    width: min(900px, 92vw);
    height: min(600px, 82vh);
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 8px;
    box-shadow: 0 24px 80px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 14px;
    border-bottom: 1px solid var(--bg-2);
  }
  .title {
    font-size: 14px;
    font-weight: 600;
    color: var(--fg-0);
  }
  .close {
    background: transparent;
    border: none;
    color: var(--fg-2);
    cursor: pointer;
    font-size: 18px;
    line-height: 1;
    padding: 0 6px;
  }
  .close:hover {
    color: var(--fg-0);
  }
  .bulk {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    padding: 9px 14px;
    border-bottom: 1px solid var(--bg-2);
    background: var(--bg-2);
    font-size: 11px;
    color: var(--fg-2);
  }
  .bulk-label {
    color: var(--fg-1);
  }
  .bulk-confirm {
    color: var(--fg-0);
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .bulk-confirm b {
    font-weight: 600;
  }
  .bulk-hint {
    color: var(--fg-2);
  }
  .bulk button {
    background: var(--bg-0);
    color: var(--fg-1);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    padding: 4px 9px;
    font-size: 11px;
    font-family: inherit;
    cursor: pointer;
    white-space: nowrap;
  }
  .bulk button:hover:not(:disabled) {
    border-color: var(--accent, #7aa2f7);
    color: var(--accent, #7aa2f7);
  }
  .bulk button.danger:hover:not(:disabled) {
    border-color: #f7768e;
    color: #f7768e;
  }
  .bulk button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .body {
    flex: 1;
    display: grid;
    grid-template-columns: 240px 1fr;
    min-height: 0;
  }
  .list {
    list-style: none;
    margin: 0;
    padding: 6px;
    overflow-y: auto;
    border-right: 1px solid var(--bg-2);
  }
  .entry {
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    color: var(--fg-1);
    cursor: pointer;
    padding: 7px 8px;
    border-radius: 4px;
    display: grid;
    gap: 3px;
    font-family: inherit;
  }
  .entry:hover {
    background: var(--bg-2);
  }
  .entry.active {
    background: var(--bg-2);
    color: var(--fg-0);
  }
  .entry-title {
    font-size: 13px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .badge {
    font-size: 10px;
    color: #e0af68;
  }
  .when {
    font-size: 10px;
    color: var(--fg-2);
  }
  .detail {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding: 12px;
    gap: 10px;
  }
  .panes {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    min-height: 0;
  }
  .pane {
    display: flex;
    flex-direction: column;
    min-height: 0;
    border: 1px solid var(--bg-3);
    border-radius: 6px;
    overflow: hidden;
  }
  .pane-head {
    padding: 6px 9px;
    font-size: 11px;
    color: var(--fg-2);
    background: var(--bg-2);
    border-bottom: 1px solid var(--bg-3);
  }
  pre {
    margin: 0;
    padding: 8px 9px;
    flex: 1;
    overflow: auto;
    font-family: var(--font-mono);
    font-size: 11px;
    line-height: 1.55;
    color: var(--fg-1);
    white-space: pre-wrap;
    word-break: break-word;
  }
  pre :global(span.changed) {
    background: rgba(224, 175, 104, 0.16);
    color: var(--fg-0);
  }
  .gone {
    flex: 1;
    display: grid;
    place-items: center;
    font-size: 12px;
    color: var(--fg-2);
  }
  .actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .actions button {
    background: var(--bg-0);
    color: var(--fg-0);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    padding: 6px 12px;
    font-size: 12px;
    font-family: inherit;
    cursor: pointer;
  }
  .actions button:hover:not(:disabled) {
    border-color: var(--accent, #7aa2f7);
    color: var(--accent, #7aa2f7);
  }
  .actions button.danger:hover:not(:disabled) {
    border-color: #f7768e;
    color: #f7768e;
  }
  .actions button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .note {
    margin: 0;
    font-size: 11px;
    color: var(--fg-2);
  }
  .empty {
    flex: 1;
    display: grid;
    place-items: center;
    color: var(--fg-2);
    font-size: 12px;
    padding: 30px;
  }
</style>
