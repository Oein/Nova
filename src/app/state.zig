//! Application state: the note list, open tabs, and the timers that persist
//! them.
//!
//! Ported from `src/lib/tabManager.ts`, `sessionManager.ts` and `autoSave.ts`.
//! Those were three modules mostly because Svelte stores forced the split; the
//! state they coordinate is one thing.
//!
//! There are two independent persistence loops, as in the original:
//!
//!   * **Session flush** (~300 ms after an edit) writes cursor, scroll and the
//!     *unsaved* buffer text into `workspace.db`, so a crash loses nothing.
//!   * **Auto-save** (a user-set interval, 30 s by default) writes dirty notes
//!     out to their real files, exactly as Cmd+S would.
//!
//! Both are driven by `tick`, not by OS timers, so the event loop owns the
//! clock and tests need no fake one.

const std = @import("std");
const core = @import("core");
const db = @import("db");

const Allocator = std.mem.Allocator;
const Buffer = core.buffer.Buffer;
const Selection = core.selection.Selection;
const Workspace = db.workspace.Workspace;
const Note = db.workspace.Note;

/// How long after an edit the session state is written to the database.
pub const tab_save_debounce_ms: i64 = 300;

/// How long after a tab-set change the whole session is rewritten.
pub const session_flush_debounce_ms: i64 = 200;

pub const autosave_default_sec: u32 = 30;
pub const autosave_min_sec: u32 = 5;
pub const autosave_max_sec: u32 = 3600;

pub fn clampAutosaveInterval(sec: u32) u32 {
    return std.math.clamp(sec, autosave_min_sec, autosave_max_sec);
}

pub const Tab = struct {
    note_id: []u8,
    /// Live title, re-derived from line 0 on every edit. The file on disk keeps
    /// its old name until the note is actually saved.
    title: []u8,
    buffer: Buffer,
    selection: Selection = Selection.initial,
    scroll_top: f64 = 0,
    /// Mtime of the file as of the last read or save -- the optimistic
    /// concurrency baseline.
    mtime_ms: i64 = 0,
    /// Content as of the last read or save, for dirty detection.
    disk_content: []u8,
    dirty: bool = false,
    /// True while the note exists only because `createAndOpenNote` materialized
    /// a placeholder row and file. Closing such a tab hard-deletes the note:
    /// the user never committed anything, so there is nothing to preserve.
    /// Deliberately not persisted -- a restored tab is always "saved", since
    /// the disk already holds whatever we would restore.
    never_saved: bool = false,

    /// Bumped on every edit. Cheap; used to decide whether the debounced
    /// session write has anything to do.
    edit_seq: u64 = 0,
    persisted_seq: u64 = 0,
    /// When the debounced session write for this tab comes due.
    save_due_ms: ?i64 = null,

    fn deinit(self: *Tab, gpa: Allocator) void {
        gpa.free(self.note_id);
        gpa.free(self.title);
        gpa.free(self.disk_content);
        self.buffer.deinit();
    }

    pub fn cursor(self: *const Tab) core.buffer.Pos {
        return self.selection.head;
    }
};

/// What closing a tab requires of the caller.
pub const CloseOutcome = enum {
    /// The tab is gone.
    closed,
    /// The tab has unsaved edits; ask the user before discarding.
    needs_confirm,
};

pub const App = struct {
    gpa: Allocator,
    io: std.Io,

    ws: ?Workspace = null,
    notes: std.ArrayList(Note) = .empty,
    tabs: std.ArrayList(Tab) = .empty,
    active: ?usize = null,

    autosave_enabled: bool = true,
    autosave_interval_sec: u32 = autosave_default_sec,
    next_autosave_ms: ?i64 = null,

    session_flush_due_ms: ?i64 = null,

    pub fn init(gpa: Allocator, io: std.Io) App {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *App) void {
        self.closeWorkspace();
        self.tabs.deinit(self.gpa);
        self.notes.deinit(self.gpa);
    }

    fn clearTabs(self: *App) void {
        for (self.tabs.items) |*t| t.deinit(self.gpa);
        self.tabs.clearRetainingCapacity();
        self.active = null;
    }

    fn clearNotes(self: *App) void {
        for (self.notes.items) |n| n.deinit(self.gpa);
        self.notes.clearRetainingCapacity();
    }

    pub fn closeWorkspace(self: *App) void {
        self.clearTabs();
        self.clearNotes();
        if (self.ws) |*w| {
            w.close();
            self.ws = null;
        }
    }

    // -- workspace -----------------------------------------------------------

    /// Open a workspace and restore its session.
    pub fn openWorkspace(self: *App, path: []const u8) !void {
        self.closeWorkspace();
        self.ws = try Workspace.open(self.gpa, self.io, path);
        try self.refreshNotes();
        try self.restoreSession();
    }

    fn workspace(self: *App) !*Workspace {
        return if (self.ws) |*w| w else error.NoWorkspace;
    }

    /// Re-read the note list from the database.
    pub fn refreshNotes(self: *App) !void {
        const w = try self.workspace();
        const fresh = try w.listNotes();
        self.clearNotes();
        try self.notes.appendSlice(self.gpa, fresh);
        // `listNotes` allocated the slice; the elements moved into `notes`.
        self.gpa.free(fresh);
    }

    pub fn findNote(self: *App, id: []const u8) ?*Note {
        for (self.notes.items) |*n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    /// Update a note's list entry in place after a save, without a full reload.
    fn touchNote(self: *App, id: []const u8, title: []const u8, mtime_ms: i64, size: i64) !void {
        const n = self.findNote(id) orelse return;
        const new_title = try self.gpa.dupe(u8, title);
        self.gpa.free(n.title);
        n.title = new_title;
        n.mtime_ms = mtime_ms;
        n.size = size;
    }

    fn removeNoteFromList(self: *App, id: []const u8) void {
        var i: usize = 0;
        while (i < self.notes.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.notes.items[i].id, id)) {
                self.notes.items[i].deinit(self.gpa);
                _ = self.notes.orderedRemove(i);
                return;
            }
        }
    }

    // -- tabs ----------------------------------------------------------------

    pub fn findTab(self: *App, note_id: []const u8) ?usize {
        for (self.tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.note_id, note_id)) return i;
        }
        return null;
    }

    pub fn activeTab(self: *App) ?*Tab {
        const i = self.active orelse return null;
        if (i >= self.tabs.items.len) return null;
        return &self.tabs.items[i];
    }

    /// Open a note, or focus it if already open.
    pub fn openNote(self: *App, id: []const u8) !usize {
        if (self.findTab(id)) |i| {
            self.active = i;
            return i;
        }
        const w = try self.workspace();
        const read = try w.readNote(id);
        errdefer read.deinit(self.gpa);

        const index = try self.pushTab(id, read.content, read.mtime_ms, false);
        read.deinit(self.gpa);
        return index;
    }

    /// Create a note and open it. The row and file are materialized eagerly so
    /// the note has a real identity, but the tab is marked `never_saved` until
    /// the user commits it.
    pub fn createAndOpenNote(self: *App) !usize {
        const w = try self.workspace();
        const note = try w.createNote();
        errdefer note.deinit(self.gpa);

        try self.notes.append(self.gpa, note);
        const index = try self.pushTab(note.id, "", note.mtime_ms, true);
        self.scheduleSessionFlush(w.nowMs());
        return index;
    }

    fn pushTab(
        self: *App,
        note_id: []const u8,
        content: []const u8,
        mtime_ms: i64,
        never_saved: bool,
    ) !usize {
        var buffer = try Buffer.initFromString(self.gpa, content, mtime_ms);
        errdefer buffer.deinit();

        const id_owned = try self.gpa.dupe(u8, note_id);
        errdefer self.gpa.free(id_owned);
        const disk = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(disk);
        const title = try self.gpa.dupe(
            u8,
            db.workspace.firstLineTitle(content, db.workspace.default_title),
        );

        try self.tabs.append(self.gpa, .{
            .note_id = id_owned,
            .title = title,
            .buffer = buffer,
            .disk_content = disk,
            .mtime_ms = mtime_ms,
            .never_saved = never_saved,
        });
        self.active = self.tabs.items.len - 1;
        return self.active.?;
    }

    /// Record that a tab's buffer changed: re-derive the title and arm the
    /// debounced session write.
    ///
    /// Only line 0 is read here. The original passed the whole document through
    /// `firstLineTitle` on every keystroke; the title can only come from the
    /// first line, so this is O(1) instead of O(document).
    pub fn noteEdited(self: *App, index: usize, now_ms: i64) !void {
        const tab = &self.tabs.items[index];
        tab.edit_seq += 1;
        // Optimistic: the accurate comparison happens when the debounced write
        // serializes the buffer anyway.
        tab.dirty = true;
        tab.save_due_ms = now_ms + tab_save_debounce_ms;

        const derived = db.workspace.firstLineTitle(
            tab.buffer.getLine(0),
            db.workspace.default_title,
        );
        if (!std.mem.eql(u8, derived, tab.title)) {
            const owned = try self.gpa.dupe(u8, derived);
            self.gpa.free(tab.title);
            tab.title = owned;
            // The sidebar shows the live title even though the filename only
            // catches up on save.
            try self.touchNoteTitle(tab.note_id, owned);
        }
    }

    fn touchNoteTitle(self: *App, id: []const u8, title: []const u8) !void {
        const n = self.findNote(id) orelse return;
        const owned = try self.gpa.dupe(u8, title);
        self.gpa.free(n.title);
        n.title = owned;
    }

    // -- saving --------------------------------------------------------------

    /// Write a tab to disk. Returns false when the save was rejected (the file
    /// changed underneath us).
    pub fn saveTab(self: *App, index: usize) !bool {
        const w = try self.workspace();
        const tab = &self.tabs.items[index];

        const content = try tab.buffer.toOwnedString(self.gpa);
        defer self.gpa.free(content);

        const saved = w.writeNote(tab.note_id, content, tab.mtime_ms) catch |err| switch (err) {
            error.MtimeMismatch => return false,
            else => return err,
        };
        defer saved.deinit(self.gpa);

        tab.mtime_ms = saved.mtime_ms;
        tab.never_saved = false;
        tab.dirty = false;
        try tab.buffer.markSaved(saved.mtime_ms);

        const new_disk = try self.gpa.dupe(u8, content);
        self.gpa.free(tab.disk_content);
        tab.disk_content = new_disk;

        try self.touchNote(tab.note_id, saved.title, saved.mtime_ms, saved.size);
        // The stored copy of the unsaved text is now stale.
        try w.saveTab(self.sessionTabFor(tab, index, null));
        return true;
    }

    /// Save every dirty tab. Dirtiness is rechecked per tab, since an earlier
    /// save in the loop may have cleaned one.
    pub fn flushDirtyTabs(self: *App) !void {
        var i: usize = 0;
        while (i < self.tabs.items.len) : (i += 1) {
            if (!self.tabs.items[i].dirty) continue;
            _ = try self.saveTab(i);
        }
    }

    pub fn anyDirty(self: *App) bool {
        for (self.tabs.items) |t| {
            if (t.dirty) return true;
        }
        return false;
    }

    // -- closing and deleting ------------------------------------------------

    /// Close a tab, discarding its edits.
    pub fn closeTabForce(self: *App, index: usize) !void {
        const w = try self.workspace();
        var tab = self.tabs.items[index];

        // A note that was never committed leaves nothing behind.
        const was_never_saved = tab.never_saved;
        const id = try self.gpa.dupe(u8, tab.note_id);
        defer self.gpa.free(id);

        tab.deinit(self.gpa);
        _ = self.tabs.orderedRemove(index);

        if (self.tabs.items.len == 0) {
            self.active = null;
        } else if (self.active) |a| {
            // Falling back to the last tab matches the original.
            self.active = if (a >= self.tabs.items.len) self.tabs.items.len - 1 else a;
        }

        try w.removeTab(id);
        if (was_never_saved) {
            try w.hardDeleteNote(id);
            self.removeNoteFromList(id);
        }
        self.scheduleSessionFlush(w.nowMs());
    }

    /// Close a tab the way the close button does.
    ///
    /// Three paths, as in the original: a never-saved note is discarded outright
    /// (no dialog -- there is nothing to lose), a dirty tab needs confirmation,
    /// and a clean tab just closes.
    pub fn closeTab(self: *App, index: usize) !CloseOutcome {
        const tab = &self.tabs.items[index];
        if (!tab.never_saved and tab.dirty) return .needs_confirm;
        try self.closeTabForce(index);
        return .closed;
    }

    /// Move notes to the trash, closing any open tabs first.
    pub fn deleteNotes(self: *App, ids: []const []const u8) !void {
        const w = try self.workspace();
        const now = w.nowMs();
        for (ids) |id| {
            if (self.findTab(id)) |i| try self.closeTabForce(i);
            try w.trashNote(id, now);
            self.removeNoteFromList(id);
        }
        self.scheduleSessionFlush(now);
    }

    /// Re-read a tab from disk after something else rewrote the file.
    ///
    /// Refuses when the tab has unsaved edits, and applies the replacement as
    /// an edit rather than swapping the buffer, so it stays undoable.
    pub fn reloadTabFromDisk(self: *App, index: usize, now_ms: i64) !bool {
        const w = try self.workspace();
        const tab = &self.tabs.items[index];
        if (tab.dirty) return false;

        const read = try w.readNote(tab.note_id);
        defer read.deinit(self.gpa);

        const last = tab.buffer.lineCount() - 1;
        try tab.buffer.beginGroup();
        try tab.buffer.applyEdit(.{ .delete = .{
            .from = .{ .line = 0, .col = 0 },
            .to = .{ .line = last, .col = tab.buffer.getLine(last).len },
        } }, now_ms);
        try tab.buffer.applyEdit(.{ .insert = .{
            .at = .{ .line = 0, .col = 0 },
            .text = read.content,
        } }, now_ms);
        try tab.buffer.endGroup();

        const disk = try self.gpa.dupe(u8, read.content);
        self.gpa.free(tab.disk_content);
        tab.disk_content = disk;
        tab.mtime_ms = read.mtime_ms;
        tab.dirty = false;
        try self.noteEdited(index, now_ms);
        tab.dirty = false;
        return true;
    }

    // -- session persistence -------------------------------------------------

    fn sessionTabFor(
        self: *App,
        tab: *const Tab,
        index: usize,
        unsaved: ?[]const u8,
    ) db.workspace.SessionTab {
        _ = self;
        return .{
            .note_id = tab.note_id,
            .position = @intCast(index),
            .cursor_line = @intCast(tab.selection.head.line),
            .cursor_col = @intCast(tab.selection.head.col),
            .scroll_top = @intFromFloat(tab.scroll_top),
            .unsaved_content = unsaved,
            .undo_log = null,
        };
    }

    /// Write one tab's state to the database.
    ///
    /// This is where the buffer is serialized, and where `dirty` becomes exact:
    /// the optimistic flag set on each keystroke is replaced by an actual
    /// comparison against the last known disk content, so undoing back to the
    /// saved text clears the dot.
    fn persistTab(self: *App, index: usize) !void {
        const w = try self.workspace();
        const tab = &self.tabs.items[index];

        const content = try tab.buffer.toOwnedString(self.gpa);
        defer self.gpa.free(content);

        tab.dirty = !std.mem.eql(u8, content, tab.disk_content);

        const undo_log = try tab.buffer.serializeHistory(self.gpa);
        defer self.gpa.free(undo_log);

        var st = self.sessionTabFor(tab, index, if (tab.dirty) content else null);
        st.undo_log = undo_log;
        try w.saveTab(st);

        tab.persisted_seq = tab.edit_seq;
        tab.save_due_ms = null;
    }

    pub fn scheduleSessionFlush(self: *App, now_ms: i64) void {
        self.session_flush_due_ms = now_ms + session_flush_debounce_ms;
    }

    /// Rewrite the whole session: tab order and the active tab.
    pub fn flushSession(self: *App) !void {
        const w = try self.workspace();

        var tabs = try self.gpa.alloc(db.workspace.SessionTab, self.tabs.items.len);
        defer self.gpa.free(tabs);
        for (self.tabs.items, 0..) |*t, i| tabs[i] = self.sessionTabFor(t, i, null);

        const active_id = if (self.activeTab()) |t| t.note_id else null;
        try w.saveSession(.{ .tabs = tabs, .active_tab = active_id });
        self.session_flush_due_ms = null;
    }

    /// Rebuild tabs from the stored session.
    fn restoreSession(self: *App) !void {
        const w = try self.workspace();
        const session = try w.loadSession();
        defer session.deinit(self.gpa);

        for (session.tabs) |st| {
            // A note deleted since the session was written is simply skipped.
            const read = w.readNote(st.note_id) catch continue;
            defer read.deinit(self.gpa);

            const content = st.unsaved_content orelse read.content;
            const index = self.pushTab(st.note_id, content, read.mtime_ms, false) catch continue;
            const tab = &self.tabs.items[index];

            // `disk_content` must be the file, not the restored buffer, or an
            // unsaved tab would come back looking clean.
            const disk = try self.gpa.dupe(u8, read.content);
            self.gpa.free(tab.disk_content);
            tab.disk_content = disk;
            tab.dirty = st.unsaved_content != null;

            tab.selection = Selection.at(.{
                .line = @intCast(@max(st.cursor_line, 0)),
                .col = @intCast(@max(st.cursor_col, 0)),
            });
            tab.selection = .{
                .anchor = tab.buffer.clampPos(tab.selection.anchor),
                .head = tab.buffer.clampPos(tab.selection.head),
            };
            tab.scroll_top = @floatFromInt(st.scroll_top);

            if (st.undo_log) |log| {
                tab.buffer.restoreHistory(self.gpa, log) catch {};
            }
        }

        self.active = null;
        if (session.active_tab) |id| {
            if (self.findTab(id)) |i| self.active = i;
        }
        if (self.active == null and self.tabs.items.len > 0) self.active = 0;
    }

    // -- the clock -----------------------------------------------------------

    /// Drive the debounced writes and the auto-save interval.
    ///
    /// Call once per frame. Returns true if anything was written, which the UI
    /// uses to decide whether the note list needs redrawing.
    pub fn tick(self: *App, now_ms: i64) !bool {
        if (self.ws == null) return false;
        var did_work = false;

        for (self.tabs.items, 0..) |*t, i| {
            if (t.save_due_ms) |due| {
                if (now_ms >= due) {
                    try self.persistTab(i);
                    did_work = true;
                }
            }
        }

        if (self.session_flush_due_ms) |due| {
            if (now_ms >= due) {
                try self.flushSession();
                did_work = true;
            }
        }

        if (self.autosave_enabled) {
            const interval: i64 = @as(i64, clampAutosaveInterval(self.autosave_interval_sec)) * 1000;
            const due = self.next_autosave_ms orelse blk: {
                self.next_autosave_ms = now_ms + interval;
                break :blk now_ms + interval;
            };
            if (now_ms >= due) {
                self.next_autosave_ms = now_ms + interval;
                if (self.anyDirty()) {
                    try self.flushDirtyTabs();
                    did_work = true;
                }
            }
        } else {
            self.next_autosave_ms = null;
        }

        return did_work;
    }

    /// Apply an auto-save settings change, re-arming the interval.
    pub fn setAutoSave(self: *App, enabled: bool, interval_sec: u32, now_ms: i64) void {
        self.autosave_enabled = enabled;
        self.autosave_interval_sec = clampAutosaveInterval(interval_sec);
        self.next_autosave_ms = if (enabled)
            now_ms + @as(i64, self.autosave_interval_sec) * 1000
        else
            null;
    }
};

// -- tests -------------------------------------------------------------------
// Covers the behavior of tabManager.ts, sessionManager.ts and autoSave.ts,
// including the scenarios the puppeteer e2e suite pinned.

const testing = std.testing;

const TestApp = struct {
    env: db.fsx.TestEnv,
    app: App,
    root: []u8,
    gpa: Allocator,

    fn init(gpa: Allocator, name: []const u8) !TestApp {
        var env = try db.fsx.TestEnv.init(gpa, name);
        errdefer env.deinit();
        const root = try std.fmt.allocPrint(gpa, "{s}/ws", .{env.path});
        errdefer gpa.free(root);

        var self = TestApp{
            .env = env,
            .app = App.init(gpa, env.io),
            .root = root,
            .gpa = gpa,
        };
        try self.app.openWorkspace(root);
        return self;
    }

    fn deinit(self: *TestApp) void {
        self.app.deinit();
        self.gpa.free(self.root);
        self.env.deinit();
    }

    /// Reopen the same workspace with fresh state, as a restart would.
    fn reopen(self: *TestApp) !void {
        self.app.deinit();
        self.app = App.init(self.gpa, self.env.io);
        try self.app.openWorkspace(self.root);
    }

    fn type_(self: *TestApp, index: usize, text: []const u8, now_ms: i64) !void {
        const tab = &self.app.tabs.items[index];
        tab.selection = try core.commands.apply(
            &tab.buffer,
            tab.selection,
            .{ .insert = .{ .text = text } },
            now_ms,
        );
        tab.buffer.clearChanges();
        try self.app.noteEdited(index, now_ms);
    }

    fn textOf(self: *TestApp, index: usize) ![]u8 {
        return self.app.tabs.items[index].buffer.toOwnedString(self.gpa);
    }
};

test "creating a note opens a tab and lists it" {
    var t = try TestApp.init(testing.allocator, "app-create");
    defer t.deinit();

    const i = try t.app.createAndOpenNote();
    try testing.expectEqual(@as(usize, 0), i);
    try testing.expectEqual(@as(usize, 1), t.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), t.app.notes.items.len);
    try testing.expectEqualStrings("Untitled", t.app.tabs.items[0].title);
    try testing.expect(t.app.tabs.items[0].never_saved);
}

test "editing updates the live title in the sidebar before any save" {
    var t = try TestApp.init(testing.allocator, "app-title");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();

    try t.type_(i, "# Weekly sync\nbody", 1000);

    try testing.expectEqualStrings("Weekly sync", t.app.tabs.items[i].title);
    // The sidebar entry follows immediately, though the filename does not.
    try testing.expectEqualStrings("Weekly sync", t.app.notes.items[0].title);
    const path = t.app.ws.?.notePath(t.app.tabs.items[i].note_id);
    try testing.expect(std.mem.startsWith(u8, path.slice(), "notes/Untitled-"));
}

test "saving writes the file, renames it and clears dirty" {
    var t = try TestApp.init(testing.allocator, "app-save");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    try t.type_(i, "# Real Title\nbody", 1000);

    try testing.expect(try t.app.saveTab(i));
    try testing.expect(!t.app.tabs.items[i].dirty);
    try testing.expect(!t.app.tabs.items[i].never_saved);

    const path = t.app.ws.?.notePath(t.app.tabs.items[i].note_id);
    try testing.expect(std.mem.startsWith(u8, path.slice(), "notes/Real-Title-"));

    const on_disk = try t.app.ws.?.fs.read(testing.allocator, path.slice());
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("# Real Title\nbody", on_disk);
}

test "undoing back to the saved text clears the dirty flag" {
    var t = try TestApp.init(testing.allocator, "app-dirty");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    try t.type_(i, "hello", 1000);
    _ = try t.app.saveTab(i);

    try t.type_(i, "!", 2000);
    try testing.expect(t.app.tabs.items[i].dirty);

    // Undo puts the text back; the exact comparison happens on the debounced
    // write, which `tick` runs.
    _ = try t.app.tabs.items[i].buffer.undo();
    try t.app.noteEdited(i, 3000);
    _ = try t.app.tick(3000 + tab_save_debounce_ms);

    try testing.expect(!t.app.tabs.items[i].dirty);
}

test "an unsaved edit and its undo history survive a restart" {
    // This is e2e scenario 08 (`session_restore_unsaved_and_undo`).
    var t = try TestApp.init(testing.allocator, "app-session");
    defer t.deinit();

    const i = try t.app.createAndOpenNote();
    try t.type_(i, "committed", 1000);
    _ = try t.app.saveTab(i);
    try t.type_(i, " and more", 2000);

    // Let both debounced writes land.
    _ = try t.app.tick(2000 + tab_save_debounce_ms);
    _ = try t.app.tick(2000 + session_flush_debounce_ms + tab_save_debounce_ms);

    const note_id = try testing.allocator.dupe(u8, t.app.tabs.items[i].note_id);
    defer testing.allocator.free(note_id);

    try t.reopen();

    try testing.expectEqual(@as(usize, 1), t.app.tabs.items.len);
    try testing.expectEqualStrings(note_id, t.app.tabs.items[0].note_id);
    try testing.expect(t.app.tabs.items[0].dirty);

    const text = try t.textOf(0);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("committed and more", text);

    // Undo history came back with it.
    _ = try t.app.tabs.items[0].buffer.undo();
    const undone = try t.textOf(0);
    defer testing.allocator.free(undone);
    try testing.expectEqualStrings("committed", undone);
}

test "cursor and scroll are restored" {
    var t = try TestApp.init(testing.allocator, "app-cursor");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    try t.type_(i, "line one\nline two", 1000);
    _ = try t.app.saveTab(i);

    t.app.tabs.items[i].selection = Selection.at(.{ .line = 1, .col = 4 });
    t.app.tabs.items[i].scroll_top = 120;
    try t.app.noteEdited(i, 2000);
    _ = try t.app.tick(2000 + tab_save_debounce_ms);
    try t.app.flushSession();

    try t.reopen();
    try testing.expectEqual(@as(usize, 1), t.app.tabs.items[0].selection.head.line);
    try testing.expectEqual(@as(usize, 4), t.app.tabs.items[0].selection.head.col);
    try testing.expectEqual(@as(f64, 120), t.app.tabs.items[0].scroll_top);
}

test "a restored cursor is clamped to the restored text" {
    var t = try TestApp.init(testing.allocator, "app-clamp");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    try t.type_(i, "short", 1000);
    _ = try t.app.saveTab(i);

    // A stored cursor well past the end of the document.
    try t.app.ws.?.saveTab(.{
        .note_id = t.app.tabs.items[i].note_id,
        .position = 0,
        .cursor_line = 99,
        .cursor_col = 99,
    });

    try t.reopen();
    try testing.expectEqual(@as(usize, 0), t.app.tabs.items[0].selection.head.line);
    try testing.expectEqual(@as(usize, 5), t.app.tabs.items[0].selection.head.col);
}

test "auto-save writes dirty tabs on the interval" {
    var t = try TestApp.init(testing.allocator, "app-autosave");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);

    t.app.setAutoSave(true, 10, 0);
    try t.type_(i, "typed", 1000);
    try testing.expect(t.app.tabs.items[i].dirty);

    // Before the interval elapses nothing is written.
    _ = try t.app.tick(5_000);
    {
        const path = t.app.ws.?.notePath(t.app.tabs.items[i].note_id);
        const on_disk = try t.app.ws.?.fs.read(testing.allocator, path.slice());
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings("", on_disk);
    }

    _ = try t.app.tick(10_000);
    try testing.expect(!t.app.tabs.items[i].dirty);

    // Saving also renamed the file, since the first line is now the title --
    // so the path has to be resolved again.
    const path = t.app.ws.?.notePath(t.app.tabs.items[i].note_id);
    try testing.expect(std.mem.startsWith(u8, path.slice(), "notes/typed-"));
    const on_disk = try t.app.ws.?.fs.read(testing.allocator, path.slice());
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("typed", on_disk);
}

test "auto-save does nothing when disabled or when nothing is dirty" {
    var t = try TestApp.init(testing.allocator, "app-autosave-off");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);

    t.app.setAutoSave(false, 10, 0);
    try t.type_(i, "typed", 1000);
    _ = try t.app.tick(100_000);
    try testing.expect(t.app.tabs.items[i].dirty);

    // Enabled but clean: the tick does no work.
    _ = try t.app.saveTab(i);
    t.app.setAutoSave(true, 10, 0);
    try testing.expect(!try t.app.tick(10_000));
}

test "changing the interval re-arms the timer" {
    var t = try TestApp.init(testing.allocator, "app-autosave-rearm");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);

    t.app.setAutoSave(true, 3600, 0);
    try t.type_(i, "x", 1);
    _ = try t.app.tick(60_000);
    try testing.expect(t.app.tabs.items[i].dirty);

    // A shorter interval takes effect from now, not from the old deadline.
    t.app.setAutoSave(true, 5, 60_000);
    _ = try t.app.tick(64_000);
    try testing.expect(t.app.tabs.items[i].dirty);
    _ = try t.app.tick(65_000);
    try testing.expect(!t.app.tabs.items[i].dirty);
}

test "the auto-save interval is clamped" {
    try testing.expectEqual(@as(u32, autosave_min_sec), clampAutosaveInterval(0));
    try testing.expectEqual(@as(u32, autosave_max_sec), clampAutosaveInterval(999_999));
    try testing.expectEqual(@as(u32, 42), clampAutosaveInterval(42));
}

test "closing a never-saved note discards it entirely" {
    var t = try TestApp.init(testing.allocator, "app-close-new");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    const id = try testing.allocator.dupe(u8, t.app.tabs.items[i].note_id);
    defer testing.allocator.free(id);

    // No dialog: nothing was ever committed.
    try testing.expectEqual(CloseOutcome.closed, try t.app.closeTab(i));
    try testing.expectEqual(@as(usize, 0), t.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), t.app.notes.items.len);
    try testing.expectError(error.NoteNotFound, t.app.ws.?.getNote(id));
}

test "closing a dirty saved note asks first" {
    var t = try TestApp.init(testing.allocator, "app-close-dirty");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);
    try t.type_(i, "edits", 1000);

    try testing.expectEqual(CloseOutcome.needs_confirm, try t.app.closeTab(i));
    try testing.expectEqual(@as(usize, 1), t.app.tabs.items.len);

    // Discarding goes through the forced path.
    try t.app.closeTabForce(i);
    try testing.expectEqual(@as(usize, 0), t.app.tabs.items.len);
    // The note itself survives -- only the tab went away.
    try testing.expectEqual(@as(usize, 1), t.app.notes.items.len);
}

test "deleting notes trashes them and closes their tabs" {
    var t = try TestApp.init(testing.allocator, "app-delete");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);
    const id = try testing.allocator.dupe(u8, t.app.tabs.items[i].note_id);
    defer testing.allocator.free(id);

    try t.app.deleteNotes(&.{id});

    try testing.expectEqual(@as(usize, 0), t.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), t.app.notes.items.len);

    const trashed = try t.app.ws.?.listTrashedNotes();
    defer db.workspace.freeTrashedNotes(testing.allocator, trashed);
    try testing.expectEqual(@as(usize, 1), trashed.len);
}

test "opening an already-open note focuses its tab" {
    var t = try TestApp.init(testing.allocator, "app-focus");
    defer t.deinit();
    const a = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(a);
    const id_a = try testing.allocator.dupe(u8, t.app.tabs.items[a].note_id);
    defer testing.allocator.free(id_a);

    const b = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(b);
    try testing.expectEqual(@as(?usize, 1), t.app.active);

    try testing.expectEqual(@as(usize, 0), try t.app.openNote(id_a));
    try testing.expectEqual(@as(?usize, 0), t.app.active);
    try testing.expectEqual(@as(usize, 2), t.app.tabs.items.len);
}

test "reloading from disk refuses while a tab is dirty" {
    var t = try TestApp.init(testing.allocator, "app-reload");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    try t.type_(i, "mine", 1000);
    _ = try t.app.saveTab(i);

    // Something else rewrites the file.
    const path = t.app.ws.?.notePath(t.app.tabs.items[i].note_id);
    try t.app.ws.?.fs.write(path.slice(), "theirs");

    try testing.expect(try t.app.reloadTabFromDisk(i, 2000));
    {
        const text = try t.textOf(i);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("theirs", text);
    }
    // And it stays undoable.
    _ = try t.app.tabs.items[i].buffer.undo();
    const undone = try t.textOf(i);
    defer testing.allocator.free(undone);
    try testing.expectEqualStrings("mine", undone);

    // With unsaved edits present, the reload is declined.
    try t.type_(i, "!", 3000);
    try testing.expect(!try t.app.reloadTabFromDisk(i, 3000));
}

test "a note deleted between sessions is skipped on restore" {
    var t = try TestApp.init(testing.allocator, "app-missing");
    defer t.deinit();
    const i = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(i);
    const id = try testing.allocator.dupe(u8, t.app.tabs.items[i].note_id);
    defer testing.allocator.free(id);
    try t.app.flushSession();

    // Remove the backing file behind the app's back.
    const path = t.app.ws.?.notePath(id);
    t.app.ws.?.fs.deleteIfExists(path.slice());

    try t.reopen();
    try testing.expectEqual(@as(usize, 0), t.app.tabs.items.len);
}

test "tab order and the active tab round-trip" {
    var t = try TestApp.init(testing.allocator, "app-order");
    defer t.deinit();
    _ = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(0);
    _ = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(1);
    _ = try t.app.createAndOpenNote();
    _ = try t.app.saveTab(2);

    const second = try testing.allocator.dupe(u8, t.app.tabs.items[1].note_id);
    defer testing.allocator.free(second);
    t.app.active = 1;
    try t.app.flushSession();

    try t.reopen();
    try testing.expectEqual(@as(usize, 3), t.app.tabs.items.len);
    try testing.expectEqualStrings(second, t.app.tabs.items[1].note_id);
    try testing.expectEqual(@as(?usize, 1), t.app.active);
}
