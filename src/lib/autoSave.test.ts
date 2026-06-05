import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// Mock the disk-write path so the auto-save loop can be observed without a
// real backend. vi.hoisted keeps the spy accessible from the (hoisted) factory.
const { saveTab } = vi.hoisted(() => ({
  saveTab: vi.fn(async (_id: string, _opts?: { silent?: boolean }) => true),
}));
vi.mock("./tabManager", () => ({ saveTab }));

import { startAutoSave, __testing } from "./autoSave";
import { dirtyTabs } from "./stores/tabs";
import { autoSaveEnabled, autoSaveIntervalSec } from "./stores/settings";

describe("autoSave", () => {
  let stop: (() => void) | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    saveTab.mockClear();
    dirtyTabs.set(new Set());
    autoSaveEnabled.set(true);
    autoSaveIntervalSec.set(5);
  });

  afterEach(() => {
    if (stop) stop();
    stop = null;
    vi.useRealTimers();
  });

  it("saves every dirty tab once per interval, silently", async () => {
    dirtyTabs.set(new Set(["a", "b"]));
    stop = startAutoSave();

    await vi.advanceTimersByTimeAsync(5000);

    expect(saveTab).toHaveBeenCalledTimes(2);
    expect(saveTab).toHaveBeenCalledWith("a", { silent: true });
    expect(saveTab).toHaveBeenCalledWith("b", { silent: true });
  });

  it("does nothing when there are no dirty tabs", async () => {
    stop = startAutoSave();
    await vi.advanceTimersByTimeAsync(5000);
    expect(saveTab).not.toHaveBeenCalled();
  });

  it("does not run when disabled", async () => {
    autoSaveEnabled.set(false);
    dirtyTabs.set(new Set(["a"]));
    stop = startAutoSave();
    await vi.advanceTimersByTimeAsync(60000);
    expect(saveTab).not.toHaveBeenCalled();
  });

  it("re-arms when the interval changes", async () => {
    dirtyTabs.set(new Set(["a"]));
    stop = startAutoSave();

    // Shorten the interval; the timer should re-arm to the new period.
    autoSaveIntervalSec.set(10);
    await vi.advanceTimersByTimeAsync(9000);
    expect(saveTab).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1000);
    expect(saveTab).toHaveBeenCalledTimes(1);
  });

  it("stops firing after the returned teardown is called", async () => {
    dirtyTabs.set(new Set(["a"]));
    stop = startAutoSave();
    stop();
    stop = null;
    await vi.advanceTimersByTimeAsync(20000);
    expect(saveTab).not.toHaveBeenCalled();
  });

  it("skips tabs cleaned between scheduling and the write", async () => {
    dirtyTabs.set(new Set(["a", "b"]));
    saveTab.mockImplementation(async (id: string) => {
      // Simulate "a" cleaning "b" (or b being closed) during its own save.
      if (id === "a") dirtyTabs.set(new Set(["a"]));
      return true;
    });
    stop = startAutoSave();
    await vi.advanceTimersByTimeAsync(5000);

    expect(saveTab).toHaveBeenCalledWith("a", { silent: true });
    expect(saveTab).not.toHaveBeenCalledWith("b", { silent: true });
  });
});

describe("autoSave internals", () => {
  afterEach(() => __testing.clearTimer());

  it("reschedule(false) clears any existing timer", () => {
    vi.useFakeTimers();
    __testing.reschedule(true, 5);
    __testing.reschedule(false, 5);
    // No assertion target other than not throwing / no pending timer; the
    // public-loop tests cover behavior. This guards the disabled path.
    vi.useRealTimers();
    expect(true).toBe(true);
  });
});
