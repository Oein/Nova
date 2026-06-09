<script lang="ts">
  import { pendingUpdate, updateDismissed } from "$lib/stores/update";
  import { preferredFile, fileDownloadUrl } from "$lib/updater";

  async function openDownload() {
    const update = $pendingUpdate;
    if (!update) return;
    const file = preferredFile(update.files);
    const url = file ? fileDownloadUrl(update.version, file.id) : null;
    if (!url) return;
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("open_url", { url });
    } catch {
      window.open(url, "_blank");
    }
  }

  function dismiss() {
    updateDismissed.set(true);
  }
</script>

{#if $pendingUpdate && !$updateDismissed}
  <div class="banner" role="status" aria-live="polite">
    <div class="info">
      <span class="tag">Update available</span>
      <span class="ver">{$pendingUpdate.version}</span>
    </div>
    <div class="actions">
      <button class="btn-download" on:click={openDownload}>Download</button>
      <button class="btn-close" on:click={dismiss} aria-label="Dismiss">✕</button>
    </div>
  </div>
{/if}

<style>
  .banner {
    position: fixed;
    bottom: 46px;
    right: 16px;
    z-index: 1050;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 10px 12px;
    background: var(--bg-2);
    border: 1px solid var(--bg-3);
    border-left: 3px solid var(--accent, #7aa2f7);
    border-radius: 6px;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.45);
    font-size: 12px;
    animation: pop-in 180ms ease;
  }
  @keyframes pop-in {
    from { transform: translateY(6px); opacity: 0; }
    to   { transform: translateY(0);   opacity: 1; }
  }
  .info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 120px;
  }
  .tag {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--fg-2);
  }
  .ver {
    font-weight: 600;
    font-family: var(--font-mono);
    color: var(--fg-0);
  }
  .actions {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .btn-download {
    background: var(--accent, #7aa2f7);
    color: #fff;
    border: none;
    border-radius: 4px;
    padding: 4px 10px;
    font-size: 12px;
    font-family: inherit;
    cursor: pointer;
  }
  .btn-download:hover { opacity: 0.85; }
  .btn-close {
    background: transparent;
    border: none;
    color: var(--fg-2);
    cursor: pointer;
    font-size: 12px;
    padding: 2px 5px;
    border-radius: 3px;
    line-height: 1;
  }
  .btn-close:hover {
    background: var(--bg-3);
    color: var(--fg-0);
  }
</style>
