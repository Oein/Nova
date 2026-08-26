//! Overlays: the command palette, modal dialogs, settings, trash and toasts.
//!
//! Ported from `Spotlight.svelte`, `Settings.svelte`, `TrashPanel.svelte`,
//! `ConfirmClose.svelte`, `ConfirmDelete.svelte`, `ContextMenu.svelte` and
//! `Toast.svelte`.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");
const db = @import("db");
const net = @import("net");
const ev = @import("event.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Painter = gfx.Painter;
const palette = theme.palette;

/// Centre a panel of the given size in `within`, at the overlay's usual offset
/// from the top.
fn centeredPanel(within: Rect, w: i32, h: i32, top_ratio: f32) Rect {
    const x = within.x + @divTrunc(within.w - w, 2);
    const y = within.y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(within.h)) * top_ratio));
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// `border-radius` on the panels the original styled as floating cards.
const radius = struct {
    /// Settings and Spotlight.
    const panel: f32 = 8;
    /// Dialogs, the trash and conflict panels, the context menu, the toast.
    const dialog: f32 = 6;
    /// Buttons and inputs.
    const control: f32 = 4;
    /// Context-menu items and the small buttons in the trash panel.
    const item: f32 = 3;
};

fn paintPanel(p: *Painter, rect: Rect, backdrop: gfx.Rgba, within: Rect, r: f32) void {
    p.fill(within, backdrop);
    p.fillRound(rect, r, palette.bg_1);
    p.strokeRound(rect, r, 1, palette.bg_3);
}

// -- toast -------------------------------------------------------------------

pub const Toast = struct {
    gpa: Allocator,
    message: ?[]u8 = null,
    expires_ms: i64 = 0,

    pub fn init(gpa: Allocator) Toast {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Toast) void {
        if (self.message) |m| self.gpa.free(m);
    }

    pub fn show(self: *Toast, text: []const u8, now_ms: i64) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        if (self.message) |m| self.gpa.free(m);
        self.message = owned;
        self.expires_ms = now_ms + theme.toast_ms;
    }

    pub fn tick(self: *Toast, now_ms: i64) void {
        if (self.message != null and now_ms >= self.expires_ms) {
            self.gpa.free(self.message.?);
            self.message = null;
        }
    }

    pub fn paint(self: *Toast, p: *Painter, within: Rect) void {
        const msg = self.message orelse return;
        const w: i32 = @intFromFloat(@ceil(p.measureRun(msg, 4)) + 24);
        const rect = Rect{
            .x = within.right() - w - 16,
            .y = within.bottom() - 30 - 16,
            .w = w,
            .h = 30,
        };
        p.fillRound(rect, radius.dialog, palette.bg_2);
        p.strokeRound(rect, radius.dialog, 1, palette.bg_3);
        p.drawLabel(rect, msg, palette.fg_0, .center, .{});
    }
};

// -- confirmation dialogs ----------------------------------------------------

pub const Confirm = struct {
    pub const Kind = enum { close_unsaved, delete_notes };

    kind: Kind,
    title: []const u8,
    message: []const u8,
    /// Note ids the action applies to; borrowed from the caller.
    targets: []const []const u8 = &.{},

    pub const Answer = enum { cancel, confirm, discard };

    /// Buttons, left to right. `close_unsaved` offers three, matching
    /// `ConfirmClose.svelte`.
    pub fn buttons(self: Confirm) []const Button {
        return switch (self.kind) {
            .close_unsaved => &.{
                .{ .label = "Don't Save", .answer = .discard, .style = .plain },
                .{ .label = "Cancel", .answer = .cancel, .style = .plain },
                .{ .label = "Save", .answer = .confirm, .style = .primary },
            },
            .delete_notes => &.{
                .{ .label = "Cancel", .answer = .cancel, .style = .plain },
                .{ .label = "Move to Trash", .answer = .confirm, .style = .danger },
            },
        };
    }

    pub const ButtonStyle = enum { plain, primary, danger };
    pub const Button = struct { label: []const u8, answer: Answer, style: ButtonStyle };

    pub fn panelRect(within: Rect) Rect {
        return centeredPanel(within, @min(480, within.w - 40), 132, 0.3);
    }

    pub fn paint(self: Confirm, p: *Painter, within: Rect) void {
        const rect = panelRect(within);
        paintPanel(p, rect, palette.backdrop, within, radius.dialog);

        p.drawEllipsized(
            .{ .x = rect.x + 20, .y = rect.y + 16, .w = rect.w - 40, .h = 20 },
            self.title,
            palette.fg_0,
            .{ .weight = .bold },
        );
        p.drawEllipsized(
            .{ .x = rect.x + 20, .y = rect.y + 42, .w = rect.w - 40, .h = 20 },
            self.message,
            palette.fg_2,
            .{},
        );

        var x = rect.right() - 14;
        var i = self.buttons().len;
        while (i > 0) {
            i -= 1;
            const b = self.buttons()[i];
            const w: i32 = @intFromFloat(@ceil(p.measureRun(b.label, 4)) + 24);
            const br = Rect{ .x = x - w, .y = rect.bottom() - 44, .w = w, .h = 28 };
            paintButton(p, br, b.label, b.style);
            x -= w + 8;
        }
    }

    /// Which button a click hit.
    pub fn hitTest(self: Confirm, p: *const Painter, within: Rect, px: i32, py: i32) ?Answer {
        const rect = panelRect(within);
        var x = rect.right() - 14;
        var i = self.buttons().len;
        while (i > 0) {
            i -= 1;
            const b = self.buttons()[i];
            const w: i32 = @intFromFloat(@ceil(p.measureRun(b.label, 4)) + 24);
            const br = Rect{ .x = x - w, .y = rect.bottom() - 44, .w = w, .h = 28 };
            if (br.contains(px, py)) return b.answer;
            x -= w + 8;
        }
        return null;
    }
};

fn paintButton(p: *Painter, rect: Rect, label: []const u8, style: Confirm.ButtonStyle) void {
    const bg = switch (style) {
        .plain => palette.bg_2,
        .primary => palette.accent,
        .danger => palette.danger,
    };
    const fg = switch (style) {
        .plain => palette.fg_0,
        .primary, .danger => gfx.Rgba{ .r = 255, .g = 255, .b = 255 },
    };
    p.fillRound(rect, radius.control, bg);
    if (style == .plain) p.strokeRound(rect, radius.control, 1, palette.bg_3);
    p.drawLabel(rect, label, fg, .center, .{});
}

// -- context menu ------------------------------------------------------------

pub const ContextMenu = struct {
    pub const Item = struct {
        label: []const u8,
        action: Action,
        danger: bool = false,
        disabled: bool = false,
    };

    pub const Action = enum { reveal, delete };

    x: i32 = 0,
    y: i32 = 0,
    items: []const Item = &.{},
    open: bool = false,

    pub const item_h: i32 = 24;
    pub const min_w: i32 = 180;

    pub fn rect(self: ContextMenu, within: Rect) Rect {
        const h = @as(i32, @intCast(self.items.len)) * item_h + 8;
        // Clamped to the window, as the original measured and clamped.
        const x = @min(self.x, within.right() - min_w - 4);
        const y = @min(self.y, within.bottom() - h - 4);
        return .{ .x = @max(within.x, x), .y = @max(within.y, y), .w = min_w, .h = h };
    }

    pub fn paint(self: ContextMenu, p: *Painter, within: Rect) void {
        if (!self.open) return;
        const r = self.rect(within);
        p.fillRound(r, radius.dialog, palette.bg_1);
        p.strokeRound(r, radius.dialog, 1, palette.bg_3);

        var y = r.y + 4;
        for (self.items) |item| {
            const fg = if (item.disabled)
                palette.fg_2
            else if (item.danger)
                palette.danger
            else
                palette.fg_0;
            p.drawEllipsized(
                .{ .x = r.x + 10, .y = y, .w = r.w - 20, .h = item_h },
                item.label,
                fg,
                .{},
            );
            y += item_h;
        }
    }

    pub fn hitTest(self: ContextMenu, within: Rect, px: i32, py: i32) ?Item {
        if (!self.open) return null;
        const r = self.rect(within);
        if (!r.contains(px, py)) return null;
        const index = @divTrunc(py - r.y - 4, item_h);
        if (index < 0 or index >= self.items.len) return null;
        const item = self.items[@intCast(index)];
        return if (item.disabled) null else item;
    }
};

// -- spotlight ---------------------------------------------------------------

pub const Spotlight = struct {
    gpa: Allocator,
    open: bool = false,
    query: std.ArrayList(u8) = .empty,
    hits: []db.search.SearchHit = &.{},
    selected: usize = 0,
    /// When the debounced search fires.
    search_due_ms: ?i64 = null,
    searching: bool = false,

    pub fn init(gpa: Allocator) Spotlight {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Spotlight) void {
        self.clearHits();
        self.query.deinit(self.gpa);
    }

    pub fn clearHits(self: *Spotlight) void {
        if (self.hits.len > 0) db.search.freeHits(self.gpa, self.hits);
        self.hits = &.{};
    }

    pub fn show(self: *Spotlight) void {
        self.open = true;
        self.selected = 0;
    }

    pub fn hide(self: *Spotlight) void {
        self.open = false;
        self.query.clearRetainingCapacity();
        self.clearHits();
        self.search_due_ms = null;
    }

    pub fn typeText(self: *Spotlight, text: []const u8, now_ms: i64) !void {
        try self.query.appendSlice(self.gpa, text);
        self.search_due_ms = now_ms + theme.search_debounce_ms;
    }

    pub fn backspace(self: *Spotlight, now_ms: i64) void {
        if (self.query.items.len == 0) return;
        const start = core.grapheme.prev(self.query.items, self.query.items.len);
        self.query.shrinkRetainingCapacity(start);
        self.search_due_ms = now_ms + theme.search_debounce_ms;
    }

    /// Move the highlighted result, wrapping at both ends.
    pub fn move(self: *Spotlight, delta: i32) void {
        if (self.hits.len == 0) return;
        const n: i32 = @intCast(self.hits.len);
        const cur: i32 = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta + n, n));
    }

    pub fn setHits(self: *Spotlight, hits: []db.search.SearchHit) void {
        // The selection only resets when the query actually changed, so that an
        // IME commit re-firing the same search does not jump the highlight --
        // the bug fixed in `34a6ea1`.
        self.clearHits();
        self.hits = hits;
        if (self.selected >= hits.len) self.selected = 0;
    }

    pub fn panelRect(within: Rect) Rect {
        const w = @min(theme.spotlight_w, within.w - 40);
        const h = @min(@divTrunc(within.h * 6, 10), 420);
        return centeredPanel(within, w, h, theme.spotlight_top_ratio);
    }

    pub const row_h: i32 = 40;
    pub const input_h: i32 = 44;

    pub fn paint(self: *Spotlight, p: *Painter, within: Rect) void {
        if (!self.open) return;
        const rect = panelRect(within);
        paintPanel(p, rect, palette.backdrop_light, within, radius.panel);

        // Query line.
        const input = Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = input_h };
        if (self.query.items.len == 0) {
            p.drawLabel(input.inset(16), "Type to search titles and body.", palette.fg_2, .left, .{});
        } else {
            p.drawEllipsized(
                .{ .x = input.x + 16, .y = input.y, .w = input.w - 32, .h = input.h },
                self.query.items,
                palette.fg_0,
                .{},
            );
        }
        p.fill(.{ .x = rect.x, .y = rect.y + input_h, .w = rect.w, .h = 1 }, palette.bg_2);

        if (self.hits.len == 0) {
            const msg = if (self.searching) "Searching..." else if (self.query.items.len > 0) "No matches." else "";
            if (msg.len > 0) {
                p.drawLabel(
                    .{ .x = rect.x, .y = rect.y + input_h + 8, .w = rect.w, .h = 24 },
                    msg,
                    palette.fg_2,
                    .center,
                    .{},
                );
            }
            return;
        }

        const saved = p.pushClip(.{
            .x = rect.x,
            .y = rect.y + input_h + 1,
            .w = rect.w,
            .h = rect.h - input_h - 1,
        });
        defer p.popClip(saved);

        var y = rect.y + input_h + 1;
        for (self.hits, 0..) |hit, i| {
            if (y > rect.bottom()) break;
            const r = Rect{ .x = rect.x, .y = y, .w = rect.w, .h = row_h };
            const active = i == self.selected;
            if (active) p.fill(r, palette.accent);

            p.drawEllipsized(
                .{ .x = r.x + 16, .y = r.y + 2, .w = r.w - 32, .h = 18 },
                if (hit.title.len > 0) hit.title else "Untitled",
                if (active) gfx.Rgba{ .r = 255, .g = 255, .b = 255 } else palette.fg_0,
                .{},
            );
            if (hit.snippet) |s| self.paintSnippet(p, r, s, active);
            y += row_h;
        }
    }

    fn paintSnippet(self: *Spotlight, p: *Painter, r: Rect, s: db.search.SnippetParts, active: bool) void {
        _ = self;
        const fg = if (active) gfx.Rgba{ .r = 230, .g = 230, .b = 230 } else palette.fg_2;
        const saved = p.pushClip(.{ .x = r.x + 16, .y = r.y + 20, .w = r.w - 32, .h = 18 });
        defer p.popClip(saved);

        const baseline = @as(f64, @floatFromInt(r.y + 20)) + p.fonts.metrics.ascent * 0.9;
        var pen: f64 = @floatFromInt(r.x + 16);
        if (s.prefix_ellipsis) pen = p.drawRun(pen, baseline, "...", fg, .{});
        pen = p.drawRun(pen, baseline, s.before, fg, .{});

        // The match itself is highlighted, as `<mark>` was.
        const mark_w = p.measureRun(s.matched, 4);
        p.fill(.{
            .x = @intFromFloat(pen),
            .y = r.y + 20,
            .w = @intFromFloat(mark_w),
            .h = 16,
        }, palette.dirty.withAlpha(90));
        pen = p.drawRun(pen, baseline, s.matched, fg, .{});
        pen = p.drawRun(pen, baseline, s.after, fg, .{});
        if (s.suffix_ellipsis) _ = p.drawRun(pen, baseline, "...", fg, .{});
    }

    pub fn hitTest(self: *const Spotlight, within: Rect, px: i32, py: i32) ?usize {
        if (!self.open) return null;
        const rect = panelRect(within);
        if (!rect.contains(px, py)) return null;
        const index = @divTrunc(py - (rect.y + input_h + 1), row_h);
        if (index < 0 or index >= self.hits.len) return null;
        return @intCast(index);
    }
};

// -- trash panel -------------------------------------------------------------

pub const TrashPanel = struct {
    gpa: Allocator,
    open: bool = false,
    notes: []db.workspace.TrashedNote = &.{},

    pub fn init(gpa: Allocator) TrashPanel {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TrashPanel) void {
        self.clear();
    }

    pub fn clear(self: *TrashPanel) void {
        if (self.notes.len > 0) db.workspace.freeTrashedNotes(self.gpa, self.notes);
        self.notes = &.{};
    }

    pub fn setNotes(self: *TrashPanel, notes: []db.workspace.TrashedNote) void {
        self.clear();
        self.notes = notes;
    }

    pub const row_h: i32 = 36;

    pub fn panelRect(within: Rect) Rect {
        return centeredPanel(within, @min(560, within.w - 40), @min(@divTrunc(within.h * 7, 10), 460), 0.15);
    }

    /// Days remaining before a trashed note is purged.
    pub fn daysLeft(deleted_at_ms: i64, now_ms: i64) i64 {
        const deadline = deleted_at_ms + db.workspace.trash_retention_ms;
        const remaining = deadline - now_ms;
        if (remaining <= 0) return 0;
        return @divTrunc(remaining + std.time.ms_per_day - 1, std.time.ms_per_day);
    }

    pub fn paint(self: *TrashPanel, p: *Painter, within: Rect, now_ms: i64) void {
        if (!self.open) return;
        const rect = panelRect(within);
        paintPanel(p, rect, palette.backdrop, within, radius.dialog);

        p.drawLabel(
            .{ .x = rect.x + 14, .y = rect.y + 10, .w = rect.w - 28, .h = 20 },
            "Trash",
            palette.fg_0,
            .left,
            .{ .weight = .bold },
        );
        p.fill(.{ .x = rect.x, .y = rect.y + 36, .w = rect.w, .h = 1 }, palette.bg_3);

        if (self.notes.len == 0) {
            p.drawLabel(
                .{ .x = rect.x, .y = rect.y + 60, .w = rect.w, .h = 24 },
                "Trash is empty.",
                palette.fg_2,
                .center,
                .{},
            );
            return;
        }

        const saved = p.pushClip(.{ .x = rect.x, .y = rect.y + 37, .w = rect.w, .h = rect.h - 37 });
        defer p.popClip(saved);

        var y = rect.y + 44;
        for (self.notes) |note| {
            if (y > rect.bottom()) break;
            p.drawEllipsized(
                .{ .x = rect.x + 14, .y = y, .w = rect.w - 200, .h = 18 },
                if (note.title.len > 0) note.title else "Untitled",
                palette.fg_0,
                .{},
            );

            var buf: [48]u8 = undefined;
            const sub = std.fmt.bufPrint(&buf, "{d} days left", .{daysLeft(note.deleted_at_ms, now_ms)}) catch "";
            p.drawLabel(
                .{ .x = rect.x + 14, .y = y + 17, .w = rect.w - 200, .h = 14 },
                sub,
                palette.fg_2,
                .left,
                .{},
            );

            paintButton(p, .{ .x = rect.right() - 168, .y = y + 2, .w = 74, .h = 24 }, "Restore", .plain);
            paintButton(p, .{ .x = rect.right() - 86, .y = y + 2, .w = 72, .h = 24 }, "Delete", .danger);

            p.fill(.{ .x = rect.x + 8, .y = y + row_h - 2, .w = rect.w - 16, .h = 1 }, palette.bg_2);
            y += row_h;
        }
    }

    pub const Hit = union(enum) { none, restore: usize, purge: usize };

    pub fn hitTest(self: *const TrashPanel, within: Rect, px: i32, py: i32) Hit {
        if (!self.open) return .none;
        const rect = panelRect(within);
        const index = @divTrunc(py - (rect.y + 44), row_h);
        if (index < 0 or index >= self.notes.len) return .none;
        const i: usize = @intCast(index);
        if (px >= rect.right() - 168 and px < rect.right() - 94) return .{ .restore = i };
        if (px >= rect.right() - 86 and px < rect.right() - 14) return .{ .purge = i };
        return .none;
    }
};

// -- settings ----------------------------------------------------------------

pub const Settings = struct {
    open: bool = false,

    /// Which font files the program ended up drawing with.
    ///
    /// The stylesheet named families and let the OS choose; a native build has
    /// to guess at paths, and whether a guess landed is invisible from the
    /// outside -- Menlo standing in for SF Mono looks like a bug in the
    /// renderer rather than a font that was not found. So it is shown.
    pub const Faces = struct {
        ui: ?[]const u8,
        mono: ?[]const u8,
    };

    /// The interactive rows, in paint order.
    pub const Row = enum { autosave_enabled, autosave_interval, font_size };

    const row_y = [_]i32{ 76, 102, 180 };
    const row_h: i32 = 26;

    /// Where a row's value control sits, so a click can be routed to it.
    fn valueRect(within: Rect, r: Row) Rect {
        const rect = panelRect(within);
        return .{
            .x = rect.x + 146,
            .y = rect.y + row_y[@intFromEnum(r)],
            .w = rect.w - 162,
            .h = row_h,
        };
    }

    /// Which control a click hit, and whether it was the left or right half --
    /// used to decrement or increment the numeric settings.
    pub const Hit = struct { row: Row, increase: bool };

    pub fn hitTest(self: Settings, within: Rect, px: i32, py: i32) ?Hit {
        if (!self.open) return null;
        inline for (@typeInfo(Row).@"enum".fields) |f| {
            const r: Row = @enumFromInt(f.value);
            const vr = valueRect(within, r);
            if (vr.contains(px, py)) {
                return .{ .row = r, .increase = px > vr.x + @divTrunc(vr.w, 2) };
            }
        }
        return null;
    }

    pub fn panelRect(within: Rect) Rect {
        return centeredPanel(within, @min(480, within.w - 40), @min(@divTrunc(within.h * 7, 10), 360), 0.15);
    }

    pub fn paint(
        self: Settings,
        p: *Painter,
        within: Rect,
        autosave_enabled: bool,
        autosave_sec: u32,
        font_px: u32,
        faces: Faces,
    ) void {
        if (!self.open) return;
        const rect = panelRect(within);
        paintPanel(p, rect, palette.backdrop_light, within, radius.panel);

        p.drawLabel(
            .{ .x = rect.x + 16, .y = rect.y + 12, .w = rect.w - 32, .h = 22 },
            "Settings",
            palette.fg_0,
            .left,
            .{ .weight = .bold },
        );

        _ = section(p, rect, rect.y + 52, "AUTO-SAVE");

        var buf: [80]u8 = undefined;
        row(p, rect, .autosave_enabled, "Enabled", if (autosave_enabled) "on" else "off");
        row(
            p,
            rect,
            .autosave_interval,
            "Save every",
            std.fmt.bufPrint(&buf, "{d} seconds   - / +", .{autosave_sec}) catch "",
        );

        const hint = if (autosave_enabled)
            "Edited notes are written to disk on this interval."
        else
            "Auto-save is off. Use Cmd+S to save.";
        p.drawEllipsized(
            .{ .x = rect.x + 16, .y = rect.y + 132, .w = rect.w - 32, .h = 20 },
            hint,
            palette.fg_2,
            .{},
        );

        _ = section(p, rect, rect.y + 156, "EDITOR");
        var fbuf: [40]u8 = undefined;
        row(
            p,
            rect,
            .font_size,
            "Font size",
            std.fmt.bufPrint(&fbuf, "{d} px   - / +", .{font_px}) catch "",
        );

        _ = section(p, rect, rect.y + 216, "TYPEFACES");
        faceLine(p, rect, rect.y + 240, "Interface", faces.ui);
        faceLine(p, rect, rect.y + 260, "Note text", faces.mono);
    }

    fn faceLine(p: *Painter, rect: Rect, y: i32, label: []const u8, path: ?[]const u8) void {
        p.drawLabel(
            .{ .x = rect.x + 16, .y = y, .w = 120, .h = 18 },
            label,
            palette.fg_2,
            .left,
            .{ .family = .{ .px = 11 } },
        );
        const name = if (path) |path_| basename(path_) else "bundled";
        p.drawEllipsized(
            .{ .x = rect.x + 146, .y = y, .w = rect.w - 162, .h = 18 },
            name,
            palette.fg_1,
            .{ .family = .{ .px = 11 } },
        );
    }

    fn basename(path: []const u8) []const u8 {
        const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
        return path[cut + 1 ..];
    }

    fn section(p: *Painter, rect: Rect, y: i32, label: []const u8) i32 {
        p.drawLabel(.{ .x = rect.x + 16, .y = y, .w = rect.w - 32, .h = 18 }, label, palette.fg_2, .left, .{});
        return y + 24;
    }

    fn row(p: *Painter, rect: Rect, which: Row, label: []const u8, value: []const u8) void {
        const y = rect.y + row_y[@intFromEnum(which)];
        p.drawLabel(.{ .x = rect.x + 16, .y = y, .w = 120, .h = row_h }, label, palette.fg_1, .left, .{});

        const vr = Rect{ .x = rect.x + 146, .y = y, .w = rect.w - 162, .h = row_h };
        p.fillRound(vr, radius.control, palette.bg_0);
        p.strokeRound(vr, radius.control, 1, palette.bg_3);
        p.drawEllipsized(vr.inset(4), value, palette.fg_0, .{});
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "toast expires on its own" {
    var t = Toast.init(testing.allocator);
    defer t.deinit();

    t.show("Saved", 0);
    try testing.expectEqualStrings("Saved", t.message.?);
    t.tick(theme.toast_ms - 1);
    try testing.expect(t.message != null);
    t.tick(theme.toast_ms);
    try testing.expect(t.message == null);
}

test "a new toast replaces the old one" {
    var t = Toast.init(testing.allocator);
    defer t.deinit();
    t.show("first", 0);
    t.show("second", 100);
    try testing.expectEqualStrings("second", t.message.?);
}

test "the unsaved-changes dialog offers three answers" {
    const c = Confirm{
        .kind = .close_unsaved,
        .title = "Save changes?",
        .message = "Your changes will be lost.",
    };
    try testing.expectEqual(@as(usize, 3), c.buttons().len);
    try testing.expectEqual(Confirm.Answer.discard, c.buttons()[0].answer);
    try testing.expectEqual(Confirm.Answer.confirm, c.buttons()[2].answer);
}

test "spotlight query editing is grapheme-aware" {
    var s = Spotlight.init(testing.allocator);
    defer s.deinit();

    try s.typeText("안녕", 0);
    try testing.expectEqualStrings("안녕", s.query.items);
    // Backspace removes one syllable, not one byte.
    s.backspace(0);
    try testing.expectEqualStrings("안", s.query.items);
    s.backspace(0);
    try testing.expectEqualStrings("", s.query.items);
    s.backspace(0);
    try testing.expectEqualStrings("", s.query.items);
}

test "spotlight typing arms the debounce" {
    var s = Spotlight.init(testing.allocator);
    defer s.deinit();
    try testing.expect(s.search_due_ms == null);
    try s.typeText("a", 1000);
    try testing.expectEqual(@as(?i64, 1000 + theme.search_debounce_ms), s.search_due_ms);
}

test "spotlight selection wraps at both ends" {
    var s = Spotlight.init(testing.allocator);
    defer s.deinit();

    const hits = try testing.allocator.alloc(db.search.SearchHit, 3);
    for (hits, 0..) |*h, i| {
        h.* = .{
            .id = try std.fmt.allocPrint(testing.allocator, "n{d}", .{i}),
            .title = try testing.allocator.dupe(u8, "t"),
            .mtime_ms = 0,
            .score = 0,
            .snippet = null,
        };
    }
    s.setHits(hits);

    try testing.expectEqual(@as(usize, 0), s.selected);
    s.move(-1);
    try testing.expectEqual(@as(usize, 2), s.selected);
    s.move(1);
    try testing.expectEqual(@as(usize, 0), s.selected);
    s.move(2);
    try testing.expectEqual(@as(usize, 2), s.selected);
}

test "hiding the spotlight clears its state" {
    var s = Spotlight.init(testing.allocator);
    defer s.deinit();
    s.show();
    try s.typeText("query", 0);
    s.hide();
    try testing.expect(!s.open);
    try testing.expectEqual(@as(usize, 0), s.query.items.len);
    try testing.expect(s.search_due_ms == null);
}

test "trash retention counts down whole days" {
    const day = std.time.ms_per_day;
    try testing.expectEqual(@as(i64, 30), TrashPanel.daysLeft(0, 0));
    try testing.expectEqual(@as(i64, 1), TrashPanel.daysLeft(0, 29 * day));
    try testing.expectEqual(@as(i64, 0), TrashPanel.daysLeft(0, 30 * day));
    // Never negative.
    try testing.expectEqual(@as(i64, 0), TrashPanel.daysLeft(0, 90 * day));
}

test "the context menu is clamped into the window" {
    const menu = ContextMenu{
        .x = 900,
        .y = 700,
        .open = true,
        .items = &.{
            .{ .label = "Reveal", .action = .reveal },
            .{ .label = "Delete", .action = .delete, .danger = true },
        },
    };
    const within = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const r = menu.rect(within);
    try testing.expect(r.right() <= within.right());
    try testing.expect(r.bottom() <= within.bottom());
}

test "a disabled context-menu item is not selectable" {
    const menu = ContextMenu{
        .x = 10,
        .y = 10,
        .open = true,
        .items = &.{
            .{ .label = "Reveal", .action = .reveal, .disabled = true },
            .{ .label = "Delete", .action = .delete },
        },
    };
    const within = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const r = menu.rect(within);
    try testing.expect(menu.hitTest(within, r.x + 5, r.y + 6) == null);
    try testing.expectEqual(
        ContextMenu.Action.delete,
        menu.hitTest(within, r.x + 5, r.y + 6 + ContextMenu.item_h).?.action,
    );
}

// -- Notion conflicts --------------------------------------------------------

/// The conflict resolver.
///
/// Ported from `NotionConflicts.svelte`. Two panes show each side as it stood
/// when the conflict was detected, with differing lines highlighted, and the
/// available actions depend on *how* the two sides diverged.
pub const ConflictPanel = struct {
    gpa: Allocator,
    open: bool = false,
    items: []net.notion.store.Conflict = &.{},
    selected: usize = 0,
    detail: ?net.notion.store.ConflictDetail = null,
    /// A bulk policy the user picked but has not confirmed. Bulk resolution is
    /// not undoable, so it always asks first.
    pending_bulk: ?net.notion.resolve.BulkPolicy = null,

    pub fn init(gpa: Allocator) ConflictPanel {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ConflictPanel) void {
        self.clear();
    }

    pub fn clear(self: *ConflictPanel) void {
        if (self.items.len > 0) net.notion.store.freeConflicts(self.gpa, self.items);
        self.items = &.{};
        if (self.detail) |d| d.deinit(self.gpa);
        self.detail = null;
    }

    pub fn setItems(self: *ConflictPanel, items: []net.notion.store.Conflict) void {
        if (self.items.len > 0) net.notion.store.freeConflicts(self.gpa, self.items);
        self.items = items;
        if (self.selected >= items.len) self.selected = 0;
    }

    pub fn setDetail(self: *ConflictPanel, detail: ?net.notion.store.ConflictDetail) void {
        if (self.detail) |d| d.deinit(self.gpa);
        self.detail = detail;
    }

    pub fn current(self: *const ConflictPanel) ?net.notion.store.Conflict {
        if (self.selected >= self.items.len) return null;
        return self.items[self.selected];
    }

    /// A human label for a conflict kind.
    pub fn kindLabel(kind: []const u8) []const u8 {
        if (std.mem.eql(u8, kind, "remote-deleted")) return "Deleted in Notion";
        if (std.mem.eql(u8, kind, "local-deleted")) return "Deleted in Nova";
        return "Edited on both sides";
    }

    pub const Choice = struct {
        label: []const u8,
        resolution: net.notion.resolve.Resolution,
        danger: bool = false,
    };

    /// The actions that make sense for this conflict.
    pub fn choicesFor(kind: []const u8) []const Choice {
        if (std.mem.eql(u8, kind, "remote-deleted")) {
            return &.{
                .{ .label = "Recreate in Notion", .resolution = .recreate_remote },
                .{ .label = "Delete here too", .resolution = .accept_remote_delete, .danger = true },
            };
        }
        if (std.mem.eql(u8, kind, "local-deleted")) {
            return &.{
                .{ .label = "Restore in Nova", .resolution = .restore_local },
                .{ .label = "Delete in Notion too", .resolution = .accept_local_delete, .danger = true },
            };
        }
        return &.{
            .{ .label = "Keep Nova version", .resolution = .keep_local },
            .{ .label = "Use Notion version", .resolution = .keep_remote },
            .{ .label = "Keep both", .resolution = .keep_both },
        };
    }

    pub const BulkChoice = struct {
        policy: net.notion.resolve.BulkPolicy,
        label: []const u8,
        hint: []const u8,
    };

    pub const bulk_choices = [_]BulkChoice{
        .{
            .policy = .local,
            .label = "Keep Nova everywhere",
            .hint = "Nova's version wins; notes deleted in Notion are recreated there.",
        },
        .{
            .policy = .remote,
            .label = "Use Notion everywhere",
            .hint = "Notion's version wins, including its deletions.",
        },
        .{
            .policy = .both,
            .label = "Keep everything",
            .hint = "Nothing is discarded: differing pages are kept as a second note.",
        },
    };

    pub fn panelRect(within: Rect) Rect {
        return centeredPanel(
            within,
            @min(900, within.w - 40),
            @min(@divTrunc(within.h * 82, 100), 600),
            0.08,
        );
    }

    const list_w: i32 = 240;
    const row_h: i32 = 44;
    const bulk_h: i32 = 34;

    pub fn paint(self: *ConflictPanel, p: *Painter, within: Rect) void {
        if (!self.open) return;
        const rect = panelRect(within);
        paintPanel(p, rect, palette.backdrop, within, radius.dialog);

        p.drawLabel(
            .{ .x = rect.x + 14, .y = rect.y + 10, .w = rect.w - 28, .h = 20 },
            "Notion conflicts",
            palette.fg_0,
            .left,
            .{ .weight = .bold },
        );
        p.fill(.{ .x = rect.x, .y = rect.y + 36, .w = rect.w, .h = 1 }, palette.bg_3);

        if (self.items.len == 0) {
            p.drawLabel(
                .{ .x = rect.x, .y = rect.y + 70, .w = rect.w, .h = 24 },
                "No conflicts. Everything is in sync.",
                palette.fg_2,
                .center,
                .{},
            );
            return;
        }

        var body_top = rect.y + 37;
        if (self.items.len >= 2) body_top = self.paintBulkBar(p, rect, body_top);

        self.paintList(p, rect, body_top);
        self.paintDetail(p, rect, body_top);
    }

    fn paintBulkBar(self: *ConflictPanel, p: *Painter, rect: Rect, top: i32) i32 {
        const bar = Rect{ .x = rect.x, .y = top, .w = rect.w, .h = bulk_h };
        p.fill(bar, palette.bg_2);

        if (self.pending_bulk) |policy| {
            var buf: [96]u8 = undefined;
            const label = for (bulk_choices) |c| {
                if (c.policy == policy) break c.label;
            } else "";
            const text = std.fmt.bufPrint(
                &buf,
                "Apply \"{s}\" to all {d} conflicts?",
                .{ label, self.items.len },
            ) catch "";
            p.drawEllipsized(.{ .x = bar.x + 10, .y = bar.y, .w = bar.w - 210, .h = bar.h }, text, palette.fg_0, .{});
            paintButton(p, self.confirmRect(rect), "Apply to all", .danger);
            paintButton(p, self.cancelBulkRect(rect), "Cancel", .plain);
            return bar.bottom();
        }

        var x = bar.x + 10;
        for (bulk_choices) |c| {
            const w: i32 = @intFromFloat(@ceil(p.measureRun(c.label, 4)) + 20);
            paintButton(p, .{ .x = x, .y = bar.y + 4, .w = w, .h = bar.h - 8 }, c.label, .plain);
            x += w + 6;
        }
        return bar.bottom();
    }

    fn confirmRect(self: *const ConflictPanel, rect: Rect) Rect {
        _ = self;
        return .{ .x = rect.right() - 190, .y = rect.y + 41, .w = 110, .h = 24 };
    }

    fn cancelBulkRect(self: *const ConflictPanel, rect: Rect) Rect {
        _ = self;
        return .{ .x = rect.right() - 74, .y = rect.y + 41, .w = 62, .h = 24 };
    }

    fn paintList(self: *ConflictPanel, p: *Painter, rect: Rect, top: i32) void {
        const list = Rect{ .x = rect.x, .y = top, .w = list_w, .h = rect.bottom() - top };
        const saved = p.pushClip(list);
        defer p.popClip(saved);

        p.fill(.{ .x = list.right() - 1, .y = list.y, .w = 1, .h = list.h }, palette.bg_2);

        var y = list.y + 4;
        for (self.items, 0..) |item, i| {
            if (y > list.bottom()) break;
            const row = Rect{ .x = list.x + 4, .y = y, .w = list.w - 12, .h = row_h - 4 };
            if (i == self.selected) p.fill(row, palette.bg_2);

            p.drawEllipsized(
                .{ .x = row.x + 6, .y = row.y + 2, .w = row.w - 12, .h = 18 },
                if (item.title.len > 0) item.title else "Untitled",
                palette.fg_0,
                .{},
            );
            p.drawEllipsized(
                .{ .x = row.x + 6, .y = row.y + 20, .w = row.w - 12, .h = 16 },
                kindLabel(item.kind),
                palette.dirty,
                .{},
            );
            y += row_h;
        }
    }

    fn paintDetail(self: *ConflictPanel, p: *Painter, rect: Rect, top: i32) void {
        const area = Rect{
            .x = rect.x + list_w,
            .y = top,
            .w = rect.w - list_w,
            .h = rect.bottom() - top,
        };
        const saved = p.pushClip(area);
        defer p.popClip(saved);

        const detail = self.detail orelse return;
        const pane_w = @divTrunc(area.w - 30, 2);
        const pane_h = area.h - 60;

        self.paintPane(p, .{ .x = area.x + 10, .y = area.y + 8, .w = pane_w, .h = pane_h }, "In Nova", detail.local_content, detail.remote_content);
        self.paintPane(p, .{ .x = area.x + 20 + pane_w, .y = area.y + 8, .w = pane_w, .h = pane_h }, "In Notion", detail.remote_content, detail.local_content);

        // Actions.
        var x = area.x + 10;
        const y = area.bottom() - 44;
        for (choicesFor(detail.kind)) |choice| {
            const w: i32 = @intFromFloat(@ceil(p.measureRun(choice.label, 4)) + 22);
            paintButton(
                p,
                .{ .x = x, .y = y, .w = w, .h = 26 },
                choice.label,
                if (choice.danger) .danger else .plain,
            );
            x += w + 8;
        }

        p.drawLabel(
            .{ .x = area.x + 10, .y = area.bottom() - 16, .w = area.w - 20, .h = 14 },
            "Nothing changes until you choose. Until then this note is left out of syncing.",
            palette.fg_2,
            .left,
            .{},
        );
    }

    /// One side of the comparison, with lines the other side lacks highlighted.
    fn paintPane(
        self: *ConflictPanel,
        p: *Painter,
        rect: Rect,
        title: []const u8,
        content: ?[]const u8,
        other: ?[]const u8,
    ) void {
        _ = self;
        p.stroke(rect, palette.bg_3);
        const head = Rect{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = 20 };
        p.fill(head, palette.bg_2);
        p.drawLabel(.{ .x = head.x + 8, .y = head.y, .w = head.w - 16, .h = head.h }, title, palette.fg_1, .left, .{});

        const body = Rect{ .x = rect.x + 1, .y = head.bottom(), .w = rect.w - 2, .h = rect.bottom() - head.bottom() - 1 };
        const saved = p.pushClip(body);
        defer p.popClip(saved);

        const text = content orelse {
            p.drawLabel(body, "Deleted here.", palette.fg_2, .center, .{});
            return;
        };

        const row_height = p.fonts.metrics.row_height;
        var y: f64 = @floatFromInt(body.y + 4);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (y > @as(f64, @floatFromInt(body.bottom()))) break;
            // A line the other side does not contain is what changed.
            const differs = other == null or std.mem.indexOf(u8, other.?, line) == null;
            if (differs and line.len > 0) {
                p.fill(.{
                    .x = body.x,
                    .y = @intFromFloat(y),
                    .w = body.w,
                    .h = @intFromFloat(row_height),
                }, palette.dirty.withAlpha(40));
            }
            _ = p.drawRun(
                @floatFromInt(body.x + 6),
                y + p.fonts.metrics.ascent,
                line,
                if (differs) palette.fg_0 else palette.fg_1,
                .{},
            );
            y += row_height;
        }
    }

    pub const Hit = union(enum) {
        none,
        select: usize,
        choose: net.notion.resolve.Resolution,
        pick_bulk: net.notion.resolve.BulkPolicy,
        confirm_bulk,
        cancel_bulk,
        dismiss,
    };

    pub fn hitTest(self: *const ConflictPanel, p: *const Painter, within: Rect, px: i32, py: i32) Hit {
        if (!self.open) return .none;
        const rect = panelRect(within);
        if (!rect.contains(px, py)) return .dismiss;
        if (self.items.len == 0) return .none;

        var top = rect.y + 37;
        if (self.items.len >= 2) {
            if (self.pending_bulk != null) {
                if (self.confirmRect(rect).contains(px, py)) return .confirm_bulk;
                if (self.cancelBulkRect(rect).contains(px, py)) return .cancel_bulk;
            } else if (py >= top and py < top + bulk_h) {
                var x = rect.x + 10;
                for (bulk_choices) |c| {
                    const w: i32 = @intFromFloat(@ceil(p.measureRun(c.label, 4)) + 20);
                    if (px >= x and px < x + w) return .{ .pick_bulk = c.policy };
                    x += w + 6;
                }
                return .none;
            }
            top += bulk_h;
        }

        if (px < rect.x + list_w) {
            const index = @divTrunc(py - (top + 4), row_h);
            if (index < 0 or index >= self.items.len) return .none;
            return .{ .select = @intCast(index) };
        }

        const detail = self.detail orelse return .none;
        const area_bottom = rect.bottom();
        if (py >= area_bottom - 44 and py < area_bottom - 18) {
            var x = rect.x + list_w + 10;
            for (choicesFor(detail.kind)) |choice| {
                const w: i32 = @intFromFloat(@ceil(p.measureRun(choice.label, 4)) + 22);
                if (px >= x and px < x + w) return .{ .choose = choice.resolution };
                x += w + 8;
            }
        }
        return .none;
    }
};
