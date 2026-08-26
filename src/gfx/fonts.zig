//! The faces the program draws with.
//!
//! The original was a web app and inherited the platform's conventions from
//! its stylesheet: `-apple-system` for the interface, `ui-monospace` for note
//! text, and a different pixel size for nearly every part of the chrome -- 13
//! for the body, 12 for a note title, 11 for a group header, 10 for its count
//! badge. Collapsing that into one face at one size changes the spacing and
//! weight of every label, which is exactly what a reader notices.
//!
//! So a family is a kind plus a size, and stacks are built on demand. The font
//! *files* are read once and shared: a stack borrows the bytes rather than
//! owning them, so asking for a fourth size costs a FreeType face, not another
//! copy of a 20 MB system font.
//!
//! Only note text follows the zoom commands, as in the original, where zoom set
//! the editor's `font-size` and the chrome was styled in fixed pixels.

const std = @import("std");
const font = @import("font.zig");
const fontpath = @import("platform").fontpath;

const Allocator = std.mem.Allocator;
const FontStack = font.FontStack;

pub const Kind = enum {
    /// `-apple-system`: proportional, for the interface.
    ui,
    /// `ui-monospace`: note text, on the cell grid.
    mono,
};

/// Which face a piece of text is drawn in.
pub const Family = struct {
    kind: Kind = .ui,
    /// Pixel size. Zero means the kind's own default: body size for the
    /// interface, the current zoom level for note text.
    px: u32 = 0,
};

pub const Options = struct {
    /// `body { font-size: 13px }`.
    ui_px: u32 = 13,
    /// The editor, and the only size the user can change.
    editor_px: u32 = 13,
    /// Device pixels per logical unit -- two on a Retina display. Glyphs are
    /// rasterized at this multiple and every metric is reported back in
    /// logical units, so nothing above the painter has to know.
    scale: f32 = 1,
    /// Read the platform's faces. Off in tests: a golden image must not depend
    /// on which fonts the machine running it happens to have installed.
    system: bool = true,
};

/// A font file, read once and lent to every stack that needs it.
const Source = struct {
    data: []u8,
    index: u32,
    /// Where it was read from. A literal out of `fontpath`, so it needs no
    /// lifetime handling -- it is shown in the settings panel, which is the
    /// only way to tell from inside the app which face actually won.
    path: []const u8,
};

const Key = struct { kind: Kind, px: u32 };

pub const Fonts = struct {
    gpa: Allocator,
    ui_px: u32,
    editor_px: u32,
    scale: f32,

    ui_default: FontStack,
    mono_default: FontStack,
    /// Sizes other than the two defaults, built when first asked for.
    extra: std.AutoHashMapUnmanaged(Key, *FontStack) = .empty,

    ui_src: ?Source = null,
    mono_src: ?Source = null,
    korean_src: ?Source = null,

    pub fn init(gpa: Allocator, io: std.Io, opts: Options) font.Error!Fonts {
        var self = Fonts{
            .gpa = gpa,
            .ui_px = opts.ui_px,
            .editor_px = opts.editor_px,
            .scale = opts.scale,
            .ui_default = try FontStack.initScaled(gpa, opts.ui_px, opts.scale),
            .mono_default = try FontStack.initScaled(gpa, opts.editor_px, opts.scale),
        };
        errdefer self.deinit();
        self.ui_default.grid = false;

        if (opts.system) {
            self.korean_src = readFirst(gpa, io, fontpath.korean);
            self.ui_src = readFirst(gpa, io, fontpath.ui);
            self.mono_src = readFirst(gpa, io, fontpath.mono);
            self.dress(&self.ui_default, .ui);
            self.dress(&self.mono_default, .mono);
        }
        return self;
    }

    /// The bundled face only, for tests.
    pub fn initBundled(gpa: Allocator, opts: Options) font.Error!Fonts {
        var tweaked = opts;
        tweaked.system = false;
        return init(gpa, undefined, tweaked);
    }

    pub fn deinit(self: *Fonts) void {
        var it = self.extra.valueIterator();
        while (it.next()) |s| {
            s.*.deinit();
            self.gpa.destroy(s.*);
        }
        self.extra.deinit(self.gpa);

        self.ui_default.deinit();
        self.mono_default.deinit();

        for ([_]?Source{ self.ui_src, self.mono_src, self.korean_src }) |maybe| {
            if (maybe) |src| self.gpa.free(src.data);
        }
    }

    /// Read the first candidate that exists. A missing file is not an error:
    /// the bundled face is behind these, so text renders either way.
    fn readFirst(gpa: Allocator, io: std.Io, candidates: []const fontpath.Face) ?Source {
        for (candidates) |c| {
            const data = std.Io.Dir.cwd().readFileAlloc(io, c.path, gpa, .limited(64 << 20)) catch continue;
            return .{ .data = data, .index = c.index, .path = c.path };
        }
        return null;
    }

    /// Put the platform's faces in front of the bundled one. Hangul goes on
    /// first so the named face ends up ahead of it: neither SF Pro nor SF Mono
    /// covers Korean, and the browser reached past them the same way.
    fn dress(self: *Fonts, stack: *FontStack, kind: Kind) void {
        if (self.korean_src) |src| {
            stack.prependFace(src.data, src.index) catch {};
        }
        const primary = switch (kind) {
            .ui => self.ui_src,
            .mono => self.mono_src,
        };
        if (primary) |src| {
            stack.prependFace(src.data, src.index) catch {};
        }
    }

    fn defaultPx(self: *const Fonts, kind: Kind) u32 {
        return switch (kind) {
            .ui => self.ui_px,
            .mono => self.editor_px,
        };
    }

    pub fn get(self: *Fonts, family: Family) *FontStack {
        const px = if (family.px == 0) self.defaultPx(family.kind) else family.px;
        const fallback: *FontStack = switch (family.kind) {
            .ui => &self.ui_default,
            .mono => &self.mono_default,
        };
        if (px == self.defaultPx(family.kind)) return fallback;

        const key = Key{ .kind = family.kind, .px = px };
        if (self.extra.get(key)) |s| return s;

        // A size we have not drawn at yet. Anything that goes wrong here is
        // cosmetic -- the default size draws instead -- so none of it is fatal.
        const stack = self.gpa.create(FontStack) catch return fallback;
        stack.* = FontStack.initScaled(self.gpa, px, self.scale) catch {
            self.gpa.destroy(stack);
            return fallback;
        };
        stack.grid = family.kind == .mono;
        self.dress(stack, family.kind);
        self.extra.put(self.gpa, key, stack) catch {
            stack.deinit();
            self.gpa.destroy(stack);
            return fallback;
        };
        return stack;
    }

    /// The file the interface face came from, or null when the bundled face is
    /// doing the job.
    pub fn uiPath(self: *const Fonts) ?[]const u8 {
        return if (self.ui_src) |src| src.path else null;
    }

    /// The file note text is set in.
    pub fn monoPath(self: *const Fonts) ?[]const u8 {
        return if (self.mono_src) |src| src.path else null;
    }

    /// Rebuild every face for a new device scale, as when the window moves to
    /// a display with a different pixel density.
    pub fn setScale(self: *Fonts, scale: f32) font.Error!void {
        if (scale == self.scale) return;
        self.scale = scale;

        // The per-size stacks are rebuilt lazily; dropping them is enough.
        var it = self.extra.valueIterator();
        while (it.next()) |st| {
            st.*.deinit();
            self.gpa.destroy(st.*);
        }
        self.extra.clearRetainingCapacity();

        for ([_]*FontStack{ &self.ui_default, &self.mono_default }) |st| {
            const px = st.px_size;
            st.scale = scale;
            st.px_size = 0; // force `setPixelSize` past its early return
            try st.setPixelSize(px);
        }
    }

    /// Apply a zoom step. Only note text moves.
    pub fn setEditorSize(self: *Fonts, px: u32) font.Error!void {
        self.editor_px = px;
        try self.mono_default.setPixelSize(px);
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "the bundled face alone gives every family usable metrics" {
    var f = try Fonts.initBundled(testing.allocator, .{});
    defer f.deinit();

    for ([_]Family{
        .{},
        .{ .px = 11 },
        .{ .kind = .mono },
        .{ .kind = .mono, .px = 11 },
    }) |fam| {
        const m = f.get(fam).metrics;
        try testing.expect(m.ch_width > 0);
        try testing.expect(m.row_height > 0);
        try testing.expect(m.ascent > 0);
    }
    // A smaller size really is smaller.
    try testing.expect(f.get(.{ .px = 10 }).metrics.row_height <
        f.get(.{}).metrics.row_height);
}

test "the default size resolves to the default stack, however it is spelled" {
    var f = try Fonts.initBundled(testing.allocator, .{ .ui_px = 13 });
    defer f.deinit();

    try testing.expectEqual(f.get(.{}), f.get(.{ .px = 13 }));
    try testing.expectEqual(@as(usize, 0), f.extra.count());

    _ = f.get(.{ .px = 11 });
    _ = f.get(.{ .px = 11 });
    try testing.expectEqual(@as(usize, 1), f.extra.count());
}

test "interface text is proportional and note text is on the grid" {
    var f = try Fonts.initBundled(testing.allocator, .{});
    defer f.deinit();

    try testing.expect(!f.get(.{}).grid);
    try testing.expect(!f.get(.{ .px = 11 }).grid);
    try testing.expect(f.get(.{ .kind = .mono }).grid);
    try testing.expect(f.get(.{ .kind = .mono, .px = 11 }).grid);
}

test "zoom moves note text and leaves the interface alone" {
    var f = try Fonts.initBundled(testing.allocator, .{});
    defer f.deinit();

    const ui_before = f.get(.{}).metrics.row_height;
    const mono_before = f.get(.{ .kind = .mono }).metrics.row_height;

    try f.setEditorSize(24);

    try testing.expect(f.get(.{ .kind = .mono }).metrics.row_height > mono_before);
    try testing.expectEqual(ui_before, f.get(.{}).metrics.row_height);
}
