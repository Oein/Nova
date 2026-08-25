//! End-to-end tests for the sync executor.
//!
//! Ported from the `mod executor` block of `src-tauri/src/notion/sync.rs`. Each
//! test drives the real engine against a real temporary workspace and the
//! in-memory `Fake` -- the substitution happens at the transport, so nothing in
//! the engine knows it is being tested.

const std = @import("std");
const db = @import("db");
const client = @import("client.zig");
const store = @import("store.zig");
const engine_mod = @import("engine.zig");
const fake_mod = @import("fake.zig");
const sync = @import("sync.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const Harness = struct {
    tw: db.workspace.TestWorkspace,
    fake: fake_mod.Fake,
    api: client.Client,
    cancel: std.atomic.Value(bool),
    gpa: Allocator,

    /// Heap-allocated: the client holds a transport pointing at `fake`, and the
    /// engine holds pointers to both.
    fn init(gpa: Allocator, name: []const u8) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);

        self.* = .{
            .tw = try db.workspace.TestWorkspace.init(gpa, name),
            .fake = fake_mod.Fake.init(gpa),
            .api = undefined,
            .cancel = std.atomic.Value(bool).init(false),
            .gpa = gpa,
        };
        self.api = client.Client.init(gpa, self.fake.transport());

        const cfg = try store.setConfig(&self.tw.ws, gpa, .{
            .token = "ntn_test",
            .database_id = "db-1",
            .enabled = true,
        });
        cfg.deinit(gpa);
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.gpa;
        self.api.deinit();
        self.fake.deinit();
        self.tw.deinit();
        gpa.destroy(self);
    }

    fn engine(self: *Harness) engine_mod.Engine {
        return engine_mod.Engine.init(self.gpa, self.tw.env.io, &self.tw.ws, &self.api, &self.cancel);
    }

    fn sync_(self: *Harness) !sync.Report {
        var e = self.engine();
        return e.run();
    }

    fn dryRun(self: *Harness) !sync.Report {
        var e = self.engine();
        e.dry_run = true;
        return e.run();
    }

    /// Create a note with the given body and return its owned id.
    fn addNote(self: *Harness, body: []const u8) ![]u8 {
        const note = try self.tw.ws.createNote();
        defer note.deinit(self.gpa);
        const saved = try self.tw.ws.writeNote(note.id, body, null);
        saved.deinit(self.gpa);
        return self.gpa.dupe(u8, note.id);
    }

    fn noteText(self: *Harness, id: []const u8) ![]u8 {
        const read = try self.tw.ws.readNote(id);
        defer read.deinit(self.gpa);
        return self.gpa.dupe(u8, read.content);
    }

    fn setNoteText(self: *Harness, id: []const u8, body: []const u8) !void {
        const saved = try self.tw.ws.writeNote(id, body, null);
        saved.deinit(self.gpa);
    }

    fn link(self: *Harness, note_id: []const u8) !?store.Link {
        return store.getLink(&self.tw.ws, self.gpa, note_id);
    }
};

test "a new note becomes a page, and syncing again is quiet" {
    const h = try Harness.init(testing.allocator, "sync-create-remote");
    defer h.deinit();

    const id = try h.addNote("# Weekly sync\n\nfirst line\n");
    defer testing.allocator.free(id);

    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.created_remote);
        try testing.expectEqual(@as(usize, 0), r.errors);
    }
    try testing.expectEqual(@as(usize, 1), h.fake.pages.items.len);
    try testing.expectEqualStrings("Weekly sync", h.fake.pages.items[0].title);

    // The second run must find nothing to do. This is the regression guard for
    // "our own push echoes back as a remote change".
    var again = try h.sync_();
    defer again.deinit();
    try testing.expect(again.quiet());
}

test "a page authored in Notion becomes a note" {
    const h = try Harness.init(testing.allocator, "sync-create-local");
    defer h.deinit();
    _ = try h.fake.addPage("Meeting notes", &.{ "agenda", "actions" });

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.created_local);
    try testing.expectEqual(@as(usize, 1), r.changed_note_ids.items.len);

    const notes = try h.tw.ws.listNotes();
    defer db.workspace.freeNotes(testing.allocator, notes);
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqualStrings("Meeting notes", notes[0].title);

    // The title lives in the body as a heading, so nothing is lost to the cap.
    const text = try h.noteText(notes[0].id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "# Meeting notes\n"));
    try testing.expect(std.mem.indexOf(u8, text, "agenda") != null);
}

test "a local edit is pushed" {
    const h = try Harness.init(testing.allocator, "sync-push");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbefore\n");
    defer testing.allocator.free(id);

    {
        var r = try h.sync_();
        defer r.deinit();
    }
    try h.setNoteText(id, "# T\n\nafter\n");

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.pushed);

    const page_id = (try h.link(id)).?;
    defer page_id.deinit(testing.allocator);
    const body = try h.fake.pageText(testing.allocator, page_id.page_id.?);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "after") != null);
    try testing.expect(std.mem.indexOf(u8, body, "before") == null);
}

test "a remote edit is pulled" {
    const h = try Harness.init(testing.allocator, "sync-pull");
    defer h.deinit();
    const id = try h.addNote("# T\n\nmine\n");
    defer testing.allocator.free(id);

    {
        var r = try h.sync_();
        defer r.deinit();
    }

    // Edit the page behind the app's back.
    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    const page = h.fake.findPage(l.page_id.?).?;
    page.blocks.clearRetainingCapacity();
    try page.blocks.append(testing.allocator, .{
        .id = "b-new",
        .json = try h.fake.paragraphJsonPublic("theirs"),
    });
    page.last_edited = try h.fake.stampPublic();

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.pulled);

    const text = try h.noteText(id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "theirs") != null);
    try testing.expectEqual(@as(usize, 1), r.changed_note_ids.items.len);
}

test "a metadata-only timestamp bump is absorbed" {
    const h = try Harness.init(testing.allocator, "sync-echo");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    // Move the timestamp without changing any content.
    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    h.fake.findPage(l.page_id.?).?.last_edited = try h.fake.stampPublic();

    var r = try h.sync_();
    defer r.deinit();
    // Stage two compares hashes and finds nothing to do.
    try testing.expect(r.quiet());
}

test "edits on both sides raise a conflict and freeze the note" {
    const h = try Harness.init(testing.allocator, "sync-conflict");
    defer h.deinit();
    const id = try h.addNote("# T\n\noriginal\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    try h.setNoteText(id, "# T\n\nmy version\n");
    {
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        const page = h.fake.findPage(l.page_id.?).?;
        page.blocks.clearRetainingCapacity();
        try page.blocks.append(testing.allocator, .{
            .id = "b-remote",
            .json = try h.fake.paragraphJsonPublic("their version"),
        });
        page.last_edited = try h.fake.stampPublic();
    }

    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.conflicts);
    }

    // Both sides were snapshotted at detection time.
    const detail = (try store.getConflict(&h.tw.ws, testing.allocator, id)).?;
    defer detail.deinit(testing.allocator);
    try testing.expectEqualStrings("both-changed", detail.kind);
    try testing.expect(std.mem.indexOf(u8, detail.local_content.?, "my version") != null);
    try testing.expect(std.mem.indexOf(u8, detail.remote_content.?, "their version") != null);

    // And the note is frozen: neither side moves until the user decides.
    const before = try h.noteText(id);
    defer testing.allocator.free(before);
    var again = try h.sync_();
    defer again.deinit();
    const after = try h.noteText(id);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(usize, 0), again.conflicts);
}

test "trashing a note archives its page" {
    const h = try Harness.init(testing.allocator, "sync-archive");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }
    const l = (try h.link(id)).?;
    const page_id = try testing.allocator.dupe(u8, l.page_id.?);
    defer testing.allocator.free(page_id);
    l.deinit(testing.allocator);

    try h.tw.ws.trashNote(id, 1000);

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.archived_remote);
    try testing.expect(h.fake.findPage(page_id).?.archived);
    try testing.expect((try h.link(id)) == null);
}

test "archiving a page trashes its note" {
    const h = try Harness.init(testing.allocator, "sync-trash-local");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }
    {
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        h.fake.findPage(l.page_id.?).?.archived = true;
    }

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.trashed_local);

    const trashed = try h.tw.ws.listTrashedNotes();
    defer db.workspace.freeTrashedNotes(testing.allocator, trashed);
    try testing.expectEqual(@as(usize, 1), trashed.len);
}

test "an unrecreatable block puts the note into pull-only mode" {
    const h = try Harness.init(testing.allocator, "sync-blocked");
    defer h.deinit();

    const page_id = try h.fake.addPage("Has a synced block", &.{});
    const page = h.fake.findPage(page_id).?;
    try page.blocks.append(testing.allocator, .{
        .id = "sb-1",
        .json = "{\"object\":\"block\",\"type\":\"synced_block\",\"synced_block\":{}}",
    });

    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.created_local);
    }

    const notes = try h.tw.ws.listNotes();
    defer db.workspace.freeNotes(testing.allocator, notes);
    const l = (try h.link(notes[0].id)).?;
    defer l.deinit(testing.allocator);
    try testing.expect(l.isBlocked());

    // The file carries the read-only marker, and a local edit is refused
    // rather than destroying the block.
    const text = try h.noteText(notes[0].id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "notion:readonly-body") != null);

    try h.setNoteText(notes[0].id, "# Edited\n\nlocal change\n");
    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.blocked);
    try testing.expectEqual(@as(usize, 0), r.pushed);
}

test "an unsupported block survives a round trip" {
    const h = try Harness.init(testing.allocator, "sync-unsupported");
    defer h.deinit();

    const page_id = try h.fake.addPage("Has a table", &.{"before"});
    const page = h.fake.findPage(page_id).?;
    try page.blocks.append(testing.allocator, .{
        .id = "tbl-1",
        .json = "{\"object\":\"block\",\"type\":\"table\",\"table\":{\"table_width\":2}}",
    });

    {
        var r = try h.sync_();
        defer r.deinit();
    }
    const notes = try h.tw.ws.listNotes();
    defer db.workspace.freeNotes(testing.allocator, notes);
    const note_id = notes[0].id;

    // The table became a placeholder in the file, and its JSON was cached.
    const text = try h.noteText(note_id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "notion:unsupported type=table") != null);

    const cached = try store.listBlocks(&h.tw.ws, testing.allocator, note_id);
    defer @import("model.zig").freeCachedBlocks(testing.allocator, cached);
    try testing.expectEqual(@as(usize, 1), cached.len);

    // Editing elsewhere and pushing must replay the table, not drop it.
    const edited = try std.mem.replaceOwned(u8, testing.allocator, text, "before", "after");
    defer testing.allocator.free(edited);
    try h.setNoteText(note_id, edited);

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.pushed);

    const l = (try h.link(note_id)).?;
    defer l.deinit(testing.allocator);
    var found_table = false;
    for (h.fake.findPage(l.page_id.?).?.blocks.items) |b| {
        if (std.mem.indexOf(u8, b.json, "\"table\"") != null) found_table = true;
    }
    try testing.expect(found_table);
}

test "a dry run changes nothing" {
    const h = try Harness.init(testing.allocator, "sync-dry");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);

    var r = try h.dryRun();
    defer r.deinit();
    try testing.expect(r.dry_run);
    try testing.expectEqual(@as(usize, 1), r.created_remote);
    // ...but nothing actually happened.
    try testing.expectEqual(@as(usize, 0), h.fake.pages.items.len);
    try testing.expect((try h.link(id)) == null);
}

test "cancellation stops the run" {
    const h = try Harness.init(testing.allocator, "sync-cancel");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);

    h.cancel.store(true, .seq_cst);
    var r = try h.sync_();
    defer r.deinit();
    try testing.expect(r.cancelled);
    try testing.expectEqual(@as(usize, 0), h.fake.pages.items.len);
}

test "a failed append leaves the page as it was" {
    const h = try Harness.init(testing.allocator, "sync-append-fail");
    defer h.deinit();
    const id = try h.addNote("# T\n\noriginal\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    const l = (try h.link(id)).?;
    const page_id = try testing.allocator.dupe(u8, l.page_id.?);
    defer testing.allocator.free(page_id);
    l.deinit(testing.allocator);

    const before = try h.fake.pageText(testing.allocator, page_id);
    defer testing.allocator.free(before);

    // The next append fails partway.
    h.fake.append_calls = 0;
    h.fake.fail_append_at = 1;
    try h.setNoteText(id, "# T\n\nnew content\n");

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.errors);

    // The page still holds exactly what it did before -- appending before
    // deleting is what makes that possible.
    const after = try h.fake.pageText(testing.allocator, page_id);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "an unreadable note is skipped, never pushed as empty" {
    const h = try Harness.init(testing.allocator, "sync-unreadable");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    // The file vanishes behind the app's back.
    h.tw.ws.fs.deleteIfExists(h.tw.ws.notePath(id).slice());

    var r = try h.sync_();
    defer r.deinit();
    // Reported as blocked, not pushed -- an empty hash would read as "the user
    // cleared this note" and blank the page.
    try testing.expectEqual(@as(usize, 1), r.blocked);
    try testing.expectEqual(@as(usize, 0), r.pushed);

    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    const body = try h.fake.pageText(testing.allocator, l.page_id.?);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "body") != null);
}

test "Korean content survives a full round trip" {
    const h = try Harness.init(testing.allocator, "sync-korean");
    defer h.deinit();
    const body = "# 회의록\n\n안녕하세요 반갑습니다\n\n- 항목 **하나**\n- 항목 둘\n";
    const id = try h.addNote(body);
    defer testing.allocator.free(id);

    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.created_remote);
    }
    // Nothing further to do, which means what came back matched byte for byte.
    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expect(r.quiet());
    }

    const text = try h.noteText(id);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(body, text);
    try testing.expectEqualStrings("회의록", h.fake.pages.items[0].title);
}

test "a first line past the title cap survives whole" {
    const h = try Harness.init(testing.allocator, "sync-long-title");
    defer h.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "# ");
    for (0..300) |_| try body.appendSlice(testing.allocator, "가");
    try body.appendSlice(testing.allocator, "\n\nbody\n");

    const id = try h.addNote(body.items);
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    // The heading is the body's first line, so the 120-character label cap
    // never touches the text itself.
    const text = try h.noteText(id);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(body.items, text);
}

test "the id column lets a lost mapping be rebuilt instead of duplicating" {
    const h = try Harness.init(testing.allocator, "sync-adopt");
    defer h.deinit();

    {
        const cfg = try store.setConfig(&h.tw.ws, testing.allocator, .{ .id_prop = "Nova Id" });
        cfg.deinit(testing.allocator);
    }
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.created_remote);
    }
    try testing.expectEqual(@as(usize, 1), h.fake.pages.items.len);

    // Simulate a lost workspace.db: the mapping is gone, the note is not.
    try store.clearAllLinks(&h.tw.ws);

    var r = try h.sync_();
    defer r.deinit();
    // Adopted, not re-published as a second page.
    try testing.expectEqual(@as(usize, 1), h.fake.pages.items.len);
    try testing.expectEqual(@as(usize, 0), r.created_remote);

    const relinked = (try h.link(id)).?;
    defer relinked.deinit(testing.allocator);
}

test "without the id column a lost mapping does duplicate" {
    // The honest counterpart to the test above: this is what the column buys.
    const h = try Harness.init(testing.allocator, "sync-no-adopt");
    defer h.deinit();

    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }
    try store.clearAllLinks(&h.tw.ws);

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), h.fake.pages.items.len);
}

test "timestamp columns are created and filled" {
    const h = try Harness.init(testing.allocator, "sync-timestamps");
    defer h.deinit();
    {
        const cfg = try store.setConfig(&h.tw.ws, testing.allocator, .{
            .created_prop = "Created",
            .updated_prop = "Updated",
        });
        cfg.deinit(testing.allocator);
    }
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);

    var r = try h.sync_();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.errors);

    // The columns were added to the schema and written to.
    try testing.expectEqualStrings("date", h.fake.schema.get("Created").?);
    try testing.expectEqualStrings("date", h.fake.schema.get("Updated").?);
    try testing.expect(std.mem.indexOf(u8, h.fake.pages.items[0].props_json, "Created") != null);
}

test "a column of the wrong type is left alone and reported" {
    const h = try Harness.init(testing.allocator, "sync-wrong-type");
    defer h.deinit();
    // The user already keeps something else in this column.
    try h.fake.addSchemaProperty("Created", "rich_text");
    {
        const cfg = try store.setConfig(&h.tw.ws, testing.allocator, .{ .created_prop = "Created" });
        cfg.deinit(testing.allocator);
    }
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);

    var r = try h.sync_();
    defer r.deinit();
    try testing.expect(r.blocked >= 1);
    // Repurposing it would destroy data, so the type is untouched.
    try testing.expectEqualStrings("rich_text", h.fake.schema.get("Created").?);
}

test "an excluded note is never touched" {
    const h = try Harness.init(testing.allocator, "sync-excluded");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    try store.setLinkState(&h.tw.ws, id, "excluded", null);
    try h.setNoteText(id, "# T\n\nchanged locally\n");

    var r = try h.sync_();
    defer r.deinit();
    try testing.expect(r.quiet());

    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    const body = try h.fake.pageText(testing.allocator, l.page_id.?);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "changed locally") == null);
}

// -- conflict resolution -----------------------------------------------------

const resolve_mod = @import("resolve.zig");

/// Drive both sides into a `both-changed` conflict and return the note id.
fn conflicted(h: *Harness) ![]u8 {
    const id = try h.addNote("# T\n\noriginal\n");
    errdefer h.gpa.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    try h.setNoteText(id, "# T\n\nmy version\n");
    {
        const l = (try h.link(id)).?;
        defer l.deinit(h.gpa);
        const page = h.fake.findPage(l.page_id.?).?;
        page.blocks.clearRetainingCapacity();
        try page.blocks.append(h.gpa, .{
            .id = "b-remote",
            .json = try h.fake.paragraphJsonPublic("their version"),
        });
        page.last_edited = try h.fake.stampPublic();
    }
    var r = try h.sync_();
    defer r.deinit();
    return id;
}

fn resolver(h: *Harness) resolve_mod.Resolver {
    return resolve_mod.Resolver.init(h.gpa, h.tw.env.io, &h.tw.ws, &h.api);
}

test "keeping the local version pushes it over the page" {
    const h = try Harness.init(testing.allocator, "resolve-local");
    defer h.deinit();
    const id = try conflicted(h);
    defer testing.allocator.free(id);

    var r = resolver(h);
    try r.resolve(id, .keep_local);

    try testing.expectEqual(@as(i64, 0), try store.countConflicts(&h.tw.ws));
    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", l.state);

    const body = try h.fake.pageText(testing.allocator, l.page_id.?);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "my version") != null);

    // And the note is no longer frozen: a later sync is quiet.
    var again = try h.sync_();
    defer again.deinit();
    try testing.expect(again.quiet());
}

test "keeping the remote version overwrites the note" {
    const h = try Harness.init(testing.allocator, "resolve-remote");
    defer h.deinit();
    const id = try conflicted(h);
    defer testing.allocator.free(id);

    var r = resolver(h);
    try r.resolve(id, .keep_remote);

    const text = try h.noteText(id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "their version") != null);
    try testing.expectEqual(@as(i64, 0), try store.countConflicts(&h.tw.ws));
}

test "keeping both forks the remote version into a second note" {
    const h = try Harness.init(testing.allocator, "resolve-both");
    defer h.deinit();
    const id = try conflicted(h);
    defer testing.allocator.free(id);

    var r = resolver(h);
    try r.resolve(id, .keep_both);

    const notes = try h.tw.ws.listNotes();
    defer db.workspace.freeNotes(testing.allocator, notes);
    try testing.expectEqual(@as(usize, 2), notes.len);

    // The fork keeps the page's text under a marked title; only the heading
    // line is replaced.
    var found_fork = false;
    for (notes) |n| {
        if (std.mem.indexOf(u8, n.title, "(Notion)") != null) {
            found_fork = true;
            const text = try h.noteText(n.id);
            defer testing.allocator.free(text);
            try testing.expect(std.mem.indexOf(u8, text, "their version") != null);
        }
    }
    try testing.expect(found_fork);

    // The original kept the local text.
    const original = try h.noteText(id);
    defer testing.allocator.free(original);
    try testing.expect(std.mem.indexOf(u8, original, "my version") != null);
}

test "accepting the remote deletion trashes the note" {
    const h = try Harness.init(testing.allocator, "resolve-accept-remote-del");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    // The page is deleted while the note is edited.
    {
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        h.fake.findPage(l.page_id.?).?.archived = true;
    }
    try h.setNoteText(id, "# T\n\nedited after the page went\n");
    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.conflicts);
    }

    var r = resolver(h);
    try r.resolve(id, .accept_remote_delete);

    const trashed = try h.tw.ws.listTrashedNotes();
    defer db.workspace.freeTrashedNotes(testing.allocator, trashed);
    try testing.expectEqual(@as(usize, 1), trashed.len);
    try testing.expect((try h.link(id)) == null);
    try testing.expectEqual(@as(i64, 0), try store.countConflicts(&h.tw.ws));
}

test "recreating the remote puts a deleted page back" {
    const h = try Harness.init(testing.allocator, "resolve-recreate");
    defer h.deinit();
    const id = try h.addNote("# T\n\nbody\n");
    defer testing.allocator.free(id);
    {
        var r = try h.sync_();
        defer r.deinit();
    }
    {
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        h.fake.findPage(l.page_id.?).?.archived = true;
    }
    try h.setNoteText(id, "# T\n\nstill wanted\n");
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    var r = resolver(h);
    try r.resolve(id, .recreate_remote);

    const l = (try h.link(id)).?;
    defer l.deinit(testing.allocator);
    const page = h.fake.findPage(l.page_id.?).?;
    try testing.expect(!page.archived);

    const body = try h.fake.pageText(testing.allocator, page.id);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "still wanted") != null);
}

test "a bulk policy resolves every conflict independently" {
    const h = try Harness.init(testing.allocator, "resolve-bulk");
    defer h.deinit();

    // Two notes, both conflicted the same way.
    var ids: [2][]u8 = undefined;
    for (&ids, 0..) |*slot, i| {
        var name: [16]u8 = undefined;
        const body = try std.fmt.bufPrint(&name, "# N{d}\n\nbase\n", .{i});
        slot.* = try h.addNote(body);
    }
    defer for (ids) |id| testing.allocator.free(id);

    {
        var r = try h.sync_();
        defer r.deinit();
    }
    for (ids) |id| {
        try h.setNoteText(id, "# N\n\nlocal edit\n");
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        const page = h.fake.findPage(l.page_id.?).?;
        page.blocks.clearRetainingCapacity();
        try page.blocks.append(testing.allocator, .{
            .id = try std.fmt.allocPrint(h.fake.arena.allocator(), "rb-{s}", .{id[0..4]}),
            .json = try h.fake.paragraphJsonPublic("remote edit"),
        });
        page.last_edited = try h.fake.stampPublic();
    }
    {
        var r = try h.sync_();
        defer r.deinit();
        try testing.expectEqual(@as(usize, 2), r.conflicts);
    }

    var r = resolver(h);
    const result = try r.resolveAll(.local);
    try testing.expectEqual(@as(usize, 2), result.resolved);
    try testing.expectEqual(@as(usize, 0), result.failed);
    try testing.expectEqual(@as(i64, 0), try store.countConflicts(&h.tw.ws));

    for (ids) |id| {
        const l = (try h.link(id)).?;
        defer l.deinit(testing.allocator);
        const body = try h.fake.pageText(testing.allocator, l.page_id.?);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "local edit") != null);
    }
}

test "a resolution cannot bypass the pull-only guard" {
    const h = try Harness.init(testing.allocator, "resolve-blocked");
    defer h.deinit();

    const page_id = try h.fake.addPage("Blocked", &.{"body"});
    const page = h.fake.findPage(page_id).?;
    try page.blocks.append(testing.allocator, .{
        .id = "sb-1",
        .json = "{\"object\":\"block\",\"type\":\"synced_block\",\"synced_block\":{}}",
    });
    {
        var r = try h.sync_();
        defer r.deinit();
    }

    const notes = try h.tw.ws.listNotes();
    defer db.workspace.freeNotes(testing.allocator, notes);
    const note_id = notes[0].id;

    // Force a conflict on a note whose page cannot be rebuilt.
    try store.upsertConflict(&h.tw.ws, .{
        .note_id = note_id,
        .page_id = page_id,
        .kind = "both-changed",
        .local_content = "mine",
        .remote_content = "theirs",
        .local_title = "Blocked",
        .remote_title = "Blocked",
        .detected_ms = 1,
    });

    var r = resolver(h);
    // Pushing would destroy the synced block, so the resolver refuses.
    try testing.expectError(error.NotResolvable, r.resolve(note_id, .keep_local));
    try testing.expectEqual(@as(i64, 1), try store.countConflicts(&h.tw.ws));
}
