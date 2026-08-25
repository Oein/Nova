//! The editable text buffer and its undo history.
//!
//! Ported from `src/lib/editor/buffer/Buffer.ts` and `RopeBuffer.ts`.
//!
//! As in the original, "rope" was aspirational: the concrete structure is a
//! flat array of lines. Newlines are implied between elements, so an empty
//! document is one empty line and `lineCount` is never 0.
//!
//! Positions are `{ line, col }` where **col is a byte offset** into the line.
//! The TypeScript original used UTF-16 code units.

const std = @import("std");

pub const Pos = struct {
    line: usize,
    /// Byte offset within the line.
    col: usize,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.line == b.line and a.col == b.col;
    }

    pub fn before(a: Pos, b: Pos) bool {
        return a.line < b.line or (a.line == b.line and a.col <= b.col);
    }
};

pub const Edit = union(enum) {
    insert: struct { at: Pos, text: []const u8 },
    delete: struct { from: Pos, to: Pos },
};

pub const Change = union(enum) {
    /// Lines `[from_line, to_line)` were replaced by `new_line_count` lines.
    replace: struct { from_line: usize, to_line: usize, new_line_count: usize },
    ready,
};

/// An edit stored in the undo history. Unlike `Edit`, it owns its text.
const StoredEdit = struct {
    kind: enum { insert, delete },
    a: Pos, // insert.at   / delete.from
    b: Pos, // (unused)    / delete.to
    text: []u8, // insert.text / (empty)

    fn deinit(self: StoredEdit, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }

    fn toEdit(self: StoredEdit) Edit {
        return switch (self.kind) {
            .insert => .{ .insert = .{ .at = self.a, .text = self.text } },
            .delete => .{ .delete = .{ .from = self.a, .to = self.b } },
        };
    }
};

/// One user-visible action. Applying the edits in array order reverts it.
const Group = std.ArrayList(StoredEdit);

/// How long a typing burst stays open for coalescing.
pub const coalesce_ms: i64 = 500;

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList([]u8),

    undo_stack: std.ArrayList(Group) = .empty,
    redo_stack: std.ArrayList(Group) = .empty,
    /// Open coalescing group, built in recording order and reversed on flush so
    /// the stored group undoes the burst last-first.
    tx_group: ?Group = null,
    tx_expires: i64 = 0,
    /// While set, every recorded inverse joins the open group regardless of
    /// timing or adjacency. See `beginGroup`.
    forced_group: bool = false,

    /// Changes emitted since the last `takeChanges`. The TypeScript version
    /// pushed these to registered listeners; a queue the view drains is the
    /// same thing without an observer registry or reentrancy hazards.
    changes: std.ArrayList(Change) = .empty,

    mtime_ms: i64 = 0,

    pub fn initFromString(gpa: std.mem.Allocator, text: []const u8, mtime_ms: i64) !Buffer {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |piece| {
            try lines.append(gpa, try gpa.dupe(u8, piece));
        }
        // splitScalar on "" yields one empty piece, which is exactly the
        // "empty document is one empty line" rule.
        return .{ .gpa = gpa, .lines = lines, .mtime_ms = mtime_ms };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        if (self.tx_group) |*g| {
            for (g.items) |e| e.deinit(self.gpa);
            g.deinit(self.gpa);
            self.tx_group = null;
        }
        self.forced_group = false;
        self.changes.deinit(self.gpa);
    }

    fn clearStack(self: *Buffer, stack: *std.ArrayList(Group)) void {
        for (stack.items) |*g| {
            for (g.items) |e| e.deinit(self.gpa);
            g.deinit(self.gpa);
        }
        stack.deinit(self.gpa);
        stack.* = .empty;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn getLine(self: *const Buffer, i: usize) []const u8 {
        if (i >= self.lines.items.len) return "";
        return self.lines.items[i];
    }

    /// Whole buffer contents, newline-joined. Caller owns the result.
    pub fn toOwnedString(self: *const Buffer, gpa: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.lines.items) |l| total += l.len + 1;
        if (total > 0) total -= 1;

        const out = try gpa.alloc(u8, total);
        var i: usize = 0;
        for (self.lines.items, 0..) |l, n| {
            if (n > 0) {
                out[i] = '\n';
                i += 1;
            }
            @memcpy(out[i..][0..l.len], l);
            i += l.len;
        }
        return out;
    }

    /// Text between two positions. Caller owns the result.
    pub fn sliceText(self: *const Buffer, a: Pos, b: Pos, gpa: std.mem.Allocator) ![]u8 {
        if (a.line == b.line) return gpa.dupe(u8, self.getLine(a.line)[a.col..b.col]);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, self.getLine(a.line)[a.col..]);
        var i = a.line + 1;
        while (i < b.line) : (i += 1) {
            try out.append(gpa, '\n');
            try out.appendSlice(gpa, self.getLine(i));
        }
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, self.getLine(b.line)[0..b.col]);
        return out.toOwnedSlice(gpa);
    }

    pub fn clampPos(self: *const Buffer, p: Pos) Pos {
        const line = @min(p.line, self.lines.items.len - 1);
        const col = @min(p.col, self.getLine(line).len);
        return .{ .line = line, .col = col };
    }

    pub fn takeChanges(self: *Buffer) []const Change {
        return self.changes.items;
    }

    pub fn clearChanges(self: *Buffer) void {
        self.changes.clearRetainingCapacity();
    }

    fn emit(self: *Buffer, c: Change) !void {
        try self.changes.append(self.gpa, c);
    }

    // -- editing -------------------------------------------------------------

    /// Apply `edit` and record its inverse for undo.
    ///
    /// `now_ms` drives typing-burst coalescing. It is a parameter rather than a
    /// call to the clock because this module must stay free of platform and I/O
    /// dependencies -- which also makes coalescing deterministic in tests
    /// instead of needing a fake clock, as the TypeScript version did.
    pub fn applyEdit(self: *Buffer, edit: Edit, now_ms: i64) !void {
        const inverse = try self.applyInternal(edit);
        try self.recordUndo(inverse, now_ms);
        self.clearStack(&self.redo_stack);
    }

    /// Apply without touching the history. Returns the owned inverse edit.
    fn applyInternal(self: *Buffer, edit: Edit) !StoredEdit {
        return switch (edit) {
            .insert => |e| self.insertAt(e.at, e.text),
            .delete => |e| self.deleteRange(e.from, e.to),
        };
    }

    fn insertAt(self: *Buffer, at: Pos, text: []const u8) !StoredEdit {
        const clamped = self.clampPos(at);
        const line = clamped.line;
        const col = clamped.col;
        const current = self.getLine(line);
        const before = current[0..col];
        const after = current[col..];

        const nl_count = std.mem.count(u8, text, "\n");

        if (nl_count == 0) {
            const merged = try std.mem.concat(self.gpa, u8, &.{ before, text, after });
            self.gpa.free(self.lines.items[line]);
            self.lines.items[line] = merged;
            try self.emit(.{ .replace = .{
                .from_line = line,
                .to_line = line + 1,
                .new_line_count = 1,
            } });
            return .{
                .kind = .delete,
                .a = clamped,
                .b = .{ .line = line, .col = col + text.len },
                .text = try self.gpa.alloc(u8, 0),
            };
        }

        // Multi-line insert: the first piece joins `before`, the last joins
        // `after`, and the middle pieces become whole new lines.
        var pieces: std.ArrayList([]u8) = .empty;
        defer pieces.deinit(self.gpa);
        errdefer for (pieces.items) |p| self.gpa.free(p);

        var it = std.mem.splitScalar(u8, text, '\n');
        var idx: usize = 0;
        var end_col: usize = 0;
        while (it.next()) |piece| : (idx += 1) {
            if (idx == 0) {
                try pieces.append(self.gpa, try std.mem.concat(self.gpa, u8, &.{ before, piece }));
            } else if (idx == nl_count) {
                end_col = piece.len;
                try pieces.append(self.gpa, try std.mem.concat(self.gpa, u8, &.{ piece, after }));
            } else {
                try pieces.append(self.gpa, try self.gpa.dupe(u8, piece));
            }
        }

        self.gpa.free(self.lines.items[line]);
        try self.lines.replaceRange(self.gpa, line, 1, pieces.items);
        // Ownership of the piece slices moved into `lines`.
        pieces.clearRetainingCapacity();

        try self.emit(.{ .replace = .{
            .from_line = line,
            .to_line = line + 1,
            .new_line_count = nl_count + 1,
        } });

        return .{
            .kind = .delete,
            .a = clamped,
            .b = .{ .line = line + nl_count, .col = end_col },
            .text = try self.gpa.alloc(u8, 0),
        };
    }

    fn deleteRange(self: *Buffer, from: Pos, to: Pos) !StoredEdit {
        var a = self.clampPos(from);
        var b = self.clampPos(to);
        if (!Pos.before(a, b)) {
            const t = a;
            a = b;
            b = t;
        }
        if (a.eql(b)) {
            return .{ .kind = .insert, .a = a, .b = a, .text = try self.gpa.alloc(u8, 0) };
        }

        const deleted = try self.sliceText(a, b, self.gpa);
        errdefer self.gpa.free(deleted);

        if (a.line == b.line) {
            const ln = self.lines.items[a.line];
            const merged = try std.mem.concat(self.gpa, u8, &.{ ln[0..a.col], ln[b.col..] });
            self.gpa.free(ln);
            self.lines.items[a.line] = merged;
            try self.emit(.{ .replace = .{
                .from_line = a.line,
                .to_line = a.line + 1,
                .new_line_count = 1,
            } });
        } else {
            const head = self.lines.items[a.line][0..a.col];
            const tail = self.lines.items[b.line][b.col..];
            const merged = try std.mem.concat(self.gpa, u8, &.{ head, tail });
            errdefer self.gpa.free(merged);

            var i = a.line;
            while (i <= b.line) : (i += 1) self.gpa.free(self.lines.items[i]);
            try self.lines.replaceRange(self.gpa, a.line, b.line - a.line + 1, &.{merged});

            try self.emit(.{ .replace = .{
                .from_line = a.line,
                .to_line = b.line + 1,
                .new_line_count = 1,
            } });
        }

        return .{ .kind = .insert, .a = a, .b = a, .text = deleted };
    }

    // -- undo history --------------------------------------------------------

    /// Can `next` join the open burst that `last` ends?
    ///
    /// The original tested `|Δcol| <= 1` on UTF-16 columns. With byte offsets
    /// that would break every non-Latin script -- a Hangul syllable moves the
    /// column by 3 -- so this tests exact adjacency instead, which is what the
    /// distance check was approximating:
    ///
    ///   * forward typing  -> delete inverses chain end-to-start
    ///   * backspace       -> insert inverses chain start-to-end
    ///   * forward delete  -> insert inverses repeat at one position
    fn canCoalesce(last: StoredEdit, next: StoredEdit) bool {
        if (last.kind != next.kind) return false;
        return switch (last.kind) {
            .delete => next.a.eql(last.b), // typing: next deletion starts where the last ended
            .insert => next.a.eql(last.a) or // forward delete at a fixed point
                (next.a.line == last.a.line and next.a.col + next.text.len == last.a.col), // backspace
        };
    }

    fn recordUndo(self: *Buffer, inverse: StoredEdit, now_ms: i64) !void {
        if (self.forced_group) {
            try self.tx_group.?.append(self.gpa, inverse);
            return;
        }
        if (self.tx_group) |*g| {
            if (g.items.len > 0 and now_ms < self.tx_expires and
                canCoalesce(g.items[g.items.len - 1], inverse))
            {
                try g.append(self.gpa, inverse);
                self.tx_expires = now_ms + coalesce_ms;
                return;
            }
        }
        try self.flushTx();
        var g: Group = .empty;
        try g.append(self.gpa, inverse);
        self.tx_group = g;
        self.tx_expires = now_ms + coalesce_ms;
    }

    fn flushTx(self: *Buffer) !void {
        if (self.tx_group) |*g| {
            if (g.items.len > 0) {
                std.mem.reverse(StoredEdit, g.items);
                try self.undo_stack.append(self.gpa, g.*);
            } else {
                g.deinit(self.gpa);
            }
        }
        self.tx_group = null;
        self.tx_expires = 0;
    }

    fn caretAfter(applied: StoredEdit) Pos {
        return switch (applied.kind) {
            .delete => applied.a,
            .insert => blk: {
                const nl = std.mem.count(u8, applied.text, "\n");
                if (nl == 0) break :blk .{ .line = applied.a.line, .col = applied.a.col + applied.text.len };
                const last = std.mem.lastIndexOfScalar(u8, applied.text, '\n').? + 1;
                break :blk .{ .line = applied.a.line + nl, .col = applied.text.len - last };
            },
        };
    }

    fn replay(self: *Buffer, from: *std.ArrayList(Group), to: *std.ArrayList(Group)) !?Pos {
        try self.flushTx();
        var group = from.pop() orelse return null;
        defer group.deinit(self.gpa);
        if (group.items.len == 0) return null;

        var out: Group = .empty;
        errdefer {
            for (out.items) |e| e.deinit(self.gpa);
            out.deinit(self.gpa);
        }

        var cursor: ?Pos = null;
        for (group.items) |stored| {
            try out.append(self.gpa, try self.applyInternal(stored.toEdit()));
            cursor = caretAfter(stored);
            stored.deinit(self.gpa);
        }
        // Flip so the opposite stack replays in the user's original order.
        std.mem.reverse(StoredEdit, out.items);
        try to.append(self.gpa, out);
        return cursor;
    }

    /// Revert one user-visible action. Returns the post-edit caret, or null.
    pub fn undo(self: *Buffer) !?Pos {
        return self.replay(&self.undo_stack, &self.redo_stack);
    }

    /// Re-apply one undone action. Returns the post-edit caret, or null.
    pub fn redo(self: *Buffer) !?Pos {
        return self.replay(&self.redo_stack, &self.undo_stack);
    }

    /// Start an explicit undo group: every edit until `endGroup` reverts as one
    /// step, whatever the timing or adjacency.
    ///
    /// The TypeScript original had no such mechanism, so a few multi-edit
    /// actions cost several undo presses: typing over a selection emitted a
    /// delete plus an insert (`commands.ts:200`), cut did the same, and
    /// indent/dedent emitted one edit per selected line -- so Shift+Tab over ten
    /// lines took ten undos to reverse.
    pub fn beginGroup(self: *Buffer) !void {
        try self.flushTx();
        self.tx_group = .empty;
        self.forced_group = true;
    }

    pub fn endGroup(self: *Buffer) !void {
        self.forced_group = false;
        try self.flushTx();
    }

    /// Close the open burst so the next keystroke starts a new undo step.
    pub fn markSaved(self: *Buffer, mtime_ms: i64) !void {
        self.mtime_ms = mtime_ms;
        try self.flushTx();
    }

    /// Serialize the undo and redo stacks to JSON. Caller owns the result.
    ///
    /// Flushes any open coalescing group first, so a burst in progress is captured
    /// rather than lost.
    pub fn serializeHistory(self: *Buffer, gpa: std.mem.Allocator) ![]u8 {
        try self.flushTx();

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const undo_groups = try arena.alloc([]const EditJson, self.undo_stack.items.len);
        for (self.undo_stack.items, undo_groups) |g, *slot| slot.* = try groupToJson(arena, g);
        const redo_groups = try arena.alloc([]const EditJson, self.redo_stack.items.len);
        for (self.redo_stack.items, redo_groups) |g, *slot| slot.* = try groupToJson(arena, g);

        return std.json.Stringify.valueAlloc(
            gpa,
            HistoryJson{ .undo = undo_groups, .redo = redo_groups },
            .{},
        );
    }

    fn jsonToStack(
        self: *Buffer,
        stack: *std.ArrayList(Group),
        groups: []const []const EditJson,
    ) !void {
        for (groups) |g| {
            var out: Group = .empty;
            errdefer {
                for (out.items) |e| e.deinit(self.gpa);
                out.deinit(self.gpa);
            }
            for (g) |j| {
                const is_insert = j.k.len > 0 and j.k[0] == 'i';
                try out.append(self.gpa, .{
                    .kind = if (is_insert) .insert else .delete,
                    .a = .{ .line = j.l, .col = j.c },
                    .b = if (is_insert) .{ .line = j.l, .col = j.c } else .{ .line = j.l2, .col = j.c2 },
                    .text = try self.gpa.dupe(u8, if (is_insert) j.t else ""),
                });
            }
            try stack.append(self.gpa, out);
        }
    }

    /// Restore undo and redo stacks from `json`.
    ///
    /// A log this build cannot interpret is dropped, not applied: replaying edits
    /// whose columns mean something else would corrupt the document. The user loses
    /// undo history across the upgrade, which is the mild failure.
    pub fn restoreHistory(self: *Buffer, gpa: std.mem.Allocator, json: []const u8) !void {
        try self.flushTx();

        const parsed = std.json.parseFromSlice(HistoryJson, gpa, json, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        if (parsed.value.v != history_version) return;

        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        try self.jsonToStack(&self.undo_stack, parsed.value.undo);
        try self.jsonToStack(&self.redo_stack, parsed.value.redo);
    }
};

// -- tests -------------------------------------------------------------------
// Ported from src/lib/editor/buffer/RopeBuffer.test.ts.

const testing = std.testing;

fn expectText(b: *const Buffer, expected: []const u8) !void {
    const s = try b.toOwnedString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

test "line splitting edge cases" {
    {
        var b = try Buffer.initFromString(testing.allocator, "", 0);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.lineCount());
        try testing.expectEqualStrings("", b.getLine(0));
    }
    {
        var b = try Buffer.initFromString(testing.allocator, "a\n", 0);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.lineCount());
        try testing.expectEqualStrings("a", b.getLine(0));
        try testing.expectEqualStrings("", b.getLine(1));
    }
    {
        var b = try Buffer.initFromString(testing.allocator, "a\nb\nc", 0);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 3), b.lineCount());
    }
}

test "round-trips text" {
    var b = try Buffer.initFromString(testing.allocator, "hello\nworld\n", 0);
    defer b.deinit();
    try expectText(&b, "hello\nworld\n");
    try testing.expectEqual(@as(usize, 3), b.lineCount());
    try testing.expectEqualStrings("hello", b.getLine(0));
    try testing.expectEqualStrings("world", b.getLine(1));
    try testing.expectEqualStrings("", b.getLine(2));
}

test "insert in the middle of a line" {
    var b = try Buffer.initFromString(testing.allocator, "hello", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 5 }, .text = " world" } }, 0);
    try expectText(&b, "hello world");
}

test "insert newlines creates new lines" {
    var b = try Buffer.initFromString(testing.allocator, "ac", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 1 }, .text = "\nb\n" } }, 0);
    try expectText(&b, "a\nb\nc");
    try testing.expectEqual(@as(usize, 3), b.lineCount());
}

test "delete within a line" {
    var b = try Buffer.initFromString(testing.allocator, "hello", 0);
    defer b.deinit();
    try b.applyEdit(.{ .delete = .{ .from = .{ .line = 0, .col = 1 }, .to = .{ .line = 0, .col = 4 } } }, 0);
    try expectText(&b, "ho");
}

test "delete across lines" {
    var b = try Buffer.initFromString(testing.allocator, "abc\ndef\nghi", 0);
    defer b.deinit();
    try b.applyEdit(.{ .delete = .{ .from = .{ .line = 0, .col = 1 }, .to = .{ .line = 2, .col = 2 } } }, 0);
    try expectText(&b, "ai");
}

test "delete reversed range is normalized" {
    var b = try Buffer.initFromString(testing.allocator, "hello", 0);
    defer b.deinit();
    try b.applyEdit(.{ .delete = .{ .from = .{ .line = 0, .col = 4 }, .to = .{ .line = 0, .col = 1 } } }, 0);
    try expectText(&b, "ho");
}

test "clamps out-of-range positions" {
    var b = try Buffer.initFromString(testing.allocator, "hi", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 999, .col = 999 }, .text = "!" } }, 0);
    try expectText(&b, "hi!");
}

test "insert emits a replace change with the correct span" {
    var b = try Buffer.initFromString(testing.allocator, "a\nb", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 1 }, .text = "Z" } }, 0);
    const changes = b.takeChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(@as(usize, 0), changes[0].replace.from_line);
    try testing.expectEqual(@as(usize, 1), changes[0].replace.to_line);
    try testing.expectEqual(@as(usize, 1), changes[0].replace.new_line_count);
}

test "undo reverses an insert" {
    var b = try Buffer.initFromString(testing.allocator, "x", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 1 }, .text = "y" } }, 0);
    try expectText(&b, "xy");
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, (try b.undo()).?);
    try expectText(&b, "x");
}

test "redo re-applies an undone edit" {
    var b = try Buffer.initFromString(testing.allocator, "x", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 1 }, .text = "y" } }, 0);
    _ = try b.undo();
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, (try b.redo()).?);
    try expectText(&b, "xy");
}

test "a new edit clears the redo stack" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = "a" } }, 0);
    _ = try b.undo();
    try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = "b" } }, 0);
    try testing.expect((try b.redo()) == null);
    try expectText(&b, "b");
}

test "undo on an empty stack returns null" {
    var b = try Buffer.initFromString(testing.allocator, "x", 0);
    defer b.deinit();
    try testing.expect((try b.undo()) == null);
}

/// Type `text` one grapheme-free chunk at a time at the end of line 0.
fn typeAscii(b: *Buffer, text: []const u8, now_ms: i64) !void {
    for (text) |ch| {
        const col = b.getLine(0).len;
        try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = col }, .text = &.{ch} } }, now_ms);
    }
}

test "a coalesced typing burst undoes as a single step" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "hello", 1000);
    try expectText(&b, "hello");
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, (try b.undo()).?);
    try expectText(&b, "");
}

test "a coalesced burst redoes in the original order" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "abc", 1000);
    _ = try b.undo();
    try expectText(&b, "");
    _ = try b.redo();
    try expectText(&b, "abc");
}

test "separate bursts are separate undo steps" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "abc", 1000);
    // Slide the clock past the coalescing window.
    try typeAscii(&b, "xyz", 1000 + coalesce_ms + 1);
    try expectText(&b, "abcxyz");
    _ = try b.undo();
    try expectText(&b, "abc");
    _ = try b.undo();
    try expectText(&b, "");
}

test "a Korean typing burst coalesces too" {
    // Regression guard for the byte-offset port: with the original
    // `|Δcol| <= 1` rule each Hangul syllable would land in its own undo step,
    // because one syllable advances the byte column by 3.
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    for ([_][]const u8{ "안", "녕", "하", "세", "요" }) |syllable| {
        const col = b.getLine(0).len;
        try b.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = col }, .text = syllable } }, 1000);
    }
    try expectText(&b, "안녕하세요");
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, (try b.undo()).?);
    try expectText(&b, "");
}

test "a backspace burst coalesces" {
    var b = try Buffer.initFromString(testing.allocator, "hello", 0);
    defer b.deinit();
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const col = b.getLine(0).len;
        try b.applyEdit(.{ .delete = .{
            .from = .{ .line = 0, .col = col - 1 },
            .to = .{ .line = 0, .col = col },
        } }, 1000);
    }
    try expectText(&b, "he");
    _ = try b.undo();
    try expectText(&b, "hello");
}

test "sliceText across lines" {
    var b = try Buffer.initFromString(testing.allocator, "abc\ndef\nghi", 0);
    defer b.deinit();
    const s = try b.sliceText(.{ .line = 0, .col = 1 }, .{ .line = 2, .col = 2 }, testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("bc\ndef\ngh", s);
}

// -- fuzz --------------------------------------------------------------------

fn offsetToPos(text: []const u8, offset: usize) Pos {
    var line: usize = 0;
    var col: usize = 0;
    for (text[0..offset]) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

test "fuzz: 10000 random edits match a naive string reference" {
    var s: u32 = 0xdead_beef ^ 12345;
    const rand = struct {
        fn next(state: *u32) f64 {
            state.* ^= state.* << 13;
            state.* ^= state.* >> 17;
            state.* ^= state.* << 5;
            return @as(f64, @floatFromInt(state.* % 1_000_000)) / 1_000_000.0;
        }
    }.next;

    const chars = "ab\nXY";
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();

    var ref: std.ArrayList(u8) = .empty;
    defer ref.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const insert = rand(&s) < 0.65 or ref.items.len == 0;
        if (insert) {
            const at: usize = @intFromFloat(rand(&s) * @as(f64, @floatFromInt(ref.items.len + 1)));
            const n: usize = 1 + @as(usize, @intFromFloat(rand(&s) * 4));
            var text: [4]u8 = undefined;
            for (0..n) |k| {
                const idx: usize = @intFromFloat(rand(&s) * @as(f64, @floatFromInt(chars.len)));
                text[k] = chars[@min(idx, chars.len - 1)];
            }
            const pos = offsetToPos(ref.items, @min(at, ref.items.len));
            try b.applyEdit(.{ .insert = .{ .at = pos, .text = text[0..n] } }, 0);
            try ref.insertSlice(testing.allocator, @min(at, ref.items.len), text[0..n]);
        } else {
            const a: usize = @intFromFloat(rand(&s) * @as(f64, @floatFromInt(ref.items.len)));
            const a_c = @min(a, ref.items.len - 1);
            const bb = @min(ref.items.len, a_c + 1 + @as(usize, @intFromFloat(rand(&s) * 5)));
            try b.applyEdit(.{ .delete = .{
                .from = offsetToPos(ref.items, a_c),
                .to = offsetToPos(ref.items, bb),
            } }, 0);
            ref.replaceRangeAssumeCapacity(a_c, bb - a_c, &.{});
        }
        b.clearChanges();

        if (i % 250 == 0) {
            const got = try b.toOwnedString(testing.allocator);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(ref.items, got);
        }
    }

    const got = try b.toOwnedString(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(ref.items, got);
}

test "beginGroup makes several edits one undo step" {
    var b = try Buffer.initFromString(testing.allocator, "a\nb\nc", 0);
    defer b.deinit();

    // Indent all three lines -- one action, one undo.
    try b.beginGroup();
    for (0..3) |l| {
        try b.applyEdit(.{ .insert = .{ .at = .{ .line = l, .col = 0 }, .text = "\t" } }, 0);
    }
    try b.endGroup();
    try expectText(&b, "\ta\n\tb\n\tc");

    _ = try b.undo();
    try expectText(&b, "a\nb\nc");

    _ = try b.redo();
    try expectText(&b, "\ta\n\tb\n\tc");
}

// -- history serialization ---------------------------------------------------
//
// The undo history is persisted alongside the tab's unsaved text so that
// closing and reopening the app does not throw away the ability to undo.

/// Bumped when the on-the-wire shape changes. Version 2 is the first with byte
/// offsets; a version-1 log (or an unversioned one, as the TypeScript build
/// wrote) holds UTF-16 columns and is discarded rather than misapplied.
pub const history_version: u32 = 2;

const EditJson = struct {
    /// "i" for insert, "d" for delete.
    k: []const u8,
    /// insert: position. delete: `from`.
    l: usize,
    c: usize,
    /// delete: `to`. Unused for insert.
    l2: usize = 0,
    c2: usize = 0,
    /// insert: the text.
    t: []const u8 = "",
};

const HistoryJson = struct {
    v: u32 = history_version,
    undo: []const []const EditJson,
    redo: []const []const EditJson,
};

fn groupToJson(gpa: std.mem.Allocator, g: Group) ![]EditJson {
    const out = try gpa.alloc(EditJson, g.items.len);
    for (g.items, out) |e, *j| {
        j.* = switch (e.kind) {
            .insert => .{ .k = "i", .l = e.a.line, .c = e.a.col, .t = e.text },
            .delete => .{ .k = "d", .l = e.a.line, .c = e.a.col, .l2 = e.b.line, .c2 = e.b.col },
        };
    }
    return out;
}

test "history survives a serialize/restore round trip" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "hello", 1000);
    try typeAscii(&b, " world", 1000 + coalesce_ms + 1);

    const json = try b.serializeHistory(testing.allocator);
    defer testing.allocator.free(json);

    var restored = try Buffer.initFromString(testing.allocator, "hello world", 0);
    defer restored.deinit();
    try restored.restoreHistory(testing.allocator, json);

    _ = try restored.undo();
    try expectText(&restored, "hello");
    _ = try restored.undo();
    try expectText(&restored, "");
    _ = try restored.redo();
    try expectText(&restored, "hello");
}

test "redo history survives the round trip too" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "abc", 1000);
    _ = try b.undo();

    const json = try b.serializeHistory(testing.allocator);
    defer testing.allocator.free(json);

    var restored = try Buffer.initFromString(testing.allocator, "", 0);
    defer restored.deinit();
    try restored.restoreHistory(testing.allocator, json);

    _ = try restored.redo();
    try expectText(&restored, "abc");
}

test "a log from an older format is discarded, not misapplied" {
    var b = try Buffer.initFromString(testing.allocator, "hello", 0);
    defer b.deinit();

    // What the TypeScript build wrote: no version, UTF-16 columns.
    try b.restoreHistory(
        testing.allocator,
        \\{"undoStack":[[{"kind":"insert","at":{"line":0,"col":1},"text":"x"}]],"redoStack":[]}
        ,
    );
    try testing.expect((try b.undo()) == null);
    try expectText(&b, "hello");

    // Explicitly-versioned but wrong is also refused.
    try b.restoreHistory(testing.allocator, "{\"v\":1,\"undo\":[],\"redo\":[]}");
    try testing.expect((try b.undo()) == null);
}

test "garbage json is ignored" {
    var b = try Buffer.initFromString(testing.allocator, "x", 0);
    defer b.deinit();
    try b.restoreHistory(testing.allocator, "not json at all");
    try b.restoreHistory(testing.allocator, "");
    try expectText(&b, "x");
}

test "restoring history replaces whatever was there" {
    var b = try Buffer.initFromString(testing.allocator, "", 0);
    defer b.deinit();
    try typeAscii(&b, "zzz", 1000);

    try b.restoreHistory(testing.allocator, "{\"v\":2,\"undo\":[],\"redo\":[]}");
    try testing.expect((try b.undo()) == null);
}
