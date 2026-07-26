import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { get } from "svelte/store";
import type { NotionConfigView, SyncReport } from "./types";

const { ipcMock, flushDirtyTabs, reloadTabFromDisk } = vi.hoisted(() => ({
  ipcMock: {
    notionGetConfig: vi.fn(),
    notionSync: vi.fn(),
    notionListConflicts: vi.fn(async () => []),
    listNotes: vi.fn(async () => []),
  },
  flushDirtyTabs: vi.fn(async () => {}),
  reloadTabFromDisk: vi.fn(async () => true),
}));

vi.mock("./ipc", () => ({ ipc: ipcMock, isMock: true }));
vi.mock("./tabManager", () => ({ flushDirtyTabs, reloadTabFromDisk }));

import { startNotionSync, __testing } from "./notionSync";
import { notionConfig, syncState } from "./stores/notion";
import { workspacePath } from "./stores/workspace";

function config(patch: Partial<NotionConfigView> = {}): NotionConfigView {
  return {
    tokenSet: true,
    tokenHint: "beef",
    databaseId: "db-1",
    databaseTitle: "Notes",
    titleProp: "Name",
    createdProp: null,
    updatedProp: null,
    idProp: null,
    enabled: true,
    syncOnStart: true,
    autoSync: true,
    intervalSec: 300,
    lastSyncMs: null,
    lastStatus: null,
    conflictCount: 0,
    ...patch,
  };
}

function report(patch: Partial<SyncReport> = {}): SyncReport {
  return {
    pulled: 0,
    pushed: 0,
    createdLocal: 0,
    createdRemote: 0,
    archivedRemote: 0,
    trashedLocal: 0,
    conflicts: 0,
    blocked: 0,
    errors: 0,
    cancelled: false,
    dryRun: false,
    items: [],
    changedNoteIds: [],
    ...patch,
  };
}

/** Lets the promise chain inside applyConfig settle under fake timers. */
async function settle() {
  await vi.advanceTimersByTimeAsync(0);
}

describe("notionSync runner", () => {
  let stop: (() => void) | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    ipcMock.notionGetConfig.mockReset().mockResolvedValue(config());
    ipcMock.notionSync.mockReset().mockResolvedValue(report());
    ipcMock.notionListConflicts.mockClear();
    flushDirtyTabs.mockClear();
    reloadTabFromDisk.mockClear();
    notionConfig.set(null);
    syncState.set("idle");
    workspacePath.set("/ws");
    __testing.resetStartup();
  });

  afterEach(() => {
    if (stop) stop();
    stop = null;
    __testing.clearTimer();
    __testing.clearStartup();
    vi.useRealTimers();
  });

  it("syncs once shortly after the workspace opens, then on the interval", async () => {
    stop = startNotionSync();
    await settle();

    // Nothing yet — the boot sync is deliberately delayed past session restore.
    expect(ipcMock.notionSync).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(2000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(300_000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(2);
  });

  it("saves dirty buffers before syncing", async () => {
    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(2000);

    expect(flushDirtyTabs).toHaveBeenCalled();
    expect(flushDirtyTabs.mock.invocationCallOrder[0]).toBeLessThan(
      ipcMock.notionSync.mock.invocationCallOrder[0],
    );
  });

  it("stays idle when the integration is off or incomplete", async () => {
    for (const patch of [
      { enabled: false },
      { tokenSet: false },
      { databaseId: null },
    ]) {
      ipcMock.notionSync.mockClear();
      ipcMock.notionGetConfig.mockResolvedValue(config(patch));
      __testing.resetStartup();
      const off = startNotionSync();
      await settle();
      await vi.advanceTimersByTimeAsync(600_000);
      expect(ipcMock.notionSync, JSON.stringify(patch)).not.toHaveBeenCalled();
      off();
    }
  });

  it("skips the startup sync when the user turned it off", async () => {
    ipcMock.notionGetConfig.mockResolvedValue(config({ syncOnStart: false }));
    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(2000);
    expect(ipcMock.notionSync).not.toHaveBeenCalled();
    // …but the periodic timer is still armed.
    await vi.advanceTimersByTimeAsync(300_000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);
  });

  it("does not repeat the startup sync for the same workspace", async () => {
    ipcMock.notionGetConfig.mockResolvedValue(config({ autoSync: false }));
    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(2000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);

    // A config reload (settings edit) must not re-trigger it.
    await __testing.applyConfig("/ws");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);
  });

  it("re-runs the startup sync after switching workspaces", async () => {
    ipcMock.notionGetConfig.mockResolvedValue(config({ autoSync: false }));
    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(2000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);

    workspacePath.set("/other");
    await settle();
    await vi.advanceTimersByTimeAsync(2000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(2);
  });

  it("re-arms when the interval changes", async () => {
    ipcMock.notionGetConfig.mockResolvedValue(config({ syncOnStart: false }));
    stop = startNotionSync();
    await settle();

    notionConfig.set(config({ syncOnStart: false, intervalSec: 600 }));
    await vi.advanceTimersByTimeAsync(300_000);
    expect(ipcMock.notionSync).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(300_000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);
  });

  it("never schedules faster than once a minute", async () => {
    ipcMock.notionGetConfig.mockResolvedValue(
      config({ syncOnStart: false, intervalSec: 1 }),
    );
    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(59_000);
    expect(ipcMock.notionSync).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);
  });

  it("stops firing after teardown", async () => {
    stop = startNotionSync();
    await settle();
    stop();
    stop = null;
    await vi.advanceTimersByTimeAsync(600_000);
    expect(ipcMock.notionSync).not.toHaveBeenCalled();
  });

  it("clears the timer when the workspace closes", async () => {
    stop = startNotionSync();
    await settle();
    expect(__testing.hasTimer()).toBe(true);
    workspacePath.set(null);
    await settle();
    expect(__testing.hasTimer()).toBe(false);
  });

  it("reloads open tabs whose files the sync rewrote", async () => {
    const { openTabs } = await import("./stores/tabs");
    openTabs.set([
      { id: "n1", title: "A", mode: "rope", mtimeMs: 1 },
      { id: "n2", title: "B", mode: "rope", mtimeMs: 1 },
    ]);
    ipcMock.notionSync.mockResolvedValue(report({ pulled: 1, changedNoteIds: ["n1", "n3"] }));

    stop = startNotionSync();
    await settle();
    await vi.advanceTimersByTimeAsync(2000);

    expect(reloadTabFromDisk).toHaveBeenCalledWith("n1");
    // n3 isn't open, so there is nothing to refresh.
    expect(reloadTabFromDisk).not.toHaveBeenCalledWith("n3");
    openTabs.set([]);
  });
});

describe("runSync guards", () => {
  beforeEach(() => {
    ipcMock.notionGetConfig.mockReset().mockResolvedValue(config());
    ipcMock.notionSync.mockReset().mockResolvedValue(report());
    notionConfig.set(config());
    syncState.set("idle");
  });

  it("refuses to start a second sync while one is running", async () => {
    const { runSync } = await import("./stores/notion");
    let release: (v: SyncReport) => void = () => {};
    ipcMock.notionSync.mockReturnValue(
      new Promise<SyncReport>((r) => {
        release = r;
      }),
    );
    const first = runSync({ silent: true });
    const second = await runSync({ silent: true });
    expect(second).toBeNull();
    expect(ipcMock.notionSync).toHaveBeenCalledTimes(1);
    release(report());
    await first;
    expect(get(syncState)).toBe("idle");
  });

  it("treats a backend busy error as a no-op, not a failure", async () => {
    const { runSync } = await import("./stores/notion");
    ipcMock.notionSync.mockRejectedValue("a Notion sync is already running");
    expect(await runSync({ silent: true })).toBeNull();
    expect(get(syncState)).toBe("idle");
  });

  it("surfaces real failures", async () => {
    const { runSync, syncError } = await import("./stores/notion");
    ipcMock.notionSync.mockRejectedValue("notion api 401: invalid token");
    expect(await runSync({ silent: true })).toBeNull();
    expect(get(syncState)).toBe("error");
    expect(get(syncError)).toContain("401");
  });
});

describe("summarize", () => {
  it("describes what changed, or says nothing did", async () => {
    const { summarize } = await import("./stores/notion");
    expect(summarize(report())).toBe("Notion: up to date");
    expect(summarize(report({ cancelled: true }))).toBe("Notion sync cancelled");
    expect(summarize(report({ pulled: 2, pushed: 1, conflicts: 1 }))).toBe(
      "Notion: 2 pulled, 1 pushed, 1 conflict(s)",
    );
  });
});
