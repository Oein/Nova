//! The window chrome: sidebar, tab bar and status bar.
//!
//! Ported from `Sidebar.svelte`, `DateGroup.svelte`, `FileEntry.svelte`,
//! `TabBar.svelte` and `BottomBar.svelte`.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");
const app = @import("app");
const db = @import("db");
const ev = @import("event.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Painter = gfx.Painter;
const Note = db.workspace.Note;
const palette = theme.palette;

// -- sidebar -----------------------------------------------------------------

pub const Sidebar = struct {
    gpa: Allocator,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scroll_top: f64 = 0,

    /// Bucket keys the user has collapsed. Persisted per workspace, as the
    /// original did in `localStorage["collapsedGroups:{path}"]`.
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    /// Notes the user has selected (multi-select via Shift and Cmd click).
    selected: std.StringHashMapUnmanaged(void) = .empty,
    /// Anchor for shift-range selection.
    anchor: ?[]u8 = null,

    hover_row: ?usize = null,

    pub fn init(gpa: Allocator) Sidebar {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sidebar) void {
        freeKeys(&self.collapsed, self.gpa);
        freeKeys(&self.selected, self.gpa);
        if (self.anchor) |a| self.gpa.free(a);
    }

    fn freeKeys(map: *std.StringHashMapUnmanaged(void), gpa: Allocator) void {
        var it = map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        map.deinit(gpa);
    }

    fn toggleKey(map: *std.StringHashMapUnmanaged(void), gpa: Allocator, key: []const u8) void {
        if (map.fetchRemove(key)) |removed| {
            gpa.free(removed.key);
            return;
        }
        const owned = gpa.dupe(u8, key) catch return;
        map.put(gpa, owned, {}) catch gpa.free(owned);
    }

    pub fn isCollapsed(self: *const Sidebar, key: []const u8) bool {
        return self.collapsed.contains(key);
    }

    pub fn toggleGroup(self: *Sidebar, key: []const u8) void {
        toggleKey(&self.collapsed, self.gpa, key);
    }

    pub fn isSelected(self: *const Sidebar, id: []const u8) bool {
        return self.selected.contains(id);
    }

    pub fn clearSelection(self: *Sidebar) void {
        freeKeys(&self.selected, self.gpa);
        self.selected = .empty;
    }

    fn select(self: *Sidebar, id: []const u8) void {
        const owned = self.gpa.dupe(u8, id) catch return;
        self.selected.put(self.gpa, owned, {}) catch self.gpa.free(owned);
    }

    fn setAnchor(self: *Sidebar, id: []const u8) void {
        const owned = self.gpa.dupe(u8, id) catch return;
        if (self.anchor) |a| self.gpa.free(a);
        self.anchor = owned;
    }

    /// One visible line in the list: a group header or a note row.
    pub const Row = union(enum) {
        group: struct { key: db.workspace.Note, index: usize },
        note: struct { id: []const u8, title: []const u8, index: usize },
    };

    /// What a click on the list means.
    pub const Click = union(enum) {
        none,
        toggle_group: []const u8,
        open_note: []const u8,
        /// Selection changed but no note should open (Cmd-click).
        select_only,
    };

    /// Apply the original's three-way click behavior (`Sidebar.svelte:40`).
    ///
    /// Plain click selects one note and opens it; Cmd-click toggles membership
    /// without opening; Shift-click extends from the anchor over the currently
    /// *visible* rows, which is why collapsed groups are skipped.
    pub fn clickNote(
        self: *Sidebar,
        id: []const u8,
        visible_ids: []const []const u8,
        mods: ev.Mods,
    ) Click {
        if (mods.meta) {
            toggleKey(&self.selected, self.gpa, id);
            self.setAnchor(id);
            return .select_only;
        }
        if (mods.shift) {
            const from = self.anchor orelse id;
            const a = indexOfId(visible_ids, from) orelse 0;
            const b = indexOfId(visible_ids, id) orelse 0;
            self.clearSelection();
            const lo = @min(a, b);
            const hi = @max(a, b);
            for (visible_ids[lo .. hi + 1]) |vid| self.select(vid);
            // The anchor deliberately does not move, so a second shift-click
            // re-ranges from the same origin.
            return .select_only;
        }
        self.clearSelection();
        self.select(id);
        self.setAnchor(id);
        return .{ .open_note = id };
    }

    fn indexOfId(ids: []const []const u8, id: []const u8) ?usize {
        for (ids, 0..) |v, i| {
            if (std.mem.eql(u8, v, id)) return i;
        }
        return null;
    }

    pub fn rowHeight(self: *const Sidebar) i32 {
        _ = self;
        return theme.sidebar_row_h;
    }

    pub const header_h: i32 = 30;

    pub fn headerRect(self: *const Sidebar) Rect {
        return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w, .h = header_h };
    }

    pub fn newNoteRect(self: *const Sidebar) Rect {
        return .{ .x = self.rect.right() - 96, .y = self.rect.y + 4, .w = 22, .h = 22 };
    }

    pub fn openFolderRect(self: *const Sidebar) Rect {
        return .{ .x = self.rect.right() - 70, .y = self.rect.y + 4, .w = 62, .h = 22 };
    }

    pub const HeaderHit = enum { new_note, open_folder };

    pub fn hitTestHeader(self: *const Sidebar, px: i32, py: i32) ?HeaderHit {
        if (self.newNoteRect().contains(px, py)) return .new_note;
        if (self.openFolderRect().contains(px, py)) return .open_folder;
        return null;
    }

    /// Paint the note list, grouped by local day.
    pub fn paint(
        self: *Sidebar,
        p: *Painter,
        groups: []const app.datefmt.Group,
        active_id: ?[]const u8,
        dirty: *const std.StringHashMapUnmanaged(void),
        workspace_path: ?[]const u8,
        now_ms: i64,
    ) void {
        const saved = p.pushClip(self.rect);
        defer p.popClip(saved);

        p.fill(self.rect, palette.bg_1);

        var y = self.rect.y - @as(i32, @intFromFloat(self.scroll_top));

        // Header: a new-note button and an open-folder button.
        const head = self.headerRect();
        p.fill(head, palette.bg_1);
        p.fill(.{ .x = head.x, .y = head.bottom() - 1, .w = head.w, .h = 1 }, palette.bg_3);
        p.drawLabel(self.newNoteRect(), "+", palette.fg_1, .center, .{});
        p.drawLabel(self.openFolderRect(), "Open...", palette.fg_1, .center, .{});
        y += head.h;

        if (workspace_path) |path| {
            const bar = Rect{ .x = self.rect.x, .y = y, .w = self.rect.w, .h = 20 };
            p.drawEllipsized(bar.inset(6), path, palette.fg_2, .{});
            p.fill(.{ .x = self.rect.x, .y = y + 20, .w = self.rect.w, .h = 1 }, palette.bg_2);
            y += 21;
        } else {
            p.drawLabel(
                .{ .x = self.rect.x, .y = self.rect.y + 20, .w = self.rect.w, .h = 24 },
                "No workspace opened",
                palette.fg_2,
                .center,
                .{},
            );
            return;
        }

        for (groups) |*g| {
            const collapsed = self.isCollapsed(&g.key);
            self.paintGroupHeader(p, g, y, collapsed, now_ms);
            y += theme.sidebar_group_h;
            if (collapsed) continue;

            for (g.entries) |note| {
                if (y > self.rect.bottom()) return;
                self.paintNoteRow(p, note, y, active_id, dirty);
                y += theme.sidebar_row_h;
            }
        }

        if (groups.len == 0) {
            p.drawLabel(
                .{ .x = self.rect.x, .y = y + 8, .w = self.rect.w, .h = 24 },
                "No notes yet -- press Cmd+N to create one",
                palette.fg_2,
                .center,
                .{},
            );
        }
    }

    fn paintGroupHeader(
        self: *Sidebar,
        p: *Painter,
        g: *const app.datefmt.Group,
        y: i32,
        collapsed: bool,
        now_ms: i64,
    ) void {
        const rect = Rect{ .x = self.rect.x, .y = y, .w = self.rect.w, .h = theme.sidebar_group_h };
        p.drawLabel(
            .{ .x = rect.x + 10, .y = rect.y, .w = 12, .h = rect.h },
            if (collapsed) ">" else "v",
            palette.fg_2,
            .left,
            .{},
        );
        p.drawEllipsized(
            .{ .x = rect.x + 24, .y = rect.y, .w = rect.w - 60, .h = rect.h },
            g.label(now_ms),
            palette.fg_1,
            .{},
        );

        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{g.count()}) catch return;
        p.drawLabel(
            .{ .x = rect.right() - 34, .y = rect.y, .w = 24, .h = rect.h },
            count,
            palette.fg_2,
            .right,
            .{},
        );
    }

    fn paintNoteRow(
        self: *Sidebar,
        p: *Painter,
        note: Note,
        y: i32,
        active_id: ?[]const u8,
        dirty: *const std.StringHashMapUnmanaged(void),
    ) void {
        const rect = Rect{ .x = self.rect.x, .y = y, .w = self.rect.w, .h = theme.sidebar_row_h };
        const is_active = active_id != null and std.mem.eql(u8, active_id.?, note.id);

        // Active wins over selected, matching the CSS source order.
        if (is_active) {
            p.fill(rect, palette.accent_dim);
        } else if (self.isSelected(note.id)) {
            p.fill(rect, palette.bg_3);
        }

        var x = rect.x + 20;
        if (dirty.contains(note.id)) {
            p.fill(.{ .x = x, .y = y + @divTrunc(rect.h, 2) - 2, .w = 4, .h = 4 }, palette.dirty);
            x += 8;
        }

        p.drawEllipsized(
            .{ .x = x, .y = rect.y, .w = rect.right() - x - 8, .h = rect.h },
            if (note.title.len > 0) note.title else "Untitled",
            if (is_active) palette.fg_0 else palette.fg_0,
            .{},
        );
    }

    /// Which row a point falls on, walking the same layout `paint` uses.
    pub fn hitTest(self: *const Sidebar, groups: []const app.datefmt.Group, py: i32) ?Row {
        var y = self.rect.y - @as(i32, @intFromFloat(self.scroll_top)) + header_h + 21;
        for (groups, 0..) |g, gi| {
            if (py >= y and py < y + theme.sidebar_group_h) {
                return .{ .group = .{ .key = undefined, .index = gi } };
            }
            y += theme.sidebar_group_h;
            if (self.isCollapsed(&g.key)) continue;

            for (g.entries, 0..) |note, ni| {
                if (py >= y and py < y + theme.sidebar_row_h) {
                    return .{ .note = .{ .id = note.id, .title = note.title, .index = ni } };
                }
                y += theme.sidebar_row_h;
            }
        }
        return null;
    }
};

// -- tab bar -----------------------------------------------------------------

pub const TabBar = struct {
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scroll_x: f64 = 0,
    /// Index being dragged, and where it would land.
    dragging: ?usize = null,
    drop_index: ?usize = null,

    /// Width one tab occupies, given its title.
    pub fn tabWidth(p: *const Painter, title: []const u8) i32 {
        const text_w: i32 = @intFromFloat(@ceil(p.measureRun(title, 4)));
        // padding + dirty dot + close button, clamped like `max-width: 200px`.
        return @min(theme.tab_max_w, @max(60, text_w + 46));
    }

    pub fn paint(self: *TabBar, p: *Painter, tabs: []const app.state.Tab, active: ?usize) void {
        const saved = p.pushClip(self.rect);
        defer p.popClip(saved);

        p.fill(self.rect, palette.bg_1);
        p.fill(
            .{ .x = self.rect.x, .y = self.rect.bottom() - 1, .w = self.rect.w, .h = 1 },
            palette.bg_3,
        );

        var x = self.rect.x - @as(i32, @intFromFloat(self.scroll_x));
        for (tabs, 0..) |t, i| {
            const w = tabWidth(p, t.title);
            const rect = Rect{ .x = x, .y = self.rect.y, .w = w, .h = self.rect.h - 1 };
            if (rect.x < self.rect.right() and rect.right() > self.rect.x) {
                self.paintTab(p, rect, t, active != null and active.? == i, self.dragging != null and self.dragging.? == i);
            }
            x += w;
        }

        if (self.drop_index) |idx| {
            var dx = self.rect.x - @as(i32, @intFromFloat(self.scroll_x));
            for (tabs[0..@min(idx, tabs.len)]) |t| dx += tabWidth(p, t.title);
            p.fill(.{ .x = dx, .y = self.rect.y, .w = 2, .h = self.rect.h }, palette.accent);
        }
    }

    fn paintTab(self: *TabBar, p: *Painter, rect: Rect, t: app.state.Tab, active: bool, dragging: bool) void {
        _ = self;
        if (active) p.fill(rect, palette.bg_0);
        p.fill(.{ .x = rect.right() - 1, .y = rect.y, .w = 1, .h = rect.h }, palette.bg_3);

        var x = rect.x + 10;
        if (t.dirty) {
            p.fill(.{ .x = x, .y = rect.y + @divTrunc(rect.h, 2) - 2, .w = 4, .h = 4 }, palette.dirty);
            x += 8;
        }

        const fg = if (dragging) palette.fg_2 else if (active) palette.fg_0 else palette.fg_1;
        p.drawEllipsized(
            .{ .x = x, .y = rect.y, .w = rect.right() - x - 22, .h = rect.h },
            t.title,
            fg,
            .{},
        );

        // Close button.
        p.drawLabel(
            .{ .x = rect.right() - 20, .y = rect.y, .w = 14, .h = rect.h },
            "x",
            palette.fg_2,
            .center,
            .{},
        );
    }

    pub const Hit = union(enum) { none, tab: usize, close: usize };

    pub fn hitTest(self: *const TabBar, p: *const Painter, tabs: []const app.state.Tab, px: i32, py: i32) Hit {
        if (!self.rect.contains(px, py)) return .none;
        var x = self.rect.x - @as(i32, @intFromFloat(self.scroll_x));
        for (tabs, 0..) |t, i| {
            const w = tabWidth(p, t.title);
            if (px >= x and px < x + w) {
                if (px >= x + w - 22) return .{ .close = i };
                return .{ .tab = i };
            }
            x += w;
        }
        return .none;
    }

    /// Where a drag would drop, using tab midpoints as the original did.
    pub fn dropIndexAt(self: *const TabBar, p: *const Painter, tabs: []const app.state.Tab, px: i32) usize {
        var x = self.rect.x - @as(i32, @intFromFloat(self.scroll_x));
        for (tabs, 0..) |t, i| {
            const w = tabWidth(p, t.title);
            if (px < x + @divTrunc(w, 2)) return i;
            x += w;
        }
        return tabs.len;
    }
};

// -- status bar --------------------------------------------------------------

pub const StatusBar = struct {
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub const Status = struct {
        line: usize = 0,
        col: usize = 0,
        selection_chars: usize = 0,
        selection_chars_no_ws: usize = 0,
    };

    /// Character counts for the current selection, including the "excluding
    /// whitespace" tally the original showed.
    pub fn statusOf(tab: *const app.state.Tab, gpa: Allocator) !Status {
        var s = Status{
            .line = tab.selection.head.line,
            .col = tab.selection.head.col,
        };
        if (tab.selection.isEmpty()) return s;

        const r = tab.selection.ordered();
        var buffer = tab.buffer;
        const text = try buffer.sliceText(r.from, r.to, gpa);
        defer gpa.free(text);

        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            s.selection_chars += 1;
            const c = g.text[0];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') s.selection_chars_no_ws += 1;
        }
        return s;
    }

    /// What a status-bar button does. The Notion entries only appear when the
    /// workspace is connected, so the set is built per frame.
    pub const Button = enum { trash, settings, notion_sync, notion_conflicts };

    pub const Item = struct {
        id: Button,
        label: []const u8,
        /// Amber, for the conflict badge.
        warn: bool = false,
        disabled: bool = false,
    };

    fn buttonRect(self: *const StatusBar, p: *const Painter, items: []const Item, index: usize) Rect {
        var x = self.rect.x + 6;
        for (items, 0..) |item, i| {
            const w: i32 = @intFromFloat(@ceil(p.measureRun(item.label, 4)) + 12);
            if (i == index) return .{ .x = x, .y = self.rect.y, .w = w, .h = self.rect.h };
            x += w + 4;
        }
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    pub fn hitTest(self: *const StatusBar, p: *const Painter, items: []const Item, px: i32, py: i32) ?Button {
        if (!self.rect.contains(px, py)) return null;
        for (items, 0..) |item, i| {
            if (item.disabled) continue;
            if (self.buttonRect(p, items, i).contains(px, py)) return item.id;
        }
        return null;
    }

    pub fn paint(self: *StatusBar, p: *Painter, status: ?Status, items: []const Item, hovered: ?Button) void {
        p.fill(self.rect, palette.bg_1);
        p.fill(.{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w, .h = 1 }, palette.bg_3);

        for (items, 0..) |item, i| {
            const r = self.buttonRect(p, items, i);
            const is_hovered = hovered != null and hovered.? == item.id and !item.disabled;
            if (is_hovered) p.fill(r, palette.bg_2);
            const fg = if (item.warn)
                palette.dirty
            else if (item.disabled)
                palette.fg_2.withAlpha(140)
            else if (is_hovered)
                palette.fg_0
            else
                palette.fg_2;
            p.drawLabel(r, item.label, fg, .center, .{});
        }

        if (status) |s| {
            var buf: [96]u8 = undefined;
            const text = if (s.selection_chars > 0)
                std.fmt.bufPrint(&buf, "{d} chars selected ({d} excl. whitespace)", .{
                    s.selection_chars, s.selection_chars_no_ws,
                }) catch return
            else
                std.fmt.bufPrint(&buf, "Ln {d}, Col {d}", .{ s.line + 1, s.col + 1 }) catch return;

            p.drawLabel(
                .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w - 10, .h = self.rect.h },
                text,
                palette.fg_2,
                .right,
                .{},
            );
        }
    }
};
