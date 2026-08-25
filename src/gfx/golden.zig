//! Golden-image comparison.
//!
//! This machine has no display, so "does it render correctly" cannot be checked
//! by looking. Instead the painter draws into a `Surface` -- the very same one a
//! window is fed from -- and the result is compared byte for byte against a
//! committed PNG.
//!
//! Comparison is on the encoded bytes rather than decoded pixels, so no PNG
//! decoder is needed: `surface.encodePng` emits stored (uncompressed) deflate
//! blocks and is deterministic.
//!
//! On a mismatch the rendered image is written next to the golden as
//! `<name>.actual.png` so a human can open both.

const std = @import("std");
const surface = @import("surface.zig");

const Surface = surface.Surface;
const dir = "src/gfx/testdata/golden";

pub const Error = error{
    GoldenMismatch,
    GoldenCreated,
};

/// Compare `s` against the golden named `name`.
///
/// When no golden exists yet, one is written and `error.GoldenCreated` is
/// returned: a new baseline should be looked at before it is trusted, so the
/// test fails the first time on purpose.
pub fn expectMatches(gpa: std.mem.Allocator, io: std.Io, name: []const u8, s: *const Surface) !void {
    const png = try surface.encodePng(s, gpa);
    defer gpa.free(png);

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ dir, name });
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDirPath(io, dir);
            try cwd.writeFile(io, .{ .sub_path = path, .data = png });
            std.debug.print(
                "\ngolden created: {s} -- review it, then re-run\n",
                .{path},
            );
            return error.GoldenCreated;
        },
        else => return err,
    };
    defer gpa.free(existing);

    if (std.mem.eql(u8, existing, png)) return;

    const actual_path = try std.fmt.allocPrint(gpa, "{s}/{s}.actual.png", .{ dir, name });
    defer gpa.free(actual_path);
    try cwd.writeFile(io, .{ .sub_path = actual_path, .data = png });
    std.debug.print(
        "\ngolden mismatch for {s}\n  expected: {s}\n  actual:   {s}\n",
        .{ name, path, actual_path },
    );
    return error.GoldenMismatch;
}

/// Set up a threaded `Io` for a golden test.
pub const TestIo = struct {
    threaded: *std.Io.Threaded,
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !TestIo {
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = .init(gpa, .{});
        return .{ .threaded = threaded, .io = threaded.io(), .gpa = gpa };
    }

    pub fn deinit(self: *TestIo) void {
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }
};
