//! The update check.
//!
//! Ported from `src/lib/updater.ts`. Nova's updates are not Tauri's: the app
//! asks a small API for the latest version on a channel and, if it is newer,
//! offers a download link.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("notion/client.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const api_base = "https://oein.fyi/api/projects/bf2e00d3-d9a8-4ebc-9057-e2f34fe1bea5/versions";

pub const Channel = enum {
    release,
    beta,
    dev,

    pub fn path(self: Channel) []const u8 {
        return switch (self) {
            .release => "/latest",
            .beta => "/latest/beta",
            .dev => "/latest/dev",
        };
    }

    pub fn label(self: Channel) []const u8 {
        return switch (self) {
            .release => "Release (stable)",
            .beta => "Beta",
            .dev => "Dev (nightly)",
        };
    }

    pub fn fromString(s: []const u8) ?Channel {
        if (std.mem.eql(u8, s, "release")) return .release;
        if (std.mem.eql(u8, s, "beta")) return .beta;
        if (std.mem.eql(u8, s, "dev")) return .dev;
        return null;
    }
};

pub const Available = struct {
    version: []const u8,
    channel: Channel,
    download_url: ?[]const u8,
};

// -- semver ------------------------------------------------------------------

const Version = struct { major: u32, minor: u32, patch: u32 };

/// Parse `1.2.3`, tolerating a leading `v` and ignoring any pre-release suffix.
fn parseVersion(s: []const u8) ?Version {
    var text = std.mem.trim(u8, s, " \t\r\nv");
    // Cut a `-beta.1` or `+build` suffix.
    if (std.mem.indexOfAny(u8, text, "-+")) |cut| text = text[0..cut];

    var it = std.mem.splitScalar(u8, text, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const patch = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// True when `candidate` is strictly newer than `current`.
///
/// An unparseable candidate is never newer -- a malformed response must not
/// nag the user about an update that does not exist.
pub fn isNewer(candidate: []const u8, current: []const u8) bool {
    const c = parseVersion(candidate) orelse return false;
    const now = parseVersion(current) orelse return true;

    if (c.major != now.major) return c.major > now.major;
    if (c.minor != now.minor) return c.minor > now.minor;
    return c.patch > now.patch;
}

// -- picking a download ------------------------------------------------------

/// The file for this platform, matching how the web build chose by user agent.
pub fn preferredFile(files: Value) ?Value {
    const arr = switch (files) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    const wanted: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ ".exe", ".msi" },
        .macos => &.{".dmg"},
        else => &.{ ".appimage", ".AppImage" },
    };

    for (wanted) |ext| {
        for (arr.items) |file| {
            const name = fieldString(file, "name") orelse continue;
            if (std.ascii.endsWithIgnoreCase(name, ext)) return file;
        }
    }
    // Better to offer something than nothing.
    return arr.items[0];
}

fn fieldString(v: Value, key: []const u8) ?[]const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

pub fn fileDownloadUrl(arena: Allocator, version: []const u8, file_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/files/{s}/download", .{ api_base, version, file_id });
}

// -- the check ---------------------------------------------------------------

/// Ask the API for the newest version on `channel`.
///
/// Returns null when the app is already current, and an error only when the
/// request itself failed -- a check that cannot reach the network is not
/// something to interrupt the user about.
pub fn check(
    arena: Allocator,
    transport: client.Transport,
    gpa: Allocator,
    channel: Channel,
    current_version: []const u8,
) !?Available {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ api_base, channel.path() });

    const response = try transport.send(gpa, .get, url, null);
    defer response.deinit(gpa);
    if (!response.ok()) return error.UpdateCheckFailed;

    const parsed = std.json.parseFromSliceLeaky(Value, arena, response.body, .{}) catch
        return error.UpdateCheckFailed;

    const version = fieldString(parsed, "version") orelse return error.UpdateCheckFailed;
    if (!isNewer(version, current_version)) return null;

    var download: ?[]const u8 = null;
    if (switch (parsed) {
        .object => |o| o.get("files"),
        else => null,
    }) |files| {
        if (preferredFile(files)) |file| {
            if (fieldString(file, "id")) |file_id| {
                download = try fileDownloadUrl(arena, version, file_id);
            }
        }
    }

    return .{ .version = version, .channel = channel, .download_url = download };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "version comparison" {
    try testing.expect(isNewer("1.0.1", "1.0.0"));
    try testing.expect(isNewer("1.1.0", "1.0.9"));
    try testing.expect(isNewer("2.0.0", "1.9.9"));
    try testing.expect(!isNewer("1.0.0", "1.0.0"));
    try testing.expect(!isNewer("0.9.9", "1.0.0"));
}

test "a leading v and a pre-release suffix are tolerated" {
    try testing.expect(isNewer("v1.0.1", "1.0.0"));
    try testing.expect(isNewer("1.1.0-beta.2", "1.0.0"));
    try testing.expect(!isNewer("1.0.0-beta.2", "1.0.0"));
}

test "a malformed candidate never claims to be newer" {
    // A broken response must not nag the user about an update that isn't there.
    try testing.expect(!isNewer("", "1.0.0"));
    try testing.expect(!isNewer("not-a-version", "1.0.0"));
    // An unknown *current* version is the opposite case: offer the update.
    try testing.expect(isNewer("1.0.0", "unknown"));
}

test "short versions default their missing parts" {
    try testing.expect(isNewer("2", "1.9.9"));
    try testing.expect(isNewer("1.1", "1.0.9"));
    try testing.expect(!isNewer("1", "1.0.0"));
}

test "channel identifiers and paths" {
    try testing.expectEqualStrings("/latest", Channel.release.path());
    try testing.expectEqualStrings("/latest/beta", Channel.beta.path());
    try testing.expectEqual(Channel.dev, Channel.fromString("dev").?);
    try testing.expect(Channel.fromString("nightly") == null);
}

test "the platform's file is preferred, with a fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Value, arena,
        \\[{"id":"1","name":"Nova.AppImage"},{"id":"2","name":"Nova.dmg"},{"id":"3","name":"Nova.exe"}]
    , .{});

    const picked = preferredFile(parsed).?;
    const name = fieldString(picked, "name").?;
    const expected = switch (builtin.os.tag) {
        .windows => "Nova.exe",
        .macos => "Nova.dmg",
        else => "Nova.AppImage",
    };
    try testing.expectEqualStrings(expected, name);

    // With nothing matching, the first entry is still offered.
    const other = try std.json.parseFromSliceLeaky(Value, arena,
        \\[{"id":"9","name":"Nova.tar.gz"}]
    , .{});
    try testing.expectEqualStrings("Nova.tar.gz", fieldString(preferredFile(other).?, "name").?);

    const empty = try std.json.parseFromSliceLeaky(Value, arena, "[]", .{});
    try testing.expect(preferredFile(empty) == null);
}

test "download urls are built from the version and file id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const url = try fileDownloadUrl(arena_state.allocator(), "1.2.3", "abc");
    try testing.expect(std.mem.endsWith(u8, url, "/versions/1.2.3/files/abc/download"));
}

// A transport that answers with a canned body, so the check can be exercised
// without a network.
const StubTransport = struct {
    status: u16 = 200,
    body: []const u8,

    fn send(
        ptr: *anyopaque,
        gpa: Allocator,
        method: client.Method,
        path: []const u8,
        body: ?[]const u8,
    ) client.Error!client.Response {
        _ = method;
        _ = path;
        _ = body;
        const self: *StubTransport = @ptrCast(@alignCast(ptr));
        return .{ .status = self.status, .body = gpa.dupe(u8, self.body) catch return error.OutOfMemory };
    }

    fn transport(self: *StubTransport) client.Transport {
        return .{ .ptr = self, .sendFn = send };
    }
};

test "a newer version is reported with a download link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var stub = StubTransport{
        .body =
        \\{"version":"9.9.9","files":[{"id":"f1","name":"Nova.dmg"},{"id":"f2","name":"Nova.exe"},{"id":"f3","name":"Nova.AppImage"}]}
        ,
    };
    const found = (try check(
        arena_state.allocator(),
        stub.transport(),
        testing.allocator,
        .release,
        "0.1.0",
    )).?;
    try testing.expectEqualStrings("9.9.9", found.version);
    try testing.expect(found.download_url != null);
    try testing.expect(std.mem.indexOf(u8, found.download_url.?, "9.9.9") != null);
}

test "an up-to-date app is told nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var stub = StubTransport{ .body = "{\"version\":\"0.1.0\",\"files\":[]}" };
    try testing.expect((try check(
        arena_state.allocator(),
        stub.transport(),
        testing.allocator,
        .release,
        "0.1.0",
    )) == null);
}

test "a failed request is an error, not a silent 'up to date'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var stub = StubTransport{ .status = 502, .body = "bad gateway" };
    try testing.expectError(error.UpdateCheckFailed, check(
        arena_state.allocator(),
        stub.transport(),
        testing.allocator,
        .release,
        "0.1.0",
    ));

    var garbage = StubTransport{ .body = "not json" };
    try testing.expectError(error.UpdateCheckFailed, check(
        arena_state.allocator(),
        garbage.transport(),
        testing.allocator,
        .release,
        "0.1.0",
    ));
}
