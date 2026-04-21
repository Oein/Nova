import { describe, it, expect } from "vitest";
import { bucketKey, bucketLabel, groupByLocalDay } from "./dateGrouping";
import type { Note } from "./types";

const DAY = 86_400_000;

const NOW = new Date(2026, 3, 20, 12, 0, 0); // 2026-04-20 12:00 local

describe("bucketKey", () => {
  it("returns YYYY-MM-DD in local TZ", () => {
    expect(bucketKey(NOW.getTime())).toBe("2026-04-20");
  });

  it("treats two times on the same local day as the same key", () => {
    const morning = new Date(2026, 3, 20, 8).getTime();
    const evening = new Date(2026, 3, 20, 23).getTime();
    expect(bucketKey(morning)).toBe(bucketKey(evening));
  });

  it("changes key at local midnight boundary", () => {
    const before = new Date(2026, 3, 20, 23, 59, 59).getTime();
    const after = new Date(2026, 3, 21, 0, 0, 1).getTime();
    expect(bucketKey(before)).not.toBe(bucketKey(after));
  });
});

describe("bucketLabel", () => {
  it("labels today, yesterday, and everything else", () => {
    expect(bucketLabel(bucketKey(NOW.getTime()), NOW)).toBe("Today");
    expect(bucketLabel(bucketKey(NOW.getTime() - DAY), NOW)).toBe("Yesterday");
    expect(bucketLabel(bucketKey(NOW.getTime() - 3 * DAY), NOW)).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("groupByLocalDay", () => {
  const mk = (id: string, mtimeMs: number, title = id): Note => ({
    id,
    title,
    createdMs: mtimeMs,
    mtimeMs,
    size: 1,
  });

  it("sorts by mtime desc and buckets by day", () => {
    const e = [
      mk("a", NOW.getTime() - 1000),
      mk("b", NOW.getTime() - DAY - 1000),
      mk("c", NOW.getTime() - 5000),
      mk("d", NOW.getTime() - 3 * DAY),
    ];
    const g = groupByLocalDay(e, NOW);
    expect(g[0].label).toBe("Today");
    expect(g[0].entries.map((x) => x.id)).toEqual(["a", "c"]);
    expect(g[1].label).toBe("Yesterday");
    expect(g[1].entries.map((x) => x.id)).toEqual(["b"]);
    expect(g[2].entries.map((x) => x.id)).toEqual(["d"]);
  });

  it("returns stable order for ties via id", () => {
    const t = NOW.getTime();
    const e = [mk("b", t), mk("a", t)];
    const g = groupByLocalDay(e, NOW);
    expect(g[0].entries.map((x) => x.id)).toEqual(["a", "b"]);
  });

  it("emits empty result for empty input", () => {
    expect(groupByLocalDay([], NOW)).toEqual([]);
  });

  it("count field matches entries.length", () => {
    const t = NOW.getTime();
    const g = groupByLocalDay([mk("a", t), mk("b", t), mk("c", t - DAY)], NOW);
    expect(g[0].count).toBe(2);
    expect(g[1].count).toBe(1);
  });
});
