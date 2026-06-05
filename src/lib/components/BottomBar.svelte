<script lang="ts">
  import { editorStatus } from "$lib/stores/editorStatus";
  import { trashPanelOpen } from "$lib/stores/trashPanel";
  import { settingsOpen } from "$lib/stores/settings";

  function openTrash() {
    trashPanelOpen.set(true);
  }

  function openSettings() {
    settingsOpen.set(true);
  }
</script>

<footer>
  <div class="left">
    <button
      class="bar-btn"
      on:click={openTrash}
      title="Open trash"
      aria-label="Open trash"
    >
      <svg
        class="icon"
        viewBox="0 0 16 16"
        width="12"
        height="12"
        fill="none"
        stroke="currentColor"
        stroke-width="1.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M2.5 4h11" />
        <path d="M6 4V2.5h4V4" />
        <path d="M3.5 4l.7 9a1 1 0 0 0 1 .9h5.6a1 1 0 0 0 1-.9l.7-9" />
        <path d="M6.5 7v4" />
        <path d="M9.5 7v4" />
      </svg>
      <span>Trash</span>
    </button>
    <button
      class="bar-btn"
      on:click={openSettings}
      title="Settings (⌘,)"
      aria-label="Open settings"
    >
      <svg
        class="icon"
        viewBox="0 0 16 16"
        width="12"
        height="12"
        fill="none"
        stroke="currentColor"
        stroke-width="1.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <circle cx="8" cy="8" r="2" />
        <path d="M8 1.5v1.6M8 12.9v1.6M3.4 3.4l1.1 1.1M11.5 11.5l1.1 1.1M1.5 8h1.6M12.9 8h1.6M3.4 12.6l1.1-1.1M11.5 4.5l1.1-1.1" />
      </svg>
      <span>Settings</span>
    </button>
  </div>
  <div class="right">
    {#if $editorStatus}
      {#if $editorStatus.selectionChars > 0}
        <span>
          {$editorStatus.selectionChars} chars selected
          ({$editorStatus.selectionCharsNoWs} excl. whitespace)
        </span>
      {:else}
        <span>Ln {$editorStatus.line + 1}, Col {$editorStatus.col + 1}</span>
      {/if}
    {/if}
  </div>
</footer>

<style>
  footer {
    display: flex;
    justify-content: space-between;
    align-items: stretch;
    height: 22px;
    background: var(--bg-1);
    border-top: 1px solid var(--bg-3);
    font-size: 11px;
    color: var(--fg-2);
    user-select: none;
  }
  .left {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 0 6px;
  }
  .right {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    padding: 0 10px;
    font-family: var(--font-mono);
  }
  .bar-btn {
    background: transparent;
    border: none;
    color: var(--fg-2);
    cursor: pointer;
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 3px;
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }
  .bar-btn:hover {
    background: var(--bg-2);
    color: var(--fg-0);
  }
  .icon { display: block; }
</style>
