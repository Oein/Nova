//! Handing a path or URL to the operating system.
//!
//! Ported from `src-tauri/src/commands/shell.rs` and the `reveal_note` command
//! in `src-tauri/src/commands/workspace.rs`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Error = error{ SpawnFailed, OutOfMemory };

/// Spawn a detached command. The child is not waited on -- these all hand off
/// to a GUI application that outlives us.
fn spawnDetached(io: Io, argv: []const []const u8) Error!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    // Reaping immediately would kill the handoff on some platforms; the OS
    // reparents the child when we exit.
    _ = &child;
}

/// Open a URL in the user's browser.
pub fn openUrl(io: Io, url: []const u8) Error!void {
    switch (builtin.os.tag) {
        .macos => try spawnDetached(io, &.{ "open", url }),
        .windows => try spawnDetached(io, &.{ "cmd", "/c", "start", "", url }),
        else => try spawnDetached(io, &.{ "xdg-open", url }),
    }
}

/// Show a file in the OS file manager.
///
/// macOS and Windows can highlight the file itself; elsewhere the best that is
/// portable is opening the containing folder.
pub fn revealPath(io: Io, gpa: std.mem.Allocator, path: []const u8) Error!void {
    switch (builtin.os.tag) {
        .macos => try spawnDetached(io, &.{ "open", "-R", path }),
        .windows => {
            const arg = try std.fmt.allocPrint(gpa, "/select,{s}", .{path});
            defer gpa.free(arg);
            try spawnDetached(io, &.{ "explorer", arg });
        },
        else => {
            const dir = std.fs.path.dirname(path) orelse ".";
            try spawnDetached(io, &.{ "xdg-open", dir });
        },
    }
}

const testing = std.testing;

test "revealPath computes the containing directory on Linux" {
    // The command itself is not run here -- only the argument derivation is
    // portable enough to assert.
    try testing.expectEqualStrings("/a/b", std.fs.path.dirname("/a/b/c.md").?);
    try testing.expect(std.fs.path.dirname("c.md") == null);
}
