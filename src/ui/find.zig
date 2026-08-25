//! The find and replace bar.
//!
//! Ported from the find half of `Editor.svelte` (:1015-1233, :1387+).

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");
const app = @import("app");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Painter = gfx.Painter;
const Pos = core.buffer.Pos;
const palette = theme.palette;

pub const Match = struct { from: Pos, to: Pos };

pub const Find = struct {
    gpa: Allocator,
    open: bool = false,
    replacing: bool = false,
    case_sensitive: bool = false,
    /// Which of the two inputs has focus.
    focus_replace: bool = false,

    query: std.ArrayList(u8) = .empty,
    replacement: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    active: usize = 0,

    pub fn init(gpa: Allocator) Find {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Find) void {
        self.query.deinit(self.gpa);
        self.replacement.deinit(self.gpa);
        self.matches.deinit(self.gpa);
    }

    pub fn close(self: *Find) void {
        self.open = false;
        self.replacing = false;
        self.focus_replace = false;
        self.matches.clearRetainingCapacity();
    }

    /// Open the bar, pre-filling from a single-line selection the way Sublime
    /// and VS Code do.
    pub fn show(self: *Find, tab: *app.state.Tab, with_replace: bool) !void {
        self.open = true;
        self.replacing = with_replace;
        self.focus_replace = false;

        const sel = tab.selection;
        if (!sel.isEmpty() and sel.anchor.line == sel.head.line) {
            const r = sel.ordered();
            const line = tab.buffer.getLine(r.from.line);
            self.query.clearRetainingCapacity();
            try self.query.appendSlice(self.gpa, line[r.from.col..r.to.col]);
        }
        try self.recompute(tab);
    }

    fn activeInput(self: *Find) *std.ArrayList(u8) {
        return if (self.focus_replace) &self.replacement else &self.query;
    }

    pub fn typeText(self: *Find, tab: *app.state.Tab, text: []const u8) !void {
        try self.activeInput().appendSlice(self.gpa, text);
        if (!self.focus_replace) try self.recompute(tab);
    }

    pub fn backspace(self: *Find, tab: *app.state.Tab) !void {
        const buf = self.activeInput();
        if (buf.items.len == 0) return;
        buf.shrinkRetainingCapacity(core.grapheme.prev(buf.items, buf.items.len));
        if (!self.focus_replace) try self.recompute(tab);
    }

    pub fn toggleCase(self: *Find, tab: *app.state.Tab) !void {
        self.case_sensitive = !self.case_sensitive;
        try self.recompute(tab);
    }

    /// Rescan the whole document for the query.
    pub fn recompute(self: *Find, tab: *app.state.Tab) !void {
        self.matches.clearRetainingCapacity();
        if (self.query.items.len == 0) return;

        var lowered: ?[]u8 = null;
        defer if (lowered) |l| self.gpa.free(l);
        const needle = if (self.case_sensitive) self.query.items else blk: {
            lowered = try std.ascii.allocLowerString(self.gpa, self.query.items);
            break :blk lowered.?;
        };

        var line: usize = 0;
        while (line < tab.buffer.lineCount()) : (line += 1) {
            const text = tab.buffer.getLine(line);
            var hay_lower: ?[]u8 = null;
            defer if (hay_lower) |h| self.gpa.free(h);
            const hay = if (self.case_sensitive) text else blk: {
                hay_lower = try std.ascii.allocLowerString(self.gpa, text);
                break :blk hay_lower.?;
            };

            var at: usize = 0;
            while (std.mem.indexOfPos(u8, hay, at, needle)) |found| {
                try self.matches.append(self.gpa, .{
                    .from = .{ .line = line, .col = found },
                    .to = .{ .line = line, .col = found + needle.len },
                });
                at = found + @max(1, needle.len);
            }
        }
        if (self.active >= self.matches.items.len) self.active = 0;
    }

    /// Step to the next or previous match, wrapping at both ends.
    pub fn step(self: *Find, delta: i32) ?Match {
        if (self.matches.items.len == 0) return null;
        const n: i32 = @intCast(self.matches.items.len);
        const cur: i32 = @intCast(self.active);
        self.active = @intCast(@mod(cur + delta + n, n));
        return self.matches.items[self.active];
    }

    pub fn current(self: *const Find) ?Match {
        if (self.active >= self.matches.items.len) return null;
        return self.matches.items[self.active];
    }

    /// Replace the current match and move to the next.
    pub fn replaceOne(self: *Find, tab: *app.state.Tab, now_ms: i64) !bool {
        const m = self.current() orelse return false;
        try tab.buffer.beginGroup();
        try tab.buffer.applyEdit(.{ .delete = .{ .from = m.from, .to = m.to } }, now_ms);
        try tab.buffer.applyEdit(
            .{ .insert = .{ .at = m.from, .text = self.replacement.items } },
            now_ms,
        );
        try tab.buffer.endGroup();
        tab.selection = core.selection.Selection.at(.{
            .line = m.from.line,
            .col = m.from.col + self.replacement.items.len,
        });
        try self.recompute(tab);
        return true;
    }

    /// Replace every match, back to front so earlier offsets stay valid.
    pub fn replaceAll(self: *Find, tab: *app.state.Tab, now_ms: i64) !usize {
        if (self.matches.items.len == 0) return 0;
        const count = self.matches.items.len;

        try tab.buffer.beginGroup();
        var i = count;
        while (i > 0) {
            i -= 1;
            const m = self.matches.items[i];
            try tab.buffer.applyEdit(.{ .delete = .{ .from = m.from, .to = m.to } }, now_ms);
            try tab.buffer.applyEdit(
                .{ .insert = .{ .at = m.from, .text = self.replacement.items } },
                now_ms,
            );
        }
        try tab.buffer.endGroup();

        try self.recompute(tab);
        return count;
    }

    pub const bar_h: i32 = 30;
    pub const bar_w: i32 = 360;

    pub fn rect(within: Rect, replacing: bool) Rect {
        const h: i32 = if (replacing) bar_h * 2 + 4 else bar_h;
        return .{ .x = within.right() - bar_w - 16, .y = within.y + 8, .w = bar_w, .h = h + 12 };
    }

    pub fn paint(self: *Find, p: *Painter, within: Rect) void {
        if (!self.open) return;
        const r = rect(within, self.replacing);
        p.fill(r, palette.bg_1);
        p.stroke(r, palette.bg_3);

        const query_box = Rect{ .x = r.x + 6, .y = r.y + 6, .w = 180, .h = bar_h - 6 };
        p.fill(query_box, palette.bg_0);
        if (!self.focus_replace) p.stroke(query_box, palette.accent);
        p.drawEllipsized(query_box.inset(4), self.query.items, palette.fg_0, .{});

        var buf: [32]u8 = undefined;
        const count = if (self.matches.items.len == 0)
            "No matches"
        else
            std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.active + 1, self.matches.items.len }) catch "";
        p.drawLabel(
            .{ .x = query_box.right() + 6, .y = query_box.y, .w = 76, .h = query_box.h },
            count,
            palette.fg_2,
            .right,
            .{},
        );

        p.drawLabel(
            .{ .x = r.right() - 84, .y = query_box.y, .w = 24, .h = query_box.h },
            "Aa",
            if (self.case_sensitive) palette.accent else palette.fg_2,
            .center,
            .{},
        );
        p.drawLabel(.{ .x = r.right() - 58, .y = query_box.y, .w = 18, .h = query_box.h }, "<", palette.fg_2, .center, .{});
        p.drawLabel(.{ .x = r.right() - 40, .y = query_box.y, .w = 18, .h = query_box.h }, ">", palette.fg_2, .center, .{});
        p.drawLabel(.{ .x = r.right() - 22, .y = query_box.y, .w = 18, .h = query_box.h }, "x", palette.fg_2, .center, .{});

        if (!self.replacing) return;

        const replace_box = Rect{ .x = r.x + 6, .y = query_box.bottom() + 4, .w = 180, .h = bar_h - 6 };
        p.fill(replace_box, palette.bg_0);
        if (self.focus_replace) p.stroke(replace_box, palette.accent);
        p.drawEllipsized(replace_box.inset(4), self.replacement.items, palette.fg_0, .{});

        p.drawLabel(
            .{ .x = replace_box.right() + 8, .y = replace_box.y, .w = 70, .h = replace_box.h },
            "Replace",
            palette.fg_1,
            .center,
            .{},
        );
        p.drawLabel(
            .{ .x = replace_box.right() + 84, .y = replace_box.y, .w = 46, .h = replace_box.h },
            "All",
            palette.fg_1,
            .center,
            .{},
        );
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const db = @import("db");

const Fixture = struct {
    env: db.fsx.TestEnv,
    application: app.state.App,
    root: []u8,
    gpa: Allocator,

    fn init(gpa: Allocator, name: []const u8, text: []const u8) !*Fixture {
        var env = try db.fsx.TestEnv.init(gpa, name);
        errdefer env.deinit();
        const root = try std.fmt.allocPrint(gpa, "{s}/ws", .{env.path});
        errdefer gpa.free(root);

        const self = try gpa.create(Fixture);
        self.* = .{ .env = env, .application = app.state.App.init(gpa, env.io), .root = root, .gpa = gpa };
        try self.application.openWorkspace(root);
        const i = try self.application.createAndOpenNote();
        const tab = &self.application.tabs.items[i];
        if (text.len > 0) {
            try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = text } }, 0);
            tab.buffer.clearChanges();
        }
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.gpa;
        self.application.deinit();
        gpa.free(self.root);
        self.env.deinit();
        gpa.destroy(self);
    }

    fn firstTab(self: *Fixture) *app.state.Tab {
        return &self.application.tabs.items[0];
    }

    fn contents(self: *Fixture) ![]u8 {
        return self.firstTab().buffer.toOwnedString(self.gpa);
    }
};

test "find locates every match across lines" {
    const f = try Fixture.init(testing.allocator, "find-basic", "foo bar\nbaz foo\nfoo");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "foo");
    try find.recompute(f.firstTab());

    try testing.expectEqual(@as(usize, 3), find.matches.items.len);
    try testing.expectEqual(@as(usize, 0), find.matches.items[0].from.line);
    try testing.expectEqual(@as(usize, 4), find.matches.items[1].from.col);
    try testing.expectEqual(@as(usize, 2), find.matches.items[2].from.line);
}

test "find is case-insensitive until asked otherwise" {
    const f = try Fixture.init(testing.allocator, "find-case", "Foo foo FOO");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "foo");
    try find.recompute(f.firstTab());
    try testing.expectEqual(@as(usize, 3), find.matches.items.len);

    try find.toggleCase(f.firstTab());
    try testing.expectEqual(@as(usize, 1), find.matches.items.len);
}

test "stepping through matches wraps" {
    const f = try Fixture.init(testing.allocator, "find-step", "a a a");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "a");
    try find.recompute(f.firstTab());

    try testing.expectEqual(@as(usize, 2), find.step(1).?.from.col);
    try testing.expectEqual(@as(usize, 4), find.step(1).?.from.col);
    try testing.expectEqual(@as(usize, 0), find.step(1).?.from.col);
    try testing.expectEqual(@as(usize, 4), find.step(-1).?.from.col);
}

test "find matches Korean text" {
    const f = try Fixture.init(testing.allocator, "find-korean", "안녕하세요 안녕");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "안녕");
    try find.recompute(f.firstTab());
    try testing.expectEqual(@as(usize, 2), find.matches.items.len);
    // Byte offsets: the second `안녕` starts after 5 syllables and a space.
    try testing.expectEqual(@as(usize, 16), find.matches.items[1].from.col);
}

test "replacing one match advances and stays undoable" {
    const f = try Fixture.init(testing.allocator, "find-replace-one", "cat cat cat");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "cat");
    try find.replacement.appendSlice(testing.allocator, "dog");
    try find.recompute(f.firstTab());

    try testing.expect(try find.replaceOne(f.firstTab(), 0));
    {
        const t = try f.contents();
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("dog cat cat", t);
    }

    // One undo reverses the whole replacement.
    _ = try f.firstTab().buffer.undo();
    const t = try f.contents();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("cat cat cat", t);
}

test "replace all rewrites every match in one undo step" {
    const f = try Fixture.init(testing.allocator, "find-replace-all", "cat cat\ncat");
    defer f.deinit();

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "cat");
    try find.replacement.appendSlice(testing.allocator, "wolf");
    try find.recompute(f.firstTab());

    try testing.expectEqual(@as(usize, 3), try find.replaceAll(f.firstTab(), 0));
    {
        const t = try f.contents();
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("wolf wolf\nwolf", t);
    }

    _ = try f.firstTab().buffer.undo();
    const t = try f.contents();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("cat cat\ncat", t);
}

test "opening the bar pre-fills from a single-line selection" {
    const f = try Fixture.init(testing.allocator, "find-prefill", "hello world");
    defer f.deinit();
    const tab = f.firstTab();
    tab.selection = .{ .anchor = .{ .line = 0, .col = 6 }, .head = .{ .line = 0, .col = 11 } };

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.show(tab, false);
    try testing.expectEqualStrings("world", find.query.items);
    try testing.expectEqual(@as(usize, 1), find.matches.items.len);
}

test "a multi-line selection does not pre-fill" {
    const f = try Fixture.init(testing.allocator, "find-prefill-multi", "one\ntwo");
    defer f.deinit();
    const tab = f.firstTab();
    tab.selection = .{ .anchor = .{ .line = 0, .col = 0 }, .head = .{ .line = 1, .col = 3 } };

    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.show(tab, false);
    try testing.expectEqual(@as(usize, 0), find.query.items.len);
}

test "an empty query matches nothing" {
    const f = try Fixture.init(testing.allocator, "find-empty", "text");
    defer f.deinit();
    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.recompute(f.firstTab());
    try testing.expectEqual(@as(usize, 0), find.matches.items.len);
    try testing.expect(find.step(1) == null);
}

test "overlapping matches advance by at least one byte" {
    const f = try Fixture.init(testing.allocator, "find-overlap", "aaaa");
    defer f.deinit();
    var find = Find.init(testing.allocator);
    defer find.deinit();
    try find.query.appendSlice(testing.allocator, "aa");
    try find.recompute(f.firstTab());
    // Non-overlapping scan: offsets 0 and 2.
    try testing.expectEqual(@as(usize, 2), find.matches.items.len);
}
