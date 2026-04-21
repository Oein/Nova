<script lang="ts">
  import { activeTabId, openTabs, getBuffer } from "$lib/stores/tabs";
  import Editor from "./Editor.svelte";
  import TabBar from "./TabBar.svelte";

  $: activeTab = $openTabs.find((t) => t.id === $activeTabId) ?? null;
  $: buffer = $activeTabId ? getBuffer($activeTabId) ?? null : null;
</script>

<div class="pane">
  <TabBar />
  <div class="editor-host">
    {#if activeTab && buffer}
      {#key activeTab.id}
        <Editor {buffer} tab={activeTab} />
      {/key}
    {:else}
      <div class="empty">
        <h2>Nova</h2>
        <p>Open a folder from the sidebar and pick a file.</p>
      </div>
    {/if}
  </div>
</div>

<style>
  .pane { display: flex; flex-direction: column; height: 100%; min-width: 0; min-height: 0; }
  .editor-host { flex: 1; position: relative; min-height: 0; }
  .empty {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    color: var(--fg-2);
    text-align: center;
  }
  .empty h2 { font-weight: 400; margin-bottom: 4px; }
  .empty p { margin: 0; font-size: 12px; }
</style>
