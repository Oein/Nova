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
const icons = @import("icons.zig");

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

    /// Where the pointer is, or null when it is outside the sidebar.
    ///
    /// Hover highlights are resolved during paint by testing each row's own
    /// rectangle. That keeps them exact -- the same rectangle that is drawn is
    /// the one that is tested -- without having to keep a row index in step
    /// with a list that changes under it.
    hover: ?struct { x: i32, y: i32 } = null,

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

    /// Height of the fixed chrome above the scrolling list: the button row,
    /// then the workspace path and its rule.
    pub const path_bar_h: i32 = 21;

    /// The scrolling list, below the header and the path bar.
    pub fn listRect(self: *const Sidebar) Rect {
        const top = self.rect.y + header_h + path_bar_h;
        return .{ .x = self.rect.x, .y = top, .w = self.rect.w, .h = @max(0, self.rect.bottom() - top) };
    }

    /// Total height of the note list, collapsed groups counted as their header
    /// alone.
    pub fn contentHeight(self: *const Sidebar, groups: []const app.datefmt.Group) i32 {
        var h: i32 = 0;
        for (groups) |*g| {
            h += theme.sidebar_group_h;
            if (self.isCollapsed(&g.key)) continue;
            h += @as(i32, @intCast(g.entries.len)) * theme.sidebar_row_h;
        }
        return h;
    }

    /// How far the list can scroll before it runs out of notes.
    ///
    /// Without this the list scrolls away into empty space and keeps going,
    /// which is what an unbounded `scroll_top` looks like from the outside.
    pub fn maxScroll(self: *const Sidebar, groups: []const app.datefmt.Group) f64 {
        const room = self.contentHeight(groups) - self.listRect().h;
        return if (room > 0) @floatFromInt(room) else 0;
    }

    pub fn clampScroll(self: *Sidebar, groups: []const app.datefmt.Group) void {
        self.scroll_top = std.math.clamp(self.scroll_top, 0, self.maxScroll(groups));
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
        // The list can shrink under a scrolled view -- a note is trashed, a
        // group is collapsed -- so the bound is re-applied here rather than
        // only where the wheel is handled.
        self.clampScroll(groups);

        const saved = p.pushClip(self.rect);
        defer p.popClip(saved);

        p.fill(self.rect, palette.bg_1);

        // Header: a new-note button and an open-folder button. Fixed, like the
        // path bar under it -- only the note list scrolls.
        const head = self.headerRect();
        p.fill(head, palette.bg_1);
        p.fill(.{ .x = head.x, .y = head.bottom() - 1, .w = head.w, .h = 1 }, palette.bg_3);
        p.drawLabel(self.newNoteRect(), "+", palette.fg_1, .center, .{});
        p.drawLabel(self.openFolderRect(), "Open...", palette.fg_1, .center, .{});

        if (workspace_path) |path| {
            const bar = Rect{ .x = self.rect.x, .y = head.bottom(), .w = self.rect.w, .h = 20 };
            p.drawEllipsized(bar.inset(6), path, palette.fg_2, .{});
            p.fill(.{ .x = bar.x, .y = bar.bottom(), .w = bar.w, .h = 1 }, palette.bg_2);
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

        // The list gets its own clip. Rows scrolled past the top would
        // otherwise keep drawing over the header, which never stops looking
        // like a bug.
        const list = self.listRect();
        const saved_list = p.pushClip(list);
        defer p.popClip(saved_list);

        var y = list.y - @as(i32, @intFromFloat(self.scroll_top));
        for (groups) |*g| {
            const collapsed = self.isCollapsed(&g.key);
            if (y + theme.sidebar_group_h > list.y) {
                self.paintGroupHeader(p, g, y, collapsed, now_ms);
            }
            y += theme.sidebar_group_h;
            if (collapsed) continue;

            for (g.entries) |note| {
                if (y > list.bottom()) return;
                if (y + theme.sidebar_row_h > list.y) {
                    self.paintNoteRow(p, note, y, active_id, dirty);
                }
                y += theme.sidebar_row_h;
            }
        }

        if (groups.len == 0) {
            p.drawLabel(
                .{ .x = list.x, .y = y + 8, .w = list.w, .h = 24 },
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
        if (self.hovers(rect)) p.fill(rect, palette.bg_2);

        // `.chev { width: 10px }`, at the row's 10px left padding.
        const chev = Rect{ .x = rect.x + 10, .y = rect.y + @divTrunc(rect.h - 10, 2), .w = 10, .h = 10 };
        p.drawIcon(chev, if (collapsed) icons.chevron_right else icons.chevron_down, palette.fg_2);

        var upper: [128]u8 = undefined;
        const label = uppercaseAscii(g.label(now_ms), &upper);

        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{g.count()}) catch "";

        // The count is a pill against the right edge; the label takes the rest.
        const count_opts = Painter.RunOptions{ .family = .{ .px = theme.sidebar_count_font_px } };
        const pill_w: i32 = @intFromFloat(@ceil(p.measureSpan(count, count_opts)) + 12);
        const pill = Rect{
            .x = rect.right() - 10 - pill_w,
            .y = rect.y + @divTrunc(rect.h - 14, 2),
            .w = pill_w,
            .h = 14,
        };
        if (count.len > 0) {
            p.fillRound(pill, 8, palette.bg_2);
            p.drawLabel(pill, count, palette.fg_2, .center, count_opts);
        }

        p.drawEllipsized(
            .{ .x = rect.x + 26, .y = rect.y, .w = pill.x - 6 - (rect.x + 26), .h = rect.h },
            label,
            palette.fg_1,
            .{ .family = .{ .px = theme.sidebar_group_font_px }, .tracking = 0.5 },
        );
    }

    /// `text-transform: uppercase`, for the ASCII the date labels are made of.
    /// Anything else is left alone, which is what the browser did with Hangul.
    fn uppercaseAscii(text: []const u8, buf: []u8) []const u8 {
        if (text.len > buf.len) return text;
        for (text, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
        return buf[0..text.len];
    }

    fn hovers(self: *const Sidebar, rect: Rect) bool {
        const h = self.hover orelse return false;
        return rect.contains(h.x, h.y);
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

        // Active wins over selected, which wins over hover, matching the CSS
        // source order.
        if (is_active) {
            p.fill(rect, palette.accent_dim);
        } else if (self.isSelected(note.id)) {
            p.fill(rect, palette.bg_3);
        } else if (self.hovers(rect)) {
            p.fill(rect, palette.bg_2);
        }

        // `padding: 3px 10px 3px 20px`.
        var x = rect.x + 20;
        if (dirty.contains(note.id)) {
            const dot = Rect{ .x = x, .y = y + @divTrunc(rect.h - 5, 2), .w = 5, .h = 5 };
            p.fillRound(dot, 2.5, palette.dirty);
            x += 5 + 6; // the dot, then `gap: 6px`
        }

        p.drawEllipsized(
            .{ .x = x, .y = rect.y, .w = rect.right() - x - 10, .h = rect.h },
            if (note.title.len > 0) note.title else "Untitled",
            if (is_active) palette.white else palette.fg_0,
            .{ .family = .{ .px = theme.sidebar_entry_font_px } },
        );
    }

    /// Which row a point falls on, walking the same layout `paint` uses.
    pub fn hitTest(self: *const Sidebar, groups: []const app.datefmt.Group, py: i32) ?Row {
        const list = self.listRect();
        if (py < list.y) return null;
        var y = list.y - @as(i32, @intFromFloat(self.scroll_top));
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
        /// The outline drawn to the left of the label. The original set one on
        /// every button except the conflict badge, which led with a warning
        /// sign instead.
        icon: ?[]const gfx.Segment = null,
        /// Amber, for the conflict badge.
        warn: bool = false,
        disabled: bool = false,
    };

    /// `footer { font-size: 11px }`.
    const label_opts = Painter.RunOptions{ .family = .{ .px = theme.status_font_px } };
    /// `.bar-btn { padding: 2px 6px; gap: 4px }` around a 12px icon.
    const btn_pad: i32 = 6;
    const btn_gap: i32 = 4;
    const icon_px: i32 = 12;

    fn buttonWidth(p: *Painter, item: Item) i32 {
        const text: i32 = @intFromFloat(@ceil(p.measureSpan(item.label, label_opts)));
        const lead: i32 = if (item.icon != null) icon_px + btn_gap else 0;
        return btn_pad + lead + text + btn_pad;
    }

    fn buttonRect(self: *const StatusBar, p: *Painter, items: []const Item, index: usize) Rect {
        // `.left { padding: 0 6px; gap: 2px }`.
        var x = self.rect.x + 6;
        const h: i32 = @min(self.rect.h - 4, 18);
        const y = self.rect.y + @divTrunc(self.rect.h - h, 2);
        for (items, 0..) |item, i| {
            const w = buttonWidth(p, item);
            if (i == index) return .{ .x = x, .y = y, .w = w, .h = h };
            x += w + 2;
        }
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    pub fn hitTest(self: *const StatusBar, p: *Painter, items: []const Item, px: i32, py: i32) ?Button {
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
            // `.bar-btn:hover { background: var(--bg-2); border-radius: 3px }`.
            if (is_hovered) p.fillRound(r, 3, palette.bg_2);

            const fg = if (item.warn)
                palette.dirty
            else if (item.disabled)
                palette.fg_2.withAlpha(140)
            else if (is_hovered)
                palette.fg_0
            else
                palette.fg_2;

            var x = r.x + btn_pad;
            if (item.icon) |segments| {
                p.drawIcon(.{
                    .x = x,
                    .y = r.y + @divTrunc(r.h - icon_px, 2),
                    .w = icon_px,
                    .h = icon_px,
                }, segments, fg);
                x += icon_px + btn_gap;
            }
            p.drawLabel(
                .{ .x = x, .y = r.y, .w = r.right() - btn_pad - x, .h = r.h },
                item.label,
                fg,
                .left,
                label_opts,
            );
        }

        if (status) |s| {
            var buf: [96]u8 = undefined;
            const text = if (s.selection_chars > 0)
                std.fmt.bufPrint(&buf, "{d} chars selected ({d} excl. whitespace)", .{
                    s.selection_chars, s.selection_chars_no_ws,
                }) catch return
            else
                std.fmt.bufPrint(&buf, "Ln {d}, Col {d}", .{ s.line + 1, s.col + 1 }) catch return;

            // `.right { font-family: var(--font-mono) }` -- monospace so the
            // digits stop shifting as the numbers change.
            p.drawLabel(
                .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w - 10, .h = self.rect.h },
                text,
                palette.fg_2,
                .right,
                .{ .family = .{ .kind = .mono, .px = theme.status_font_px } },
            );
        }
    }
};
