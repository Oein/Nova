/** Derive a display title from the first non-empty line of content, mirroring
 *  the Rust `first_line_title` so the live UI title matches what the backend
 *  will persist on save. */
export function firstLineTitle(content: string, fallback = "Untitled"): string {
  const first = (content.split("\n")[0] ?? "").replace(/^#+/, "").trim();
  if (!first) return fallback;
  return first.length > 120 ? first.slice(0, 120) : first;
}
