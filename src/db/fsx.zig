//! Filesystem and clock helpers, scoped to a workspace directory.
//!
//! Zig 0.16 routes all file I/O through the `std.Io` interface, so every
//! operation takes an `io` handle. Rather than thread that through the whole
//! workspace layer, `Fs` binds it together with the workspace root directory.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Error = std.mem.Allocator.Error || error{
    FsFailed,
    NotFound,
};

/// Milliseconds since the Unix epoch.
pub fn nowMs(io: Io) i64 {
    const ts = Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

fn timestampMs(ts: Io.Timestamp) i64 {
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

pub const Meta = struct {
    mtime_ms: i64,
    size: i64,
};

pub const Fs = struct {
    io: Io,
    dir: Dir,

    /// Open `root` (creating it and the `notes/` and `trash/` subdirectories).
    pub fn openRoot(io: Io, root: []const u8) Error!Fs {
        const cwd = Dir.cwd();
        cwd.createDirPath(io, root) catch return error.FsFailed;
        var dir = cwd.openDir(io, root, .{}) catch return error.FsFailed;
        errdefer dir.close(io);
        dir.createDirPath(io, "notes") catch return error.FsFailed;
        dir.createDirPath(io, "trash") catch return error.FsFailed;
        return .{ .io = io, .dir = dir };
    }

    pub fn close(self: *Fs) void {
        self.dir.close(self.io);
    }

    /// Read a whole file. Caller owns the result.
    pub fn read(self: Fs, gpa: std.mem.Allocator, sub_path: []const u8) Error![]u8 {
        return self.dir.readFileAlloc(self.io, sub_path, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => error.NotFound,
            else => error.FsFailed,
        };
    }

    /// Read a whole file, or return an empty string when it is missing or
    /// unreadable. Mirrors the original's `unwrap_or_default()` at the call
    /// sites that only want best-effort content (FTS backfill, snippets).
    pub fn readOrEmpty(self: Fs, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return self.read(gpa, sub_path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => try gpa.dupe(u8, ""),
        };
    }

    pub fn write(self: Fs, sub_path: []const u8, data: []const u8) Error!void {
        self.dir.writeFile(self.io, .{ .sub_path = sub_path, .data = data }) catch
            return error.FsFailed;
    }

    pub fn statMeta(self: Fs, sub_path: []const u8) Error!Meta {
        const st = self.dir.statFile(self.io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.FsFailed,
        };
        return .{ .mtime_ms = timestampMs(st.mtime), .size = @intCast(st.size) };
    }

    pub fn exists(self: Fs, sub_path: []const u8) bool {
        _ = self.statMeta(sub_path) catch return false;
        return true;
    }

    pub fn rename(self: Fs, old_sub_path: []const u8, new_sub_path: []const u8) Error!void {
        self.dir.rename(old_sub_path, self.dir, new_sub_path, self.io) catch
            return error.FsFailed;
    }

    /// Delete, ignoring a missing file -- the original used `let _ = remove_file`
    /// throughout, since a note whose file is already gone is still deletable.
    pub fn deleteIfExists(self: Fs, sub_path: []const u8) void {
        self.dir.deleteFile(self.io, sub_path) catch {};
    }
};

/// A UUID v4 in canonical 8-4-4-4-12 form.
pub const Uuid = struct {
    bytes: [36]u8,

    pub fn slice(self: *const Uuid) []const u8 {
        return &self.bytes;
    }
};

/// Randomness comes from the `Io` interface rather than a stored `std.Random`.
/// A `std.Random` is a fat pointer into its generator, so holding one in a
/// struct that is ever copied by value leaves it dangling.
pub fn uuidV4(io: Io) Uuid {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    raw[6] = (raw[6] & 0x0F) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3F) | 0x80; // variant 1

    var out: Uuid = .{ .bytes = undefined };
    const hex = "0123456789abcdef";
    var i: usize = 0; // index into raw
    var o: usize = 0; // index into out
    for ([_]usize{ 4, 2, 2, 2, 6 }, 0..) |group, g| {
        if (g > 0) {
            out.bytes[o] = '-';
            o += 1;
        }
        for (0..group) |_| {
            out.bytes[o] = hex[raw[i] >> 4];
            out.bytes[o + 1] = hex[raw[i] & 0x0F];
            i += 1;
            o += 2;
        }
    }
    return out;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

/// Spin up a threaded `Io` plus a scratch directory for tests.
pub const TestEnv = struct {
    threaded: *std.Io.Threaded,
    io: Io,
    path: []u8,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, name: []const u8) !TestEnv {
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = .init(gpa, .{});
        const io = threaded.io();

        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/nova-test-{s}", .{name});
        errdefer gpa.free(path);
        // Start from a clean slate so reruns are deterministic.
        Dir.cwd().deleteTree(io, path) catch {};
        try Dir.cwd().createDirPath(io, path);

        return .{ .threaded = threaded, .io = io, .path = path, .gpa = gpa };
    }

    pub fn deinit(self: *TestEnv) void {
        Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.gpa.free(self.path);
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }
};

test "clock returns a plausible epoch time" {
    var env = try TestEnv.init(testing.allocator, "clock");
    defer env.deinit();
    const t = nowMs(env.io);
    // Somewhere after 2020 and before 2100.
    try testing.expect(t > 1_577_836_800_000);
    try testing.expect(t < 4_102_444_800_000);
}

test "workspace root gets its subdirectories" {
    var env = try TestEnv.init(testing.allocator, "root");
    defer env.deinit();

    const root = try std.fmt.allocPrint(testing.allocator, "{s}/ws", .{env.path});
    defer testing.allocator.free(root);

    var fs = try Fs.openRoot(env.io, root);
    defer fs.close();

    try fs.write("notes/a.md", "hello");
    try testing.expect(fs.exists("notes/a.md"));

    const body = try fs.read(testing.allocator, "notes/a.md");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);

    const meta = try fs.statMeta("notes/a.md");
    try testing.expectEqual(@as(i64, 5), meta.size);
    try testing.expect(meta.mtime_ms > 0);
}

test "rename and delete" {
    var env = try TestEnv.init(testing.allocator, "rename");
    defer env.deinit();
    const root = try std.fmt.allocPrint(testing.allocator, "{s}/ws", .{env.path});
    defer testing.allocator.free(root);

    var fs = try Fs.openRoot(env.io, root);
    defer fs.close();

    try fs.write("notes/a.md", "x");
    try fs.rename("notes/a.md", "trash/a.md");
    try testing.expect(!fs.exists("notes/a.md"));
    try testing.expect(fs.exists("trash/a.md"));

    fs.deleteIfExists("trash/a.md");
    try testing.expect(!fs.exists("trash/a.md"));
    // Deleting something already gone is not an error.
    fs.deleteIfExists("trash/a.md");
}

test "missing file reads as NotFound" {
    var env = try TestEnv.init(testing.allocator, "missing");
    defer env.deinit();
    const root = try std.fmt.allocPrint(testing.allocator, "{s}/ws", .{env.path});
    defer testing.allocator.free(root);
    var fs = try Fs.openRoot(env.io, root);
    defer fs.close();

    try testing.expectError(error.NotFound, fs.read(testing.allocator, "notes/nope.md"));

    const empty = try fs.readOrEmpty(testing.allocator, "notes/nope.md");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "uuid v4 shape" {
    var env = try TestEnv.init(testing.allocator, "uuid");
    defer env.deinit();
    const u = uuidV4(env.io);
    const s = u.slice();
    try testing.expectEqual(@as(usize, 36), s.len);
    try testing.expectEqual(@as(u8, '-'), s[8]);
    try testing.expectEqual(@as(u8, '-'), s[13]);
    try testing.expectEqual(@as(u8, '-'), s[18]);
    try testing.expectEqual(@as(u8, '-'), s[23]);
    try testing.expectEqual(@as(u8, '4'), s[14]); // version nibble
    try testing.expect(s[19] == '8' or s[19] == '9' or s[19] == 'a' or s[19] == 'b');

    // Two draws differ.
    const v = uuidV4(env.io);
    try testing.expect(!std.mem.eql(u8, u.slice(), v.slice()));
}
