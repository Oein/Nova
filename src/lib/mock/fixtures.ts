export const ROOT = "/mock/workspace";

const DAY_MS = 86_400_000;

interface SeedNote {
  id: string;
  title: string;
  createdMs: number;
  mtimeMs: number;
  size: number;
  content: string;
}

export function firstLineTitle(content: string, fallback: string): string {
  const first = (content.split("\n")[0] ?? "").replace(/^#+/, "").trim();
  if (!first) return fallback;
  return first.length > 120 ? first.slice(0, 120) : first;
}

export function seedFixtures(push: (n: SeedNote) => void): void {
  const now = Date.now();
  const day = (d: number) => now - d * DAY_MS;

  const note = (id: string, content: string, mtimeMs: number): SeedNote => {
    const size = new TextEncoder().encode(content).length;
    return {
      id,
      title: firstLineTitle(content, "Untitled"),
      createdMs: mtimeMs,
      mtimeMs,
      size,
      content,
    };
  };

  push(note("note-1", "# Project notes\n\nToday I worked on the sidebar layout.\n", now - 2 * 60_000));
  push(note("note-2", "# Sublime clone ideas\n\n- DB-backed workspace\n- First-line titles\n", now - 5 * 60_000));
  push(note("note-3", "# Meeting with Alex\n\nDiscussed backlog.\n", now - 15 * 60_000));

  push(note("note-4", "# Yesterday's draft\n\nRough sketch.\n", day(1) - 60_000));
  push(note("note-5", "# Reading list\n\n- paper on ropes\n", day(1) - 3 * 3600_000));

  push(note("note-6", "# Changelog\n\n- 0.1.0 scaffolding\n", day(2)));
  push(note("note-7", "# Scratch\n\nquick notes\n", day(2) - 60_000));

  push(note("note-8", "# Old draft\n\ndraft content\n", day(7)));
  push(note("note-9", "# Snippets\n\n`console.log($1)`\n", day(7) - 2 * 3600_000));
}
