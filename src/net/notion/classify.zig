//! Deciding what a sync should do to one note.
//!
//! Ported from the `classify` half of `src-tauri/src/notion/sync.rs`.
//!
//! Nothing here does I/O. That is deliberate and load-bearing: the merge table
//! is the part most likely to be wrong, and keeping it pure means every cell of
//! it is testable without a network or a database.
//!
//! The baseline is content-addressed, not time-addressed. Notion's
//! `last_edited_time` has second granularity and bumps on our own writes, so it
//! only ever answers "*might* this have changed?" -- a hash over the rendered
//! markdown answers "did it actually?".

const std = @import("std");

pub const ConflictKind = enum {
    both_changed,
    remote_deleted,
    local_deleted,

    /// The string stored in `notion_conflicts.kind`, unchanged from the Rust
    /// build so an existing database still reads.
    pub fn toString(self: ConflictKind) []const u8 {
        return switch (self) {
            .both_changed => "both-changed",
            .remote_deleted => "remote-deleted",
            .local_deleted => "local-deleted",
        };
    }

    pub fn fromString(s: []const u8) ?ConflictKind {
        if (std.mem.eql(u8, s, "both-changed")) return .both_changed;
        if (std.mem.eql(u8, s, "remote-deleted")) return .remote_deleted;
        if (std.mem.eql(u8, s, "local-deleted")) return .local_deleted;
        return null;
    }
};

pub const Action = union(enum) {
    skip,
    pull,
    push,
    /// The remote timestamp moved, which only proves the page *might* have
    /// changed. Fetch its blocks and re-decide with `stageTwo`.
    maybe_pull,
    create_remote,
    create_local,
    archive_remote,
    trash_local,
    conflict: ConflictKind,
    /// A page carries a Nova id matching a local note that has no link -- the
    /// mapping was lost (fresh install, deleted workspace.db) but the identity
    /// survived in Notion. Re-attach rather than importing a duplicate.
    adopt,
    /// Content is in sync, but the page's Nova-owned columns (created, updated,
    /// id) do not hold the right values yet -- typically right after the user
    /// turns one of them on.
    update_props,
    /// Both sides are gone; the mapping is dead weight.
    drop_link,

    pub fn eql(a: Action, b: Action) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .conflict => |k| k == b.conflict,
            else => true,
        };
    }

    /// Ordering for the plan: incoming changes land first, deletions last --
    /// deletions being the least recoverable if something fails midway.
    pub fn priority(self: Action) u8 {
        return switch (self) {
            .adopt => 0,
            .pull, .maybe_pull, .create_local => 1,
            .push, .create_remote => 2,
            .conflict => 3,
            .update_props => 4,
            else => 5,
        };
    }
};

pub const LocalState = struct {
    /// sha256 of the note's markdown.
    hash: []const u8,
    trashed: bool,
};

pub const RemoteState = struct {
    /// Notion's `last_edited_time`, compared as an opaque string.
    last_edited: []const u8,
    archived: bool,
};

pub const Baseline = struct {
    local_hash: []const u8,
    remote_edited: []const u8,
    /// `ok`, `conflict`, `error` or `excluded`.
    state: []const u8,
};

/// Stage one. Cheap: a local content hash against the baseline, and a remote
/// timestamp against the baseline.
pub fn stageOne(local: ?LocalState, remote: ?RemoteState, base: ?Baseline) Action {
    // A note the user excluded, or one waiting on a conflict decision, is
    // frozen: touching either side would destroy the very thing being compared.
    if (base) |b| {
        if (std.mem.eql(u8, b.state, "excluded") or std.mem.eql(u8, b.state, "conflict")) {
            return .skip;
        }
    }

    const local_live: ?LocalState = if (local) |l| (if (l.trashed) null else l) else null;
    const remote_live: ?RemoteState = if (remote) |r| (if (r.archived) null else r) else null;

    const b = base orelse {
        if (local_live != null) return .create_remote;
        if (remote_live != null) return .create_local;
        // A trashed note that was never linked has no business on Notion.
        return .skip;
    };

    const local_changed = if (local_live) |l| !std.mem.eql(u8, l.hash, b.local_hash) else false;

    if (local_live == null and remote_live == null) return .drop_link;

    if (local_live != null and remote_live == null) {
        return if (local_changed) .{ .conflict = .remote_deleted } else .trash_local;
    }

    if (local_live == null) {
        const r = remote_live.?;
        return if (!std.mem.eql(u8, r.last_edited, b.remote_edited))
            .{ .conflict = .local_deleted }
        else
            .archive_remote;
    }

    const r = remote_live.?;
    if (!std.mem.eql(u8, r.last_edited, b.remote_edited)) {
        // Covers both "only remote moved" and "both moved" -- the timestamp
        // cannot tell them apart, so stage two settles it.
        return .maybe_pull;
    }
    return if (local_changed) .push else .skip;
}

/// Stage two, once the remote blocks have been rendered to markdown and hashed.
///
/// `remote_changed == false` with a moved timestamp is the common case: the echo
/// of our own push, or a metadata-only edit in Notion.
pub fn stageTwo(local_changed: bool, remote_changed: bool) Action {
    if (!local_changed and !remote_changed) return .skip;
    if (local_changed and !remote_changed) return .push;
    if (!local_changed and remote_changed) return .pull;
    return .{ .conflict = .both_changed };
}

// -- tests -------------------------------------------------------------------
// The stage-one table, cell by cell, ported from src-tauri/src/notion/sync.rs.

const testing = std.testing;

const live = LocalState{ .hash = "H", .trashed = false };
const changed = LocalState{ .hash = "H2", .trashed = false };
const trashed = LocalState{ .hash = "H", .trashed = true };

const page = RemoteState{ .last_edited = "T", .archived = false };
const moved = RemoteState{ .last_edited = "T2", .archived = false };
const archived = RemoteState{ .last_edited = "T", .archived = true };

const synced = Baseline{ .local_hash = "H", .remote_edited = "T", .state = "ok" };

fn expectAction(expected: Action, actual: Action) !void {
    if (!expected.eql(actual)) {
        std.debug.print("expected {any}, got {any}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

test "with no baseline, whichever side exists is created on the other" {
    try expectAction(.create_remote, stageOne(live, null, null));
    try expectAction(.create_local, stageOne(null, page, null));
    // A note trashed before it was ever linked has no business on Notion.
    try expectAction(.skip, stageOne(trashed, null, null));
    try expectAction(.skip, stageOne(null, null, null));
    // A local note wins over an unlinked page: it is pushed, not imported.
    try expectAction(.create_remote, stageOne(live, page, null));
}

test "an excluded or conflicted note is frozen" {
    const excluded = Baseline{ .local_hash = "H", .remote_edited = "T", .state = "excluded" };
    const conflicted = Baseline{ .local_hash = "H", .remote_edited = "T", .state = "conflict" };

    try expectAction(.skip, stageOne(changed, moved, excluded));
    try expectAction(.skip, stageOne(changed, moved, conflicted));
    // Even a deletion on either side does not move a frozen note.
    try expectAction(.skip, stageOne(trashed, null, conflicted));
}

test "nothing changed on either side" {
    try expectAction(.skip, stageOne(live, page, synced));
}

test "only the local side changed" {
    try expectAction(.push, stageOne(changed, page, synced));
}

test "the remote timestamp moved, so stage two must settle it" {
    try expectAction(.maybe_pull, stageOne(live, moved, synced));
    try expectAction(.maybe_pull, stageOne(changed, moved, synced));
}

test "one side deleted, the other untouched" {
    // The page is gone and the note is unchanged: follow the deletion.
    try expectAction(.trash_local, stageOne(live, archived, synced));
    try expectAction(.trash_local, stageOne(live, null, synced));
    // The note is gone and the page is unchanged: follow the deletion.
    try expectAction(.archive_remote, stageOne(trashed, page, synced));
    try expectAction(.archive_remote, stageOne(null, page, synced));
}

test "one side deleted while the other changed is a conflict" {
    try expectAction(.{ .conflict = .remote_deleted }, stageOne(changed, null, synced));
    try expectAction(.{ .conflict = .remote_deleted }, stageOne(changed, archived, synced));
    try expectAction(.{ .conflict = .local_deleted }, stageOne(trashed, moved, synced));
    try expectAction(.{ .conflict = .local_deleted }, stageOne(null, moved, synced));
}

test "both sides gone leaves a dead mapping" {
    try expectAction(.drop_link, stageOne(trashed, archived, synced));
    try expectAction(.drop_link, stageOne(null, null, synced));
}

test "stage two absorbs the echo of our own push" {
    // The timestamp moved because *we* wrote; the content did not change.
    try expectAction(.skip, stageTwo(false, false));
    try expectAction(.push, stageTwo(true, false));
    try expectAction(.pull, stageTwo(false, true));
    try expectAction(.{ .conflict = .both_changed }, stageTwo(true, true));
}

test "conflict kinds round-trip through their stored strings" {
    for ([_]ConflictKind{ .both_changed, .remote_deleted, .local_deleted }) |k| {
        try testing.expectEqual(k, ConflictKind.fromString(k.toString()).?);
    }
    try testing.expect(ConflictKind.fromString("nonsense") == null);
}

test "the plan orders incoming changes before deletions" {
    const adopt: Action = .adopt;
    const pull: Action = .pull;
    const push: Action = .push;
    const conflict: Action = .{ .conflict = .both_changed };
    const props: Action = .update_props;
    const trash: Action = .trash_local;

    try testing.expect(adopt.priority() < pull.priority());
    try testing.expect(pull.priority() < push.priority());
    try testing.expect(push.priority() < conflict.priority());
    try testing.expect(conflict.priority() < props.priority());
    try testing.expect(props.priority() < trash.priority());
}
