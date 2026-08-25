//! The text editor view.
//!
//! Ported from `src/lib/components/Editor.svelte` (1690 lines), minus every
//! workaround that existed only to fight WKWebView: the focus-retry loop, the
//! `document.fonts.ready` re-measure, `compositionend` preferring
//! `textarea.value`, and the deferred-Tab dance. What those produced -- an
//! inline underlined preedit, the candidate window anchored past it, the
//! selection dropped when composition starts -- is kept.
//!
//! The rendering model is the same: a virtualized list of visual rows, with
//! every coordinate computed on the monospace cell grid. The difference is that
//! the glyphs are now painted on that same grid instead of being laid out
//! independently by a browser.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");
const app = @import("app");
const ev = @import("event.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Painter = gfx.Painter;
const Pos = core.buffer.Pos;
const Selection = core.selection.Selection;
const Tab = app.state.Tab;
const palette = theme.palette;

pub const EditorView = struct {
    gpa: Allocator,
    fonts: *gfx.FontStack,

    /// Which note the current layout describes. A change means a full relayout.
    laid_out_for: ?[]const u8 = null,
    /// Soft-wrap starts, one entry per buffer line.
    wrap: std.ArrayList(core.wrap.Starts) = .empty,
    /// Visual-row prefix sums over `wrap`.
    rows: core.rowindex.RowIndex,
    /// Text column width the wrap was computed for.
    content_width: f64 = 0,

    viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scroll_top: f64 = 0,

    /// Pixel x remembered across consecutive vertical moves, so walking down
    /// past short lines returns to the original column.
    sticky_x: ?f64 = null,

    composing: bool = false,
    preedit: std.ArrayList(u8) = .empty,

    /// Drag state for text selection.
    dragging: bool = false,

    caret_phase_ms: i64 = 0,

    pub fn init(gpa: Allocator, fonts: *gfx.FontStack) EditorView {
        return .{ .gpa = gpa, .fonts = fonts, .rows = core.rowindex.RowIndex.init(gpa) };
    }

    pub fn deinit(self: *EditorView) void {
        self.clearWrap();
        self.wrap.deinit(self.gpa);
        self.rows.deinit();
        self.preedit.deinit(self.gpa);
        if (self.laid_out_for) |id| self.gpa.free(id);
    }

    fn clearWrap(self: *EditorView) void {
        for (self.wrap.items) |w| w.deinit(self.gpa);
        self.wrap.clearRetainingCapacity();
    }

    // -- layout --------------------------------------------------------------

    pub fn metrics(self: *const EditorView) core.wrap.Metrics {
        return .{
            .ch_width = self.fonts.metrics.ch_width,
            .cjk_width = self.fonts.metrics.cjk_width,
            .tab_size = theme.tab_size,
        };
    }

    pub fn rowHeight(self: *const EditorView) f64 {
        return self.fonts.metrics.row_height;
    }

    /// Gutter width, sized to the line count as the original did.
    pub fn gutterWidth(self: *const EditorView, line_count: usize) f64 {
        const digits: f64 = @floatFromInt(@max(2, digitCount(@max(1, line_count))));
        return @ceil(digits * self.fonts.metrics.ch_width + theme.gutter_pad);
    }

    fn digitCount(n: usize) usize {
        var d: usize = 1;
        var v = n;
        while (v >= 10) : (v /= 10) d += 1;
        return d;
    }

    pub fn contentLeft(self: *const EditorView, line_count: usize) f64 {
        return self.gutterWidth(line_count) + @as(f64, theme.gutter_gap);
    }

    /// Recompute every line's wrap. O(document); used on a font or width change
    /// and when switching tabs.
    pub fn relayout(self: *EditorView, tab: *Tab) !void {
        self.clearWrap();
        const m = self.metrics();
        var counts: std.ArrayList(u32) = .empty;
        defer counts.deinit(self.gpa);

        var i: usize = 0;
        while (i < tab.buffer.lineCount()) : (i += 1) {
            const starts = try core.wrap.computeStarts(
                self.gpa,
                tab.buffer.getLine(i),
                self.content_width,
                m,
            );
            try self.wrap.append(self.gpa, starts);
            try counts.append(self.gpa, @intCast(starts.rowCount()));
        }
        try self.rows.rebuild(counts.items);

        const id = try self.gpa.dupe(u8, tab.note_id);
        if (self.laid_out_for) |old| self.gpa.free(old);
        self.laid_out_for = id;
    }

    /// Apply a buffer change to the layout without touching untouched lines.
    ///
    /// The original derived the replaced range from the length delta because
    /// the change record's `toLine` was ambiguous (`Editor.svelte:244`); the
    /// Zig buffer reports the range exactly, so this just uses it.
    pub fn applyChange(self: *EditorView, tab: *Tab, change: core.buffer.Change) !void {
        switch (change) {
            .ready => try self.relayout(tab),
            .replace => |r| {
                if (r.from_line > self.wrap.items.len) return self.relayout(tab);

                const old_end = @min(r.to_line, self.wrap.items.len);
                const m = self.metrics();

                var fresh: std.ArrayList(core.wrap.Starts) = .empty;
                defer fresh.deinit(self.gpa);
                var counts: std.ArrayList(u32) = .empty;
                defer counts.deinit(self.gpa);

                var i: usize = 0;
                while (i < r.new_line_count) : (i += 1) {
                    const starts = try core.wrap.computeStarts(
                        self.gpa,
                        tab.buffer.getLine(r.from_line + i),
                        self.content_width,
                        m,
                    );
                    try fresh.append(self.gpa, starts);
                    try counts.append(self.gpa, @intCast(starts.rowCount()));
                }

                for (self.wrap.items[r.from_line..old_end]) |w| w.deinit(self.gpa);
                try self.wrap.replaceRange(self.gpa, r.from_line, old_end - r.from_line, fresh.items);
                fresh.clearRetainingCapacity();

                try self.rows.replaceRange(r.from_line, old_end - r.from_line, counts.items);
            },
        }
    }

    /// Set the area the editor occupies. Returns true if the wrap had to be
    /// recomputed, which happens when the text column width changed.
    pub fn setViewport(self: *EditorView, tab: *Tab, rect: Rect) !bool {
        self.viewport = rect;
        const left = self.contentLeft(tab.buffer.lineCount());
        // The 8px allowance mirrors the original's scrollbar fudge.
        const width = @max(20, @as(f64, @floatFromInt(rect.w)) - left - 8);
        if (@abs(width - self.content_width) < 0.01 and self.laid_out_for != null) return false;
        self.content_width = width;
        try self.relayout(tab);
        return true;
    }

    /// Ensure the layout matches `tab`; call before anything that reads it.
    pub fn sync(self: *EditorView, tab: *Tab) !void {
        const stale = self.laid_out_for == null or
            !std.mem.eql(u8, self.laid_out_for.?, tab.note_id) or
            self.wrap.items.len != tab.buffer.lineCount();
        if (stale) try self.relayout(tab);
    }

    pub fn totalRows(self: *const EditorView) u64 {
        return self.rows.totalRows();
    }

    pub fn contentHeight(self: *const EditorView) f64 {
        return @as(f64, @floatFromInt(self.rows.totalRows())) * self.rowHeight();
    }

    // -- coordinates ---------------------------------------------------------

    pub const Visual = struct { row: u64, x: f64 };

    /// Where a buffer position lands on screen, relative to the text origin.
    pub fn caretVisual(self: *EditorView, tab: *Tab, p: Pos) Visual {
        if (p.line >= self.wrap.items.len) return .{ .row = 0, .x = 0 };
        const line = tab.buffer.getLine(p.line);
        const starts = self.wrap.items[p.line];
        const sr = starts.subRowAt(p.col);
        const r = starts.rowRange(sr, line.len);
        // Measured from the sub-row start, so tab stops restart on each wrapped
        // row -- the original's behavior (`Editor.svelte:769`).
        const x = core.wrap.advanceTo(line[r.start..@min(p.col, line.len)], p.col - r.start, self.metrics());
        return .{ .row = self.rows.firstRow(p.line) + sr, .x = x };
    }

    /// The buffer position under a visual row and pixel x.
    pub fn posAtVisualRow(self: *EditorView, tab: *Tab, row: u64, x: f64) Pos {
        if (self.rows.len() == 0) return .{ .line = 0, .col = 0 };
        const clamped = @min(row, self.rows.totalRows() -| 1);
        const line = self.rows.lineAtRow(clamped);
        const sub = clamped - self.rows.firstRow(line);

        const text = tab.buffer.getLine(line);
        const starts = self.wrap.items[line];
        const sr = @min(sub, starts.rowCount() - 1);
        const r = starts.rowRange(@intCast(sr), text.len);
        const col = r.start + core.wrap.colFromPx(text[r.start..r.end], @max(0, x), self.metrics());
        return .{ .line = line, .col = col };
    }

    /// Map a window point to a buffer position.
    pub fn hitTest(self: *EditorView, tab: *Tab, px: i32, py: i32) Pos {
        const left = self.contentLeft(tab.buffer.lineCount());
        const y = @as(f64, @floatFromInt(py - self.viewport.y)) + self.scroll_top;
        const x = @as(f64, @floatFromInt(px - self.viewport.x)) - left;
        const row_h = self.rowHeight();
        const row: u64 = @intFromFloat(@max(0, @floor(y / row_h)));
        return self.posAtVisualRow(tab, row, x);
    }

    /// True when a point is over the gutter rather than the text.
    pub fn isInGutter(self: *EditorView, tab: *Tab, px: i32) bool {
        const rel: f64 = @floatFromInt(px - self.viewport.x);
        return rel < self.gutterWidth(tab.buffer.lineCount());
    }

    // -- scrolling -----------------------------------------------------------

    pub fn maxScroll(self: *const EditorView) f64 {
        return @max(0, self.contentHeight() - @as(f64, @floatFromInt(self.viewport.h)));
    }

    pub fn scrollTo(self: *EditorView, y: f64) void {
        self.scroll_top = std.math.clamp(y, 0, self.maxScroll());
    }

    /// Nudge the view just enough to show the caret -- no centering, matching
    /// `scrollCaretIntoView`.
    pub fn scrollCaretIntoView(self: *EditorView, tab: *Tab, p: Pos) void {
        const v = self.caretVisual(tab, p);
        const row_h = self.rowHeight();
        const y = @as(f64, @floatFromInt(v.row)) * row_h;
        const height: f64 = @floatFromInt(self.viewport.h);

        if (y < self.scroll_top) {
            self.scrollTo(y);
        } else if (y + row_h > self.scroll_top + height) {
            self.scrollTo(y + row_h - height);
        }
    }

    /// Centre a position in the viewport. Used when search reveals a match.
    pub fn scrollPosCentered(self: *EditorView, tab: *Tab, p: Pos) void {
        const v = self.caretVisual(tab, p);
        const row_h = self.rowHeight();
        const y = @as(f64, @floatFromInt(v.row)) * row_h;
        self.scrollTo(y - @as(f64, @floatFromInt(self.viewport.h)) / 2 + row_h / 2);
    }

    pub fn pageRows(self: *const EditorView) usize {
        const h: f64 = @floatFromInt(self.viewport.h);
        const n: i64 = @intFromFloat(@floor(h / self.rowHeight()) - 2);
        return @intCast(@max(5, n));
    }

    // -- editing -------------------------------------------------------------

    /// Run a command and keep the layout, caret and scroll in step.
    pub fn dispatch(self: *EditorView, tab: *Tab, cmd: core.commands.Command, now_ms: i64) !void {
        try self.sync(tab);

        // Vertical motion walks *visual* rows, not buffer lines, so it is
        // handled here rather than in `core.commands` -- which cannot see the
        // wrap. This is why the original intercepted it too (`:440`).
        switch (cmd) {
            .move => |m| if (m.by == .line) {
                return self.verticalMove(tab, if (m.dir == .back) -1 else 1, m.extend, 1);
            },
            .page => |m| {
                const rows: i64 = @intCast(m.page_lines);
                return self.verticalMove(tab, if (m.dir == .back) -rows else rows, m.extend, 1);
            },
            else => {},
        }

        tab.selection = try core.commands.apply(&tab.buffer, tab.selection, cmd, now_ms);
        for (tab.buffer.takeChanges()) |change| try self.applyChange(tab, change);
        tab.buffer.clearChanges();

        self.sticky_x = null;
        self.scrollCaretIntoView(tab, tab.selection.head);
    }

    fn verticalMove(self: *EditorView, tab: *Tab, delta: i64, extend: bool, count: i64) !void {
        const v = self.caretVisual(tab, tab.selection.head);
        const target_x = self.sticky_x orelse v.x;
        self.sticky_x = target_x;

        const total: i64 = @intCast(self.rows.totalRows());
        const want = @as(i64, @intCast(v.row)) + delta * count;
        const clamped: i64 = std.math.clamp(want, 0, @max(0, total - 1));

        var head = self.posAtVisualRow(tab, @intCast(clamped), target_x);
        // Moving past either end lands on the document edge, as the original did.
        if (want < 0) head = .{ .line = 0, .col = 0 };
        if (want >= total and total > 0) {
            const last = tab.buffer.lineCount() - 1;
            head = .{ .line = last, .col = tab.buffer.getLine(last).len };
        }

        tab.selection = .{ .anchor = if (extend) tab.selection.anchor else head, .head = head };
        self.scrollCaretIntoView(tab, head);
    }

    // -- painting ------------------------------------------------------------

    /// Which visual rows are worth drawing, with the original's overscan.
    fn visibleRows(self: *const EditorView) struct { first: u64, last: u64 } {
        const row_h = self.rowHeight();
        const total = self.rows.totalRows();
        const first_f = @floor(self.scroll_top / row_h) - theme.overscan_rows;
        const last_f = @ceil((self.scroll_top + @as(f64, @floatFromInt(self.viewport.h))) / row_h) +
            theme.overscan_rows;
        return .{
            .first = @intFromFloat(@max(0, first_f)),
            .last = @min(total, @as(u64, @intFromFloat(@max(0, last_f)))),
        };
    }

    pub fn paint(self: *EditorView, p: *Painter, tab: *Tab, focused: bool) !void {
        try self.sync(tab);

        const saved = p.pushClip(self.viewport);
        defer p.popClip(saved);

        p.fill(self.viewport, palette.bg_0);

        const row_h = self.rowHeight();
        const gutter_w = self.gutterWidth(tab.buffer.lineCount());
        const left = self.contentLeft(tab.buffer.lineCount());
        const origin_x = @as(f64, @floatFromInt(self.viewport.x)) + left;
        const range = self.visibleRows();

        // Gutter background runs the full height.
        p.fill(.{
            .x = self.viewport.x,
            .y = self.viewport.y,
            .w = @intFromFloat(gutter_w),
            .h = self.viewport.h,
        }, palette.bg_1);
        p.fill(.{
            .x = self.viewport.x + @as(i32, @intFromFloat(gutter_w)),
            .y = self.viewport.y,
            .w = 1,
            .h = self.viewport.h,
        }, palette.bg_2);

        try self.paintSelection(p, tab, range.first, range.last, origin_x, row_h);

        var row = range.first;
        while (row < range.last) : (row += 1) {
            const line_index = self.rows.lineAtRow(row);
            if (line_index >= self.wrap.items.len) break;
            const sub = row - self.rows.firstRow(line_index);
            const y = self.rowY(row);

            if (sub == 0) self.paintGutterNumber(p, line_index, y, gutter_w, row_h);

            const line = tab.buffer.getLine(line_index);
            const starts = self.wrap.items[line_index];
            if (sub >= starts.rowCount()) continue;
            const r = starts.rowRange(@intCast(sub), line.len);

            try self.paintRow(p, tab, line, line_index, r.start, r.end, origin_x, y);
        }

        if (focused) self.paintCaret(p, tab, origin_x, row_h);
    }

    fn rowY(self: *const EditorView, row: u64) f64 {
        return @as(f64, @floatFromInt(self.viewport.y)) +
            @as(f64, @floatFromInt(row)) * self.rowHeight() - self.scroll_top;
    }

    fn paintGutterNumber(
        self: *EditorView,
        p: *Painter,
        line_index: usize,
        y: f64,
        gutter_w: f64,
        row_h: f64,
    ) void {
        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{line_index + 1}) catch return;
        p.drawLabel(.{
            .x = self.viewport.x,
            .y = @intFromFloat(y),
            .w = @as(i32, @intFromFloat(gutter_w)) - 10,
            .h = @intFromFloat(row_h),
        }, text, palette.fg_2, .right, .{});
    }

    /// Paint one visual row's text, with markdown styling and any inline
    /// preedit.
    fn paintRow(
        self: *EditorView,
        p: *Painter,
        tab: *Tab,
        line: []const u8,
        line_index: usize,
        start: usize,
        end: usize,
        origin_x: f64,
        y: f64,
    ) !void {
        // Tokenizing the whole buffer line, not the sub-row, keeps `**bold**`
        // styled across a wrap boundary.
        const ranges = try core.markdown.tokenize(self.gpa, line);
        defer self.gpa.free(ranges);
        const toks = try core.markdown.tokensForSlice(self.gpa, ranges, line, start, end);
        defer self.gpa.free(toks);

        const baseline = y + self.fonts.metrics.ascent;
        const head = tab.selection.head;
        const preedit_here = self.composing and self.preedit.items.len > 0 and
            head.line == line_index and head.col >= start and head.col <= end;

        var pen = origin_x;
        if (!preedit_here) {
            for (toks) |t| pen = self.drawToken(p, pen, baseline, t);
            return;
        }

        // Split the row's tokens at the caret and drop the preedit into the gap,
        // underlined in the accent color -- the original's `.preedit-inline`.
        const split = try core.markdown.splitTokensAt(self.gpa, toks, head.col - start);
        defer self.gpa.free(split.before);
        defer self.gpa.free(split.after);

        for (split.before) |t| pen = self.drawToken(p, pen, baseline, t);
        pen = p.drawRun(pen, baseline, self.preedit.items, palette.accent, .{ .underline = true });
        for (split.after) |t| pen = self.drawToken(p, pen, baseline, t);
    }

    fn drawToken(self: *EditorView, p: *Painter, pen: f64, baseline: f64, t: core.markdown.Token) f64 {
        _ = self;
        return p.drawRun(pen, baseline, t.text, palette.fg_0, .{
            .weight = if (t.style.bold) .bold else .regular,
            .underline = t.style.underline,
            .strike = t.style.strike,
            .tab_size = theme.tab_size,
        });
    }

    fn paintSelection(
        self: *EditorView,
        p: *Painter,
        tab: *Tab,
        first: u64,
        last: u64,
        origin_x: f64,
        row_h: f64,
    ) !void {
        if (tab.selection.isEmpty()) return;
        const r = tab.selection.ordered();
        const m = self.metrics();

        var line = r.from.line;
        while (line <= r.to.line and line < self.wrap.items.len) : (line += 1) {
            const text = tab.buffer.getLine(line);
            const starts = self.wrap.items[line];

            for (0..starts.rowCount()) |sr| {
                const vr = self.rows.firstRow(line) + sr;
                if (vr < first or vr >= last) continue;

                const sub = starts.rowRange(sr, text.len);
                const sel_start = if (line == r.from.line) r.from.col else sub.start;
                const sel_end = if (line == r.to.line) r.to.col else sub.end;

                const s0 = @max(sub.start, sel_start);
                const s1 = @min(sub.end, @max(sub.start, sel_end));
                if (s1 < s0) continue;

                const x0 = core.wrap.advanceTo(text[sub.start..sub.end], s0 - sub.start, m);
                var x1 = core.wrap.advanceTo(text[sub.start..sub.end], s1 - sub.start, m);

                // A one-cell nub past the end of the line, so a multi-line
                // selection reads as continuous over blank tails.
                const continues = (line < r.to.line and sr == starts.rowCount() - 1) or
                    (line == r.to.line and r.to.col > sub.end);
                if (continues) x1 += self.fonts.metrics.ch_width;
                if (x1 <= x0) continue;

                p.fill(.{
                    .x = @intFromFloat(origin_x + x0),
                    .y = @intFromFloat(self.rowY(vr)),
                    .w = @intFromFloat(@max(1, x1 - x0)),
                    .h = @intFromFloat(row_h),
                }, palette.selection);
            }
        }
    }

    fn paintCaret(self: *EditorView, p: *Painter, tab: *Tab, origin_x: f64, row_h: f64) void {
        // Blink on a 1s square wave, as the original CSS animation did.
        const on = @mod(@divFloor(self.caret_phase_ms, theme.caret_blink_ms / 2), 2) == 0;
        if (!on and !self.composing) return;

        const v = self.caretVisual(tab, tab.selection.head);
        // During composition the caret sits after the preedit, which is also
        // where the IME candidate window is anchored.
        const extra = if (self.composing)
            core.wrap.advanceTo(self.preedit.items, self.preedit.items.len, self.metrics())
        else
            0;

        p.fill(.{
            .x = @intFromFloat(origin_x + v.x + extra),
            .y = @intFromFloat(self.rowY(v.row)),
            .w = theme.caret_w,
            .h = @intFromFloat(row_h),
        }, palette.fg_0);
    }

    /// Screen rect of the caret, for placing the IME candidate window.
    pub fn caretRect(self: *EditorView, tab: *Tab) Rect {
        const v = self.caretVisual(tab, tab.selection.head);
        const left = self.contentLeft(tab.buffer.lineCount());
        const extra = if (self.composing)
            core.wrap.advanceTo(self.preedit.items, self.preedit.items.len, self.metrics())
        else
            0;
        return .{
            .x = self.viewport.x + @as(i32, @intFromFloat(left + v.x + extra)),
            .y = @intFromFloat(self.rowY(v.row)),
            .w = theme.caret_w,
            .h = @intFromFloat(self.rowHeight()),
        };
    }

    // -- input ---------------------------------------------------------------

    /// Begin composition: the selection is dropped so the preedit appears in
    /// its place (recoverable with undo), matching `Editor.svelte:542`.
    pub fn imeStart(self: *EditorView, tab: *Tab, now_ms: i64) !void {
        self.composing = true;
        self.preedit.clearRetainingCapacity();
        if (!tab.selection.isEmpty()) {
            const r = tab.selection.ordered();
            try tab.buffer.applyEdit(.{ .delete = .{ .from = r.from, .to = r.to } }, now_ms);
            tab.selection = Selection.at(r.from);
            for (tab.buffer.takeChanges()) |change| try self.applyChange(tab, change);
            tab.buffer.clearChanges();
        }
    }

    pub fn imeUpdate(self: *EditorView, text: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(self.gpa, text);
    }

    pub fn imeEnd(self: *EditorView) void {
        self.composing = false;
        self.preedit.clearRetainingCapacity();
    }

    pub fn insertText(self: *EditorView, tab: *Tab, text: []const u8, now_ms: i64) !void {
        try self.dispatch(tab, .{ .insert = .{ .text = text } }, now_ms);
    }

    /// Word or line selection for a double click.
    pub fn selectAt(self: *EditorView, tab: *Tab, px: i32, py: i32, gutter: bool) !void {
        try self.sync(tab);
        const p = self.hitTest(tab, px, py);

        if (gutter) {
            // Select the whole line, including its trailing newline unless it
            // is the last.
            const end: Pos = if (p.line + 1 < tab.buffer.lineCount())
                .{ .line = p.line + 1, .col = 0 }
            else
                .{ .line = p.line, .col = tab.buffer.getLine(p.line).len };
            tab.selection = .{ .anchor = .{ .line = p.line, .col = 0 }, .head = end };
            return;
        }

        const line = tab.buffer.getLine(p.line);
        const r = core.word.wordAt(line, p.col);
        if (r.start == r.end) return;
        tab.selection = .{
            .anchor = .{ .line = p.line, .col = r.start },
            .head = .{ .line = p.line, .col = r.end },
        };
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const golden = @import("gfx").golden;

const Fixture = struct {
    env: @import("db").fsx.TestEnv,
    application: app.state.App,
    fonts: gfx.Fonts,
    surf: gfx.Surface,
    view: EditorView,
    root: []u8,
    gpa: Allocator,

    /// Heap-allocated because `EditorView` holds a pointer to `fonts`: a
    /// fixture returned by value would leave that pointer aimed at the dead
    /// stack frame of `init`.
    fn init(gpa: Allocator, name: []const u8, text: []const u8) !*Fixture {
        var env = try @import("db").fsx.TestEnv.init(gpa, name);
        errdefer env.deinit();
        const root = try std.fmt.allocPrint(gpa, "{s}/ws", .{env.path});
        errdefer gpa.free(root);

        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .env = env,
            .application = app.state.App.init(gpa, env.io),
            .fonts = try gfx.Fonts.initBundled(gpa, .{ .editor_px = 16 }),
            .surf = try gfx.Surface.init(gpa, 420, 200),
            .view = undefined,
            .root = root,
            .gpa = gpa,
        };
        self.view = EditorView.init(gpa, self.fonts.get(.{ .kind = .mono }));

        try self.application.openWorkspace(root);
        const i = try self.application.createAndOpenNote();
        if (text.len > 0) {
            const tab = &self.application.tabs.items[i];
            try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = text } }, 0);
            tab.buffer.clearChanges();
        }
        _ = try self.view.setViewport(self.firstTab(), .{ .x = 0, .y = 0, .w = 420, .h = 200 });
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.gpa;
        self.view.deinit();
        self.surf.deinit();
        self.fonts.deinit();
        self.application.deinit();
        gpa.free(self.root);
        self.env.deinit();
        gpa.destroy(self);
    }

    fn firstTab(self: *Fixture) *Tab {
        return &self.application.tabs.items[0];
    }

    fn painter(self: *Fixture) Painter {
        return Painter.init(&self.surf, &self.fonts);
    }
};

test "layout counts one visual row per short line" {
    const f = try Fixture.init(testing.allocator, "ed-layout", "one\ntwo\nthree");
    defer f.deinit();
    try f.view.sync(f.firstTab());
    try testing.expectEqual(@as(u64, 3), f.view.totalRows());
}

test "a long line wraps into several visual rows" {
    const f = try Fixture.init(testing.allocator, "ed-wrap", "");
    defer f.deinit();

    const tab = f.firstTab();
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..300) |_| try long.append(testing.allocator, 'a');
    try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = long.items } }, 0);
    tab.buffer.clearChanges();

    try f.view.relayout(tab);
    try testing.expect(f.view.totalRows() > 3);
}

test "an edit relayouts only the touched lines" {
    const f = try Fixture.init(testing.allocator, "ed-incremental", "a\nb\nc");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    // Splitting line 1 adds a row.
    try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 1, .col = 0 }, .text = "x\ny" } }, 0);
    for (tab.buffer.takeChanges()) |c| try f.view.applyChange(tab, c);
    tab.buffer.clearChanges();

    try testing.expectEqual(@as(usize, 4), f.view.wrap.items.len);
    try testing.expectEqual(@as(u64, 4), f.view.totalRows());
}

test "caretVisual and hitTest are inverses" {
    const f = try Fixture.init(testing.allocator, "ed-hit", "ab안녕cd\nsecond line");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    const left = f.view.contentLeft(tab.buffer.lineCount());
    for ([_]Pos{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 2 },
        .{ .line = 0, .col = 8 }, // after 안녕
        .{ .line = 1, .col = 6 },
    }) |p| {
        const v = f.view.caretVisual(tab, p);
        const px: i32 = @intFromFloat(left + v.x + 1);
        const py: i32 = @intFromFloat(@as(f64, @floatFromInt(v.row)) * f.view.rowHeight() + 1);
        const back = f.view.hitTest(tab, px, py);
        try testing.expectEqual(p.line, back.line);
        try testing.expectEqual(p.col, back.col);
    }
}

test "clicking past the end of a line lands at its end" {
    const f = try Fixture.init(testing.allocator, "ed-past-eol", "short\nlonger line here");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    const p = f.view.hitTest(tab, 400, 1);
    try testing.expectEqual(@as(usize, 0), p.line);
    try testing.expectEqual(@as(usize, 5), p.col);
}

test "the gutter is hit-tested separately from the text" {
    const f = try Fixture.init(testing.allocator, "ed-gutter", "a\nb");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);
    try testing.expect(f.view.isInGutter(tab, 2));
    try testing.expect(!f.view.isInGutter(tab, 300));
}

test "vertical movement keeps a sticky column" {
    const f = try Fixture.init(testing.allocator, "ed-sticky", "aaaaaaaaaa\nbb\ncccccccccc");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    tab.selection = Selection.at(.{ .line = 0, .col = 8 });
    const down = core.commands.Command{ .move = .{ .by = .line, .dir = .fwd, .extend = false } };

    // Line 1 is short, so the caret clamps to its end...
    try f.view.dispatch(tab, down, 0);
    try testing.expectEqual(@as(usize, 1), tab.selection.head.line);
    try testing.expectEqual(@as(usize, 2), tab.selection.head.col);

    // ...and continuing down returns to the remembered column.
    try f.view.dispatch(tab, down, 0);
    try testing.expectEqual(@as(usize, 2), tab.selection.head.line);
    try testing.expectEqual(@as(usize, 8), tab.selection.head.col);
}

test "a horizontal move clears the sticky column" {
    const f = try Fixture.init(testing.allocator, "ed-sticky-clear", "aaaaaaaaaa\nbb\ncccccccccc");
    defer f.deinit();
    const tab = f.firstTab();
    tab.selection = Selection.at(.{ .line = 0, .col = 8 });

    try f.view.dispatch(tab, .{ .move = .{ .by = .line, .dir = .fwd, .extend = false } }, 0);
    try f.view.dispatch(tab, .{ .move = .{ .by = .char, .dir = .back, .extend = false } }, 0);
    try testing.expect(f.view.sticky_x == null);

    try f.view.dispatch(tab, .{ .move = .{ .by = .line, .dir = .fwd, .extend = false } }, 0);
    // Now the column comes from where the caret actually was, not from before.
    try testing.expectEqual(@as(usize, 1), tab.selection.head.col);
}

test "vertical movement walks visual rows, not buffer lines" {
    const f = try Fixture.init(testing.allocator, "ed-visual-rows", "");
    defer f.deinit();
    const tab = f.firstTab();

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..200) |_| try long.append(testing.allocator, 'x');
    try long.appendSlice(testing.allocator, "\nnext");
    try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = long.items } }, 0);
    tab.buffer.clearChanges();
    try f.view.relayout(tab);

    tab.selection = Selection.at(.{ .line = 0, .col = 0 });
    try f.view.dispatch(tab, .{ .move = .{ .by = .line, .dir = .fwd, .extend = false } }, 0);

    // One "down" must stay inside the wrapped first line.
    try testing.expectEqual(@as(usize, 0), tab.selection.head.line);
    try testing.expect(tab.selection.head.col > 0);
}

test "the caret is scrolled into view" {
    const f = try Fixture.init(testing.allocator, "ed-scroll", "");
    defer f.deinit();
    const tab = f.firstTab();

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        try many.appendSlice(testing.allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    try tab.buffer.applyEdit(.{ .insert = .{ .at = .{ .line = 0, .col = 0 }, .text = many.items } }, 0);
    tab.buffer.clearChanges();
    try f.view.relayout(tab);

    try testing.expectEqual(@as(f64, 0), f.view.scroll_top);
    tab.selection = Selection.at(.{ .line = 90, .col = 0 });
    f.view.scrollCaretIntoView(tab, tab.selection.head);
    try testing.expect(f.view.scroll_top > 0);

    // Scrolling back to the top follows the caret up again.
    tab.selection = Selection.at(.{ .line = 0, .col = 0 });
    f.view.scrollCaretIntoView(tab, tab.selection.head);
    try testing.expectEqual(@as(f64, 0), f.view.scroll_top);
}

test "scrolling is clamped to the document" {
    const f = try Fixture.init(testing.allocator, "ed-clamp", "a\nb\nc");
    defer f.deinit();
    try f.view.sync(f.firstTab());

    f.view.scrollTo(-100);
    try testing.expectEqual(@as(f64, 0), f.view.scroll_top);
    f.view.scrollTo(99999);
    try testing.expectEqual(f.view.maxScroll(), f.view.scroll_top);
}

test "composition drops the selection and shows the preedit" {
    const f = try Fixture.init(testing.allocator, "ed-ime", "hello world");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    tab.selection = .{ .anchor = .{ .line = 0, .col = 0 }, .head = .{ .line = 0, .col = 5 } };
    try f.view.imeStart(tab, 0);

    const text = try tab.buffer.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(" world", text);
    try testing.expect(tab.selection.isEmpty());

    try f.view.imeUpdate("한");
    try testing.expectEqualStrings("한", f.view.preedit.items);

    // The caret rect sits past the composing text, where the candidate window
    // is anchored.
    const with_preedit = f.view.caretRect(tab);
    f.view.imeEnd();
    const without = f.view.caretRect(tab);
    try testing.expect(with_preedit.x > without.x);
}

test "a Korean commit lands in the buffer" {
    // e2e scenario 04: compositionstart / update / update / end.
    const f = try Fixture.init(testing.allocator, "ed-hangul", "");
    defer f.deinit();
    const tab = f.firstTab();

    try f.view.imeStart(tab, 0);
    try f.view.imeUpdate("ㅎ");
    try f.view.imeUpdate("한");
    f.view.imeEnd();
    try f.view.insertText(tab, "한글", 0);

    const text = try tab.buffer.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("한글", text);
}

test "double click selects a word, and the gutter selects a line" {
    const f = try Fixture.init(testing.allocator, "ed-dblclick", "foo bar baz\nsecond");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    const left = f.view.contentLeft(tab.buffer.lineCount());
    const m = f.view.metrics();
    const x = left + core.wrap.advanceTo("foo bar baz", 5, m);
    try f.view.selectAt(tab, @intFromFloat(x), 1, false);
    try testing.expectEqual(@as(usize, 4), tab.selection.anchor.col);
    try testing.expectEqual(@as(usize, 7), tab.selection.head.col);

    try f.view.selectAt(tab, 2, 1, true);
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, tab.selection.anchor);
    try testing.expectEqual(Pos{ .line = 1, .col = 0 }, tab.selection.head);
}

test "golden: a full editor pane with gutter, selection and caret" {
    const f = try Fixture.init(testing.allocator, "ed-golden", "# 회의록\n\n안녕하세요 반갑습니다\n\tindented line\nplain **bold** tail");
    defer f.deinit();
    const tab = f.firstTab();
    try f.view.sync(tab);

    tab.selection = .{ .anchor = .{ .line = 2, .col = 0 }, .head = .{ .line = 2, .col = 15 } };
    f.view.caret_phase_ms = 0;

    var p = f.painter();
    p.clear(palette.bg_0);
    try f.view.paint(&p, tab, true);

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "editor-pane", &f.surf);
}
