<script lang="ts">
  import {
    settingsOpen,
    autoSaveEnabled,
    autoSaveIntervalSec,
    setAutoSaveInterval,
    clampInterval,
    AUTOSAVE_PRESETS,
    AUTOSAVE_MIN_SEC,
    AUTOSAVE_MAX_SEC,
  } from "$lib/stores/settings";

  // Local mirror of the interval so the number input can hold a transient /
  // out-of-range value while typing; committed (clamped) on blur or Enter.
  let intervalDraft = $autoSaveIntervalSec;
  $: if ($settingsOpen) {
    // Re-sync the draft whenever the dialog opens or the store changes from a
    // preset click.
    intervalDraft = $autoSaveIntervalSec;
  }

  // True when the current interval matches one of the presets — used to drive
  // the <select>; "custom" otherwise.
  $: selectValue = AUTOSAVE_PRESETS.some((p) => p.sec === $autoSaveIntervalSec)
    ? String($autoSaveIntervalSec)
    : "custom";

  function close() {
    settingsOpen.set(false);
  }

  function onPresetChange(e: Event) {
    const val = (e.currentTarget as HTMLSelectElement).value;
    if (val === "custom") return; // keep current value; user edits the number
    setAutoSaveInterval(Number(val));
  }

  function commitInterval() {
    setAutoSaveInterval(intervalDraft);
    intervalDraft = $autoSaveIntervalSec;
  }

  function onIntervalKey(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      commitInterval();
    }
  }

  function onKeydown(e: KeyboardEvent) {
    if (!$settingsOpen) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  }
</script>

<svelte:window on:keydown|capture={onKeydown} />

{#if $settingsOpen}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="backdrop" on:click={close} role="presentation">
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-noninteractive-element-interactions -->
    <div
      class="panel"
      role="dialog"
      aria-modal="true"
      aria-label="Settings"
      on:click|stopPropagation
      on:keydown|stopPropagation
    >
      <header>
        <h2>Settings</h2>
        <button class="close" on:click={close} aria-label="Close settings">✕</button>
      </header>

      <section>
        <h3>Auto-save</h3>

        <label class="row toggle">
          <input
            type="checkbox"
            bind:checked={$autoSaveEnabled}
            aria-label="Enable auto-save"
          />
          <span>Automatically save edited notes</span>
        </label>

        <div class="row" class:disabled={!$autoSaveEnabled}>
          <span class="label">Save every</span>
          <select
            value={selectValue}
            on:change={onPresetChange}
            disabled={!$autoSaveEnabled}
            aria-label="Auto-save interval preset"
          >
            {#each AUTOSAVE_PRESETS as p (p.sec)}
              <option value={String(p.sec)}>{p.label}</option>
            {/each}
            <option value="custom">Custom…</option>
          </select>
        </div>

        <div class="row custom" class:disabled={!$autoSaveEnabled}>
          <span class="label">Custom interval</span>
          <input
            class="num"
            type="number"
            min={AUTOSAVE_MIN_SEC}
            max={AUTOSAVE_MAX_SEC}
            step="1"
            bind:value={intervalDraft}
            on:blur={commitInterval}
            on:keydown={onIntervalKey}
            disabled={!$autoSaveEnabled}
            aria-label="Auto-save interval in seconds"
          />
          <span class="unit">seconds</span>
        </div>

        <p class="hint">
          {#if $autoSaveEnabled}
            Edited notes are written to disk every
            {clampInterval($autoSaveIntervalSec)} second{clampInterval($autoSaveIntervalSec) === 1 ? "" : "s"}.
          {:else}
            Auto-save is off. Use ⌘S to save manually.
          {/if}
        </p>
      </section>
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
    width: min(480px, 90vw);
    max-height: 70vh;
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
    padding: 14px 16px;
    border-bottom: 1px solid var(--bg-2);
  }
  h2 {
    margin: 0;
    font-size: 15px;
    color: var(--fg-0);
    font-weight: 600;
  }
  .close {
    background: transparent;
    border: none;
    color: var(--fg-2);
    cursor: pointer;
    font-size: 13px;
    padding: 4px 8px;
    border-radius: 4px;
    line-height: 1;
  }
  .close:hover {
    background: var(--bg-2);
    color: var(--fg-0);
  }
  section {
    padding: 16px;
    overflow-y: auto;
  }
  h3 {
    margin: 0 0 12px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--fg-2);
    font-weight: 600;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
    font-size: 13px;
    color: var(--fg-0);
  }
  .row.disabled {
    opacity: 0.5;
  }
  .row .label {
    min-width: 110px;
    color: var(--fg-1);
  }
  .toggle {
    cursor: pointer;
  }
  .toggle input {
    width: 15px;
    height: 15px;
    cursor: pointer;
  }
  select,
  .num {
    background: var(--bg-0);
    color: var(--fg-0);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    padding: 5px 8px;
    font-family: inherit;
    font-size: 13px;
    outline: none;
  }
  select:focus,
  .num:focus {
    border-color: var(--accent, #7aa2f7);
  }
  .num {
    width: 84px;
    font-family: var(--font-mono);
  }
  .unit {
    color: var(--fg-2);
    font-size: 12px;
  }
  .hint {
    margin: 4px 0 0;
    font-size: 11px;
    color: var(--fg-2);
    line-height: 1.5;
  }
</style>
