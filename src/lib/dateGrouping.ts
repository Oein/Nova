import type { Note, Group } from "./types";

const pad2 = (n: number) => n.toString().padStart(2, "0");

export function bucketKey(mtimeMs: number): string {
  const d = new Date(mtimeMs);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function bucketLabel(key: string, now = new Date()): string {
  const todayKey = bucketKey(now.getTime());
  const yesterdayKey = bucketKey(now.getTime() - 86_400_000);
  if (key === todayKey) return "Today";
  if (key === yesterdayKey) return "Yesterday";
  return key;
}

export function groupByLocalDay(notes: Note[], now = new Date()): Group[] {
  const sorted = [...notes].sort((a, b) => {
    if (b.mtimeMs !== a.mtimeMs) return b.mtimeMs - a.mtimeMs;
    return a.id.localeCompare(b.id);
  });
  const map = new Map<string, Note[]>();
  for (const e of sorted) {
    const k = bucketKey(e.mtimeMs);
    let arr = map.get(k);
    if (!arr) {
      arr = [];
      map.set(k, arr);
    }
    arr.push(e);
  }
  const groups: Group[] = [];
  for (const [key, arr] of map) {
    groups.push({ key, label: bucketLabel(key, now), count: arr.length, entries: arr });
  }
  return groups;
}
