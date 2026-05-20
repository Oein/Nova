<script lang="ts">
  import { themePanelOpen, themeColors, activePresetId, PRESETS, applyTheme } from "$lib/stores/theme";
  import type { ThemeColors } from "$lib/stores/theme";

  let draft: ThemeColors = { ...$themeColors };

  $: {
    draft = { ...$themeColors };
  }

  function selectPreset(id: string) {
    const preset = PRESETS.find((p) => p.id === id);
    if (!preset) return;
    draft = { ...preset.colors };
    commit();
  }

  function commit() {
    themeColors.set({ ...draft });
    applyTheme(draft);
  }

  function onColorInput(key: keyof ThemeColors, value: string) {
    draft = { ...draft, [key]: value };
    commit();
  }

  function getInputValue(e: Event): string {
    return (e.target as HTMLInputElement).value;
  }

  function close() {
    themePanelOpen.set(false);
  }

  function onOverlayKey(e: KeyboardEvent) {
    if (e.key === "Escape") close();
  }

  const colorFields: { key: keyof ThemeColors; label: string }[] = [
    { key: "bg0", label: "배경 (가장 어두움)" },
    { key: "bg1", label: "배경 1" },
    { key: "bg2", label: "배경 2" },
    { key: "bg3", label: "배경 3" },
    { key: "fg0", label: "텍스트 (기본)" },
    { key: "fg1", label: "텍스트 (보조)" },
    { key: "fg2", label: "텍스트 (약한)" },
    { key: "accent", label: "강조색" },
    { key: "accentDim", label: "강조색 (어두움)" },
    { key: "dirty", label: "미저장 표시" },
    { key: "danger", label: "위험 / 삭제" },
  ];
</script>

<!-- svelte-ignore a11y-no-static-element-interactions -->
<div class="overlay" on:mousedown|self={close} on:keydown={onOverlayKey} role="none">
  <div class="panel" role="dialog" aria-modal="true" aria-label="테마 색상 설정">
    <header>
      <span class="title">테마 색상</span>
      <button class="close-btn" on:click={close} aria-label="닫기">✕</button>
    </header>

    <section class="presets">
      <div class="section-label">프리셋</div>
      <div class="preset-list">
        {#each PRESETS as preset (preset.id)}
          <button
            class="preset-btn"
            class:active={$activePresetId === preset.id}
            on:click={() => selectPreset(preset.id)}
            style="
              --p-bg: {preset.colors.bg1};
              --p-fg: {preset.colors.fg0};
              --p-accent: {preset.colors.accent};
            "
          >
            <span class="preset-swatch">
              <span class="sw-bg" style="background:{preset.colors.bg0}" />
              <span class="sw-accent" style="background:{preset.colors.accent}" />
              <span class="sw-fg" style="background:{preset.colors.fg0}" />
            </span>
            {preset.name}
          </button>
        {/each}
      </div>
    </section>

    <section class="colors">
      <div class="section-label">색상 직접 편집</div>
      <div class="color-grid">
        {#each colorFields as { key, label }}
          <label class="color-row">
            <span class="color-label">{label}</span>
            <span class="color-value-wrap">
              <input
                type="color"
                value={draft[key]}
                on:input={(e) => onColorInput(key, getInputValue(e))}
                aria-label={label}
              />
              <input
                type="text"
                class="hex-input"
                value={draft[key]}
                maxlength="7"
                spellcheck="false"
                on:change={(e) => {
                  const v = getInputValue(e);
                  if (/^#[0-9a-fA-F]{6}$/.test(v)) onColorInput(key, v);
                }}
                aria-label="{label} hex"
              />
            </span>
          </label>
        {/each}
      </div>
    </section>
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    z-index: 200;
    background: rgba(0, 0, 0, 0.45);
    display: flex;
    align-items: flex-end;
    justify-content: flex-start;
    padding: 0 0 24px 16px;
    animation: fade-in 120ms ease;
  }
  @keyframes fade-in {
    from { opacity: 0; }
    to { opacity: 1; }
  }
  .panel {
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 10px;
    width: 320px;
    max-height: calc(100vh - 80px);
    overflow-y: auto;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
    animation: slide-up 150ms cubic-bezier(0.2, 0, 0, 1);
    display: flex;
    flex-direction: column;
    gap: 0;
  }
  @keyframes slide-up {
    from { transform: translateY(12px); opacity: 0.6; }
    to { transform: translateY(0); opacity: 1; }
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 14px 10px;
    border-bottom: 1px solid var(--bg-3);
    position: sticky;
    top: 0;
    background: var(--bg-1);
    z-index: 1;
  }
  .title {
    font-size: 13px;
    font-weight: 600;
    color: var(--fg-0);
  }
  .close-btn {
    background: transparent;
    border: none;
    color: var(--fg-2);
    cursor: pointer;
    font-size: 12px;
    padding: 2px 6px;
    border-radius: 4px;
    line-height: 1;
  }
  .close-btn:hover {
    background: var(--bg-2);
    color: var(--fg-0);
  }
  section {
    padding: 12px 14px;
  }
  section + section {
    border-top: 1px solid var(--bg-2);
  }
  .section-label {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--fg-2);
    margin-bottom: 8px;
  }
  .preset-list {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .preset-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    font-size: 12px;
    background: var(--p-bg, var(--bg-2));
    color: var(--p-fg, var(--fg-0));
    border: 1.5px solid transparent;
    border-radius: 6px;
    cursor: pointer;
    transition: border-color 80ms;
  }
  .preset-btn:hover {
    border-color: var(--p-accent, var(--accent));
  }
  .preset-btn.active {
    border-color: var(--p-accent, var(--accent));
    box-shadow: 0 0 0 1px var(--p-accent, var(--accent));
  }
  .preset-swatch {
    display: flex;
    border-radius: 3px;
    overflow: hidden;
    width: 30px;
    height: 12px;
    flex-shrink: 0;
  }
  .preset-swatch span {
    flex: 1;
  }
  .color-grid {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .color-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    cursor: pointer;
  }
  .color-label {
    font-size: 12px;
    color: var(--fg-1);
    flex: 1;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .color-value-wrap {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }
  input[type="color"] {
    width: 28px;
    height: 22px;
    border: 1.5px solid var(--bg-3);
    border-radius: 4px;
    padding: 1px 2px;
    background: var(--bg-2);
    cursor: pointer;
    flex-shrink: 0;
  }
  input[type="color"]::-webkit-color-swatch-wrapper {
    padding: 0;
  }
  input[type="color"]::-webkit-color-swatch {
    border: none;
    border-radius: 3px;
  }
  .hex-input {
    width: 72px;
    font-family: var(--font-mono);
    font-size: 11px;
    padding: 3px 6px;
    background: var(--bg-2);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    color: var(--fg-1);
    text-align: center;
  }
  .hex-input:focus {
    outline: none;
    border-color: var(--accent);
    color: var(--fg-0);
  }
</style>
