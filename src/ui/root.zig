//! The root view: layout, event routing and the global keymap.
//!
//! Ported from `src/App.svelte`. Everything the window shows hangs off here,
//! and nothing here knows that SDL exists -- events come in as `event.Event`,
//! and anything needing the window system goes out through `Outbox`.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");
const app = @import("app");
const db = @import("db");
const platform = @import("platform");
const net = @import("net");

const ev = @import("event.zig");
const theme = @import("theme.zig");
const chrome = @import("chrome.zig");
const icons = @import("icons.zig");
const overlays = @import("overlays.zig");
const editor_view = @import("editor_view.zig");
const find_mod = @import("find.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Painter = gfx.Painter;
const palette = theme.palette;

pub const Root = struct {
    gpa: Allocator,
    io: std.Io,

    application: app.state.App,
    fonts: gfx.Fonts,
    surface: gfx.Surface,
    outbox: ev.Outbox,

    editor: editor_view.EditorView = undefined,
    sidebar: chrome.Sidebar,
    tabbar: chrome.TabBar = .{},
    statusbar: chrome.StatusBar = .{},
    find: find_mod.Find,
    spotlight: overlays.Spotlight,
    trash: overlays.TrashPanel,
    settings: overlays.Settings = .{},
    toast: overlays.Toast,
    context_menu: overlays.ContextMenu = .{},

    /// Notion sync: the schedule, the last known config, and the resolver UI.
    notion: app.notion.Scheduler,
    notion_cfg: ?net.notion.store.Config = null,
    conflicts: overlays.ConflictPanel,
    conflict_count: i64 = 0,
    /// Stable storage for the conflict badge's text, which outlives the frame
    /// scratch the items array is built in.
    conflict_label_buf: [24]u8 = @splat(0),

    confirm: ?overlays.Confirm = null,
    /// Storage backing the pending confirmation's strings.
    confirm_arena: std.heap.ArenaAllocator,
    confirm_targets: std.ArrayList([]const u8) = .empty,
    /// Tab index the close confirmation refers to.
    confirm_tab: ?usize = null,

    width: u32 = 1200,
    height: u32 = 800,
    sidebar_width: i32 = theme.sidebar_default_w,
    sidebar_collapsed: bool = false,
    peeking: bool = false,
    resizing: bool = false,
    editor_font_px: u32 = theme.editor_font_default,

    /// Set whenever something visible changed.
    needs_paint: bool = true,
    now_ms: i64 = 0,
    mouse_down_in_editor: bool = false,
    status_hover: ?chrome.StatusBar.Button = null,
    /// When a fractional wheel delta was last seen. See `handleWheel`.
    precise_wheel_ms: ?i64 = null,

    /// Scratch for the grouped note list, rebuilt each paint.
    groups: std.ArrayList(app.datefmt.Group) = .empty,
    visible_ids: std.ArrayList([]const u8) = .empty,

    pub const Options = struct {
        /// Device pixels per logical unit; see `gfx.Painter.scale`.
        scale: f32 = 1,
        /// Draw with the platform's own faces. Tests turn this off: a golden
        /// image compared byte for byte must not depend on which fonts the
        /// machine running it happens to have installed.
        system_fonts: bool = true,
    };

    /// A logical extent in device pixels.
    fn devicePx(v: u32, scale: f32) u32 {
        const px = @round(@as(f32, @floatFromInt(v)) * scale);
        return @intFromFloat(@max(px, 1));
    }

    pub fn init(gpa: Allocator, io: std.Io, width: u32, height: u32, opts: Options) !Root {
        const self = Root{
            .gpa = gpa,
            .io = io,
            .application = app.state.App.init(gpa, io),
            .fonts = try gfx.Fonts.init(gpa, io, .{
                .ui_px = theme.ui_font_px,
                .editor_px = theme.editor_font_default,
                .system = opts.system_fonts,
                .scale = opts.scale,
            }),
            .surface = try gfx.Surface.init(gpa, devicePx(width, opts.scale), devicePx(height, opts.scale)),
            .outbox = ev.Outbox.init(gpa),
            .sidebar = chrome.Sidebar.init(gpa),
            .find = find_mod.Find.init(gpa),
            .spotlight = overlays.Spotlight.init(gpa),
            .trash = overlays.TrashPanel.init(gpa),
            .toast = overlays.Toast.init(gpa),
            .notion = app.notion.Scheduler.init(gpa, io),
            .conflicts = overlays.ConflictPanel.init(gpa),
            .confirm_arena = std.heap.ArenaAllocator.init(gpa),
            .width = width,
            .height = height,
        };
        // `editor` holds a pointer to `fonts`, so it can only be built once the
        // Root is at its final address; `attach` does that.
        return self;
    }

    /// Finish construction. Must be called once the Root is where it will live.
    pub fn attach(self: *Root) void {
        self.editor = editor_view.EditorView.init(self.gpa, self.fonts.get(.{ .kind = .mono }));
    }

    pub fn deinit(self: *Root) void {
        self.editor.deinit();
        self.sidebar.deinit();
        self.find.deinit();
        self.spotlight.deinit();
        self.trash.deinit();
        self.toast.deinit();
        self.notion.deinit();
        self.conflicts.deinit();
        if (self.notion_cfg) |cfg| cfg.deinit(self.gpa);
        self.confirm_targets.deinit(self.gpa);
        self.confirm_arena.deinit();
        self.groups.deinit(self.gpa);
        self.visible_ids.deinit(self.gpa);
        self.outbox.deinit();
        self.surface.deinit();
        self.fonts.deinit();
        self.application.deinit();
    }

    fn activeTab(self: *Root) ?*app.state.Tab {
        return self.application.activeTab();
    }

    fn invalidate(self: *Root) void {
        self.needs_paint = true;
    }

    // -- layout --------------------------------------------------------------

    pub fn bounds(self: *const Root) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    fn sidebarRect(self: *const Root) Rect {
        const w = if (self.sidebar_collapsed and !self.peeking) 0 else self.sidebar_width;
        return .{ .x = 0, .y = 0, .w = w, .h = @as(i32, @intCast(self.height)) - theme.statusbar_h };
    }

    fn resizerRect(self: *const Root) Rect {
        const s = self.sidebarRect();
        return .{ .x = s.w, .y = 0, .w = theme.resizer_w, .h = s.h };
    }

    fn paneRect(self: *const Root) Rect {
        // When peeking, the sidebar floats over the pane rather than pushing it.
        const left = if (self.sidebar_collapsed) 0 else self.sidebar_width + theme.resizer_w;
        return .{
            .x = left,
            .y = 0,
            .w = @as(i32, @intCast(self.width)) - left,
            .h = @as(i32, @intCast(self.height)) - theme.statusbar_h,
        };
    }

    fn tabBarRect(self: *const Root) Rect {
        const pane = self.paneRect();
        return .{ .x = pane.x, .y = pane.y, .w = pane.w, .h = theme.tabbar_h };
    }

    fn editorRect(self: *const Root) Rect {
        const pane = self.paneRect();
        const top = if (self.application.tabs.items.len > 0) theme.tabbar_h else 0;
        return .{ .x = pane.x, .y = pane.y + top, .w = pane.w, .h = pane.h - top };
    }

    fn statusRect(self: *const Root) Rect {
        return .{
            .x = 0,
            .y = @as(i32, @intCast(self.height)) - theme.statusbar_h,
            .w = @intCast(self.width),
            .h = theme.statusbar_h,
        };
    }

    fn applyLayout(self: *Root) !void {
        self.sidebar.rect = self.sidebarRect();
        self.tabbar.rect = self.tabBarRect();
        self.statusbar.rect = self.statusRect();
        if (self.activeTab()) |tab| {
            _ = try self.editor.setViewport(tab, self.editorRect());
        }
    }

    /// True while a modal is up and should swallow input.
    fn modalOpen(self: *const Root) bool {
        return self.confirm != null or self.spotlight.open or
            self.trash.open or self.settings.open or self.conflicts.open;
    }

    // -- events --------------------------------------------------------------

    pub fn handle(self: *Root, e: ev.Event) !void {
        switch (e) {
            .tick => |now| {
                self.now_ms = now;
                self.toast.tick(now);
                if (try self.application.tick(now)) self.invalidate();
                try self.tickSpotlight(now);
                try self.tickNotion(now);
                self.editor.caret_phase_ms = now;
                if (self.activeTab() != null) self.invalidate();
            },
            .resize => |r| {
                if (r.scale != self.fonts.scale) try self.fonts.setScale(r.scale);
                self.width = r.width;
                self.height = r.height;
                try self.surface.resize(
                    devicePx(r.width, r.scale),
                    devicePx(r.height, r.scale),
                );
                try self.applyLayout();
                self.invalidate();
            },
            .menu => |action| try self.handleMenu(action),
            .key_down => |k| try self.handleKey(k.key, k.mods),
            .text_input => |text| try self.handleText(text),
            .ime_start => {
                if (self.activeTab()) |tab| try self.editor.imeStart(tab, self.now_ms);
                self.invalidate();
            },
            .ime_preedit => |pre| {
                // SDL has no separate composition-start event: the first
                // non-empty preedit *is* the start. Without this the view
                // never enters composing state, and the preedit is drawn as
                // ordinary text instead of underlined in the accent color.
                if (!self.editor.composing) {
                    if (self.activeTab()) |tab| try self.editor.imeStart(tab, self.now_ms);
                }
                try self.editor.imeUpdate(pre.text);
                self.sendImeArea();
                self.invalidate();
            },
            .ime_end => {
                self.editor.imeEnd();
                self.invalidate();
            },
            .mouse_down => |m| try self.handleMouseDown(m.x, m.y, m.button, m.clicks, m.mods),
            .mouse_up => |m| {
                _ = m;
                self.resizing = false;
                self.mouse_down_in_editor = false;
                self.editor.dragging = false;
            },
            .mouse_move => |m| try self.handleMouseMove(m.x, m.y),
            .wheel => |w| try self.handleWheel(w.x, w.y, w.dy),
            .clipboard => |text| try self.handleText(text),
            .folder_picked => |path| {
                try self.application.openWorkspace(path);
                try self.applyLayout();
                try self.refreshNotionConfig();
                try self.notion.workspaceOpened(path, self.now_ms);
                self.toast.show("Workspace opened", self.now_ms);
                self.invalidate();
            },
            .focus_lost => {},
        }
    }

    fn handleText(self: *Root, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.spotlight.open) {
            try self.spotlight.typeText(text, self.now_ms);
            self.invalidate();
            return;
        }
        if (self.find.open) {
            if (self.activeTab()) |tab| try self.find.typeText(tab, text);
            self.invalidate();
            return;
        }
        if (self.modalOpen()) return;

        const tab = self.activeTab() orelse return;
        const index = self.application.active.?;
        try self.editor.insertText(tab, text, self.now_ms);
        try self.application.noteEdited(index, self.now_ms);
        self.sendImeArea();
        self.invalidate();
    }

    fn handleKey(self: *Root, key: ev.Key, mods: ev.Mods) !void {
        if (try self.handleGlobalKey(key, mods)) return;
        if (self.confirm != null) return self.handleConfirmKey(key);
        if (self.spotlight.open) return self.handleSpotlightKey(key);
        if (self.conflicts.open) {
            if (key == .character and key.character == 27) {
                self.conflicts.open = false;
                self.invalidate();
            }
            return;
        }
        if (self.trash.open or self.settings.open) {
            if (key == .other) return;
            if (key == .character and key.character == 27) {}
            return;
        }
        if (self.find.open and try self.handleFindKey(key, mods)) return;

        const tab = self.activeTab() orelse return;
        const index = self.application.active.?;

        // Tab and Shift+Tab indent rather than inserting, when a selection
        // spans lines -- as the original intercepted before the keymap.
        if (key == .tab) {
            const multi = tab.selection.anchor.line != tab.selection.head.line;
            const cmd: core.commands.Command = if (mods.shift)
                .dedent
            else if (multi)
                .indent
            else
                .{ .insert = .{ .text = "\t" } };
            try self.editor.dispatch(tab, cmd, self.now_ms);
            try self.application.noteEdited(index, self.now_ms);
            self.invalidate();
            return;
        }

        if (core.commands.keymap(.{
            .key = key,
            .meta = mods.meta,
            .shift = mods.shift,
            .alt = mods.alt,
        }, self.editor.pageRows())) |cmd| {
            try self.editor.dispatch(tab, cmd, self.now_ms);
            if (isEdit(cmd)) try self.application.noteEdited(index, self.now_ms);
            self.sendImeArea();
            self.invalidate();
        }
    }

    fn isEdit(cmd: core.commands.Command) bool {
        return switch (cmd) {
            .insert, .newline, .backspace, .delete, .indent, .dedent, .undo, .redo => true,
            else => false,
        };
    }

    /// The capture-phase shortcuts from `App.svelte:54`. Returns true when the
    /// key was consumed.
    fn handleGlobalKey(self: *Root, key: ev.Key, mods: ev.Mods) !bool {
        // Ctrl+Tab cycles tabs regardless of what has focus.
        if (key == .tab and mods.meta) {
            self.cycleTab(if (mods.shift) -1 else 1);
            return true;
        }
        if (!mods.meta or mods.alt) return false;

        switch (key) {
            .character => |c| switch (c) {
                'b' => {
                    if (mods.shift) return false;
                    self.sidebar_collapsed = !self.sidebar_collapsed;
                    try self.applyLayout();
                    self.invalidate();
                    return true;
                },
                'k' => {
                    if (mods.shift) return false;
                    try self.toggleSpotlight();
                    return true;
                },
                'n' => {
                    if (mods.shift) return false;
                    try self.newNote();
                    return true;
                },
                'w' => {
                    if (mods.shift) return false;
                    try self.closeActiveTab();
                    return true;
                },
                's' => {
                    if (mods.shift) return false;
                    try self.saveActive();
                    return true;
                },
                'f' => {
                    try self.openFind(mods.alt);
                    return true;
                },
                ',' => {
                    self.settings.open = true;
                    self.invalidate();
                    return true;
                },
                '=', '+' => {
                    try self.setFontSize(self.editor_font_px + 1);
                    return true;
                },
                '-', '_' => {
                    try self.setFontSize(self.editor_font_px -| 1);
                    return true;
                },
                '0' => {
                    try self.setFontSize(theme.editor_font_default);
                    return true;
                },
                else => return false,
            },
            .backspace => {
                if (mods.shift) return false;
                try self.deleteSelectedNotes();
                return true;
            },
            else => return false,
        }
    }

    fn handleMenu(self: *Root, action: ev.MenuAction) !void {
        switch (action) {
            .app_settings => self.settings.open = true,
            .file_new_note => try self.newNote(),
            .file_save => try self.saveActive(),
            .file_close_tab => try self.closeActiveTab(),
            .edit_undo, .edit_redo, .edit_select_all => {
                const tab = self.activeTab() orelse return;
                const cmd: core.commands.Command = switch (action) {
                    .edit_undo => .undo,
                    .edit_redo => .redo,
                    else => .select_all,
                };
                try self.editor.dispatch(tab, cmd, self.now_ms);
                if (action != .edit_select_all) {
                    try self.application.noteEdited(self.application.active.?, self.now_ms);
                }
            },
            .edit_find => try self.openFind(false),
            .edit_replace => try self.openFind(true),
            .view_toggle_sidebar => {
                self.sidebar_collapsed = !self.sidebar_collapsed;
                try self.applyLayout();
            },
            .view_spotlight => try self.toggleSpotlight(),
            .view_zoom_in => try self.setFontSize(self.editor_font_px + 1),
            .view_zoom_out => try self.setFontSize(self.editor_font_px -| 1),
            .view_zoom_reset => try self.setFontSize(theme.editor_font_default),
            .tab_next => self.cycleTab(1),
            .tab_prev => self.cycleTab(-1),
        }
        self.invalidate();
    }

    // -- actions -------------------------------------------------------------

    fn setFontSize(self: *Root, px: u32) !void {
        const clamped = theme.clampEditorFont(px);
        if (clamped == self.editor_font_px) return;
        self.editor_font_px = clamped;
        try self.fonts.setEditorSize(clamped);
        if (self.activeTab()) |tab| {
            self.editor.content_width = 0; // force a re-wrap
            _ = try self.editor.setViewport(tab, self.editorRect());
        }
        self.invalidate();
    }

    fn cycleTab(self: *Root, delta: i32) void {
        const n = self.application.tabs.items.len;
        if (n == 0) return;
        const cur: i32 = @intCast(self.application.active orelse 0);
        const next = @mod(cur + delta + @as(i32, @intCast(n)), @as(i32, @intCast(n)));
        self.application.active = @intCast(next);
        self.invalidate();
    }

    fn newNote(self: *Root) !void {
        if (self.application.ws == null) {
            self.outbox.push(.pick_folder);
            return;
        }
        _ = try self.application.createAndOpenNote();
        try self.applyLayout();
        self.invalidate();
    }

    fn saveActive(self: *Root) !void {
        const index = self.application.active orelse return;
        if (try self.application.saveTab(index)) {
            self.toast.show("Saved", self.now_ms);
        } else {
            self.toast.show("Save failed -- the file changed on disk", self.now_ms);
        }
        self.invalidate();
    }

    fn closeActiveTab(self: *Root) !void {
        const index = self.application.active orelse return;
        switch (try self.application.closeTab(index)) {
            .closed => {},
            .needs_confirm => try self.askCloseConfirm(index),
        }
        try self.applyLayout();
        self.invalidate();
    }

    fn askCloseConfirm(self: *Root, index: usize) !void {
        _ = self.confirm_arena.reset(.retain_capacity);
        const arena = self.confirm_arena.allocator();
        const title = try std.fmt.allocPrint(
            arena,
            "Save changes to \"{s}\"?",
            .{self.application.tabs.items[index].title},
        );
        self.confirm = .{
            .kind = .close_unsaved,
            .title = title,
            .message = "Your changes will be lost if you don't save them.",
        };
        self.confirm_tab = index;
    }

    fn deleteSelectedNotes(self: *Root) !void {
        if (self.sidebar.selected.count() == 0) return;
        _ = self.confirm_arena.reset(.retain_capacity);
        const arena = self.confirm_arena.allocator();

        self.confirm_targets.clearRetainingCapacity();
        var sample: []const u8 = "";
        var it = self.sidebar.selected.keyIterator();
        while (it.next()) |k| {
            const owned = try arena.dupe(u8, k.*);
            try self.confirm_targets.append(self.gpa, owned);
            if (sample.len == 0) {
                if (self.application.findNote(owned)) |n| sample = try arena.dupe(u8, n.title);
            }
        }

        const count = self.confirm_targets.items.len;
        const title = if (count == 1)
            try std.fmt.allocPrint(arena, "Move \"{s}\" to trash?", .{sample})
        else
            try std.fmt.allocPrint(arena, "Move {d} notes to trash?", .{count});

        self.confirm = .{
            .kind = .delete_notes,
            .title = title,
            .message = "Trashed notes are kept for 30 days, then permanently removed.",
            .targets = self.confirm_targets.items,
        };
        self.invalidate();
    }

    fn handleConfirmKey(self: *Root, key: ev.Key) !void {
        const answer: ?overlays.Confirm.Answer = switch (key) {
            .enter => .confirm,
            .character => |c| if (c == 27) .cancel else null,
            else => null,
        };
        if (answer) |a| try self.resolveConfirm(a);
    }

    fn resolveConfirm(self: *Root, answer: overlays.Confirm.Answer) !void {
        const pending = self.confirm orelse return;
        self.confirm = null;

        switch (pending.kind) {
            .close_unsaved => {
                const index = self.confirm_tab orelse return;
                switch (answer) {
                    .cancel => {},
                    .confirm => {
                        _ = try self.application.saveTab(index);
                        try self.application.closeTabForce(index);
                    },
                    .discard => try self.application.closeTabForce(index),
                }
                self.confirm_tab = null;
            },
            .delete_notes => {
                if (answer == .confirm) {
                    try self.application.deleteNotes(pending.targets);
                    self.sidebar.clearSelection();
                    self.toast.show("Moved to trash", self.now_ms);
                }
            },
        }
        try self.applyLayout();
        self.invalidate();
    }

    fn adjustSetting(self: *Root, hit: overlays.Settings.Hit) !void {
        switch (hit.row) {
            .autosave_enabled => self.application.setAutoSave(
                !self.application.autosave_enabled,
                self.application.autosave_interval_sec,
                self.now_ms,
            ),
            .autosave_interval => {
                const step: i64 = if (hit.increase) 5 else -5;
                const next: i64 = @as(i64, self.application.autosave_interval_sec) + step;
                self.application.setAutoSave(
                    self.application.autosave_enabled,
                    @intCast(@max(1, next)),
                    self.now_ms,
                );
            },
            .font_size => try self.setFontSize(
                if (hit.increase) self.editor_font_px + 1 else self.editor_font_px -| 1,
            ),
        }
    }

    // -- spotlight -----------------------------------------------------------

    fn toggleSpotlight(self: *Root) !void {
        if (self.spotlight.open) {
            self.spotlight.hide();
        } else {
            self.spotlight.show();
        }
        self.invalidate();
    }

    fn handleSpotlightKey(self: *Root, key: ev.Key) !void {
        switch (key) {
            .arrow_down => self.spotlight.move(1),
            .arrow_up => self.spotlight.move(-1),
            .backspace => self.spotlight.backspace(self.now_ms),
            .enter => try self.openSelectedHit(),
            .character => |c| if (c == 27) self.spotlight.hide(),
            else => {},
        }
        self.invalidate();
    }

    fn openSelectedHit(self: *Root) !void {
        if (self.spotlight.selected >= self.spotlight.hits.len) return;
        const id = try self.gpa.dupe(u8, self.spotlight.hits[self.spotlight.selected].id);
        defer self.gpa.free(id);
        self.spotlight.hide();
        _ = try self.application.openNote(id);
        try self.applyLayout();
    }

    fn tickSpotlight(self: *Root, now_ms: i64) !void {
        const due = self.spotlight.search_due_ms orelse return;
        if (now_ms < due) return;
        self.spotlight.search_due_ms = null;

        const ws = if (self.application.ws) |*w| w else return;
        const hits = try db.search.searchNotes(ws, self.gpa, self.spotlight.query.items, 30);
        self.spotlight.setHits(hits);
        self.invalidate();
    }

    // -- Notion --------------------------------------------------------------

    /// Re-read the stored Notion settings and conflict count.
    fn refreshNotionConfig(self: *Root) !void {
        const ws = if (self.application.ws) |*w| w else return;
        const cfg = try net.notion.store.getConfig(ws, self.gpa);
        if (self.notion_cfg) |old| old.deinit(self.gpa);
        self.notion_cfg = cfg;
        self.conflict_count = try net.notion.store.countConflicts(ws);
    }

    fn tickNotion(self: *Root, now_ms: i64) !void {
        if (self.application.ws == null) return;

        if (self.notion.takeOutcome()) |outcome| {
            defer outcome.deinit();
            self.toast.show(outcome.summary, now_ms);

            // Files the sync rewrote need their open tabs re-read.
            try self.application.refreshNotes();
            for (outcome.changed) |id| {
                if (self.application.findTab(id)) |i| {
                    _ = self.application.reloadTabFromDisk(i, now_ms) catch false;
                }
            }
            try self.refreshNotionConfig();
            self.invalidate();
        }

        const cfg = self.notion_cfg orelse return;
        if (!self.notion.due(cfg, now_ms)) return;

        // The engine compares what is on disk, so anything unsaved has to land
        // first or the sync would push stale content.
        try self.application.flushDirtyTabs();

        const ws = if (self.application.ws) |*w| w else return;
        self.notion.start(ws.root, cfg, now_ms) catch |err| {
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Could not start sync: {s}", .{@errorName(err)}) catch
                "Could not start sync";
            self.toast.show(text, now_ms);
        };
        self.invalidate();
    }

    /// Start a sync now, from the status bar.
    pub fn syncNow(self: *Root) !void {
        const cfg = self.notion_cfg orelse return;
        if (self.notion.isRunning()) {
            self.notion.requestCancel();
            self.toast.show("Cancelling sync...", self.now_ms);
            return;
        }
        _ = cfg.credentials() catch {
            self.toast.show("Connect a Notion database in Settings first", self.now_ms);
            return;
        };
        try self.application.flushDirtyTabs();
        const ws = if (self.application.ws) |*w| w else return;
        try self.notion.start(ws.root, cfg, self.now_ms);
        self.invalidate();
    }

    pub fn openConflicts(self: *Root) !void {
        const ws = if (self.application.ws) |*w| w else return;
        self.conflicts.setItems(try net.notion.store.listConflicts(ws, self.gpa));
        try self.loadConflictDetail();
        self.conflicts.open = true;
        self.invalidate();
    }

    fn loadConflictDetail(self: *Root) !void {
        const ws = if (self.application.ws) |*w| w else return;
        const item = self.conflicts.current() orelse return self.conflicts.setDetail(null);
        self.conflicts.setDetail(try net.notion.store.getConflict(ws, self.gpa, item.note_id));
    }

    fn resolveConflict(self: *Root, how: net.notion.resolve.Resolution) !void {
        const ws = if (self.application.ws) |*w| w else return;
        const item = self.conflicts.current() orelse return;
        const note_id = try self.gpa.dupe(u8, item.note_id);
        defer self.gpa.free(note_id);

        const cfg = self.notion_cfg orelse return;
        const creds = cfg.credentials() catch return;

        var http = try net.notion.client.Http.init(self.gpa, self.io, creds.token, &self.notion.cancel);
        defer http.deinit();
        var api = net.notion.client.Client.init(self.gpa, http.transport());
        defer api.deinit();

        var resolver = net.notion.resolve.Resolver.init(self.gpa, self.io, ws, &api);
        resolver.resolve(note_id, how) catch {
            self.toast.show("Could not resolve that conflict", self.now_ms);
            return;
        };

        self.toast.show("Conflict resolved", self.now_ms);
        try self.application.refreshNotes();
        if (self.application.findTab(note_id)) |i| {
            _ = self.application.reloadTabFromDisk(i, self.now_ms) catch false;
        }
        try self.afterResolution();
    }

    fn resolveAllConflicts(self: *Root, policy: net.notion.resolve.BulkPolicy) !void {
        const ws = if (self.application.ws) |*w| w else return;
        const cfg = self.notion_cfg orelse return;
        const creds = cfg.credentials() catch return;

        var http = try net.notion.client.Http.init(self.gpa, self.io, creds.token, &self.notion.cancel);
        defer http.deinit();
        var api = net.notion.client.Client.init(self.gpa, http.transport());
        defer api.deinit();

        var resolver = net.notion.resolve.Resolver.init(self.gpa, self.io, ws, &api);
        const result = resolver.resolveAll(policy) catch
            net.notion.resolve.BulkResult{ .resolved = 0, .failed = 0 };

        var buf: [96]u8 = undefined;
        const text = if (result.failed > 0)
            std.fmt.bufPrint(&buf, "Resolved {d}, {d} failed", .{ result.resolved, result.failed }) catch ""
        else
            std.fmt.bufPrint(&buf, "Resolved {d} conflict(s)", .{result.resolved}) catch "";
        self.toast.show(text, self.now_ms);

        try self.application.refreshNotes();
        try self.afterResolution();
    }

    fn afterResolution(self: *Root) !void {
        const ws = if (self.application.ws) |*w| w else return;
        self.conflicts.pending_bulk = null;
        self.conflicts.setItems(try net.notion.store.listConflicts(ws, self.gpa));
        try self.loadConflictDetail();
        // The panel closes itself once the list empties.
        if (self.conflicts.items.len == 0) self.conflicts.open = false;
        self.conflict_count = try net.notion.store.countConflicts(ws);
        self.invalidate();
    }

    /// The status-bar entries for this frame.
    fn statusItems(self: *Root, buf: *[4]chrome.StatusBar.Item) []const chrome.StatusBar.Item {
        var n: usize = 0;
        buf[n] = .{ .id = .trash, .label = "Trash", .icon = icons.trash };
        n += 1;
        buf[n] = .{ .id = .settings, .label = "Settings", .icon = icons.settings };
        n += 1;

        const cfg = self.notion_cfg orelse return buf[0..n];
        if (cfg.ready()) {
            buf[n] = .{
                .id = .notion_sync,
                .label = if (self.notion.isRunning()) "Syncing..." else "Notion",
                .icon = icons.sync,
            };
            n += 1;
        }
        if (self.conflict_count > 0) {
            var text: [24]u8 = undefined;
            const label = std.fmt.bufPrint(&text, "! {d}", .{self.conflict_count}) catch "!";
            // The label lives in the frame's scratch, which outlives the paint.
            buf[n] = .{
                .id = .notion_conflicts,
                .label = self.conflictLabel(label),
                .warn = true,
            };
            n += 1;
        }
        return buf[0..n];
    }

    fn conflictLabel(self: *Root, text: []const u8) []const u8 {
        const n = @min(text.len, self.conflict_label_buf.len);
        @memcpy(self.conflict_label_buf[0..n], text[0..n]);
        return self.conflict_label_buf[0..n];
    }

    // -- find ----------------------------------------------------------------

    fn openFind(self: *Root, with_replace: bool) !void {
        const tab = self.activeTab() orelse return;
        try self.find.show(tab, with_replace);
        self.invalidate();
    }

    fn handleFindKey(self: *Root, key: ev.Key, mods: ev.Mods) !bool {
        const tab = self.activeTab() orelse return false;
        switch (key) {
            .character => |c| {
                if (c == 27) {
                    self.find.close();
                    self.invalidate();
                    return true;
                }
                return false;
            },
            .enter => {
                if (self.find.focus_replace) {
                    _ = try self.find.replaceOne(tab, self.now_ms);
                    try self.application.noteEdited(self.application.active.?, self.now_ms);
                } else if (self.find.step(if (mods.shift) -1 else 1)) |m| {
                    tab.selection = .{ .anchor = m.from, .head = m.to };
                    self.editor.scrollPosCentered(tab, m.from);
                }
                self.invalidate();
                return true;
            },
            .backspace => {
                try self.find.backspace(tab);
                self.invalidate();
                return true;
            },
            .tab => {
                if (self.find.replacing) self.find.focus_replace = !self.find.focus_replace;
                self.invalidate();
                return true;
            },
            else => return false,
        }
    }

    // -- mouse ---------------------------------------------------------------

    fn handleMouseDown(
        self: *Root,
        x: i32,
        y: i32,
        button: ev.MouseButton,
        clicks: u8,
        mods: ev.Mods,
    ) !void {
        defer self.invalidate();

        if (self.context_menu.open) {
            if (self.context_menu.hitTest(self.bounds(), x, y)) |item| {
                try self.runContextAction(item.action);
            }
            self.context_menu.open = false;
            return;
        }

        if (self.conflicts.open) {
            var p = self.painter();
            switch (self.conflicts.hitTest(&p, self.bounds(), x, y)) {
                .select => |i| {
                    self.conflicts.selected = i;
                    try self.loadConflictDetail();
                },
                .choose => |how| try self.resolveConflict(how),
                .pick_bulk => |policy| self.conflicts.pending_bulk = policy,
                .confirm_bulk => {
                    if (self.conflicts.pending_bulk) |policy| try self.resolveAllConflicts(policy);
                },
                .cancel_bulk => self.conflicts.pending_bulk = null,
                .dismiss => {},
                .none => {},
            }
            if (!overlays.ConflictPanel.panelRect(self.bounds()).contains(x, y)) {
                self.conflicts.open = false;
            }
            return;
        }

        if (self.confirm) |c| {
            if (c.hitTest(&self.painter(), self.bounds(), x, y)) |answer| {
                try self.resolveConfirm(answer);
            }
            return;
        }
        if (self.spotlight.open) {
            if (self.spotlight.hitTest(self.bounds(), x, y)) |i| {
                self.spotlight.selected = i;
                try self.openSelectedHit();
            } else if (!overlays.Spotlight.panelRect(self.bounds()).contains(x, y)) {
                self.spotlight.hide();
            }
            return;
        }
        if (self.trash.open) {
            switch (self.trash.hitTest(self.bounds(), x, y)) {
                .restore => |i| try self.restoreTrashed(i),
                .purge => |i| try self.purgeTrashed(i),
                .none => if (!overlays.TrashPanel.panelRect(self.bounds()).contains(x, y)) {
                    self.trash.open = false;
                },
            }
            return;
        }
        if (self.settings.open) {
            if (self.settings.hitTest(self.bounds(), x, y)) |hit| {
                try self.adjustSetting(hit);
            } else if (!overlays.Settings.panelRect(self.bounds()).contains(x, y)) {
                self.settings.open = false;
            }
            return;
        }

        if (self.statusRect().contains(x, y)) {
            var p = self.painter();
            var buf: [4]chrome.StatusBar.Item = undefined;
            if (self.statusbar.hitTest(&p, self.statusItems(&buf), x, y)) |b| switch (b) {
                .trash => try self.openTrash(),
                .settings => self.settings.open = true,
                .notion_sync => try self.syncNow(),
                .notion_conflicts => try self.openConflicts(),
            };
            return;
        }
        if (self.resizerRect().contains(x, y)) {
            self.resizing = true;
            return;
        }
        if (self.sidebarRect().contains(x, y)) return self.clickSidebar(x, y, button, mods);
        if (self.tabBarRect().contains(x, y) and self.application.tabs.items.len > 0) {
            return self.clickTabBar(x, y);
        }
        if (self.editorRect().contains(x, y)) return self.clickEditor(x, y, clicks, mods);
    }

    fn clickSidebar(self: *Root, x: i32, y: i32, button: ev.MouseButton, mods: ev.Mods) !void {
        if (self.sidebar.hitTestHeader(x, y)) |hit| {
            switch (hit) {
                .new_note => try self.newNote(),
                .open_folder => self.outbox.push(.pick_folder),
            }
            return;
        }
        try self.rebuildGroups();
        const hit = self.sidebar.hitTest(self.groups.items, y) orelse return;
        switch (hit) {
            .group => |g| {
                if (g.index < self.groups.items.len) {
                    self.sidebar.toggleGroup(&self.groups.items[g.index].key);
                }
            },
            .note => |n| {
                if (button == .right) {
                    if (!self.sidebar.isSelected(n.id)) {
                        self.sidebar.clearSelection();
                        _ = self.sidebar.clickNote(n.id, self.visible_ids.items, .{});
                    }
                    self.openContextMenu(x, y);
                    return;
                }
                switch (self.sidebar.clickNote(n.id, self.visible_ids.items, mods)) {
                    .open_note => |id| {
                        const owned = try self.gpa.dupe(u8, id);
                        defer self.gpa.free(owned);
                        _ = try self.application.openNote(owned);
                        try self.applyLayout();
                    },
                    else => {},
                }
            },
        }
    }

    fn openContextMenu(self: *Root, x: i32, y: i32) void {
        const single = self.sidebar.selected.count() == 1;
        self.context_menu = .{
            .x = x,
            .y = y,
            .open = true,
            .items = &.{
                .{ .label = "Reveal in file manager", .action = .reveal, .disabled = !single },
                .{ .label = "Delete", .action = .delete, .danger = true },
            },
        };
    }

    fn runContextAction(self: *Root, action: overlays.ContextMenu.Action) !void {
        switch (action) {
            .reveal => {
                var it = self.sidebar.selected.keyIterator();
                const id = (it.next() orelse return).*;
                const ws = if (self.application.ws) |*w| w else return;
                const path = try ws.absoluteNotePath(self.gpa, id);
                defer self.gpa.free(path);
                self.outbox.pushText(.reveal_path, path);
            },
            .delete => try self.deleteSelectedNotes(),
        }
    }

    fn clickTabBar(self: *Root, x: i32, y: i32) !void {
        var p = self.painter();
        switch (self.tabbar.hitTest(&p, self.application.tabs.items, x, y)) {
            .tab => |i| {
                self.application.active = i;
                try self.applyLayout();
            },
            .close => |i| {
                switch (try self.application.closeTab(i)) {
                    .closed => {},
                    .needs_confirm => try self.askCloseConfirm(i),
                }
                try self.applyLayout();
            },
            .none => {},
        }
    }

    fn clickEditor(self: *Root, x: i32, y: i32, clicks: u8, mods: ev.Mods) !void {
        const tab = self.activeTab() orelse return;
        try self.editor.sync(tab);

        if (clicks >= 2) {
            try self.editor.selectAt(tab, x, y, self.editor.isInGutter(tab, x));
            return;
        }

        const pos = self.editor.hitTest(tab, x, y);
        tab.selection = if (mods.shift)
            .{ .anchor = tab.selection.anchor, .head = pos }
        else
            core.selection.Selection.at(pos);
        self.editor.sticky_x = null;
        self.editor.dragging = true;
        self.mouse_down_in_editor = true;
        self.sendImeArea();
    }

    fn handleMouseMove(self: *Root, x: i32, y: i32) !void {
        if (self.resizing) {
            if (x < theme.sidebar_collapse_w) {
                self.sidebar_collapsed = true;
            } else {
                self.sidebar_collapsed = false;
                self.sidebar_width = theme.clampSidebarWidth(x);
            }
            try self.applyLayout();
            self.invalidate();
            return;
        }

        // Hovering the left edge reveals a collapsed sidebar.
        if (self.sidebar_collapsed) {
            const should_peek = x < theme.edge_trigger_w or
                (self.peeking and x < self.sidebar_width);
            if (should_peek != self.peeking) {
                self.peeking = should_peek;
                try self.applyLayout();
                self.invalidate();
            }
        }

        if (self.editor.dragging) {
            const tab = self.activeTab() orelse return;
            tab.selection = .{
                .anchor = tab.selection.anchor,
                .head = self.editor.hitTest(tab, x, y),
            };
            self.invalidate();
        }

        // The sidebar resolves its own hover during paint, from the rectangles
        // it draws, so it only needs to be told where the pointer is.
        {
            const inside = self.sidebar.rect.contains(x, y);
            const next: @TypeOf(self.sidebar.hover) = if (inside) .{ .x = x, .y = y } else null;
            const changed = (next == null) != (self.sidebar.hover == null) or
                (next != null and self.sidebar.hover != null and
                    (next.?.x != self.sidebar.hover.?.x or next.?.y != self.sidebar.hover.?.y));
            if (changed) {
                self.sidebar.hover = next;
                self.invalidate();
            }
        }

        {
            var p = self.painter();
            var buf: [4]chrome.StatusBar.Item = undefined;
            const hovered = self.statusbar.hitTest(&p, self.statusItems(&buf), x, y);
            if (hovered != self.status_hover) {
                self.status_hover = hovered;
                self.invalidate();
            }
        }

        self.outbox.push(.{ .set_cursor = if (self.resizerRect().contains(x, y))
            .col_resize
        else if (self.editorRect().contains(x, y))
            .text
        else
            .arrow });
    }

    /// Scroll by one wheel event.
    ///
    /// A stepped mouse wheel and a trackpad arrive through the same event and
    /// want completely different amounts of travel per unit, and nothing in
    /// the event says which sent it. What does distinguish them is that SDL
    /// rounds a stepped wheel to whole notches, while a trackpad reports the
    /// distance the fingers moved, scaled by a tenth -- so a fraction is proof
    /// of a trackpad. Treating a trackpad as three rows per unit made it six
    /// times too eager, which reads as a scroll that cannot be aimed.
    ///
    /// A fraction is proof, but a whole number is not proof of the opposite: a
    /// gesture will occasionally land on one. The grace window carries the
    /// verdict across those events so a single one does not jolt the page
    /// mid-swipe.
    fn handleWheel(self: *Root, x: i32, y: i32, dy: f32) !void {
        const d: f64 = dy;
        const fractional = d != @round(d);
        if (fractional) self.precise_wheel_ms = self.now_ms;
        const precise = fractional or if (self.precise_wheel_ms) |t|
            self.now_ms - t < theme.precise_wheel_grace_ms
        else
            false;

        const step = if (precise)
            d * theme.wheel_points_per_precise_unit
        else
            d * self.editor.rowHeight() * theme.wheel_rows_per_notch;
        if (self.sidebarRect().contains(x, y)) {
            self.sidebar.scroll_top -= step;
            self.sidebar.clampScroll(self.groups.items);
        } else if (self.editorRect().contains(x, y)) {
            self.editor.scrollTo(self.editor.scroll_top - step);
        }
        self.invalidate();
    }

    // -- trash ---------------------------------------------------------------

    pub fn openTrash(self: *Root) !void {
        const ws = if (self.application.ws) |*w| w else return;
        self.trash.setNotes(try ws.listTrashedNotes());
        self.trash.open = true;
        self.invalidate();
    }

    fn restoreTrashed(self: *Root, index: usize) !void {
        const ws = if (self.application.ws) |*w| w else return;
        if (index >= self.trash.notes.len) return;
        const id = try self.gpa.dupe(u8, self.trash.notes[index].id);
        defer self.gpa.free(id);

        try ws.restoreNote(id, self.now_ms);
        try self.application.refreshNotes();
        self.trash.setNotes(try ws.listTrashedNotes());
        self.toast.show("Restored", self.now_ms);
    }

    fn purgeTrashed(self: *Root, index: usize) !void {
        const ws = if (self.application.ws) |*w| w else return;
        if (index >= self.trash.notes.len) return;
        const id = try self.gpa.dupe(u8, self.trash.notes[index].id);
        defer self.gpa.free(id);

        try ws.hardDeleteNote(id);
        self.trash.setNotes(try ws.listTrashedNotes());
        self.toast.show("Deleted permanently", self.now_ms);
    }

    // -- painting ------------------------------------------------------------

    fn painter(self: *Root) Painter {
        return Painter.init(&self.surface, &self.fonts);
    }

    fn sendImeArea(self: *Root) void {
        const tab = self.activeTab() orelse return;
        self.outbox.push(.{ .set_ime_area = self.editor.caretRect(tab) });
    }

    fn rebuildGroups(self: *Root) !void {
        self.groups.clearRetainingCapacity();
        const groups = try app.datefmt.groupByLocalDay(
            self.gpa,
            self.application.notes.items,
            self.now_ms,
        );
        defer self.gpa.free(groups);
        try self.groups.appendSlice(self.gpa, groups);

        // The visible id list drives shift-range selection, so collapsed
        // groups are skipped exactly as they are on screen.
        self.visible_ids.clearRetainingCapacity();
        for (self.groups.items) |g| {
            if (self.sidebar.isCollapsed(&g.key)) continue;
            for (g.entries) |n| try self.visible_ids.append(self.gpa, n.id);
        }
    }

    pub fn paint(self: *Root) !void {
        try self.applyLayout();
        try self.rebuildGroups();

        var p = self.painter();
        p.clear(palette.bg_0);

        var dirty: std.StringHashMapUnmanaged(void) = .empty;
        defer dirty.deinit(self.gpa);
        for (self.application.tabs.items) |t| {
            if (t.dirty) try dirty.put(self.gpa, t.note_id, {});
        }

        const active_id = if (self.activeTab()) |t| t.note_id else null;

        if (self.activeTab()) |tab| {
            self.tabbar.paint(&p, self.application.tabs.items, self.application.active);
            try self.editor.paint(&p, tab, !self.modalOpen());
            self.find.paint(&p, self.editorRect());
        } else {
            const pane = self.paneRect();
            p.fill(pane, palette.bg_0);
            p.drawLabel(
                .{ .x = pane.x, .y = pane.y + @divTrunc(pane.h, 2) - 30, .w = pane.w, .h = 28 },
                "Nova",
                palette.fg_1,
                .center,
                .{},
            );
            p.drawLabel(
                .{ .x = pane.x, .y = pane.y + @divTrunc(pane.h, 2), .w = pane.w, .h = 20 },
                "Open a folder from the sidebar and pick a note.",
                palette.fg_2,
                .center,
                .{},
            );
        }

        // The sidebar paints last of the chrome so a peek floats over the pane.
        if (!self.sidebar_collapsed or self.peeking) {
            self.sidebar.paint(
                &p,
                self.groups.items,
                active_id,
                &dirty,
                if (self.application.ws) |w| w.root else null,
                self.now_ms,
            );
            p.fill(self.resizerRect(), palette.bg_3);
        }

        const status: ?chrome.StatusBar.Status = if (self.activeTab()) |tab|
            try chrome.StatusBar.statusOf(tab, self.gpa)
        else
            null;
        var status_buf: [4]chrome.StatusBar.Item = undefined;
        self.statusbar.paint(&p, status, self.statusItems(&status_buf), self.status_hover);

        self.trash.paint(&p, self.bounds(), self.now_ms);
        self.settings.paint(
            &p,
            self.bounds(),
            self.application.autosave_enabled,
            self.application.autosave_interval_sec,
            self.editor_font_px,
            .{ .ui = self.fonts.uiPath(), .mono = self.fonts.monoPath() },
        );
        self.spotlight.paint(&p, self.bounds());
        self.conflicts.paint(&p, self.bounds());
        if (self.confirm) |c| c.paint(&p, self.bounds());
        self.context_menu.paint(&p, self.bounds());
        self.toast.paint(&p, self.bounds());

        self.needs_paint = false;
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const golden = gfx.golden;

const Harness = struct {
    env: db.fsx.TestEnv,
    root: *Root,
    ws_path: []u8,
    gpa: Allocator,

    /// Heap-allocated: `Root.attach` points the editor at `Root.fonts`, so the
    /// Root has to be at its final address before anything runs.
    fn init(gpa: Allocator, name: []const u8) !*Harness {
        return initScaled(gpa, name, 1);
    }

    fn initScaled(gpa: Allocator, name: []const u8, scale: f32) !*Harness {
        var env = try db.fsx.TestEnv.init(gpa, name);
        errdefer env.deinit();
        const ws_path = try std.fmt.allocPrint(gpa, "{s}/ws", .{env.path});
        errdefer gpa.free(ws_path);

        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);

        const r = try gpa.create(Root);
        r.* = try Root.init(gpa, env.io, 900, 560, .{
            .system_fonts = false,
            .scale = scale,
        });
        r.attach();
        try r.application.openWorkspace(ws_path);
        // A fixed clock, so the date headings the sidebar derives from note
        // timestamps -- and therefore the golden images -- do not change with
        // the day the suite runs on.
        if (r.application.ws) |*w| w.clock = 1_724_500_000_000;
        try r.applyLayout();

        self.* = .{ .env = env, .root = r, .ws_path = ws_path, .gpa = gpa };
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.gpa;
        self.root.deinit();
        gpa.destroy(self.root);
        gpa.free(self.ws_path);
        self.env.deinit();
        gpa.destroy(self);
    }

    fn send(self: *Harness, e: ev.Event) !void {
        try self.root.handle(e);
    }

    fn key(self: *Harness, k: ev.Key, mods: ev.Mods) !void {
        try self.send(.{ .key_down = .{ .key = k, .mods = mods } });
    }

    fn typeText(self: *Harness, text: []const u8) !void {
        try self.send(.{ .text_input = text });
    }

    fn contents(self: *Harness) ![]u8 {
        const tab = self.root.activeTab() orelse return self.gpa.dupe(u8, "");
        return tab.buffer.toOwnedString(self.gpa);
    }
};

test "a fresh window shows the empty state" {
    const h = try Harness.init(testing.allocator, "root-empty");
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), h.root.application.tabs.items.len);
    try h.root.paint();
}

test "Cmd+N creates a note and typing lands in it" {
    const h = try Harness.init(testing.allocator, "root-new");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try testing.expectEqual(@as(usize, 1), h.root.application.tabs.items.len);

    try h.typeText("# 회의록");
    const text = try h.contents();
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("# 회의록", text);
    try testing.expectEqualStrings("회의록", h.root.application.tabs.items[0].title);
}

test "Cmd+S saves and shows a toast" {
    const h = try Harness.init(testing.allocator, "root-save");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("content");
    try h.key(.{ .character = 's' }, .{ .meta = true });

    try testing.expect(!h.root.application.tabs.items[0].dirty);
    try testing.expectEqualStrings("Saved", h.root.toast.message.?);
}

test "Cmd+B toggles the sidebar" {
    const h = try Harness.init(testing.allocator, "root-sidebar");
    defer h.deinit();

    const before = h.root.editorRect().x;
    try h.key(.{ .character = 'b' }, .{ .meta = true });
    try testing.expect(h.root.sidebar_collapsed);
    try testing.expect(h.root.editorRect().x < before);

    try h.key(.{ .character = 'b' }, .{ .meta = true });
    try testing.expect(!h.root.sidebar_collapsed);
}

test "Cmd+K toggles the command palette" {
    const h = try Harness.init(testing.allocator, "root-spotlight");
    defer h.deinit();

    try h.key(.{ .character = 'k' }, .{ .meta = true });
    try testing.expect(h.root.spotlight.open);

    // Typing goes to the palette, not the buffer.
    try h.typeText("안녕");
    try testing.expectEqualStrings("안녕", h.root.spotlight.query.items);

    try h.key(.{ .character = 27 }, .{});
    try testing.expect(!h.root.spotlight.open);
}

test "the palette searches after its debounce and opens the chosen note" {
    const h = try Harness.init(testing.allocator, "root-search");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("안녕하세요 반갑습니다");
    try h.key(.{ .character = 's' }, .{ .meta = true });
    try h.key(.{ .character = 'w' }, .{ .meta = true });
    try testing.expectEqual(@as(usize, 0), h.root.application.tabs.items.len);

    try h.key(.{ .character = 'k' }, .{ .meta = true });
    try h.typeText("안녕");

    // Nothing runs before the debounce elapses.
    try h.send(.{ .tick = 10 });
    try testing.expectEqual(@as(usize, 0), h.root.spotlight.hits.len);

    try h.send(.{ .tick = theme.search_debounce_ms + 10 });
    try testing.expectEqual(@as(usize, 1), h.root.spotlight.hits.len);

    try h.key(.enter, .{});
    try testing.expectEqual(@as(usize, 1), h.root.application.tabs.items.len);
    try testing.expect(!h.root.spotlight.open);
}

test "zoom changes the font and re-wraps" {
    const h = try Harness.init(testing.allocator, "root-zoom");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("some text to lay out");

    const before = h.root.fonts.mono_default.metrics.ch_width;
    try h.key(.{ .character = '=' }, .{ .meta = true });
    try testing.expectEqual(@as(u32, theme.editor_font_default + 1), h.root.editor_font_px);
    // One step need not change the integer cell width -- a 0.5 em advance can
    // round to the same pixel -- but several steps must.
    for (0..4) |_| try h.key(.{ .character = '=' }, .{ .meta = true });
    try testing.expect(h.root.fonts.mono_default.metrics.ch_width > before);

    try h.key(.{ .character = '0' }, .{ .meta = true });
    try testing.expectEqual(@as(u32, theme.editor_font_default), h.root.editor_font_px);
}

test "closing a dirty tab asks first" {
    const h = try Harness.init(testing.allocator, "root-close-dirty");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("draft");
    try h.key(.{ .character = 's' }, .{ .meta = true });
    try h.typeText(" more");

    try h.key(.{ .character = 'w' }, .{ .meta = true });
    try testing.expect(h.root.confirm != null);
    try testing.expectEqual(@as(usize, 1), h.root.application.tabs.items.len);

    // Escape cancels.
    try h.key(.{ .character = 27 }, .{});
    try testing.expect(h.root.confirm == null);
    try testing.expectEqual(@as(usize, 1), h.root.application.tabs.items.len);
}

test "Tab indents a multi-line selection and Shift+Tab undoes it" {
    const h = try Harness.init(testing.allocator, "root-indent");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("one\ntwo\nthree");
    try h.key(.{ .character = 'a' }, .{ .meta = true });

    try h.key(.tab, .{});
    {
        const text = try h.contents();
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("\tone\n\ttwo\n\tthree", text);
    }

    try h.key(.tab, .{ .shift = true });
    const text = try h.contents();
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("one\ntwo\nthree", text);
}

test "an IME composition commits Korean into the buffer" {
    const h = try Harness.init(testing.allocator, "root-ime");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });

    try h.send(.ime_start);
    try h.send(.{ .ime_preedit = .{ .text = "ㅎ" } });
    try h.send(.{ .ime_preedit = .{ .text = "한" } });
    try h.send(.ime_end);
    try h.typeText("한글");

    const text = try h.contents();
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("한글", text);
}

test "the caret area is reported for the IME candidate window" {
    const h = try Harness.init(testing.allocator, "root-ime-area");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    h.root.outbox.clear();

    try h.typeText("abc");

    var found = false;
    for (h.root.outbox.drain()) |r| {
        if (r == .set_ime_area) found = true;
    }
    try testing.expect(found);
}

test "Ctrl+Tab cycles tabs and wraps" {
    const h = try Harness.init(testing.allocator, "root-cycle");
    defer h.deinit();

    for (0..3) |_| {
        try h.key(.{ .character = 'n' }, .{ .meta = true });
        try h.key(.{ .character = 's' }, .{ .meta = true });
    }
    try testing.expectEqual(@as(?usize, 2), h.root.application.active);

    try h.key(.tab, .{ .meta = true });
    try testing.expectEqual(@as(?usize, 0), h.root.application.active);
    try h.key(.tab, .{ .meta = true, .shift = true });
    try testing.expectEqual(@as(?usize, 2), h.root.application.active);
}

test "find highlights matches and replace rewrites them" {
    const h = try Harness.init(testing.allocator, "root-find");
    defer h.deinit();

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("cat cat cat");

    try h.send(.{ .menu = .edit_replace });
    try testing.expect(h.root.find.open);
    try h.typeText("cat");
    try testing.expectEqual(@as(usize, 3), h.root.find.matches.items.len);

    // Tab moves focus to the replacement field.
    try h.key(.tab, .{});
    try testing.expect(h.root.find.focus_replace);
    try h.typeText("dog");
    try h.key(.enter, .{});

    const text = try h.contents();
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("dog cat cat", text);
}

test "clicking in the editor moves the caret" {
    const h = try Harness.init(testing.allocator, "root-click");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("hello world");

    const r = h.root.editorRect();
    const tab = h.root.activeTab().?;
    const left = h.root.editor.contentLeft(tab.buffer.lineCount());
    const m = h.root.editor.metrics();
    const x = r.x + @as(i32, @intFromFloat(left + core.wrap.advanceTo("hello world", 6, m)));

    try h.send(.{ .mouse_down = .{ .x = x, .y = r.y + 2 } });
    try testing.expectEqual(@as(usize, 6), h.root.activeTab().?.selection.head.col);
}

test "a window resize relayouts everything" {
    const h = try Harness.init(testing.allocator, "root-resize");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });

    try h.send(.{ .resize = .{ .width = 640, .height = 400 } });
    try testing.expectEqual(@as(u32, 640), h.root.surface.width);
    try testing.expectEqual(@as(i32, 640), h.root.statusRect().w);
    try h.root.paint();
}

/// Two notes, the second dirty and unsaved -- the state the window golden and
/// the two chrome goldens all start from.
fn goldenScene(h: *Harness) !void {
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("# 프로젝트 노트\n\n첫 번째 노트입니다.");
    try h.key(.{ .character = 's' }, .{ .meta = true });

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("# Weekly sync\n\n안녕하세요 반갑습니다\n\t- indented item\nplain **bold** tail");
    try h.key(.{ .character = 's' }, .{ .meta = true });
    try h.typeText("\nunsaved edit");

    h.root.now_ms = 1_724_500_000_000;
    h.root.editor.caret_phase_ms = 0;
}

test "golden: the settings panel, rounded as the stylesheet had it" {
    const h = try Harness.init(testing.allocator, "root-golden-settings");
    defer h.deinit();
    try goldenScene(h);

    h.root.settings.open = true;
    try h.root.paint();

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "settings", &h.root.surface);
}

test "golden: the sidebar and bottom bar under the pointer" {
    const h = try Harness.init(testing.allocator, "root-golden-hover");
    defer h.deinit();
    try goldenScene(h);

    // The second note row: the first is the active one, whose own background
    // covers hover, so it would show nothing.
    const row = h.root.sidebar.rect.y + chrome.Sidebar.header_h + 21 +
        theme.sidebar_group_h + theme.sidebar_row_h + @divTrunc(theme.sidebar_row_h, 2);
    try h.send(.{ .mouse_move = .{ .x = h.root.sidebar.rect.x + 60, .y = row } });
    try h.root.paint();
    try testing.expect(h.root.sidebar.hover != null);
    // `.entry:hover { background: var(--bg-2) }`. The two greys are seven
    // values apart, so this is checked by number rather than by eye.
    // Inside the row's 20px left padding, so the probe cannot land on a glyph
    // whose width depends on the face in use.
    try testing.expect(h.root.surface.at(h.root.sidebar.rect.x + 5, row).eql(theme.palette.bg_2));

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "sidebar-hover", &h.root.surface);
}

test "golden: a hovered bottom-bar button" {
    const h = try Harness.init(testing.allocator, "root-golden-btn");
    defer h.deinit();
    try goldenScene(h);

    const bar = h.root.statusRect();
    try h.send(.{ .mouse_move = .{ .x = bar.x + 20, .y = bar.y + @divTrunc(bar.h, 2) } });
    try h.root.paint();
    try testing.expectEqual(chrome.StatusBar.Button.trash, h.root.status_hover.?);
    // In the 4px gap between the icon and the label, so the probe lands on
    // the button's own background rather than on ink.
    try testing.expect(h.root.surface.at(bar.x + 26, bar.y + @divTrunc(bar.h, 2)).eql(theme.palette.bg_2));

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "bottom-bar-hover", &h.root.surface);
}

test "a denser display draws the same layout into a bigger surface" {
    const one = try Harness.init(testing.allocator, "root-scale-1");
    defer one.deinit();
    const two = try Harness.initScaled(testing.allocator, "root-scale-2", 2);
    defer two.deinit();

    // Logical geometry is identical...
    try testing.expectEqual(one.root.bounds(), two.root.bounds());
    try testing.expectEqual(one.root.sidebar.rect, two.root.sidebar.rect);
    try testing.expectEqual(one.root.editorRect(), two.root.editorRect());
    try testing.expectApproxEqAbs(
        one.root.fonts.mono_default.metrics.ch_width,
        two.root.fonts.mono_default.metrics.ch_width,
        0.01,
    );

    // ...and only the surface behind it is denser.
    try testing.expectEqual(one.root.surface.width * 2, two.root.surface.width);
    try testing.expectEqual(one.root.surface.height * 2, two.root.surface.height);
}

test "a resize onto a denser display rebuilds the faces" {
    const h = try Harness.init(testing.allocator, "root-rescale");
    defer h.deinit();

    const before = h.root.fonts.mono_default.metrics.ch_width;
    try h.send(.{ .resize = .{ .width = 900, .height = 560, .scale = 2 } });

    try testing.expectEqual(@as(u32, 1800), h.root.surface.width);
    try testing.expectEqual(@as(i32, 900), h.root.bounds().w);
    // The logical cell is unchanged; the glyphs behind it are twice the size.
    try testing.expectApproxEqAbs(before, h.root.fonts.mono_default.metrics.ch_width, 0.01);
}

test "golden: the whole window on a Retina display" {
    const h = try Harness.initScaled(testing.allocator, "root-golden-2x", 2);
    defer h.deinit();
    try goldenScene(h);
    h.root.toast.show("Saved", h.root.now_ms);
    try h.root.paint();

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "window-2x", &h.root.surface);
}

test "a trackpad scrolls with the fingers, a wheel notch by rows" {
    const h = try Harness.init(testing.allocator, "root-wheel");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    var long: [200][]const u8 = undefined;
    for (&long) |*l| l.* = "a line of text\n";
    for (long) |l| try h.typeText(l);

    const e = h.root.editorRect();
    const px = e.x + @divTrunc(e.w, 2);
    const py = e.y + @divTrunc(e.h, 2);

    // A fraction can only have come from a trackpad: the content follows the
    // fingers, ten points per unit.
    h.root.now_ms = 1_000;
    h.root.editor.scrollTo(1000);
    const before = h.root.editor.scroll_top;
    try h.send(.{ .wheel = .{ .x = px, .y = py, .dx = 0, .dy = -2.5 } });
    try testing.expectApproxEqAbs(before + 25, h.root.editor.scroll_top, 0.01);

    // A whole number, well after any gesture, is a stepped wheel: three rows.
    h.root.now_ms = 10_000;
    h.root.editor.scrollTo(1000);
    try h.send(.{ .wheel = .{ .x = px, .y = py, .dx = 0, .dy = -1 } });
    try testing.expectApproxEqAbs(
        1000 + h.root.editor.rowHeight() * 3,
        h.root.editor.scroll_top,
        0.01,
    );
}

test "one whole-numbered event mid-gesture does not jolt the page" {
    const h = try Harness.init(testing.allocator, "root-wheel-grace");
    defer h.deinit();
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    var long: [200][]const u8 = undefined;
    for (&long) |*l| l.* = "a line of text\n";
    for (long) |l| try h.typeText(l);

    const e = h.root.editorRect();
    const px = e.x + @divTrunc(e.w, 2);
    const py = e.y + @divTrunc(e.h, 2);

    h.root.now_ms = 1_000;
    h.root.editor.scrollTo(1000);
    try h.send(.{ .wheel = .{ .x = px, .y = py, .dx = 0, .dy = -0.3 } });

    // Still the same swipe, and this delta happens to be exactly one.
    h.root.now_ms = 1_050;
    const before = h.root.editor.scroll_top;
    try h.send(.{ .wheel = .{ .x = px, .y = py, .dx = 0, .dy = -1 } });
    try testing.expectApproxEqAbs(before + 10, h.root.editor.scroll_top, 0.01);
}

test "the sidebar list stops when it runs out of notes" {
    const h = try Harness.init(testing.allocator, "root-sidebar-scroll");
    defer h.deinit();

    // Two notes: nothing like enough to fill the list.
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("first");
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("second");
    try h.root.paint();

    const s = h.root.sidebar;
    try testing.expectEqual(@as(f64, 0), s.maxScroll(h.root.groups.items));

    // A firm swipe down moves nothing, because there is nothing below.
    const px = s.rect.x + 40;
    const py = s.rect.y + s.rect.h - 40;
    h.root.now_ms = 1_000;
    for (0..20) |_| try h.send(.{ .wheel = .{ .x = px, .y = py, .dx = 0, .dy = -12.5 } });
    try testing.expectEqual(@as(f64, 0), h.root.sidebar.scroll_top);
}

test "a scrolled sidebar list never draws over its header" {
    const h = try Harness.init(testing.allocator, "root-sidebar-clip");
    defer h.deinit();
    for (0..60) |_| {
        try h.key(.{ .character = 'n' }, .{ .meta = true });
        try h.typeText("a note");
    }
    try h.root.paint();

    const list = h.root.sidebar.listRect();
    try testing.expect(h.root.sidebar.maxScroll(h.root.groups.items) > 0);

    // Scroll well into the list, so rows would land over the header.
    h.root.sidebar.scroll_top = 200;
    try h.root.paint();

    // Nothing above the list may move when the list scrolls. That is a
    // stronger claim than any single probe, and it does not depend on knowing
    // which colour a given pixel should have.
    const above_rows: usize = @intCast(list.y - h.root.sidebar.rect.y);
    const stride: usize = h.root.surface.width;
    const px_above = stride * above_rows * @as(usize, @intFromFloat(h.root.fonts.scale));

    const before = try testing.allocator.dupe(gfx.Rgba, h.root.surface.pixels[0..px_above]);
    defer testing.allocator.free(before);

    h.root.sidebar.scroll_top = 200;
    h.root.invalidate();
    try h.root.paint();
    try testing.expect(h.root.sidebar.scroll_top > 0);

    try testing.expectEqualSlices(gfx.Rgba, before, h.root.surface.pixels[0..px_above]);
}

test "golden: the whole window" {
    const h = try Harness.init(testing.allocator, "root-golden");
    defer h.deinit();

    // Two notes so the sidebar has content, with the second left dirty.
    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("# 프로젝트 노트\n\n첫 번째 노트입니다.");
    try h.key(.{ .character = 's' }, .{ .meta = true });

    try h.key(.{ .character = 'n' }, .{ .meta = true });
    try h.typeText("# Weekly sync\n\n안녕하세요 반갑습니다\n\t- indented item\nplain **bold** tail");
    try h.key(.{ .character = 's' }, .{ .meta = true });
    try h.typeText("\nunsaved edit");

    const tab = h.root.activeTab().?;
    tab.selection = .{ .anchor = .{ .line = 2, .col = 0 }, .head = .{ .line = 2, .col = 15 } };
    h.root.now_ms = 1_724_500_000_000;
    h.root.editor.caret_phase_ms = 0;
    h.root.toast.show("Saved", h.root.now_ms);

    try h.root.paint();

    var tio = try golden.TestIo.init(testing.allocator);
    defer tio.deinit();
    try golden.expectMatches(testing.allocator, tio.io, "window", &h.root.surface);
}
