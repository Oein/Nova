//! The SDL3 shell: window, event loop, IME, clipboard and cursors.
//!
//! The only part of Nova that knows a window system exists. Everything above it
//! deals in `ui.Event` and `ui.Request`, which is what lets the whole UI be
//! rendered and driven in tests on a machine with no display.

const std = @import("std");
const builtin = @import("builtin");
const gfx = @import("gfx");
const ui = @import("ui");
const platform = @import("platform");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const Allocator = std.mem.Allocator;

pub const Error = error{
    SdlInit,
    WindowCreate,
    RendererCreate,
    TextureCreate,
};

pub const Shell = struct {
    gpa: Allocator,
    io: std.Io,
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,
    texture_w: u32 = 0,
    texture_h: u32 = 0,

    cursors: [3]?*c.SDL_Cursor = @splat(null),
    current_cursor: ui.event.CursorShape = .arrow,

    running: bool = true,
    /// Set while a folder dialog is open, so its callback can be picked up.
    picked_folder: ?[]u8 = null,

    pub fn init(gpa: Allocator, io: std.Io, title: [:0]const u8, w: u32, h: u32) Error!Shell {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        errdefer c.SDL_Quit();

        const window = c.SDL_CreateWindow(
            title.ptr,
            @intCast(w),
            @intCast(h),
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse return error.WindowCreate;
        errdefer c.SDL_DestroyWindow(window);

        const renderer = c.SDL_CreateRenderer(window, null) orelse return error.RendererCreate;
        errdefer c.SDL_DestroyRenderer(renderer);
        // The UI is drawn into a CPU surface and uploaded whole; nearest
        // sampling keeps the 1:1 blit exact.
        _ = c.SDL_SetRenderVSync(renderer, 1);

        var self = Shell{ .gpa = gpa, .io = io, .window = window, .renderer = renderer };
        self.cursors = .{
            c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
            c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_EW_RESIZE),
        };
        return self;
    }

    pub fn deinit(self: *Shell) void {
        for (self.cursors) |cur| {
            if (cur) |x| c.SDL_DestroyCursor(x);
        }
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        if (self.picked_folder) |p| self.gpa.free(p);
    }

    /// Logical size of the window, in the units SDL reports mouse positions
    /// in. On a Retina display this is half the drawable size.
    pub fn windowSize(self: *Shell) struct { w: u32, h: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{ .w = @intCast(@max(1, w)), .h = @intCast(@max(1, h)) };
    }

    /// Device pixels per logical unit for the display the window is on.
    pub fn pixelDensity(self: *Shell) f32 {
        const d = c.SDL_GetWindowPixelDensity(self.window);
        return if (d > 0) d else 1;
    }

    /// Upload a rendered surface and present it.
    pub fn present(self: *Shell, surface: *const gfx.Surface) !void {
        if (self.texture == null or
            self.texture_w != surface.width or
            self.texture_h != surface.height)
        {
            if (self.texture) |t| c.SDL_DestroyTexture(t);
            self.texture = c.SDL_CreateTexture(
                self.renderer,
                c.SDL_PIXELFORMAT_RGBA32,
                c.SDL_TEXTUREACCESS_STREAMING,
                @intCast(surface.width),
                @intCast(surface.height),
            ) orelse return error.TextureCreate;
            _ = c.SDL_SetTextureScaleMode(self.texture, c.SDL_SCALEMODE_NEAREST);
            self.texture_w = surface.width;
            self.texture_h = surface.height;
        }

        _ = c.SDL_UpdateTexture(
            self.texture,
            null,
            surface.pixels.ptr,
            @intCast(surface.width * @sizeOf(gfx.Rgba)),
        );
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderTexture(self.renderer, self.texture, null, null);
        _ = c.SDL_RenderPresent(self.renderer);
    }

    // -- events --------------------------------------------------------------

    fn modsOf(mod: c.SDL_Keymod) ui.event.Mods {
        return .{
            .shift = (mod & c.SDL_KMOD_SHIFT) != 0,
            // Cmd on macOS, Ctrl elsewhere -- one flag, as the editor keymap
            // expects.
            .meta = if (builtin.os.tag == .macos)
                (mod & c.SDL_KMOD_GUI) != 0
            else
                (mod & c.SDL_KMOD_CTRL) != 0,
            .alt = (mod & c.SDL_KMOD_ALT) != 0,
        };
    }

    fn keyOf(sym: c.SDL_Keycode) ui.event.Key {
        return switch (sym) {
            c.SDLK_LEFT => .arrow_left,
            c.SDLK_RIGHT => .arrow_right,
            c.SDLK_UP => .arrow_up,
            c.SDLK_DOWN => .arrow_down,
            c.SDLK_HOME => .home,
            c.SDLK_END => .end,
            c.SDLK_PAGEUP => .page_up,
            c.SDLK_PAGEDOWN => .page_down,
            c.SDLK_BACKSPACE => .backspace,
            c.SDLK_DELETE => .delete,
            c.SDLK_RETURN, c.SDLK_KP_ENTER => .enter,
            c.SDLK_TAB => .tab,
            c.SDLK_ESCAPE => .{ .character = 27 },
            else => blk: {
                // Printable keys arrive lowercased, which is what the keymap
                // compares against.
                if (sym > 0 and sym < 0x110000) {
                    const cp: u21 = @intCast(sym);
                    if (cp >= ' ' and cp != 0x7F) {
                        break :blk .{ .character = std.ascii.toLower(@intCast(@min(cp, 127))) };
                    }
                }
                break :blk .other;
            },
        };
    }

    fn buttonOf(b: u8) ui.event.MouseButton {
        return switch (b) {
            c.SDL_BUTTON_RIGHT => .right,
            c.SDL_BUTTON_MIDDLE => .middle,
            else => .left,
        };
    }

    /// Translate one SDL event. Returns null for events the UI does not care
    /// about.
    pub fn translate(self: *Shell, e: *const c.SDL_Event) ?ui.Event {
        return switch (e.type) {
            c.SDL_EVENT_QUIT => blk: {
                self.running = false;
                break :blk null;
            },
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            c.SDL_EVENT_WINDOW_RESIZED,
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
            => blk: {
                // Logical, not the drawable: everything above the painter
                // works in the same units SDL reports mouse positions in.
                const size = self.windowSize();
                break :blk .{ .resize = .{
                    .width = size.w,
                    .height = size.h,
                    .scale = self.pixelDensity(),
                } };
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => .focus_lost,

            c.SDL_EVENT_KEY_DOWN => .{ .key_down = .{
                .key = keyOf(e.key.key),
                .mods = modsOf(e.key.mod),
            } },
            c.SDL_EVENT_TEXT_INPUT => .{ .text_input = std.mem.sliceTo(e.text.text, 0) },
            c.SDL_EVENT_TEXT_EDITING => blk: {
                const text = std.mem.sliceTo(e.edit.text, 0);
                // SDL reports an empty preedit when composition ends.
                if (text.len == 0) break :blk .ime_end;
                break :blk .{ .ime_preedit = .{ .text = text, .cursor = e.edit.start } };
            },

            c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .mouse_down = .{
                .x = @intFromFloat(e.button.x),
                .y = @intFromFloat(e.button.y),
                .button = buttonOf(e.button.button),
                .clicks = @intCast(@max(1, e.button.clicks)),
                .mods = modsOf(c.SDL_GetModState()),
            } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .mouse_up = .{
                .x = @intFromFloat(e.button.x),
                .y = @intFromFloat(e.button.y),
                .button = buttonOf(e.button.button),
            } },
            c.SDL_EVENT_MOUSE_MOTION => .{ .mouse_move = .{
                .x = @intFromFloat(e.motion.x),
                .y = @intFromFloat(e.motion.y),
            } },
            c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
                .x = @intFromFloat(e.wheel.mouse_x),
                .y = @intFromFloat(e.wheel.mouse_y),
                .dx = e.wheel.x,
                .dy = e.wheel.y,
            } },
            else => null,
        };
    }

    // -- requests ------------------------------------------------------------

    pub fn apply(self: *Shell, requests: []const ui.Request) !void {
        for (requests) |r| switch (r) {
            .set_ime_area => |rect| {
                // Tells the IME where to put its candidate window. This is the
                // native equivalent of the 1px textarea the web build had to
                // drag around behind the caret.
                var area = c.SDL_Rect{
                    .x = rect.x,
                    .y = rect.y,
                    .w = @max(1, rect.w),
                    .h = @max(1, rect.h),
                };
                _ = c.SDL_SetTextInputArea(self.window, &area, 0);
            },
            .start_text_input => _ = c.SDL_StartTextInput(self.window),
            .stop_text_input => _ = c.SDL_StopTextInput(self.window),
            .set_clipboard => |text| {
                const z = try self.gpa.dupeZ(u8, text);
                defer self.gpa.free(z);
                _ = c.SDL_SetClipboardText(z.ptr);
            },
            .read_clipboard => {},
            .open_url => |url| {
                const z = try self.gpa.dupeZ(u8, url);
                defer self.gpa.free(z);
                _ = c.SDL_OpenURL(z.ptr);
            },
            .reveal_path => |path| platform.shell.revealPath(self.io, self.gpa, path) catch {},
            .pick_folder => self.showFolderDialog(),
            .set_title => |title| {
                const z = try self.gpa.dupeZ(u8, title);
                defer self.gpa.free(z);
                _ = c.SDL_SetWindowTitle(self.window, z.ptr);
            },
            .set_cursor => |shape| self.setCursor(shape),
            .quit => self.running = false,
        };
    }

    fn setCursor(self: *Shell, shape: ui.event.CursorShape) void {
        if (shape == self.current_cursor) return;
        self.current_cursor = shape;
        const index: usize = switch (shape) {
            .arrow => 0,
            .text => 1,
            .col_resize => 2,
        };
        if (self.cursors[index]) |cur| _ = c.SDL_SetCursor(cur);
    }

    /// Read the clipboard now. Caller owns the result.
    pub fn clipboardText(self: *Shell) ?[]u8 {
        const raw = c.SDL_GetClipboardText();
        if (raw == null) return null;
        defer c.SDL_free(raw);
        const slice = std.mem.sliceTo(raw, 0);
        if (slice.len == 0) return null;
        return self.gpa.dupe(u8, slice) catch null;
    }

    fn folderCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
        _ = filter;
        const self: *Shell = @ptrCast(@alignCast(userdata orelse return));
        if (filelist == null or filelist[0] == null) return;
        const path = std.mem.sliceTo(filelist[0], 0);
        if (self.picked_folder) |old| self.gpa.free(old);
        self.picked_folder = self.gpa.dupe(u8, path) catch null;
    }

    fn showFolderDialog(self: *Shell) void {
        c.SDL_ShowOpenFolderDialog(folderCallback, self, self.window, null, false);
    }

    /// A folder the dialog produced since the last call, if any.
    pub fn takePickedFolder(self: *Shell) ?[]u8 {
        const p = self.picked_folder;
        self.picked_folder = null;
        return p;
    }

    /// Milliseconds since SDL started; used to drive the UI clock.
    pub fn ticks(self: *Shell) i64 {
        _ = self;
        return @intCast(c.SDL_GetTicks());
    }

    pub fn wallClockMs(self: *Shell) i64 {
        return platform.localtime.nowMs(self.io);
    }

    /// Per-user config directory, created if needed. SDL knows the right place
    /// on each OS (`~/Library/Application Support`, `%APPDATA%`,
    /// `$XDG_CONFIG_HOME`), which is worth more than rolling our own.
    /// Caller owns the result.
    pub fn prefPath(self: *Shell, sub: []const u8) ?[]u8 {
        const raw = c.SDL_GetPrefPath("Nova", "Nova");
        if (raw == null) return null;
        defer c.SDL_free(raw);
        const dir = std.mem.sliceTo(raw, 0);
        return std.fmt.allocPrint(self.gpa, "{s}{s}", .{ dir, sub }) catch null;
    }

    /// Remember the workspace the user last had open.
    pub fn saveLastWorkspace(self: *Shell, path: []const u8) void {
        const config = self.prefPath("last-workspace") orelse return;
        defer self.gpa.free(config);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = config, .data = path }) catch {};
    }

    /// The workspace from the previous run, if there was one.
    pub fn loadLastWorkspace(self: *Shell) ?[]u8 {
        const config = self.prefPath("last-workspace") orelse return null;
        defer self.gpa.free(config);

        const raw = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            config,
            self.gpa,
            .limited(4096),
        ) catch return null;
        defer self.gpa.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return self.gpa.dupe(u8, trimmed) catch null;
    }

    /// Drain the SDL queue into `handler`, blocking up to `timeout_ms` when
    /// there is nothing waiting.
    pub fn pump(self: *Shell, context: anytype, timeout_ms: i32) !void {
        var event: c.SDL_Event = undefined;
        if (!c.SDL_WaitEventTimeout(&event, timeout_ms)) return;
        while (true) {
            if (self.translate(&event)) |ui_event| try context.handle(ui_event);
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
};

const testing = std.testing;

test "key translation covers the editor's keys" {
    try testing.expectEqual(ui.event.Key.arrow_left, Shell.keyOf(c.SDLK_LEFT));
    try testing.expectEqual(ui.event.Key.backspace, Shell.keyOf(c.SDLK_BACKSPACE));
    try testing.expectEqual(ui.event.Key.enter, Shell.keyOf(c.SDLK_RETURN));
    try testing.expectEqual(ui.event.Key.tab, Shell.keyOf(c.SDLK_TAB));

    const z = Shell.keyOf(c.SDLK_Z);
    try testing.expectEqual(@as(u21, 'z'), z.character);
    try testing.expectEqual(@as(u21, 27), Shell.keyOf(c.SDLK_ESCAPE).character);
}

test "modifier mapping folds Cmd and Ctrl into one flag" {
    const shift = Shell.modsOf(c.SDL_KMOD_LSHIFT);
    try testing.expect(shift.shift and !shift.meta);

    const primary = if (builtin.os.tag == .macos) c.SDL_KMOD_LGUI else c.SDL_KMOD_LCTRL;
    try testing.expect(Shell.modsOf(primary).meta);
}
