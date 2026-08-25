//! The macOS menu bar.
//!
//! Ported from `build_menu` in `src-tauri/src/lib.rs`.
//!
//! SDL has no menu API, so this talks to AppKit through the Objective-C runtime
//! directly -- `objc_msgSend` and friends, declared here rather than pulled in
//! from the SDK, so the file compiles anywhere even though it only does anything
//! on macOS.
//!
//! Windows and Linux get no menu bar. They never really had one: the Tauri build
//! defined this menu for macOS only, and every accelerator on it is also handled
//! by the in-app keymap (`ui/root.zig`), which is what those platforms use.

const std = @import("std");
const builtin = @import("builtin");

pub const is_supported = builtin.os.tag == .macos;

/// The menu items that emit an action, matching the ids the Tauri build sent as
/// `menu:action`. Kept in the same order and with the same accelerators.
pub const Action = enum(u32) {
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

pub const Item = struct {
    title: []const u8,
    action: Action,
    /// The key equivalent, lowercase.
    key: []const u8,
    /// Command is implied; these are the extras.
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
};

pub const Submenu = struct {
    title: []const u8,
    items: []const Item,
};

/// The menu, exactly as the Tauri build defined it.
pub const layout = struct {
    pub const app = [_]Item{
        .{ .title = "Settings…", .action = .app_settings, .key = "," },
    };
    pub const file = [_]Item{
        .{ .title = "New Note", .action = .file_new_note, .key = "n" },
        .{ .title = "Save", .action = .file_save, .key = "s" },
        .{ .title = "Close Tab", .action = .file_close_tab, .key = "w" },
    };
    pub const edit = [_]Item{
        .{ .title = "Undo", .action = .edit_undo, .key = "z" },
        .{ .title = "Redo", .action = .edit_redo, .key = "z", .shift = true },
        .{ .title = "Select All", .action = .edit_select_all, .key = "a" },
        .{ .title = "Find…", .action = .edit_find, .key = "f" },
        .{ .title = "Find and Replace…", .action = .edit_replace, .key = "f", .alt = true },
    };
    pub const view = [_]Item{
        .{ .title = "Toggle Sidebar", .action = .view_toggle_sidebar, .key = "b" },
        .{ .title = "Command Palette…", .action = .view_spotlight, .key = "k" },
        .{ .title = "Zoom In", .action = .view_zoom_in, .key = "=" },
        .{ .title = "Zoom Out", .action = .view_zoom_out, .key = "-" },
        .{ .title = "Actual Size", .action = .view_zoom_reset, .key = "0" },
        .{ .title = "Next Tab", .action = .tab_next, .key = "\t", .control = true },
        .{ .title = "Previous Tab", .action = .tab_prev, .key = "\t", .control = true, .shift = true },
    };
};

/// Called on the main thread when the user picks an item.
pub const Handler = *const fn (ctx: ?*anyopaque, action: Action) void;

// -- the Objective-C runtime -------------------------------------------------
//
// Declared rather than imported: these live in libobjc, which Zig links for a
// macOS target without needing the SDK headers.

const objc = if (is_supported) struct {
    const Id = ?*anyopaque;
    const Class = ?*anyopaque;
    const Sel = ?*anyopaque;
    const Imp = *const fn () callconv(.c) void;

    extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
    extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
    extern "objc" fn objc_registerClassPair(cls: Class) void;
    extern "objc" fn class_addMethod(cls: Class, name: Sel, imp: Imp, types: [*:0]const u8) bool;
    extern "objc" fn objc_msgSend() void;

    /// `objc_msgSend` is variadic in C and must be called through a pointer
    /// cast to the exact signature of the message being sent. These are the
    /// handful of shapes the menu needs.
    fn msg(comptime Fn: type) *const Fn {
        return @ptrCast(&objc_msgSend);
    }

    fn id(target: Id, sel: Sel) Id {
        return msg(fn (Id, Sel) callconv(.c) Id)(target, sel);
    }
    fn idWith(target: Id, sel: Sel, arg: Id) Id {
        return msg(fn (Id, Sel, Id) callconv(.c) Id)(target, sel, arg);
    }
    fn idWithCStr(target: Id, sel: Sel, arg: [*:0]const u8) Id {
        return msg(fn (Id, Sel, [*:0]const u8) callconv(.c) Id)(target, sel, arg);
    }
    fn initItem(target: Id, sel: Sel, title: Id, action: Sel, key: Id) Id {
        return msg(fn (Id, Sel, Id, Sel, Id) callconv(.c) Id)(target, sel, title, action, key);
    }
    fn voidWith(target: Id, sel: Sel, arg: Id) void {
        msg(fn (Id, Sel, Id) callconv(.c) void)(target, sel, arg);
    }
    fn voidWithU64(target: Id, sel: Sel, arg: u64) void {
        msg(fn (Id, Sel, u64) callconv(.c) void)(target, sel, arg);
    }
    fn voidWithIsize(target: Id, sel: Sel, arg: isize) void {
        msg(fn (Id, Sel, isize) callconv(.c) void)(target, sel, arg);
    }
    fn isizeOf(target: Id, sel: Sel) isize {
        return msg(fn (Id, Sel) callconv(.c) isize)(target, sel);
    }
} else struct {};

var installed_handler: ?Handler = null;
var handler_ctx: ?*anyopaque = null;

/// Build and install the menu bar. A no-op off macOS.
pub fn install(handler: Handler, ctx: ?*anyopaque) void {
    installed_handler = handler;
    handler_ctx = ctx;
    if (!is_supported) return;
    installMac() catch {};
}

fn installMac() !void {
    if (!is_supported) return;

    const NSApplication = objc.objc_getClass("NSApplication");
    const app = objc.id(NSApplication, objc.sel_registerName("sharedApplication"));
    if (app == null) return;

    // A target class with one selector, created at runtime, whose only job is
    // to forward the tag of the clicked item back into Zig.
    const NSObject = objc.objc_getClass("NSObject");
    const target_class = objc.objc_allocateClassPair(NSObject, "NovaMenuTarget", 0) orelse
        objc.objc_getClass("NovaMenuTarget");
    if (target_class) |cls| {
        _ = objc.class_addMethod(
            cls,
            objc.sel_registerName("novaMenuAction:"),
            @ptrCast(&menuActionThunk),
            "v@:@",
        );
        objc.objc_registerClassPair(cls);
    }
    const target = objc.id(objc.id(target_class, objc.sel_registerName("alloc")), objc.sel_registerName("init"));

    const main_menu = try newMenu("");
    objc.voidWith(app, objc.sel_registerName("setMainMenu:"), main_menu);

    // The application menu is special-cased by AppKit: its first submenu is
    // named after the app whatever title we give it.
    const app_menu = try addSubmenu(main_menu, "Nova");
    try addItems(app_menu, target, &layout.app);
    try addSeparator(app_menu);
    try addSelectorItem(app_menu, "Hide Nova", "hide:", "h", false);
    try addSelectorItem(app_menu, "Hide Others", "hideOtherApplications:", "h", true);
    try addSelectorItem(app_menu, "Show All", "unhideAllApplications:", "", false);
    try addSeparator(app_menu);
    try addSelectorItem(app_menu, "Quit Nova", "terminate:", "q", false);

    const file_menu = try addSubmenu(main_menu, "File");
    try addItems(file_menu, target, &layout.file);

    const edit_menu = try addSubmenu(main_menu, "Edit");
    try addItems(edit_menu, target, &layout.edit);
    try addSeparator(edit_menu);
    // Cut/Copy/Paste go to the responder chain, which is what makes them work
    // in every text field without the app routing them.
    try addSelectorItem(edit_menu, "Cut", "cut:", "x", false);
    try addSelectorItem(edit_menu, "Copy", "copy:", "c", false);
    try addSelectorItem(edit_menu, "Paste", "paste:", "v", false);

    const view_menu = try addSubmenu(main_menu, "View");
    try addItems(view_menu, target, &layout.view);

    const window_menu = try addSubmenu(main_menu, "Window");
    try addSelectorItem(window_menu, "Minimize", "performMiniaturize:", "m", false);
    try addSelectorItem(window_menu, "Close", "performClose:", "w", false);
}

fn nsString(text: []const u8) objc.Id {
    const NSString = objc.objc_getClass("NSString");
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return objc.idWithCStr(
        NSString,
        objc.sel_registerName("stringWithUTF8String:"),
        @ptrCast(&buf),
    );
}

fn newMenu(title: []const u8) !objc.Id {
    const NSMenu = objc.objc_getClass("NSMenu");
    const alloc = objc.id(NSMenu, objc.sel_registerName("alloc"));
    return objc.idWith(alloc, objc.sel_registerName("initWithTitle:"), nsString(title));
}

fn addSubmenu(parent: objc.Id, title: []const u8) !objc.Id {
    const NSMenuItem = objc.objc_getClass("NSMenuItem");
    const item = objc.id(objc.id(NSMenuItem, objc.sel_registerName("alloc")), objc.sel_registerName("init"));
    const menu = try newMenu(title);
    objc.voidWith(item, objc.sel_registerName("setSubmenu:"), menu);
    objc.voidWith(parent, objc.sel_registerName("addItem:"), item);
    return menu;
}

fn addSeparator(menu: objc.Id) !void {
    const NSMenuItem = objc.objc_getClass("NSMenuItem");
    const sep = objc.id(NSMenuItem, objc.sel_registerName("separatorItem"));
    objc.voidWith(menu, objc.sel_registerName("addItem:"), sep);
}

/// Modifier mask bits, from `NSEventModifierFlags`.
const mod_shift: u64 = 1 << 17;
const mod_control: u64 = 1 << 18;
const mod_alt: u64 = 1 << 19;
const mod_command: u64 = 1 << 20;

fn addItems(menu: objc.Id, target: objc.Id, items: []const Item) !void {
    for (items) |item| {
        const NSMenuItem = objc.objc_getClass("NSMenuItem");
        const alloc = objc.id(NSMenuItem, objc.sel_registerName("alloc"));
        const created = objc.initItem(
            alloc,
            objc.sel_registerName("initWithTitle:action:keyEquivalent:"),
            nsString(item.title),
            objc.sel_registerName("novaMenuAction:"),
            nsString(item.key),
        );

        var mask: u64 = mod_command;
        if (item.shift) mask |= mod_shift;
        if (item.alt) mask |= mod_alt;
        if (item.control) mask |= mod_control;
        objc.voidWithU64(created, objc.sel_registerName("setKeyEquivalentModifierMask:"), mask);
        objc.voidWith(created, objc.sel_registerName("setTarget:"), target);
        // The tag carries the action back; no per-item selector needed.
        objc.voidWithIsize(created, objc.sel_registerName("setTag:"), @intFromEnum(item.action));
        objc.voidWith(menu, objc.sel_registerName("addItem:"), created);
    }
}

/// An item wired to a standard AppKit selector rather than to Nova.
fn addSelectorItem(menu: objc.Id, title: []const u8, selector: []const u8, key: []const u8, shift: bool) !void {
    var sel_buf: [64]u8 = undefined;
    const n = @min(selector.len, sel_buf.len - 1);
    @memcpy(sel_buf[0..n], selector[0..n]);
    sel_buf[n] = 0;

    const NSMenuItem = objc.objc_getClass("NSMenuItem");
    const alloc = objc.id(NSMenuItem, objc.sel_registerName("alloc"));
    const created = objc.initItem(
        alloc,
        objc.sel_registerName("initWithTitle:action:keyEquivalent:"),
        nsString(title),
        objc.sel_registerName(@ptrCast(&sel_buf)),
        nsString(key),
    );
    var mask: u64 = mod_command;
    if (shift) mask |= mod_shift;
    objc.voidWithU64(created, objc.sel_registerName("setKeyEquivalentModifierMask:"), mask);
    objc.voidWith(menu, objc.sel_registerName("addItem:"), created);
}

/// The Objective-C method body: read the tag and hand it to the Zig handler.
fn menuActionThunk(self: objc.Id, cmd: objc.Sel, sender: objc.Id) callconv(.c) void {
    _ = self;
    _ = cmd;
    const handler = installed_handler orelse return;
    const tag = objc.isizeOf(sender, objc.sel_registerName("tag"));
    if (tag < 0 or tag > @intFromEnum(Action.tab_prev)) return;
    handler(handler_ctx, @enumFromInt(@as(u32, @intCast(tag))));
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "the menu layout matches the one the Tauri build defined" {
    // Same items, same accelerators -- the point of the port is that a macOS
    // user's muscle memory keeps working.
    try testing.expectEqual(@as(usize, 1), layout.app.len);
    try testing.expectEqual(@as(usize, 3), layout.file.len);
    try testing.expectEqual(@as(usize, 5), layout.edit.len);
    try testing.expectEqual(@as(usize, 7), layout.view.len);

    try testing.expectEqualStrings("n", layout.file[0].key);
    try testing.expectEqualStrings("s", layout.file[1].key);
    try testing.expectEqualStrings("w", layout.file[2].key);

    // Redo is Cmd+Shift+Z, and Find and Replace is Cmd+Alt+F.
    try testing.expect(layout.edit[1].shift);
    try testing.expectEqualStrings("z", layout.edit[1].key);
    try testing.expect(layout.edit[4].alt);
    try testing.expectEqualStrings("f", layout.edit[4].key);

    // Tab cycling uses Control, not Command.
    try testing.expect(layout.view[5].control);
    try testing.expect(layout.view[6].control and layout.view[6].shift);
}

test "every action appears exactly once" {
    var seen = std.EnumSet(Action).initEmpty();
    inline for (.{ layout.app, layout.file, layout.edit, layout.view }) |group| {
        for (group) |item| {
            try testing.expect(!seen.contains(item.action));
            seen.insert(item.action);
        }
    }
    // All sixteen, which is what `menu.ts` enumerated.
    try testing.expectEqual(@as(usize, 16), seen.count());
}

test "installing is a no-op where there is no menu bar" {
    if (is_supported) return error.SkipZigTest;
    const noop = struct {
        fn f(_: ?*anyopaque, _: Action) void {}
    }.f;
    install(noop, null);
}
