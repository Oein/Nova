<script lang="ts">
  import { ipc } from "$lib/ipc";
  import {
    notionConfig,
    conflictPanelOpen,
    errorMessage,
    lastReport,
    syncError,
    loadNotionConfig,
    runSync,
    summarize,
    syncState,
    updateConfig,
  } from "$lib/stores/notion";
  import { settingsOpen } from "$lib/stores/settings";
  import type { NotionDbSummary } from "$lib/types";

  const INTERVAL_PRESETS = [
    { sec: 300, label: "Every 5 minutes" },
    { sec: 900, label: "Every 15 minutes" },
    { sec: 1800, label: "Every 30 minutes" },
    { sec: 3600, label: "Every hour" },
  ];

  // The stored PAT is never sent back to us, so this box always starts empty
  // and only carries a value the user just typed.
  let tokenDraft = "";
  let databases: NotionDbSummary[] = [];
  let loadingDbs = false;
  let testing = false;
  let status: { kind: "ok" | "error"; text: string } | null = null;
  let warnings: string[] = [];
  let showAllProblems = false;

  // Local drafts so typing doesn't round-trip to the backend on every key.
  let createdDraft = "";
  let updatedDraft = "";
  let idDraft = "";
  let propsLoaded = false;

  $: cfg = $notionConfig;
  // The panel mounts once and stays mounted, so refresh whenever it opens.
  $: if ($settingsOpen) void loadNotionConfig();
  $: intervalDraft = cfg?.intervalSec ?? 900;
  // Seed the property drafts once, then leave them to the user.
  $: if (cfg && !propsLoaded) {
    createdDraft = cfg.createdProp ?? "";
    updatedDraft = cfg.updatedProp ?? "";
    idDraft = cfg.idProp ?? "";
    propsLoaded = true;
  }
  $: intervalPreset = INTERVAL_PRESETS.some((p) => p.sec === intervalDraft)
    ? String(intervalDraft)
    : "custom";
  $: connected = Boolean(cfg?.tokenSet && cfg?.databaseId);
  // Errors first — they're the ones that stopped something from happening.
  $: problems = ($lastReport?.items ?? [])
    .filter((i) => i.severity !== "info")
    .sort((a, b) => (a.severity === "error" ? -1 : 0) - (b.severity === "error" ? -1 : 0));
  $: if ($lastReport) showAllProblems = false;

  async function saveToken() {
    const token = tokenDraft.trim();
    if (!token) return;
    status = null;
    const next = await updateConfig({ token });
    if (next) {
      tokenDraft = "";
      status = { kind: "ok", text: "Token saved." };
      await loadDatabases();
    }
  }

  async function clearToken() {
    try {
      notionConfig.set(await ipc.notionClearToken());
      databases = [];
      status = { kind: "ok", text: "Token removed." };
    } catch (err) {
      status = { kind: "error", text: errorMessage(err) };
    }
  }

  async function loadDatabases() {
    if (!cfg?.tokenSet && !tokenDraft.trim()) return;
    loadingDbs = true;
    status = null;
    try {
      databases = await ipc.notionListDatabases(tokenDraft.trim() || undefined);
      if (databases.length === 0) {
        status = {
          kind: "error",
          text: "No databases are shared with this integration yet. In Notion, open the database → ⋯ → Connections → add your integration.",
        };
      }
    } catch (err) {
      status = { kind: "error", text: errorMessage(err) };
    } finally {
      loadingDbs = false;
    }
  }

  async function pickDatabase(e: Event) {
    const id = (e.currentTarget as HTMLSelectElement).value;
    if (!id) return;
    const title = databases.find((d) => d.id === id)?.title;
    await updateConfig({ databaseId: id, databaseTitle: title });
  }

  function commitProps() {
    if (
      createdDraft.trim() === (cfg?.createdProp ?? "") &&
      updatedDraft.trim() === (cfg?.updatedProp ?? "") &&
      idDraft.trim() === (cfg?.idProp ?? "")
    ) {
      return;
    }
    void updateConfig({
      createdProp: createdDraft.trim(),
      updatedProp: updatedDraft.trim(),
      idProp: idDraft.trim(),
    });
  }

  async function testConnection() {
    testing = true;
    status = null;
    warnings = [];
    try {
      // Commit any pending property names first so the check reflects them.
      commitProps();
      const info = await ipc.notionTestConnection();
      warnings = info.propertyWarnings ?? [];
      const where = info.workspaceName ? ` (${info.workspaceName})` : "";
      status = {
        kind: "ok",
        text: info.databaseTitle
          ? `Connected as ${info.botName}${where} — "${info.databaseTitle}", title property "${info.titleProp}".`
          : `Connected as ${info.botName}${where}. Pick a database to sync.`,
      };
      await loadNotionConfig();
    } catch (err) {
      status = { kind: "error", text: errorMessage(err) };
    } finally {
      testing = false;
    }
  }

  function commitInterval() {
    const sec = Math.min(86400, Math.max(60, Math.round(intervalDraft) || 900));
    void updateConfig({ intervalSec: sec });
  }

  function onPresetChange(e: Event) {
    const v = (e.currentTarget as HTMLSelectElement).value;
    if (v === "custom") return;
    intervalDraft = Number(v);
    commitInterval();
  }

  function formatTime(ms: number | null): string {
    if (!ms) return "never";
    return new Date(ms).toLocaleString();
  }

  function openConflicts() {
    settingsOpen.set(false);
    conflictPanelOpen.set(true);
  }
</script>

<section data-testid="notion-settings">
  <h3>Notion sync</h3>

  <label class="row toggle">
    <input
      type="checkbox"
      checked={cfg?.enabled ?? false}
      disabled={!connected}
      on:change={(e) => updateConfig({ enabled: e.currentTarget.checked })}
      aria-label="Enable Notion sync"
      data-testid="notion-enabled"
    />
    <span>Sync this workspace with a Notion database</span>
  </label>

  <div class="row">
    <span class="label">Integration token</span>
    {#if cfg?.tokenSet}
      <span class="value-mono">••••{cfg.tokenHint}</span>
      <button class="link-btn" on:click={clearToken}>Remove</button>
    {:else}
      <input
        class="num token"
        type="password"
        placeholder="ntn_…"
        bind:value={tokenDraft}
        on:keydown={(e) => e.key === "Enter" && saveToken()}
        aria-label="Notion integration token"
        data-testid="notion-token"
      />
      <button class="btn-check" on:click={saveToken} disabled={!tokenDraft.trim()}>
        Save
      </button>
    {/if}
  </div>

  <div class="row" class:disabled={!cfg?.tokenSet}>
    <span class="label">Database</span>
    <select
      value={cfg?.databaseId ?? ""}
      on:change={pickDatabase}
      disabled={!cfg?.tokenSet || databases.length === 0}
      aria-label="Notion database"
      data-testid="notion-database"
    >
      {#if cfg?.databaseId && !databases.some((d) => d.id === cfg?.databaseId)}
        <option value={cfg.databaseId}>
          {cfg.databaseTitle ?? cfg.databaseId}
        </option>
      {:else if databases.length === 0}
        <option value="">—</option>
      {/if}
      {#each databases as d (d.id)}
        <option value={d.id}>{d.title}</option>
      {/each}
    </select>
    <button class="btn-check" on:click={loadDatabases} disabled={!cfg?.tokenSet || loadingDbs}>
      {loadingDbs ? "Loading…" : "Refresh"}
    </button>
  </div>

  <div class="row">
    <button class="btn-check" on:click={testConnection} disabled={!cfg?.tokenSet || testing}>
      {testing ? "Testing…" : "Test connection"}
    </button>
  </div>

  {#if status}
    <p class="hint" class:error={status.kind === "error"}>{status.text}</p>
  {/if}
  {#each warnings as w}
    <p class="hint warn">{w}</p>
  {/each}

  <div class="row" class:disabled={!cfg?.tokenSet}>
    <span class="label">Created column</span>
    <input
      class="num prop"
      type="text"
      placeholder="off"
      bind:value={createdDraft}
      on:blur={commitProps}
      on:keydown={(e) => e.key === "Enter" && commitProps()}
      disabled={!cfg?.tokenSet}
      aria-label="Notion property for the note's creation time"
      data-testid="notion-created-prop"
    />
  </div>

  <div class="row" class:disabled={!cfg?.tokenSet}>
    <span class="label">Updated column</span>
    <input
      class="num prop"
      type="text"
      placeholder="off"
      bind:value={updatedDraft}
      on:blur={commitProps}
      on:keydown={(e) => e.key === "Enter" && commitProps()}
      disabled={!cfg?.tokenSet}
      aria-label="Notion property for the note's last-modified time"
      data-testid="notion-updated-prop"
    />
  </div>

  <div class="row" class:disabled={!cfg?.tokenSet}>
    <span class="label">ID column</span>
    <input
      class="num prop"
      type="text"
      placeholder="off"
      bind:value={idDraft}
      on:blur={commitProps}
      on:keydown={(e) => e.key === "Enter" && commitProps()}
      disabled={!cfg?.tokenSet}
      aria-label="Notion property for the note's unique id"
      data-testid="notion-id-prop"
    />
  </div>

  <p class="hint">
    Extra Notion columns Nova fills in. <b>Created</b> and <b>Updated</b> are
    <code>date</code> properties holding each note's timestamps, so you can sort
    and filter by them in Notion. <b>ID</b> is a <code>rich_text</code> property
    holding the note's unique id — two notes can share a title, but never an id,
    and it lets Nova re-attach pages to notes if this workspace's local
    bookkeeping is ever lost instead of importing everything twice.
  </p>
  <p class="hint">
    Leave a field blank to skip it. A property that doesn't exist yet is
    created; one that already exists with another type is left alone. Editing
    these values in Notion has no effect — Nova overwrites them on the next
    sync.
  </p>

  <div class="row divider-row"></div>

  <div class="row" class:disabled={!connected}>
    <label class="toggle inline">
      <input
        type="checkbox"
        checked={cfg?.syncOnStart ?? true}
        disabled={!connected}
        on:change={(e) => updateConfig({ syncOnStart: e.currentTarget.checked })}
        aria-label="Sync when Nova starts"
      />
      <span>Sync when Nova starts</span>
    </label>
  </div>

  <div class="row" class:disabled={!connected}>
    <label class="toggle inline">
      <input
        type="checkbox"
        checked={cfg?.autoSync ?? true}
        disabled={!connected}
        on:change={(e) => updateConfig({ autoSync: e.currentTarget.checked })}
        aria-label="Sync automatically"
      />
      <span>Sync automatically</span>
    </label>
  </div>

  <div class="row" class:disabled={!connected || !cfg?.autoSync}>
    <span class="label">Sync every</span>
    <select
      value={intervalPreset}
      on:change={onPresetChange}
      disabled={!connected || !cfg?.autoSync}
      aria-label="Sync interval preset"
    >
      {#each INTERVAL_PRESETS as p (p.sec)}
        <option value={String(p.sec)}>{p.label}</option>
      {/each}
      <option value="custom">Custom…</option>
    </select>
    <input
      class="num"
      type="number"
      min="60"
      max="86400"
      step="60"
      bind:value={intervalDraft}
      on:blur={commitInterval}
      on:keydown={(e) => e.key === "Enter" && commitInterval()}
      disabled={!connected || !cfg?.autoSync}
      aria-label="Sync interval in seconds"
    />
    <span class="unit">seconds</span>
  </div>

  <div class="row">
    <button
      class="btn-check"
      on:click={() => runSync()}
      disabled={!connected || !cfg?.enabled || $syncState === "syncing"}
      data-testid="notion-sync-now"
    >
      {$syncState === "syncing" ? "Syncing…" : "Sync now"}
    </button>
    <span class="value-mono">Last: {formatTime(cfg?.lastSyncMs ?? null)}</span>
  </div>

  {#if $syncError}
    <p class="hint error">{$syncError}</p>
  {/if}

  {#if $lastReport}
    <p class="hint" data-testid="notion-last-report">{summarize($lastReport)}</p>
    <!-- Counts alone can't be acted on; the per-note reason is what tells the
         user whether it's their token, one bad page, or something else. -->
    {#if problems.length > 0}
      <ul class="problems" data-testid="notion-problems">
        {#each problems.slice(0, showAllProblems ? problems.length : 5) as item}
          <li class:err={item.severity === "error"}>
            <span class="problem-title">{item.title || "Untitled"}</span>
            {#if item.message}<span class="problem-msg">{item.message}</span>{/if}
          </li>
        {/each}
      </ul>
      {#if problems.length > 5 && !showAllProblems}
        <button class="link-btn" on:click={() => (showAllProblems = true)}>
          Show {problems.length - 5} more
        </button>
      {/if}
    {/if}
  {/if}

  {#if (cfg?.conflictCount ?? 0) > 0}
    <p class="hint error">
      {cfg?.conflictCount} conflict(s) waiting.
      <button class="link-btn" on:click={openConflicts}>Resolve</button>
    </p>
  {/if}

  <p class="hint">
    Notes and Notion pages are matched one to one. Blocks Nova can't show
    (tables, callouts, toggles) are kept as a placeholder comment and restored
    on the way back.
  </p>
</section>

<style>
  section {
    padding: 16px;
    border-top: 1px solid var(--bg-2);
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
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .toggle input {
    width: 15px;
    height: 15px;
    cursor: pointer;
  }
  .toggle.inline {
    margin: 0;
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
  select {
    max-width: 190px;
  }
  .num {
    width: 84px;
    font-family: var(--font-mono);
  }
  .num.token {
    width: 170px;
  }
  .num.prop {
    width: 170px;
    font-family: inherit;
  }
  .hint.warn {
    color: #e0af68;
  }
  .problems {
    list-style: none;
    margin: 0 0 8px;
    padding: 0;
    display: grid;
    gap: 6px;
  }
  .problems li {
    font-size: 11px;
    line-height: 1.45;
    padding: 6px 8px;
    border-radius: 4px;
    background: var(--bg-0);
    border-left: 2px solid #e0af68;
    color: var(--fg-2);
  }
  .problems li.err {
    border-left-color: #f7768e;
  }
  .problem-title {
    display: block;
    color: var(--fg-1);
    font-weight: 600;
    word-break: break-word;
  }
  .problem-msg {
    display: block;
    margin-top: 2px;
    word-break: break-word;
  }
  .hint code {
    font-family: var(--font-mono);
    font-size: 10px;
  }
  .divider-row {
    border-top: 1px solid var(--bg-2);
    margin: 4px 0 12px;
    padding: 0;
    height: 0;
  }
  .unit {
    color: var(--fg-2);
    font-size: 12px;
  }
  .hint {
    margin: 4px 0 12px;
    font-size: 11px;
    color: var(--fg-2);
    line-height: 1.5;
  }
  .hint.error {
    color: #f7768e;
  }
  .value-mono {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--fg-1);
  }
  .btn-check {
    background: var(--bg-0);
    color: var(--fg-0);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    padding: 5px 12px;
    font-size: 12px;
    font-family: inherit;
    cursor: pointer;
    white-space: nowrap;
  }
  .btn-check:hover:not(:disabled) {
    border-color: var(--accent, #7aa2f7);
    color: var(--accent, #7aa2f7);
  }
  .btn-check:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .link-btn {
    background: transparent;
    border: none;
    color: var(--accent, #7aa2f7);
    font-size: 11px;
    font-family: inherit;
    cursor: pointer;
    padding: 0;
    text-decoration: underline;
  }
</style>
