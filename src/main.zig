//! Nova.

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const platform = @import("platform");
const sdl = @import("shell/sdl.zig");

/// Menu picks arrive on the main thread, between event pumps, so handing them
/// straight to the root view is safe.
fn onMenuAction(ctx: ?*anyopaque, action: platform.menu_macos.Action) void {
    const root: *ui.Root = @ptrCast(@alignCast(ctx orelse return));
    root.handle(.{ .menu = switch (action) {
        .app_settings => .app_settings,
        .file_new_note => .file_new_note,
        .file_save => .file_save,
        .file_close_tab => .file_close_tab,
        .edit_undo => .edit_undo,
        .edit_redo => .edit_redo,
        .edit_select_all => .edit_select_all,
        .edit_find => .edit_find,
        .edit_replace => .edit_replace,
        .view_toggle_sidebar => .view_toggle_sidebar,
        .view_spotlight => .view_spotlight,
        .view_zoom_in => .view_zoom_in,
        .view_zoom_out => .view_zoom_out,
        .view_zoom_reset => .view_zoom_reset,
        .tab_next => .tab_next,
        .tab_prev => .tab_prev,
    } }) catch {};
}

/// How long to block waiting for an event before running a frame anyway. The UI
/// is event-driven -- there is nothing animating beyond the caret blink -- so an
/// idle Nova wakes a few times a second and uses no CPU in between.
const idle_frame_ms = 120;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shell = try sdl.Shell.init(gpa, io, "Nova", 1200, 800);
    defer shell.deinit();

    // Logical units everywhere above the painter: the same ones SDL reports
    // mouse positions in. The painter multiplies by the density.
    const size = shell.windowSize();
    const scale = shell.pixelDensity();

    // Heap-allocated: `Root.attach` points its editor at `Root.fonts`, so the
    // Root must already be at its final address.
    const root = try gpa.create(ui.Root);
    defer gpa.destroy(root);
    root.* = try ui.Root.init(gpa, io, size.w, size.h, .{ .scale = scale });
    root.attach();
    defer root.deinit();

    if (shell.loadLastWorkspace()) |path| {
        defer gpa.free(path);
        root.application.openWorkspace(path) catch {};
    }
    if (root.application.ws == null) try shell.apply(&.{.pick_folder});

    // macOS gets a real menu bar; elsewhere the same shortcuts are handled by
    // the in-app keymap, which is how the Tauri build worked too.
    if (platform.menu_macos.is_supported) {
        platform.menu_macos.install(onMenuAction, root);
    }

    try shell.apply(&.{.start_text_input});
    try root.handle(.{ .resize = .{ .width = size.w, .height = size.h, .scale = scale } });

    while (shell.running) {
        try shell.pump(root, idle_frame_ms);
        try root.handle(.{ .tick = platform.localtime.nowMs(io) });

        if (shell.takePickedFolder()) |path| {
            defer gpa.free(path);
            try root.handle(.{ .folder_picked = path });
            shell.saveLastWorkspace(path);
        }

        try shell.apply(root.outbox.drain());
        root.outbox.clear();

        if (root.needs_paint) {
            try root.paint();
            try shell.present(&root.surface);
        }
    }

    // Leave the session and any unsaved work on disk, as a graceful quit should.
    root.application.flushDirtyTabs() catch {};
    root.application.flushSession() catch {};
}
