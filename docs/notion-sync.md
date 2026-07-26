# Notion sync

Links one Nova workspace to one Notion database and keeps them in step in both
directions. Each note maps to exactly one page.

## The title is part of the note

Nova's title convention — the first line of the file — carries over verbatim:
the `# Heading` line is pushed as the page's **first block**, and the Notion
title property is a *label derived from it*. Rename a note by editing that
heading; the title is always re-read from the body, never stored separately.

This matters because both labels are capped (120 characters for the note title,
2000 for a Notion title property) while the line itself is not. Stripping the
first line into the property would silently truncate any note that opens with a
long sentence. Keeping it in the body means the caps only ever shorten a label.

A page authored in Notion has its title only in the property, so Nova prepends
the heading when pulling it down. After one push the two agree and nothing
further changes.

## Setup

1. Create an integration at <https://www.notion.so/my-integrations> and copy its
   internal integration secret (`ntn_…`).
2. In Notion, open the database you want to sync → `⋯` → **Connections** → add
   the integration. A database that hasn't been shared is invisible to the API,
   which is the usual reason the picker comes back empty.
3. In Nova: **Settings → Notion sync** → paste the token → **Save** → pick the
   database → **Test connection** → tick *Sync this workspace…*.

The token is stored in that workspace's `workspace.db` and never leaves the Rust
process — the frontend only ever sees whether one is set plus its last four
characters. Switching to a different database clears every stored mapping,
since page ids from the old database mean nothing in the new one.

## Extra columns (optional)

Nova can fill in three Notion properties. Name them in **Settings → Notion
sync**; a blank field turns that column off, which is the default.

| Setting | Notion type | Holds |
|---|---|---|
| Created column | `date` | when the note was created |
| Updated column | `date` | when the note was last modified |
| ID column | `rich_text` | the note's unique id |

**Why not Notion's built-in `created_time` / `last_edited_time`?** Notion
manages those and the API refuses writes to them, and they'd record when the
*sync* touched the page rather than when you wrote the note.

**Why an ID column?** Two notes can share a title; they can never share an id.
It also makes the link recoverable: if this workspace's local bookkeeping is
lost (fresh install, deleted `workspace.db`), the next sync re-attaches each
page to its note by id instead of importing every page a second time. Without
it, that situation duplicates everything. If a page and its note drifted apart
while unlinked, re-attaching raises a conflict rather than picking a winner.

For any of the three:

- A property that doesn't exist yet is **created** on the next sync.
- One that already exists with the right type is reused.
- One that exists with a *different* type is left completely alone and reported
  as a warning; repurposing a column you use for something else would destroy
  data.
- **Editing these values in Notion has no effect.** Nova's are the source of
  truth and overwrite them on the next sync.
- Turning a column on **backfills pages that are already in sync** — you don't
  have to edit every note to populate it.

`Test connection` tells you which of these will happen before anything changes.

## When it runs

Three triggers, all optional except the manual one:

- **Sync now** — the button in Settings, or the ↻ in the status bar
- **On start** — once, a couple of seconds after the workspace opens
- **On a timer** — every 15 minutes by default (1 minute minimum)

Every sync saves any unsaved buffers first. The engine compares files on disk,
so an unsaved edit would otherwise look like "no local change" and lose to the
remote.

A sync takes real wall-clock time (rate limiting, pagination), and you may keep
editing while it runs. Both directions re-check the file immediately before
writing it: a pull that finds the note changed underneath it raises a conflict
instead of overwriting, and a push keeps your newer text and leaves it queued
for the next pass.

## How changes are decided

Each linked note carries a *baseline*: the last state at which both sides agreed.
A sync compares three things — the local file's hash, the page's
`last_edited_time`, and that baseline.

`last_edited_time` only ever answers *"might this have changed?"*. It has
second granularity, bumps when we ourselves write, and moves for
metadata-only edits. So when it differs, Nova fetches the page's blocks, renders
them to markdown, and compares *that* hash against the baseline. Only then does
it decide:

| Local changed | Remote changed | Result |
|---|---|---|
| no | no | nothing to do |
| yes | no | push |
| no | yes | pull |
| yes | yes | **conflict** |

Deletions follow the same shape: an untouched note whose page was deleted goes
to the trash, an untouched page whose note was deleted gets archived, and either
one with edits on the surviving side raises a conflict instead.

## Notes whose file is missing

A note row whose `.md` file has been deleted outside Nova is skipped with a
warning rather than synced — pushing it would replace the Notion page with an
empty one. Delete the note in Nova to clear the warning.

## Conflicts

Nothing is merged automatically and nothing is overwritten. The note is frozen —
skipped by every later sync — until you choose, so leaving a conflict unresolved
is always safe. The status bar shows `⚠ N`; clicking it opens a side-by-side
view with changed lines highlighted.

- **Edited on both sides** — keep Nova's, use Notion's, or keep both (the Notion
  version becomes a new note, which the next sync publishes as its own page)
- **Deleted in Notion** — recreate it there, or delete it here too
- **Deleted in Nova** — restore it here, or delete it there too

### Resolving them all at once

With more than one conflict outstanding, a bar at the top of the panel offers
one answer for the whole set. Each maps onto the per-kind choices above:

| | Edited on both sides | Deleted in Notion | Deleted in Nova |
|---|---|---|---|
| **Keep Nova everywhere** | keep Nova's | recreate in Notion | restore in Nova |
| **Use Notion everywhere** | use Notion's | delete here too | delete there too |
| **Keep everything** | keep both | recreate in Notion | restore in Nova |

"Keep everything" never discards anything, which is the one to reach for when
you're not sure. Bulk actions ask for confirmation first, and each conflict is
applied independently — if one fails, the rest still resolve and the failed one
stays listed so you can retry it.

## What survives a round trip

Headings (`#`–`###`), paragraphs, bulleted and numbered lists, to-dos, quotes,
fenced code, dividers, externally-hosted images, and three levels of list
nesting. Inline: `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, and links.

Anything else — tables, callouts, toggles, columns, embeds, equations, page
mentions — is preserved rather than rendered. It shows up as a one-line marker:

```
<!-- notion:unsupported type=callout id=1a2b3c4d-… -->
```

Nova keeps the block's original JSON and replays it on the next push. Deleting
the marker line deletes the block; copying it duplicates it.

### Known limits

1. **Pushing rebuilds the page body.** Notion has no block-move API and can't
   insert at the front of a page, so writing a body means writing all of it and
   removing all of the old. Consequences: block ids change (deep links to a
   specific block break), and per-block comments and edit history are lost.
   Deleted blocks sit in Notion's trash for 30 days.

   The order is append-first, delete-second, so a failed push leaves the page
   exactly as it was rather than empty. If the cleanup deletes fail after a
   successful append, you'll see the previous version below the new one — the
   sync reports this, and the next push clears it.
2. **Some blocks can't be recreated at all** — synced blocks, sub-pages, child
   databases, and Notion-hosted files (their URLs expire and there's no upload
   API). A page containing one becomes **pull-only**: local edits to the body
   aren't pushed, and each sync warns instead. Adopt the Notion version to clear
   it. Such notes carry a `<!-- notion:readonly-body -->` marker under the title.
3. **Text colour and underline are dropped**; `_underscores_` are literal text,
   not italics, so `snake_case` survives untouched.
4. **Empty paragraphs are dropped** — markdown says the same thing with a blank
   line between blocks.
5. **List nesting past three levels is flattened** onto the third.
6. **Only the title and the three optional columns above are synced.** Every
   other database property is left alone in both directions.
7. **Sub-pages don't become notes.** One note, one page.

## Architecture notes

All Notion HTTP lives in Rust (`src-tauri/src/notion/`). This isn't a
preference: `api.notion.com` sends no CORS headers, so the webview can't call it
at all. Keeping it backend-side also means the PAT never enters the JS context.

`sync::classify` is a pure function — no clock, no network, no database — which
is what makes the whole merge table testable directly. `NotionApi` is a trait so
the executor can be exercised against `notion::fake::FakeNotion` instead of a
live workspace; see `sync.rs`'s `executor` tests for the scenarios covered.

Requests are serialized ~3/second with retry on 429 and 5xx. The workspace mutex
is taken and released inside `Executor::ws` and never held across an `.await` —
`rusqlite::Connection` is `!Sync`, so breaking that rule fails to compile rather
than deadlocking at runtime.
