<script lang="ts">
  import { toastMessage } from "$lib/stores/ui";
</script>

{#if $toastMessage}
  <div class="toast" role="status">{$toastMessage}</div>
{/if}

<style>
  .toast {
    position: fixed;
    bottom: 16px;
    right: 16px;
    background: var(--bg-2);
    border: 1px solid var(--bg-3);
    color: var(--fg-0);
    padding: 8px 12px;
    border-radius: 6px;
    font-size: 12px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
    z-index: 1000;
  }
</style>
