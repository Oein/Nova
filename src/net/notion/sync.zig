//! The two-way sync engine.
//!
//! Ported from the executor half of `src-tauri/src/notion/sync.rs`.
//!
//! Two invariants carry the whole design:
//!
//!  1. `classify` never does I/O, so the merge table is exhaustively testable
//!     (see `classify.zig`).
//!  2. The baseline is content-addressed, not time-addressed. Notion's
//!     `last_edited_time` bumps on our own writes, so it only says "*might*
//!     this have changed"; a hash over the rendered markdown says whether it
//!     did.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");
const client = @import("client.zig");
const store = @import("store.zig");
const b2m = @import("blocks_to_md.zig");
const m2b = @import("md_to_blocks.zig");
const classify = @import("classify.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;
const Workspace = db.workspace.Workspace;
const Action = classify.Action;
const ConflictKind = classify.ConflictKind;

/// Nested children are fetched to this depth, matching the three list levels
/// markdown can express. Anything deeper is left with `has_children: true` and
/// no `children`, which the renderer reads as "unrepresentable" and preserves
/// as a placeholder.
pub const fetch_depth: usize = 3;

pub const Error = error{
    OutOfMemory,
    SqliteError,
    FsFailed,
    NotFound,
    NoteNotFound,
    MtimeMismatch,
    Transport,
    NotionError,
    BadResponse,
    Cancelled,
    TokenNotSet,
    DatabaseNotSelected,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

// -- reporting ---------------------------------------------------------------

pub const ItemKind = enum {
    pulled,
    pushed,
    created_local,
    created_remote,
    archived_remote,
    trashed_local,
    conflict,
    blocked,
    err,
    info,

    pub fn severity(self: ItemKind) Severity {
        return switch (self) {
            .conflict, .blocked => .warn,
            .err => .@"error",
            else => .info,
        };
    }
};

pub const Severity = enum { info, warn, @"error" };

pub const ReportItem = struct {
    note_id: ?[]const u8,
    page_id: ?[]const u8,
    title: []const u8,
    kind: ItemKind,
    message: ?[]const u8,
};

pub const Report = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,

    pulled: usize = 0,
    pushed: usize = 0,
    created_local: usize = 0,
    created_remote: usize = 0,
    archived_remote: usize = 0,
    trashed_local: usize = 0,
    conflicts: usize = 0,
    blocked: usize = 0,
    errors: usize = 0,

    items: std.ArrayList(ReportItem) = .empty,
    /// Notes whose files this sync rewrote, so open tabs can be reloaded.
    changed_note_ids: std.ArrayList([]const u8) = .empty,
    cancelled: bool = false,
    dry_run: bool = false,

    pub fn init(gpa: Allocator) Report {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Report) void {
        self.items.deinit(self.gpa);
        self.changed_note_ids.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn push(
        self: *Report,
        kind: ItemKind,
        note_id: ?[]const u8,
        page_id: ?[]const u8,
        title: []const u8,
        message: ?[]const u8,
    ) !void {
        const a = self.arena.allocator();
        switch (kind) {
            .pulled => self.pulled += 1,
            .pushed => self.pushed += 1,
            .created_local => self.created_local += 1,
            .created_remote => self.created_remote += 1,
            .archived_remote => self.archived_remote += 1,
            .trashed_local => self.trashed_local += 1,
            .conflict => self.conflicts += 1,
            .blocked => self.blocked += 1,
            .err => self.errors += 1,
            .info => {},
        }
        try self.items.append(self.gpa, .{
            .note_id = if (note_id) |v| try a.dupe(u8, v) else null,
            .page_id = if (page_id) |v| try a.dupe(u8, v) else null,
            .title = try a.dupe(u8, title),
            .kind = kind,
            .message = if (message) |v| try a.dupe(u8, v) else null,
        });
    }

    pub fn noteChanged(self: *Report, note_id: []const u8) !void {
        for (self.changed_note_ids.items) |existing| {
            if (std.mem.eql(u8, existing, note_id)) return;
        }
        const owned = try self.arena.allocator().dupe(u8, note_id);
        try self.changed_note_ids.append(self.gpa, owned);
    }

    pub fn quiet(self: *const Report) bool {
        return self.pulled == 0 and self.pushed == 0 and self.created_local == 0 and
            self.created_remote == 0 and self.archived_remote == 0 and
            self.trashed_local == 0 and self.conflicts == 0 and
            self.blocked == 0 and self.errors == 0;
    }

    /// The one-line summary the status bar shows.
    pub fn summarize(self: *const Report, gpa: Allocator) ![]u8 {
        if (self.cancelled) return gpa.dupe(u8, "Notion sync cancelled");
        if (self.quiet()) return gpa.dupe(u8, "Notion: up to date");

        var parts: std.ArrayList(u8) = .empty;
        errdefer parts.deinit(gpa);

        const counts = [_]struct { usize, []const u8 }{
            .{ self.pulled, "pulled" },
            .{ self.pushed, "pushed" },
            .{ self.created_local, "new here" },
            .{ self.created_remote, "new in Notion" },
            .{ self.trashed_local, "trashed" },
            .{ self.archived_remote, "archived" },
            .{ self.conflicts, "conflict(s)" },
            .{ self.blocked, "blocked" },
            .{ self.errors, "failed" },
        };
        for (counts) |c| {
            if (c[0] == 0) continue;
            if (parts.items.len > 0) try parts.appendSlice(gpa, ", ");
            var buf: [32]u8 = undefined;
            try parts.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d} {s}", .{ c[0], c[1] }));
        }
        if (self.errors > 0 or self.blocked > 0) {
            try parts.appendSlice(gpa, " -- see Settings for details");
        }
        return parts.toOwnedSlice(gpa);
    }
};

// -- hashing -----------------------------------------------------------------

pub const Hash = [64]u8;

pub fn sha256Hex(text: []const u8) Hash {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    var out: Hash = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return out;
}

// -- the timestamp columns ---------------------------------------------------

/// The Nova-owned columns, after checking them against the database schema.
pub const Props = struct {
    title_prop: []const u8,
    created: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    id: ?[]const u8 = null,

    pub fn anyConfigured(self: Props) bool {
        return self.created != null or self.updated != null or self.id != null;
    }

    /// The properties payload for a page.
    pub fn payload(
        self: Props,
        arena: Allocator,
        title: []const u8,
        created_ms: i64,
        updated_ms: i64,
        note_id: []const u8,
    ) !Value {
        var parts: std.ArrayList(Value) = .empty;
        try parts.append(arena, try client.titleProperty(arena, self.title_prop, title));
        if (self.created) |name| {
            try parts.append(arena, try client.dateProperty(arena, name, created_ms));
        }
        if (self.updated) |name| {
            try parts.append(arena, try client.dateProperty(arena, name, updated_ms));
        }
        if (self.id) |name| {
            try parts.append(arena, try client.textProperty(arena, name, note_id));
        }
        return client.mergeProperties(arena, parts.items);
    }

    /// True when the page already carries the values we would write, so a
    /// content-clean note needs no property update.
    pub fn matches(
        self: Props,
        arena: Allocator,
        page: model.PageMeta,
        created_ms: i64,
        updated_ms: i64,
        note_id: []const u8,
    ) !bool {
        if (self.created) |name| {
            if (!try dateMatches(arena, page.properties, name, created_ms)) return false;
        }
        if (self.updated) |name| {
            if (!try dateMatches(arena, page.properties, name, updated_ms)) return false;
        }
        if (self.id) |name| {
            const stored = try model.pagePropertyPlain(arena, page.properties, name);
            if (stored == null or !std.mem.eql(u8, stored.?, note_id)) return false;
        }
        return true;
    }
};

fn dateMatches(arena: Allocator, props: Value, name: []const u8, ms: i64) !bool {
    const prop = switch (props) {
        .object => |o| o.get(name) orelse return false,
        else => return false,
    };
    const date = switch (prop) {
        .object => |o| o.get("date") orelse return false,
        else => return false,
    };
    const start = switch (date) {
        .object => |o| o.get("start") orelse return false,
        else => return false,
    };
    const text = switch (start) {
        .string => |s| s,
        else => return false,
    };
    _ = arena;
    // Notion may normalize the format, so compare the instant, not the string.
    const stored_ms = model.iso8601ToMs(text) orelse return false;
    return stored_ms == ms;
}

// -- fetching ----------------------------------------------------------------

/// A page's blocks, rendered to markdown and hashed.
pub const Fetched = struct {
    arena: std.heap.ArenaAllocator,
    markdown: []u8,
    hash: Hash,
    unsupported: []model.CachedBlock,
    push_mode: []const u8,

    pub fn deinit(self: *Fetched, gpa: Allocator) void {
        gpa.free(self.markdown);
        model.freeCachedBlocks(gpa, self.unsupported);
        self.arena.deinit();
    }
};

/// A page that holds an unrecreatable block can only ever be pulled from.
fn pushModeFor(blocks: []const model.CachedBlock) []const u8 {
    for (blocks) |b| {
        if (!b.recreatable) return "blocked";
    }
    return "rebuild";
}

/// Insert the read-only marker directly under the title heading.
fn insertReadonlyMarker(gpa: Allocator, md: []const u8) ![]u8 {
    const eol = std.mem.indexOfScalar(u8, md, '\n') orelse md.len;
    if (eol >= md.len) {
        return std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ md, b2m.readonly_marker });
    }
    return std.fmt.allocPrint(
        gpa,
        "{s}\n{s}\n{s}",
        .{ md[0..eol], b2m.readonly_marker, md[eol + 1 ..] },
    );
}

/// Render a page and hash exactly what will land on disk.
///
/// The read-only marker is folded in *before* hashing, so the hash describes
/// the file's real contents rather than something one step removed from them.
pub fn renderFetched(
    gpa: Allocator,
    title: []const u8,
    blocks: []const Value,
) !Fetched {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const rendered = try b2m.renderPage(gpa, title, blocks);
    errdefer rendered.deinit(gpa);

    const push_mode = pushModeFor(rendered.unsupported);
    var markdown = rendered.markdown;
    if (std.mem.eql(u8, push_mode, "blocked")) {
        markdown = try insertReadonlyMarker(gpa, rendered.markdown);
        gpa.free(rendered.markdown);
    }

    return .{
        .arena = arena,
        .markdown = markdown,
        .hash = sha256Hex(markdown),
        .unsupported = rendered.unsupported,
        .push_mode = push_mode,
    };
}

// -- placeholder ids ---------------------------------------------------------

pub const IdMap = std.StringHashMapUnmanaged([]const u8);

/// Rewrite placeholder block ids line by line, preserving the trailing newline.
///
/// After a push the old block ids are freed, so the file's placeholders have to
/// point at the new ones -- otherwise the next sync sees a phantom local change.
pub fn rewritePlaceholderIds(gpa: Allocator, content: []const u8, map: IdMap) ![]u8 {
    if (map.count() == 0) return gpa.dupe(u8, content);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;

        if (b2m.parsePlaceholder(line)) |ph| {
            if (map.get(ph.id)) |new_id| {
                const replacement = try b2m.placeholderLine(gpa, ph.block_type, new_id);
                defer gpa.free(replacement);
                // Keep the original indentation.
                const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
                try out.appendSlice(gpa, line[0..lead]);
                try out.appendSlice(gpa, replacement);
                continue;
            }
        }
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "sha256 hex is stable and distinguishes content" {
    const a = sha256Hex("hello");
    const b = sha256Hex("hello");
    const c = sha256Hex("hello!");
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &c));
    try testing.expectEqual(@as(usize, 64), a.len);
    // Known vector for "hello".
    try testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &a,
    );
}

test "the read-only marker goes under the title" {
    const out = try insertReadonlyMarker(testing.allocator, "# Title\n\nbody\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# Title\n" ++ b2m.readonly_marker ++ "\n\nbody\n", out);
}

test "a page with an unrecreatable block is pull-only" {
    const blocks = [_]model.CachedBlock{
        .{ .block_id = "a", .ord = 0, .block_type = "table", .raw_json = "{}", .recreatable = true },
        .{ .block_id = "b", .ord = 1, .block_type = "synced_block", .raw_json = "{}", .recreatable = false },
    };
    try testing.expectEqualStrings("blocked", pushModeFor(&blocks));
    try testing.expectEqualStrings("rebuild", pushModeFor(blocks[0..1]));
    try testing.expectEqualStrings("rebuild", pushModeFor(&.{}));
}

test "rendering a blocked page folds the marker in before hashing" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"id":"b1","type":"synced_block","synced_block":{}}]
    , .{});
    defer parsed.deinit();

    var fetched = try renderFetched(testing.allocator, "T", parsed.value.array.items);
    defer fetched.deinit(testing.allocator);

    try testing.expectEqualStrings("blocked", fetched.push_mode);
    try testing.expect(std.mem.indexOf(u8, fetched.markdown, b2m.readonly_marker) != null);
    // The hash must describe the file as it will be written.
    try testing.expectEqualSlices(u8, &sha256Hex(fetched.markdown), &fetched.hash);
}

test "placeholder ids are rewritten in place" {
    var map: IdMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "old-1", "new-1");

    const before = try b2m.placeholderLine(testing.allocator, "table", "old-1");
    defer testing.allocator.free(before);
    const content = try std.fmt.allocPrint(testing.allocator, "# T\n\n{s}\n\nafter\n", .{before});
    defer testing.allocator.free(content);

    const after = try rewritePlaceholderIds(testing.allocator, content, map);
    defer testing.allocator.free(after);

    try testing.expect(std.mem.indexOf(u8, after, "id=new-1") != null);
    try testing.expect(std.mem.indexOf(u8, after, "id=old-1") == null);
    // Everything else is untouched, trailing newline included.
    try testing.expect(std.mem.startsWith(u8, after, "# T\n\n"));
    try testing.expect(std.mem.endsWith(u8, after, "\nafter\n"));
}

test "an unmapped placeholder is left alone" {
    var map: IdMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "other", "new");

    const content = "<!-- notion:unsupported type=table id=keep -->\n";
    const after = try rewritePlaceholderIds(testing.allocator, content, map);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(content, after);
}

test "an empty map copies the content unchanged" {
    var map: IdMap = .empty;
    defer map.deinit(testing.allocator);
    const after = try rewritePlaceholderIds(testing.allocator, "a\nb\n", map);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("a\nb\n", after);
}

test "a report summarizes its counts" {
    var r = Report.init(testing.allocator);
    defer r.deinit();

    {
        const s = try r.summarize(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("Notion: up to date", s);
    }

    try r.push(.pulled, "n1", "p1", "Note", null);
    try r.push(.pushed, "n2", "p2", "Other", null);
    try r.push(.conflict, "n3", "p3", "Third", null);
    {
        const s = try r.summarize(testing.allocator);
        defer testing.allocator.free(s);
        // The "see Settings" pointer is only added for errors and blocked
        // notes -- a conflict is surfaced by the badge instead.
        try testing.expectEqualStrings("1 pulled, 1 pushed, 1 conflict(s)", s);
    }

    try r.push(.err, "n4", null, "Fourth", "boom");
    {
        const s = try r.summarize(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.endsWith(u8, s, " -- see Settings for details"));
    }

    r.cancelled = true;
    const s = try r.summarize(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Notion sync cancelled", s);
}

test "changed note ids are recorded once" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    try r.noteChanged("n1");
    try r.noteChanged("n1");
    try r.noteChanged("n2");
    try testing.expectEqual(@as(usize, 2), r.changed_note_ids.items.len);
}

test "item severity follows its kind" {
    try testing.expectEqual(Severity.info, ItemKind.pulled.severity());
    try testing.expectEqual(Severity.warn, ItemKind.conflict.severity());
    try testing.expectEqual(Severity.warn, ItemKind.blocked.severity());
    try testing.expectEqual(Severity.@"error", ItemKind.err.severity());
}
