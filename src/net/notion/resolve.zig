//! Resolving a conflict.
//!
//! Ported from `resolve_with` / `resolve_all` in `src-tauri/src/notion/sync.rs`.
//!
//! Every branch finishes its work **before** clearing the conflict. Deleting the
//! row first would lose both the conflict and its remote snapshot if anything
//! failed midway, leaving the user with neither the decision nor the evidence.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");
const client = @import("client.zig");
const store = @import("store.zig");
const classify = @import("classify.zig");
const sync = @import("sync.zig");
const engine_mod = @import("engine.zig");

const Allocator = std.mem.Allocator;
const Workspace = db.workspace.Workspace;
const Endpoints = client.Endpoints;
const ConflictKind = classify.ConflictKind;

pub const Error = engine_mod.Error || error{ NotResolvable, UnknownPolicy };

pub const Resolution = enum {
    keep_local,
    keep_remote,
    keep_both,
    recreate_remote,
    restore_local,
    accept_remote_delete,
    accept_local_delete,

    /// The identifiers the UI sends, unchanged from the Tauri build.
    pub fn fromString(s: []const u8) ?Resolution {
        const pairs = .{
            .{ "keepLocal", Resolution.keep_local },
            .{ "keepRemote", Resolution.keep_remote },
            .{ "keepBoth", Resolution.keep_both },
            .{ "recreateRemote", Resolution.recreate_remote },
            .{ "restoreLocal", Resolution.restore_local },
            .{ "acceptRemoteDelete", Resolution.accept_remote_delete },
            .{ "acceptLocalDelete", Resolution.accept_local_delete },
        };
        inline for (pairs) |p| {
            if (std.mem.eql(u8, s, p[0])) return p[1];
        }
        return null;
    }
};

/// Applying one decision to every conflict at once.
pub const BulkPolicy = enum {
    /// Nova's version wins everywhere; notes deleted in Notion are recreated.
    local,
    /// Notion's version wins everywhere, including its deletions.
    remote,
    /// Nothing is discarded: a differing page is kept as a second note, and no
    /// deletion is applied.
    both,

    pub fn fromString(s: []const u8) ?BulkPolicy {
        if (std.mem.eql(u8, s, "local")) return .local;
        if (std.mem.eql(u8, s, "remote")) return .remote;
        if (std.mem.eql(u8, s, "both")) return .both;
        return null;
    }
};

/// The full three-by-three matrix of policy against conflict kind.
pub fn resolutionFor(kind: ConflictKind, policy: BulkPolicy) Resolution {
    return switch (policy) {
        .local => switch (kind) {
            .both_changed => .keep_local,
            // The page is gone but Nova still has the note: put it back.
            .remote_deleted => .recreate_remote,
            // Nova deleted it, and Nova wins: let Notion follow.
            .local_deleted => .accept_local_delete,
        },
        .remote => switch (kind) {
            .both_changed => .keep_remote,
            .remote_deleted => .accept_remote_delete,
            // Notion still has it, and Notion wins: bring it back locally.
            .local_deleted => .restore_local,
        },
        .both => switch (kind) {
            .both_changed => .keep_both,
            // Nothing is discarded, so both deletions are undone.
            .remote_deleted => .recreate_remote,
            .local_deleted => .restore_local,
        },
    };
}

pub const BulkResult = struct { resolved: usize, failed: usize };

pub const Resolver = struct {
    gpa: Allocator,
    io: std.Io,
    ws: *Workspace,
    api: *client.Client,
    /// A resolution uses a *fresh* cancel flag, never the sync's.
    ///
    /// The sync flag stays latched after a cancelled run, and reusing it would
    /// abort every later resolution the user asked for.
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    arena: std.heap.ArenaAllocator = undefined,

    pub fn init(gpa: Allocator, io: std.Io, ws: *Workspace, api: *client.Client) Resolver {
        return .{ .gpa = gpa, .io = io, .ws = ws, .api = api };
    }

    fn a(self: *Resolver) Allocator {
        return self.arena.allocator();
    }

    fn engine(self: *Resolver) engine_mod.Engine {
        return engine_mod.Engine.init(self.gpa, self.io, self.ws, self.api, &self.cancel);
    }

    /// Apply one decision to one conflicted note.
    pub fn resolve(self: *Resolver, note_id: []const u8, how: Resolution) Error!void {
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer self.arena.deinit();

        const detail = (try store.getConflict(self.ws, self.a(), note_id)) orelse return;
        const cfg = try store.getConfig(self.ws, self.a());
        const creds = try cfg.credentials();

        switch (how) {
            .keep_local => try self.pushLocal(note_id, detail, creds.database_id),
            .keep_both => {
                // Fork first: the page's version is preserved as a second note
                // before the local one overwrites it.
                try self.forkRemoteCopy(detail);
                try self.pushLocal(note_id, detail, creds.database_id);
            },
            .keep_remote => try self.pullRemote(note_id, detail),
            .recreate_remote => try self.recreateRemote(note_id, creds.database_id),
            .restore_local => try self.restoreLocal(note_id, detail),
            .accept_remote_delete => {
                try self.ws.trashNote(note_id, self.nowMs());
                try store.deleteLink(self.ws, note_id);
            },
            .accept_local_delete => {
                if (detail.page_id) |page_id| {
                    _ = try Endpoints.updatePage(self.api, self.a(), page_id, null, true);
                }
                try store.deleteLink(self.ws, note_id);
            },
        }

        // Only now, with the work done, is the decision recorded as settled.
        try store.deleteConflict(self.ws, note_id);
        if (try store.getLink(self.ws, self.a(), note_id)) |_| {
            try store.setLinkState(self.ws, note_id, "ok", null);
        }
    }

    fn nowMs(self: *Resolver) i64 {
        return @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    /// Refuse a resolution that would rebuild a page holding a block Nova
    /// cannot recreate. Without this the resolver would be a back door around
    /// the pull-only guard.
    fn ensurePushable(self: *Resolver, note_id: []const u8) Error!void {
        const link = (try store.getLink(self.ws, self.a(), note_id)) orelse return;
        if (link.isBlocked()) return error.NotResolvable;
    }

    fn pushLocal(self: *Resolver, note_id: []const u8, detail: store.ConflictDetail, database_id: []const u8) Error!void {
        try self.ensurePushable(note_id);
        var e = self.engine();
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer e.arena.deinit();

        const content = try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
        var report = sync.Report.init(self.gpa);
        defer report.deinit();

        const props = sync.Props{ .title_prop = "Name" };
        if (detail.page_id) |page_id| {
            try e.rebuildPageForResolve(&report, props, note_id, page_id, content);
        } else {
            // The page is gone, so making one is the only way to keep the note.
            try e.createRemoteForResolve(&report, props, database_id, note_id);
        }
    }

    fn pullRemote(self: *Resolver, note_id: []const u8, detail: store.ConflictDetail) Error!void {
        const page_id = detail.page_id orelse return;
        var e = self.engine();
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer e.arena.deinit();

        var report = sync.Report.init(self.gpa);
        defer report.deinit();
        // No `expect_local`: the user looked at both sides, so a newer local
        // save loses on purpose.
        try e.pullForResolve(&report, note_id, page_id);
    }

    fn recreateRemote(self: *Resolver, note_id: []const u8, database_id: []const u8) Error!void {
        try store.deleteLink(self.ws, note_id);
        var e = self.engine();
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer e.arena.deinit();

        var report = sync.Report.init(self.gpa);
        defer report.deinit();
        const props = sync.Props{ .title_prop = "Name" };
        try e.createRemoteForResolve(&report, props, database_id, note_id);
    }

    fn restoreLocal(self: *Resolver, note_id: []const u8, detail: store.ConflictDetail) Error!void {
        try self.ws.restoreNote(note_id, self.nowMs());
        const page_id = detail.page_id orelse return;

        var e = self.engine();
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer e.arena.deinit();
        var report = sync.Report.init(self.gpa);
        defer report.deinit();
        try e.pullForResolve(&report, note_id, page_id);
    }

    /// Keep the page's version as a second note, so "keep both" discards
    /// nothing.
    ///
    /// Only the heading line is replaced; the rest of the body carries over
    /// verbatim.
    fn forkRemoteCopy(self: *Resolver, detail: store.ConflictDetail) Error!void {
        const remote = detail.remote_content orelse return;

        const eol = std.mem.indexOfScalar(u8, remote, '\n') orelse remote.len;
        const rest = if (eol < remote.len) remote[eol + 1 ..] else "";
        const old_title = db.workspace.firstLineTitle(remote, db.workspace.default_title);
        const forked = try std.fmt.allocPrint(
            self.a(),
            "# {s} (Notion)\n{s}",
            .{ old_title, rest },
        );

        const note = try self.ws.createNote();
        defer note.deinit(self.gpa);
        const title = db.workspace.firstLineTitle(forked, db.workspace.default_title);
        _ = try self.ws.applyRemoteContent(note.id, forked, title);
    }

    /// Apply one policy to every outstanding conflict.
    ///
    /// Each is resolved independently, so one failure leaves the rest listed
    /// rather than abandoning the batch.
    pub fn resolveAll(self: *Resolver, policy: BulkPolicy) Error!BulkResult {
        var result = BulkResult{ .resolved = 0, .failed = 0 };

        const conflicts = try store.listConflicts(self.ws, self.gpa);
        defer store.freeConflicts(self.gpa, conflicts);

        for (conflicts) |c| {
            const kind = ConflictKind.fromString(c.kind) orelse {
                result.failed += 1;
                continue;
            };
            self.resolve(c.note_id, resolutionFor(kind, policy)) catch {
                result.failed += 1;
                continue;
            };
            result.resolved += 1;
        }
        return result;
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "resolution identifiers round-trip" {
    try testing.expectEqual(Resolution.keep_local, Resolution.fromString("keepLocal").?);
    try testing.expectEqual(Resolution.keep_both, Resolution.fromString("keepBoth").?);
    try testing.expectEqual(
        Resolution.accept_remote_delete,
        Resolution.fromString("acceptRemoteDelete").?,
    );
    try testing.expect(Resolution.fromString("nonsense") == null);
}

test "bulk policies round-trip" {
    try testing.expectEqual(BulkPolicy.local, BulkPolicy.fromString("local").?);
    try testing.expectEqual(BulkPolicy.remote, BulkPolicy.fromString("remote").?);
    try testing.expectEqual(BulkPolicy.both, BulkPolicy.fromString("both").?);
    try testing.expect(BulkPolicy.fromString("neither") == null);
}

test "the policy matrix keeps Nova's side everywhere" {
    try testing.expectEqual(Resolution.keep_local, resolutionFor(.both_changed, .local));
    // The page is gone but Nova still has the note, so put it back.
    try testing.expectEqual(Resolution.recreate_remote, resolutionFor(.remote_deleted, .local));
    // Nova deleted it and Nova wins, so Notion follows.
    try testing.expectEqual(Resolution.accept_local_delete, resolutionFor(.local_deleted, .local));
}

test "the policy matrix takes Notion's side everywhere, deletions included" {
    try testing.expectEqual(Resolution.keep_remote, resolutionFor(.both_changed, .remote));
    try testing.expectEqual(Resolution.accept_remote_delete, resolutionFor(.remote_deleted, .remote));
    try testing.expectEqual(Resolution.restore_local, resolutionFor(.local_deleted, .remote));
}

test "the keep-everything policy never applies a deletion" {
    try testing.expectEqual(Resolution.keep_both, resolutionFor(.both_changed, .both));
    try testing.expectEqual(Resolution.recreate_remote, resolutionFor(.remote_deleted, .both));
    try testing.expectEqual(Resolution.restore_local, resolutionFor(.local_deleted, .both));

    // Whatever the kind, "keep everything" never discards either side.
    for ([_]ConflictKind{ .both_changed, .remote_deleted, .local_deleted }) |kind| {
        const r = resolutionFor(kind, .both);
        try testing.expect(r != .accept_local_delete);
        try testing.expect(r != .accept_remote_delete);
    }
}
