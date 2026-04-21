import { describe, it, expect, beforeEach } from "vitest";
import { get } from "svelte/store";
import { notes, sortedGroups, upsertNote, removeNote, touchNote } from "./workspace";
import type { Note } from "../types";

const NOW = Date.now();

const mk = (id: string, mtimeMs = NOW, title = id): Note => ({
  id,
  title,
  createdMs: mtimeMs,
  mtimeMs,
  size: 0,
});

beforeEach(() => notes.set([]));

describe("notes store", () => {
  it("upsertNote inserts new and updates existing", () => {
    upsertNote(mk("a"));
    upsertNote(mk("b"));
    expect(get(notes)).toHaveLength(2);
    upsertNote({ ...mk("a"), title: "renamed" });
    expect(get(notes).find((n) => n.id === "a")?.title).toBe("renamed");
    expect(get(notes)).toHaveLength(2);
  });

  it("removeNote drops a note", () => {
    upsertNote(mk("a"));
    upsertNote(mk("b"));
    removeNote("a");
    expect(get(notes).map((n) => n.id)).toEqual(["b"]);
  });

  it("touchNote updates title + mtime + size", () => {
    upsertNote(mk("a"));
    touchNote("a", "new title", NOW + 1000, 42);
    const n = get(notes)[0];
    expect(n.title).toBe("new title");
    expect(n.mtimeMs).toBe(NOW + 1000);
    expect(n.size).toBe(42);
  });

  it("sortedGroups re-derives as notes change", () => {
    upsertNote(mk("a", NOW - 1000));
    expect(get(sortedGroups)[0]?.count).toBe(1);
    upsertNote(mk("b", NOW));
    expect(get(sortedGroups)[0].count).toBe(2);
  });
});
