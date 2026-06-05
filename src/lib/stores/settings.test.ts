import { describe, it, expect } from "vitest";
import { get } from "svelte/store";
import {
  autoSaveIntervalSec,
  setAutoSaveInterval,
  clampInterval,
  AUTOSAVE_MIN_SEC,
  AUTOSAVE_MAX_SEC,
  AUTOSAVE_DEFAULT_SEC,
} from "./settings";

describe("clampInterval", () => {
  it("keeps in-range values, rounding to whole seconds", () => {
    expect(clampInterval(30)).toBe(30);
    expect(clampInterval(45.6)).toBe(46);
  });

  it("clamps below the minimum and above the maximum", () => {
    expect(clampInterval(1)).toBe(AUTOSAVE_MIN_SEC);
    expect(clampInterval(999999)).toBe(AUTOSAVE_MAX_SEC);
  });

  it("falls back to the default for non-finite input", () => {
    expect(clampInterval(NaN)).toBe(AUTOSAVE_DEFAULT_SEC);
    // Infinity is non-finite, so it takes the safe default rather than MAX.
    expect(clampInterval(Infinity)).toBe(AUTOSAVE_DEFAULT_SEC);
  });
});

describe("setAutoSaveInterval", () => {
  it("writes a clamped value into the store", () => {
    setAutoSaveInterval(60);
    expect(get(autoSaveIntervalSec)).toBe(60);
    setAutoSaveInterval(2);
    expect(get(autoSaveIntervalSec)).toBe(AUTOSAVE_MIN_SEC);
  });
});
