//! Editor commands and the key -> command mapping.
//!
//! Ported from `src/lib/editor/commands.ts`.
//!
//! The `editable` flag from the original is gone. It existed for a read-only
//! "paged" buffer mode that was never implemented -- nothing ever constructed
//! one, and `TabMode: "paged"` was dead surface throughout the codebase.

const std = @import("std");
const buf = @import("buffer.zig");
const grapheme = @import("grapheme.zig");
const sel_mod = @import("selection.zig");

const Buffer = buf.Buffer;
const Pos = buf.Pos;
const Selection = sel_mod.Selection;

pub const Dir = enum {
    back,
    fwd,

    fn delta(self: Dir) i2 {
        return switch (self) {
            .back => -1,
            .fwd => 1,
        };
    }
};

pub const MoveBy = enum { char, word, line };

pub const Command = union(enum) {
    move: struct { by: MoveBy, dir: Dir, extend: bool },
    move_home: struct { extend: bool },
    move_end: struct { extend: bool },
    move_doc_edge: struct { dir: Dir, extend: bool },
    page: struct { dir: Dir, extend: bool, page_lines: usize },
    insert: struct { text: []const u8 },
    newline,
    backspace,
    delete,
    indent,
    dedent,
    select_all,
    undo,
    redo,
};

// -- movement helpers --------------------------------------------------------

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Whitespace-delimited word boundary.
///
/// Note this is a *different* word model from `word.zig`, which is used for
/// double-click and splits letters from punctuation. Alt+Arrow deliberately
/// treats punctuation as part of the word, matching the original.
///
/// Byte-safe: the scan only ever stops adjacent to an ASCII space or tab, so
/// the result always lands on a code point boundary.
fn wordBoundary(line: []const u8, col: usize, dir: Dir) usize {
    if (line.len == 0) return 0;
    var i = col;
    switch (dir) {
        .fwd => {
            while (i < line.len and isWs(line[i])) i += 1;
            while (i < line.len and !isWs(line[i])) i += 1;
        },
        .back => {
            i = if (i == 0) 0 else i - 1;
            while (i > 0 and isWs(line[i])) i -= 1;
            while (i > 0 and !isWs(line[i - 1])) i -= 1;
        },
    }
    return i;
}

/// One grapheme cluster per step, so arrows and backspace treat emoji, ZWJ
/// sequences, flag pairs, VS-16 sequences and combining marks as one glyph.
fn moveChar(b: *const Buffer, p: Pos, dir: Dir) Pos {
    switch (dir) {
        .fwd => {
            const line = b.getLine(p.line);
            if (p.col < line.len) return .{ .line = p.line, .col = grapheme.next(line, p.col) };
            if (p.line + 1 < b.lineCount()) return .{ .line = p.line + 1, .col = 0 };
            return p;
        },
        .back => {
            if (p.col > 0) {
                const line = b.getLine(p.line);
                return .{ .line = p.line, .col = grapheme.prev(line, p.col) };
            }
            if (p.line > 0) return .{ .line = p.line - 1, .col = b.getLine(p.line - 1).len };
            return p;
        },
    }
}

fn moveWord(b: *const Buffer, p: Pos, dir: Dir) Pos {
    const line = b.getLine(p.line);
    if (dir == .fwd and p.col >= line.len) return moveChar(b, p, .fwd);
    if (dir == .back and p.col == 0) return moveChar(b, p, .back);
    return .{ .line = p.line, .col = wordBoundary(line, p.col, dir) };
}

fn moveLine(b: *const Buffer, p: Pos, dir: Dir) Pos {
    const target: usize = switch (dir) {
        .back => if (p.line == 0) 0 else p.line - 1,
        .fwd => @min(b.lineCount() - 1, p.line + 1),
    };
    return .{ .line = target, .col = @min(p.col, b.getLine(target).len) };
}

fn advanceByText(p: Pos, text: []const u8) Pos {
    const nl = std.mem.count(u8, text, "\n");
    if (nl == 0) return .{ .line = p.line, .col = p.col + text.len };
    const last = std.mem.lastIndexOfScalar(u8, text, '\n').? + 1;
    return .{ .line = p.line + nl, .col = text.len - last };
}

fn headMove(s: Selection, head: Pos, extend: bool) Selection {
    return .{ .anchor = if (extend) s.anchor else head, .head = head };
}

fn clampSelection(s: Selection, b: *const Buffer) Selection {
    return .{ .anchor = b.clampPos(s.anchor), .head = b.clampPos(s.head) };
}

// -- command application -----------------------------------------------------

/// Apply `cmd` and return the new selection. `now_ms` feeds undo coalescing.
pub fn apply(b: *Buffer, sel: Selection, cmd: Command, now_ms: i64) !Selection {
    switch (cmd) {
        .move => |m| {
            // A plain (non-extending) horizontal step on a non-empty selection
            // collapses to the near edge rather than stepping from the head --
            // macOS / Sublime / VS Code behavior.
            if (m.by == .char and !m.extend and !sel.isEmpty()) {
                const r = sel.ordered();
                const head = if (m.dir == .back) r.from else r.to;
                return Selection.at(head);
            }
            const head = switch (m.by) {
                .char => moveChar(b, sel.head, m.dir),
                .word => moveWord(b, sel.head, m.dir),
                .line => moveLine(b, sel.head, m.dir),
            };
            return headMove(sel, head, m.extend);
        },
        .move_home => |m| {
            return headMove(sel, .{ .line = sel.head.line, .col = 0 }, m.extend);
        },
        .move_end => |m| {
            const head = Pos{ .line = sel.head.line, .col = b.getLine(sel.head.line).len };
            return headMove(sel, head, m.extend);
        },
        .move_doc_edge => |m| {
            const head: Pos = switch (m.dir) {
                .fwd => .{
                    .line = b.lineCount() - 1,
                    .col = b.getLine(b.lineCount() - 1).len,
                },
                .back => .{ .line = 0, .col = 0 },
            };
            return headMove(sel, head, m.extend);
        },
        .page => |m| {
            const last = b.lineCount() - 1;
            const dest: usize = switch (m.dir) {
                .back => if (sel.head.line > m.page_lines) sel.head.line - m.page_lines else 0,
                .fwd => @min(last, sel.head.line + m.page_lines),
            };
            const head = Pos{ .line = dest, .col = @min(sel.head.col, b.getLine(dest).len) };
            return headMove(sel, head, m.extend);
        },

        .insert => |m| return doInsert(b, sel, m.text, now_ms),
        .newline => return doInsert(b, sel, "\n", now_ms),

        .backspace => {
            if (!sel.isEmpty()) {
                const r = sel.ordered();
                try b.applyEdit(.{ .delete = .{ .from = r.from, .to = r.to } }, now_ms);
                return Selection.at(r.from);
            }
            const left = moveChar(b, sel.head, .back);
            if (left.eql(sel.head)) return sel;
            try b.applyEdit(.{ .delete = .{ .from = left, .to = sel.head } }, now_ms);
            return Selection.at(left);
        },
        .delete => {
            if (!sel.isEmpty()) {
                const r = sel.ordered();
                try b.applyEdit(.{ .delete = .{ .from = r.from, .to = r.to } }, now_ms);
                return Selection.at(r.from);
            }
            const right = moveChar(b, sel.head, .fwd);
            if (right.eql(sel.head)) return sel;
            try b.applyEdit(.{ .delete = .{ .from = sel.head, .to = right } }, now_ms);
            return sel;
        },

        .indent => {
            const min_line = @min(sel.anchor.line, sel.head.line);
            const max_line = @max(sel.anchor.line, sel.head.line);
            // One undo step for the whole action; the original cost one press
            // per selected line.
            try b.beginGroup();
            defer b.endGroup() catch {};
            var l = min_line;
            while (l <= max_line) : (l += 1) {
                try b.applyEdit(.{ .insert = .{ .at = .{ .line = l, .col = 0 }, .text = "\t" } }, now_ms);
            }
            return .{
                .anchor = .{ .line = sel.anchor.line, .col = sel.anchor.col + 1 },
                .head = .{ .line = sel.head.line, .col = sel.head.col + 1 },
            };
        },
        .dedent => {
            const min_line = @min(sel.anchor.line, sel.head.line);
            const max_line = @max(sel.anchor.line, sel.head.line);

            var removed = try std.DynamicBitSet.initEmpty(b.gpa, max_line - min_line + 1);
            defer removed.deinit();

            try b.beginGroup();
            defer b.endGroup() catch {};
            // Delete back-to-front so earlier lines keep their indices.
            var l = max_line + 1;
            while (l > min_line) {
                l -= 1;
                if (std.mem.startsWith(u8, b.getLine(l), "\t")) {
                    try b.applyEdit(.{ .delete = .{
                        .from = .{ .line = l, .col = 0 },
                        .to = .{ .line = l, .col = 1 },
                    } }, now_ms);
                    removed.set(l - min_line);
                }
            }

            const adjust = struct {
                fn f(p: Pos, lo: usize, hi: usize, set: *const std.DynamicBitSet) Pos {
                    if (p.line < lo or p.line > hi) return p;
                    if (!set.isSet(p.line - lo)) return p;
                    return .{ .line = p.line, .col = if (p.col == 0) 0 else p.col - 1 };
                }
            }.f;

            return .{
                .anchor = adjust(sel.anchor, min_line, max_line, &removed),
                .head = adjust(sel.head, min_line, max_line, &removed),
            };
        },

        .select_all => {
            const last = b.lineCount() - 1;
            return .{
                .anchor = .{ .line = 0, .col = 0 },
                .head = .{ .line = last, .col = b.getLine(last).len },
            };
        },

        .undo => {
            const p = try b.undo();
            return if (p) |pos| Selection.at(pos) else clampSelection(sel, b);
        },
        .redo => {
            const p = try b.redo();
            return if (p) |pos| Selection.at(pos) else clampSelection(sel, b);
        },
    }
}

fn doInsert(b: *Buffer, sel: Selection, text: []const u8, now_ms: i64) !Selection {
    if (!sel.isEmpty()) {
        const r = sel.ordered();
        // Replacing a selection is one action. The original emitted the delete
        // and the insert as separate undo entries, so typing over a selection
        // took two Cmd+Z presses to reverse.
        try b.beginGroup();
        defer b.endGroup() catch {};
        try b.applyEdit(.{ .delete = .{ .from = r.from, .to = r.to } }, now_ms);
        try b.applyEdit(.{ .insert = .{ .at = r.from, .text = text } }, now_ms);
        return Selection.at(advanceByText(r.from, text));
    }
    try b.applyEdit(.{ .insert = .{ .at = sel.head, .text = text } }, now_ms);
    return Selection.at(advanceByText(sel.head, text));
}

// -- keymap ------------------------------------------------------------------

pub const Key = union(enum) {
    /// A printable key, already lowercased by the platform layer.
    character: u21,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    home,
    end,
    page_up,
    page_down,
    backspace,
    delete,
    enter,
    tab,
    other,
};

pub const KeyEvent = struct {
    key: Key,
    /// Cmd on macOS, Ctrl elsewhere. The original folded both into one flag
    /// with no platform split; kept as-is.
    meta: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub fn keymap(e: KeyEvent, page_lines: usize) ?Command {
    if (e.meta and !e.shift and !e.alt) {
        switch (e.key) {
            .character => |c| {
                if (c == 'z') return .undo;
                if (c == 'a') return .select_all;
            },
            .arrow_left => return .{ .move_home = .{ .extend = false } },
            .arrow_right => return .{ .move_end = .{ .extend = false } },
            .arrow_up => return .{ .move_doc_edge = .{ .dir = .back, .extend = false } },
            .arrow_down => return .{ .move_doc_edge = .{ .dir = .fwd, .extend = false } },
            else => {},
        }
    }
    if (e.meta and e.shift and !e.alt) {
        switch (e.key) {
            .character => |c| {
                if (c == 'z') return .redo;
            },
            .arrow_left => return .{ .move_home = .{ .extend = true } },
            .arrow_right => return .{ .move_end = .{ .extend = true } },
            .arrow_up => return .{ .move_doc_edge = .{ .dir = .back, .extend = true } },
            .arrow_down => return .{ .move_doc_edge = .{ .dir = .fwd, .extend = true } },
            else => {},
        }
    }
    if (e.alt and !e.meta) {
        switch (e.key) {
            .arrow_left => return .{ .move = .{ .by = .word, .dir = .back, .extend = e.shift } },
            .arrow_right => return .{ .move = .{ .by = .word, .dir = .fwd, .extend = e.shift } },
            else => {},
        }
    }
    if (!e.meta and !e.alt) {
        switch (e.key) {
            .arrow_left => return .{ .move = .{ .by = .char, .dir = .back, .extend = e.shift } },
            .arrow_right => return .{ .move = .{ .by = .char, .dir = .fwd, .extend = e.shift } },
            .arrow_up => return .{ .move = .{ .by = .line, .dir = .back, .extend = e.shift } },
            .arrow_down => return .{ .move = .{ .by = .line, .dir = .fwd, .extend = e.shift } },
            .home => return .{ .move_home = .{ .extend = e.shift } },
            .end => return .{ .move_end = .{ .extend = e.shift } },
            .page_up => return .{ .page = .{ .dir = .back, .extend = e.shift, .page_lines = page_lines } },
            .page_down => return .{ .page = .{ .dir = .fwd, .extend = e.shift, .page_lines = page_lines } },
            .backspace => return .backspace,
            .delete => return .delete,
            .enter => return .newline,
            .tab => return .{ .insert = .{ .text = "\t" } },
            else => {},
        }
    }
    return null;
}

// -- tests -------------------------------------------------------------------
// Ported from src/lib/editor/commands.test.ts. Columns are byte offsets, so the
// emoji and flag cases differ numerically from the UTF-16 originals.

const testing = std.testing;

const Fixture = struct {
    b: Buffer,
    sel: Selection = Selection.initial,

    fn init(text: []const u8) !Fixture {
        return .{ .b = try Buffer.initFromString(testing.allocator, text, 0) };
    }
    fn deinit(self: *Fixture) void {
        self.b.deinit();
    }
    fn run(self: *Fixture, cmd: Command) !void {
        self.sel = try apply(&self.b, self.sel, cmd, 0);
        self.b.clearChanges();
    }
    fn expectText(self: *const Fixture, expected: []const u8) !void {
        const s = try self.b.toOwnedString(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(expected, s);
    }
};

const step_right = Command{ .move = .{ .by = .char, .dir = .fwd, .extend = false } };
const step_left = Command{ .move = .{ .by = .char, .dir = .back, .extend = false } };

test "move char right then left" {
    var f = try Fixture.init("abc");
    defer f.deinit();
    try f.run(step_right);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, f.sel.head);
    try f.run(step_left);
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, f.sel.head);
}

test "char movement crosses a line boundary" {
    var f = try Fixture.init("ab\ncd");
    defer f.deinit();
    try f.run(.{ .move_end = .{ .extend = false } });
    try f.run(step_right);
    try testing.expectEqual(Pos{ .line = 1, .col = 0 }, f.sel.head);
}

test "shift-arrow extends the selection" {
    var f = try Fixture.init("abc");
    defer f.deinit();
    try f.run(.{ .move = .{ .by = .char, .dir = .fwd, .extend = true } });
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, f.sel.anchor);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, f.sel.head);
}

test "word jump skips whitespace" {
    var f = try Fixture.init("hello  world");
    defer f.deinit();
    try f.run(.{ .move = .{ .by = .word, .dir = .fwd, .extend = false } });
    try testing.expectEqual(@as(usize, 5), f.sel.head.col);
    try f.run(.{ .move = .{ .by = .word, .dir = .fwd, .extend = false } });
    try testing.expectEqual(@as(usize, 12), f.sel.head.col);
}

test "left arrow on a selection collapses to the left edge" {
    var f = try Fixture.init("abcde");
    defer f.deinit();
    // Reversed selection: anchor 4, head 1. The left edge is col 1.
    f.sel = .{ .anchor = .{ .line = 0, .col = 4 }, .head = .{ .line = 0, .col = 1 } };
    try f.run(step_left);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, f.sel.head);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, f.sel.anchor);
}

test "right arrow on a selection collapses to the right edge" {
    var f = try Fixture.init("abcde");
    defer f.deinit();
    f.sel = .{ .anchor = .{ .line = 0, .col = 1 }, .head = .{ .line = 0, .col = 4 } };
    try f.run(step_right);
    try testing.expectEqual(Pos{ .line = 0, .col = 4 }, f.sel.head);
    try testing.expectEqual(Pos{ .line = 0, .col = 4 }, f.sel.anchor);
}

test "arrows step over an emoji as one glyph" {
    // U+1F642 is 4 bytes in UTF-8, so the cluster spans bytes 1..5.
    var f = try Fixture.init("a🙂b");
    defer f.deinit();
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 5), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 6), f.sel.head.col);

    f.sel = Selection.at(.{ .line = 0, .col = 5 });
    try f.run(step_left);
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
}

test "backspace on an emoji deletes the whole cluster" {
    var f = try Fixture.init("a🙂");
    defer f.deinit();
    try f.run(.{ .move_end = .{ .extend = false } });
    try testing.expectEqual(@as(usize, 5), f.sel.head.col);
    try f.run(.backspace);
    try f.expectText("a");
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
}

test "arrows step over a VS-16 sequence as one glyph" {
    // ⬛️ = U+2B1B (3 bytes) + U+FE0F (3 bytes) -> cluster spans bytes 1..7.
    var f = try Fixture.init("a⬛\u{FE0F}b");
    defer f.deinit();
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 7), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 8), f.sel.head.col);

    f.sel = Selection.at(.{ .line = 0, .col = 7 });
    try f.run(step_left);
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
}

test "backspace on a VS-16 sequence deletes the whole cluster" {
    var f = try Fixture.init("a⬛\u{FE0F}");
    defer f.deinit();
    try f.run(.{ .move_end = .{ .extend = false } });
    try testing.expectEqual(@as(usize, 7), f.sel.head.col);
    try f.run(.backspace);
    try f.expectText("a");
}

test "arrows step over a regional-indicator flag as one glyph" {
    // Each regional indicator is 4 bytes, so the flag spans bytes 1..9.
    var f = try Fixture.init("a🇰🇷b");
    defer f.deinit();
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 1), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 9), f.sel.head.col);
    try f.run(step_right);
    try testing.expectEqual(@as(usize, 10), f.sel.head.col);
}

test "select all spans the document" {
    var f = try Fixture.init("ab\ncde");
    defer f.deinit();
    try f.run(.select_all);
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, f.sel.anchor);
    try testing.expectEqual(Pos{ .line = 1, .col = 3 }, f.sel.head);
}

test "insert types text and advances the caret" {
    var f = try Fixture.init("");
    defer f.deinit();
    try f.run(.{ .insert = .{ .text = "hi" } });
    try f.expectText("hi");
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, f.sel.head);
}

test "newline splits the line" {
    var f = try Fixture.init("ab");
    defer f.deinit();
    try f.run(step_right);
    try f.run(.newline);
    try f.expectText("a\nb");
    try testing.expectEqual(Pos{ .line = 1, .col = 0 }, f.sel.head);
}

test "backspace at line start joins with the previous line" {
    var f = try Fixture.init("ab\ncd");
    defer f.deinit();
    try f.run(.{ .move = .{ .by = .line, .dir = .fwd, .extend = false } });
    try f.run(.{ .move_home = .{ .extend = false } });
    try f.run(.backspace);
    try f.expectText("abcd");
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, f.sel.head);
}

test "typing with a selection replaces it" {
    var f = try Fixture.init("hello");
    defer f.deinit();
    try f.run(.select_all);
    try f.run(.{ .insert = .{ .text = "X" } });
    try f.expectText("X");
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, f.sel.head);
}

test "replacing a selection is a single undo step" {
    // The original needed two Cmd+Z presses here.
    var f = try Fixture.init("hello");
    defer f.deinit();
    try f.run(.select_all);
    try f.run(.{ .insert = .{ .text = "X" } });
    try f.expectText("X");
    try f.run(.undo);
    try f.expectText("hello");
}

test "undo and redo through the command path" {
    var f = try Fixture.init("x");
    defer f.deinit();
    try f.run(.{ .move_end = .{ .extend = false } });
    try f.run(.{ .insert = .{ .text = "y" } });
    try f.expectText("xy");
    try f.run(.undo);
    try f.expectText("x");
    try f.run(.redo);
    try f.expectText("xy");
}

test "indent adds a tab to every selected line and undoes as one step" {
    var f = try Fixture.init("a\nb\nc");
    defer f.deinit();
    f.sel = .{ .anchor = .{ .line = 0, .col = 0 }, .head = .{ .line = 2, .col = 1 } };
    try f.run(.indent);
    try f.expectText("\ta\n\tb\n\tc");
    try testing.expectEqual(@as(usize, 1), f.sel.anchor.col);
    try testing.expectEqual(@as(usize, 2), f.sel.head.col);
    try f.run(.undo);
    try f.expectText("a\nb\nc");
}

test "dedent removes one tab per line and only shifts lines that had one" {
    var f = try Fixture.init("\ta\nb\n\tc");
    defer f.deinit();
    f.sel = .{ .anchor = .{ .line = 0, .col = 2 }, .head = .{ .line = 2, .col = 2 } };
    try f.run(.dedent);
    try f.expectText("a\nb\nc");
    try testing.expectEqual(@as(usize, 1), f.sel.anchor.col); // line 0 lost a tab
    try testing.expectEqual(@as(usize, 1), f.sel.head.col); // line 2 lost a tab
}

test "dedent leaves a line without leading tab alone" {
    var f = try Fixture.init("a\n\tb");
    defer f.deinit();
    f.sel = .{ .anchor = .{ .line = 0, .col = 1 }, .head = .{ .line = 1, .col = 2 } };
    try f.run(.dedent);
    try f.expectText("a\nb");
    try testing.expectEqual(@as(usize, 1), f.sel.anchor.col); // unchanged
    try testing.expectEqual(@as(usize, 1), f.sel.head.col); // shifted by the removed tab
}

test "page movement clamps at both ends" {
    var f = try Fixture.init("0\n1\n2\n3\n4");
    defer f.deinit();
    try f.run(.{ .page = .{ .dir = .fwd, .extend = false, .page_lines = 3 } });
    try testing.expectEqual(@as(usize, 3), f.sel.head.line);
    try f.run(.{ .page = .{ .dir = .fwd, .extend = false, .page_lines = 3 } });
    try testing.expectEqual(@as(usize, 4), f.sel.head.line);
    try f.run(.{ .page = .{ .dir = .back, .extend = false, .page_lines = 10 } });
    try testing.expectEqual(@as(usize, 0), f.sel.head.line);
}

test "keymap covers the documented shortcuts" {
    try testing.expectEqual(Command.undo, keymap(.{ .key = .{ .character = 'z' }, .meta = true }, 10).?);
    try testing.expectEqual(Command.redo, keymap(.{ .key = .{ .character = 'z' }, .meta = true, .shift = true }, 10).?);
    try testing.expectEqual(Command.select_all, keymap(.{ .key = .{ .character = 'a' }, .meta = true }, 10).?);
    try testing.expectEqual(Command.backspace, keymap(.{ .key = .backspace }, 10).?);
    try testing.expectEqual(Command.newline, keymap(.{ .key = .enter }, 10).?);

    const word_left = keymap(.{ .key = .arrow_left, .alt = true, .shift = true }, 10).?;
    try testing.expectEqual(MoveBy.word, word_left.move.by);
    try testing.expectEqual(Dir.back, word_left.move.dir);
    try testing.expect(word_left.move.extend);

    const pg = keymap(.{ .key = .page_down }, 42).?;
    try testing.expectEqual(@as(usize, 42), pg.page.page_lines);

    // Cmd+Left is line-home, not a word move.
    try testing.expect(keymap(.{ .key = .arrow_left, .meta = true }, 10).? == .move_home);
    // Unmapped keys produce nothing.
    try testing.expect(keymap(.{ .key = .other }, 10) == null);
    try testing.expect(keymap(.{ .key = .{ .character = 'q' }, .meta = true }, 10) == null);
}
