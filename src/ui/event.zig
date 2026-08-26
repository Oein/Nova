//! Input events and the requests the UI makes of the shell.
//!
//! Nothing here knows about SDL. The shell translates window-system events into
//! these, and acts on the requests that come back -- which is what lets every
//! screen be driven and rendered in a test with no window at all.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx");

pub const Key = core.commands.Key;

pub const Mods = packed struct {
    shift: bool = false,
    /// Cmd on macOS, Ctrl elsewhere. The editor keymap folds the two together,
    /// as the original did.
    meta: bool = false,
    alt: bool = false,

    pub fn none(self: Mods) bool {
        return !self.shift and !self.meta and !self.alt;
    }
};

pub const MouseButton = enum { left, middle, right };

/// Menu items, matching the ids the Tauri build emitted as `menu:action`
/// (`src-tauri/src/lib.rs:20`). On macOS these arrive from the real menu bar;
/// elsewhere they come from the in-app keymap.
pub const MenuAction = enum {
    app_settings,
    file_new_note,
    file_save,
    file_close_tab,
    edit_undo,
    edit_redo,
    edit_select_all,
    edit_find,
    edit_replace,
    view_toggle_sidebar,
    view_spotlight,
    view_zoom_in,
    view_zoom_out,
    view_zoom_reset,
    tab_next,
    tab_prev,
};

pub const Event = union(enum) {
    key_down: struct { key: Key, mods: Mods = .{} },
    /// Text the input method committed.
    text_input: []const u8,
    /// Composition started; the UI drops the selection so the preedit replaces
    /// it, matching `Editor.svelte:542`.
    ime_start,
    /// Composition in progress. `text` is the preedit; it is not in the buffer.
    ime_preedit: struct { text: []const u8, cursor: i32 = -1 },
    ime_end,

    mouse_down: struct {
        x: i32,
        y: i32,
        button: MouseButton = .left,
        clicks: u8 = 1,
        mods: Mods = .{},
    },
    mouse_up: struct { x: i32, y: i32, button: MouseButton = .left },
    mouse_move: struct { x: i32, y: i32 },
    wheel: struct { x: i32, y: i32, dx: f32, dy: f32 },

    /// New window size in logical units, with the display's device-pixel
    /// ratio. Both arrive together because dragging a window between displays
    /// can change either one.
    resize: struct { width: u32, height: u32, scale: f32 = 1 },
    focus_lost,
    menu: MenuAction,
    /// Clipboard content, in reply to a `read_clipboard` request.
    clipboard: []const u8,
    /// A folder the user picked, in reply to `pick_folder`.
    folder_picked: []const u8,
    /// One frame of wall clock.
    tick: i64,
};

/// Something the UI needs the window system to do.
pub const Request = union(enum) {
    /// Where the caret is, so the IME candidate window can be placed. Sent
    /// whenever the caret moves.
    set_ime_area: gfx.Rect,
    start_text_input,
    stop_text_input,
    set_clipboard: []const u8,
    read_clipboard,
    open_url: []const u8,
    reveal_path: []const u8,
    pick_folder,
    set_title: []const u8,
    set_cursor: CursorShape,
    quit,
};

pub const CursorShape = enum { arrow, text, col_resize };

/// Requests accumulate here and the shell drains them once per frame.
pub const Outbox = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Request) = .empty,
    /// Strings referenced by queued requests, freed when the outbox is drained.
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Outbox {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Outbox) void {
        self.items.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn push(self: *Outbox, r: Request) void {
        self.items.append(self.gpa, r) catch {};
    }

    /// Queue a request that carries text, copying it into the outbox arena so
    /// the caller need not keep it alive.
    pub fn pushText(self: *Outbox, comptime tag: std.meta.Tag(Request), text: []const u8) void {
        const owned = self.arena.allocator().dupe(u8, text) catch return;
        self.push(@unionInit(Request, @tagName(tag), owned));
    }

    pub fn drain(self: *Outbox) []const Request {
        return self.items.items;
    }

    pub fn clear(self: *Outbox) void {
        self.items.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

const testing = std.testing;

test "outbox queues and clears" {
    var out = Outbox.init(testing.allocator);
    defer out.deinit();

    out.push(.read_clipboard);
    out.pushText(.set_clipboard, "hello");
    try testing.expectEqual(@as(usize, 2), out.drain().len);
    try testing.expectEqualStrings("hello", out.drain()[1].set_clipboard);

    out.clear();
    try testing.expectEqual(@as(usize, 0), out.drain().len);
}

test "queued text survives the caller's buffer going away" {
    var out = Outbox.init(testing.allocator);
    defer out.deinit();

    var buf: [8]u8 = "abcdefgh".*;
    out.pushText(.set_clipboard, &buf);
    @memset(&buf, 'x');
    try testing.expectEqualStrings("abcdefgh", out.drain()[0].set_clipboard);
}

test "mods" {
    try testing.expect((Mods{}).none());
    try testing.expect(!(Mods{ .shift = true }).none());
}
