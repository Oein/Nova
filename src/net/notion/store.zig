//! The Notion tables in `workspace.db`.
//!
//! Ported from `src-tauri/src/notion/store.rs`. The schema itself lives in
//! `db/schema.zig` alongside the rest of the workspace, so one migration covers
//! everything.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Workspace = db.workspace.Workspace;
const CachedBlock = model.CachedBlock;

pub const default_interval_sec: i64 = 900;
pub const min_interval_sec: i64 = 60;
pub const max_interval_sec: i64 = 86_400;

pub fn clampInterval(sec: i64) i64 {
    return std.math.clamp(sec, min_interval_sec, max_interval_sec);
}

// -- config ------------------------------------------------------------------

pub const Config = struct {
    /// The integration token. Never leaves this process.
    token: ?[]const u8 = null,
    database_id: ?[]const u8 = null,
    database_title: ?[]const u8 = null,
    title_prop: []const u8 = "Name",
    /// A `date` property to write the note's creation time into. Null means the
    /// user has not opted in.
    created_prop: ?[]const u8 = null,
    /// Same, for the note's last-modified time.
    updated_prop: ?[]const u8 = null,
    /// A `rich_text` property holding the note's uuid, giving a page an identity
    /// independent of its title.
    id_prop: ?[]const u8 = null,
    enabled: bool = false,
    sync_on_start: bool = true,
    auto_sync: bool = true,
    interval_sec: i64 = default_interval_sec,
    last_sync_ms: ?i64 = null,
    last_status: ?[]const u8 = null,

    pub fn deinit(self: Config, gpa: Allocator) void {
        inline for (.{ self.token, self.database_id, self.database_title, self.created_prop, self.updated_prop, self.id_prop, self.last_status }) |maybe| {
            if (maybe) |s| gpa.free(s);
        }
        gpa.free(self.title_prop);
    }

    pub fn tokenSet(self: Config) bool {
        return self.token != null and self.token.?.len > 0;
    }

    /// Last four characters of the token, so the user can identify it without
    /// the token itself ever crossing a boundary.
    pub fn tokenHint(self: Config) []const u8 {
        const t = self.token orelse return "";
        if (t.len <= 4) return t;
        // Back up four code points, so a non-ASCII token is not cut mid-way.
        var i = t.len;
        var n: usize = 0;
        while (i > 0 and n < 4) {
            i -= 1;
            while (i > 0 and t[i] & 0xC0 == 0x80) i -= 1;
            n += 1;
        }
        return t[i..];
    }

    pub const Credentials = struct { token: []const u8, database_id: []const u8 };

    /// The token and database a sync needs before it can run.
    pub fn credentials(self: Config) !Credentials {
        const token = self.token orelse return error.TokenNotSet;
        if (token.len == 0) return error.TokenNotSet;
        const database_id = self.database_id orelse return error.DatabaseNotSelected;
        if (database_id.len == 0) return error.DatabaseNotSelected;
        return .{ .token = token, .database_id = database_id };
    }

    /// True when sync is configured well enough to run at all.
    pub fn ready(self: Config) bool {
        _ = self.credentials() catch return false;
        return self.enabled;
    }
};

/// A partial update. An absent field keeps its stored value -- in particular
/// `token`, which the settings UI only sends when the user types a new one.
pub const ConfigInput = struct {
    token: ?[]const u8 = null,
    database_id: ?[]const u8 = null,
    database_title: ?[]const u8 = null,
    /// An empty string clears the setting; null leaves it alone.
    created_prop: ?[]const u8 = null,
    updated_prop: ?[]const u8 = null,
    id_prop: ?[]const u8 = null,
    enabled: ?bool = null,
    sync_on_start: ?bool = null,
    auto_sync: ?bool = null,
    interval_sec: ?i64 = null,
};

fn dupeOrNull(gpa: Allocator, s: ?[]const u8) !?[]const u8 {
    const v = s orelse return null;
    return try gpa.dupe(u8, v);
}

/// Trim, then treat empty as "not set" -- how the UI says "turn this off".
fn trimmedOrNull(gpa: Allocator, s: []const u8) !?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return try gpa.dupe(u8, t);
}

pub fn getConfig(ws: *Workspace, gpa: Allocator) !Config {
    var st = try ws.db.prepare(
        "SELECT token, database_id, database_title, title_prop, created_prop, updated_prop, " ++
            "id_prop, enabled, sync_on_start, auto_sync, interval_sec, last_sync_ms, last_status " ++
            "FROM notion_config WHERE id = 1",
    );
    defer st.deinit();

    if (!try st.step()) {
        return .{ .title_prop = try gpa.dupe(u8, "Name") };
    }
    return .{
        .token = try st.textDupe(gpa, 0),
        .database_id = try st.textDupe(gpa, 1),
        .database_title = try st.textDupe(gpa, 2),
        .title_prop = (try st.textDupe(gpa, 3)) orelse try gpa.dupe(u8, "Name"),
        .created_prop = try st.textDupe(gpa, 4),
        .updated_prop = try st.textDupe(gpa, 5),
        .id_prop = try st.textDupe(gpa, 6),
        .enabled = st.int(7) != 0,
        .sync_on_start = st.int(8) != 0,
        .auto_sync = st.int(9) != 0,
        .interval_sec = clampInterval(st.int(10)),
        .last_sync_ms = if (st.isNull(11)) null else st.int(11),
        .last_status = try st.textDupe(gpa, 12),
    };
}

pub fn writeConfig(ws: *Workspace, cfg: Config) !void {
    try ws.db.run(
        "INSERT INTO notion_config (id, token, database_id, database_title, title_prop, enabled, " ++
            "sync_on_start, auto_sync, interval_sec, last_sync_ms, last_status, created_prop, updated_prop, id_prop) " ++
            "VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) " ++
            "ON CONFLICT(id) DO UPDATE SET token=excluded.token, database_id=excluded.database_id, " ++
            "database_title=excluded.database_title, title_prop=excluded.title_prop, enabled=excluded.enabled, " ++
            "sync_on_start=excluded.sync_on_start, auto_sync=excluded.auto_sync, interval_sec=excluded.interval_sec, " ++
            "last_sync_ms=excluded.last_sync_ms, last_status=excluded.last_status, " ++
            "created_prop=excluded.created_prop, updated_prop=excluded.updated_prop, id_prop=excluded.id_prop",
        .{
            cfg.token,       cfg.database_id,   cfg.database_title, cfg.title_prop,
            cfg.enabled,     cfg.sync_on_start, cfg.auto_sync,      cfg.interval_sec,
            cfg.last_sync_ms, cfg.last_status,  cfg.created_prop,   cfg.updated_prop,
            cfg.id_prop,
        },
    );
}

/// Apply a partial update. Caller owns the returned config.
pub fn setConfig(ws: *Workspace, gpa: Allocator, input: ConfigInput) !Config {
    var cfg = try getConfig(ws, gpa);
    errdefer cfg.deinit(gpa);

    if (input.token) |t| {
        if (cfg.token) |old| gpa.free(old);
        cfg.token = try trimmedOrNull(gpa, t);
    }
    if (input.database_id) |raw| {
        const next = try trimmedOrNull(gpa, raw);
        const same = (next == null and cfg.database_id == null) or
            (next != null and cfg.database_id != null and
                std.mem.eql(u8, next.?, cfg.database_id.?));
        // Repointing at a different database invalidates every mapping -- the
        // old page ids do not exist there. Clearing is safer than leaving links
        // that would resolve to "remote deleted" and trash the user's notes.
        if (!same) try clearAllLinks(ws);
        if (cfg.database_id) |old| gpa.free(old);
        cfg.database_id = next;
    }
    if (input.database_title) |t| {
        if (cfg.database_title) |old| gpa.free(old);
        cfg.database_title = try gpa.dupe(u8, t);
    }
    inline for (.{
        .{ "created_prop", input.created_prop },
        .{ "updated_prop", input.updated_prop },
        .{ "id_prop", input.id_prop },
    }) |pair| {
        if (pair[1]) |raw| {
            if (@field(cfg, pair[0])) |old| gpa.free(old);
            @field(cfg, pair[0]) = try trimmedOrNull(gpa, raw);
        }
    }
    if (input.enabled) |v| cfg.enabled = v;
    if (input.sync_on_start) |v| cfg.sync_on_start = v;
    if (input.auto_sync) |v| cfg.auto_sync = v;
    if (input.interval_sec) |v| cfg.interval_sec = clampInterval(v);

    try writeConfig(ws, cfg);
    return cfg;
}

pub fn setTitleProp(ws: *Workspace, prop: []const u8) !void {
    try ws.db.run("UPDATE notion_config SET title_prop = ?1 WHERE id = 1", .{prop});
}

pub fn setDatabaseTitle(ws: *Workspace, title: []const u8) !void {
    try ws.db.run("UPDATE notion_config SET database_title = ?1 WHERE id = 1", .{title});
}

pub fn setLastSync(ws: *Workspace, ms: i64, status: []const u8) !void {
    try ws.db.run(
        "UPDATE notion_config SET last_sync_ms = ?1, last_status = ?2 WHERE id = 1",
        .{ ms, status },
    );
}

pub fn clearToken(ws: *Workspace) !void {
    try ws.db.run("UPDATE notion_config SET token = NULL WHERE id = 1", .{});
}

// -- links -------------------------------------------------------------------

pub const Link = struct {
    note_id: []const u8,
    page_id: ?[]const u8 = null,
    base_local_hash: []const u8 = "",
    base_local_mtime_ms: i64 = 0,
    base_remote_hash: []const u8 = "",
    base_remote_edited: []const u8 = "",
    last_synced_ms: i64 = 0,
    /// `rebuild` or `blocked`.
    push_mode: []const u8 = "rebuild",
    /// `ok`, `conflict`, `error` or `excluded`.
    state: []const u8 = "ok",
    last_error: ?[]const u8 = null,

    pub fn deinit(self: Link, gpa: Allocator) void {
        gpa.free(self.note_id);
        if (self.page_id) |s| gpa.free(s);
        gpa.free(self.base_local_hash);
        gpa.free(self.base_remote_hash);
        gpa.free(self.base_remote_edited);
        gpa.free(self.push_mode);
        gpa.free(self.state);
        if (self.last_error) |s| gpa.free(s);
    }

    /// True when the page holds a block Nova cannot recreate, so it may only be
    /// pulled from, never pushed to.
    pub fn isBlocked(self: Link) bool {
        return std.mem.eql(u8, self.push_mode, "blocked");
    }
};

pub fn freeLinks(gpa: Allocator, links: []Link) void {
    for (links) |l| l.deinit(gpa);
    gpa.free(links);
}

fn readLink(gpa: Allocator, st: *db.sqlite.Stmt) !Link {
    return .{
        .note_id = try st.textDupeOrEmpty(gpa, 0),
        .page_id = try st.textDupe(gpa, 1),
        .base_local_hash = try st.textDupeOrEmpty(gpa, 2),
        .base_local_mtime_ms = st.int(3),
        .base_remote_hash = try st.textDupeOrEmpty(gpa, 4),
        .base_remote_edited = try st.textDupeOrEmpty(gpa, 5),
        .last_synced_ms = st.int(6),
        .push_mode = try st.textDupeOrEmpty(gpa, 7),
        .state = try st.textDupeOrEmpty(gpa, 8),
        .last_error = try st.textDupe(gpa, 9),
    };
}

const link_columns = "note_id, page_id, base_local_hash, base_local_mtime_ms, base_remote_hash, " ++
    "base_remote_edited, last_synced_ms, push_mode, state, last_error";

pub fn listLinks(ws: *Workspace, gpa: Allocator) ![]Link {
    var st = try ws.db.prepare("SELECT " ++ link_columns ++ " FROM notion_links");
    defer st.deinit();

    var out: std.ArrayList(Link) = .empty;
    errdefer {
        for (out.items) |l| l.deinit(gpa);
        out.deinit(gpa);
    }
    while (try st.step()) try out.append(gpa, try readLink(gpa, &st));
    return out.toOwnedSlice(gpa);
}

pub fn getLink(ws: *Workspace, gpa: Allocator, note_id: []const u8) !?Link {
    var st = try ws.db.prepare("SELECT " ++ link_columns ++ " FROM notion_links WHERE note_id = ?1");
    defer st.deinit();
    try st.bindAll(.{note_id});
    if (!try st.step()) return null;
    return try readLink(gpa, &st);
}

pub fn upsertLink(ws: *Workspace, link: Link) !void {
    try ws.db.run(
        "INSERT INTO notion_links (" ++ link_columns ++ ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) " ++
            "ON CONFLICT(note_id) DO UPDATE SET page_id=excluded.page_id, " ++
            "base_local_hash=excluded.base_local_hash, base_local_mtime_ms=excluded.base_local_mtime_ms, " ++
            "base_remote_hash=excluded.base_remote_hash, base_remote_edited=excluded.base_remote_edited, " ++
            "last_synced_ms=excluded.last_synced_ms, push_mode=excluded.push_mode, " ++
            "state=excluded.state, last_error=excluded.last_error",
        .{
            link.note_id,           link.page_id,            link.base_local_hash,
            link.base_local_mtime_ms, link.base_remote_hash, link.base_remote_edited,
            link.last_synced_ms,    link.push_mode,          link.state,
            link.last_error,
        },
    );
}

pub fn setLinkState(ws: *Workspace, note_id: []const u8, state: []const u8, err: ?[]const u8) !void {
    try ws.db.run(
        "UPDATE notion_links SET state = ?1, last_error = ?2 WHERE note_id = ?3",
        .{ state, err, note_id },
    );
}

pub fn deleteLink(ws: *Workspace, note_id: []const u8) !void {
    try ws.db.run("DELETE FROM notion_links WHERE note_id = ?1", .{note_id});
    try deleteBlocks(ws, note_id);
}

pub fn clearAllLinks(ws: *Workspace) !void {
    try ws.db.run("DELETE FROM notion_links", .{});
    try ws.db.run("DELETE FROM notion_blocks", .{});
    try ws.db.run("DELETE FROM notion_conflicts", .{});
}

// -- note rows ---------------------------------------------------------------

pub const NoteRow = struct {
    id: []const u8,
    title: []const u8,
    created_ms: i64,
    mtime_ms: i64,
    trashed: bool,

    pub fn deinit(self: NoteRow, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.title);
    }
};

pub fn freeNoteRows(gpa: Allocator, rows: []NoteRow) void {
    for (rows) |r| r.deinit(gpa);
    gpa.free(rows);
}

/// Every note, **including trashed ones**. The engine has to see a soft-deleted
/// note to know it should archive the remote page.
pub fn listNoteRows(ws: *Workspace, gpa: Allocator) ![]NoteRow {
    var st = try ws.db.prepare(
        "SELECT id, title, created_ms, mtime_ms, deleted_at_ms FROM notes",
    );
    defer st.deinit();

    var out: std.ArrayList(NoteRow) = .empty;
    errdefer {
        for (out.items) |r| r.deinit(gpa);
        out.deinit(gpa);
    }
    while (try st.step()) {
        try out.append(gpa, .{
            .id = try st.textDupeOrEmpty(gpa, 0),
            .title = try st.textDupeOrEmpty(gpa, 1),
            .created_ms = st.int(2),
            .mtime_ms = st.int(3),
            .trashed = !st.isNull(4),
        });
    }
    return out.toOwnedSlice(gpa);
}

// -- cached blocks -----------------------------------------------------------

pub fn listBlocks(ws: *Workspace, gpa: Allocator, note_id: []const u8) ![]CachedBlock {
    var st = try ws.db.prepare(
        "SELECT block_id, ord, block_type, raw_json, recreatable FROM notion_blocks " ++
            "WHERE note_id = ?1 ORDER BY ord ASC",
    );
    defer st.deinit();
    try st.bindAll(.{note_id});

    var out: std.ArrayList(CachedBlock) = .empty;
    errdefer {
        for (out.items) |b| b.deinit(gpa);
        out.deinit(gpa);
    }
    while (try st.step()) {
        try out.append(gpa, .{
            .block_id = try st.textDupeOrEmpty(gpa, 0),
            .ord = st.int(1),
            .block_type = try st.textDupeOrEmpty(gpa, 2),
            .raw_json = try st.textDupeOrEmpty(gpa, 3),
            .recreatable = st.int(4) != 0,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Wholesale replace: the cache always mirrors the last pull.
pub fn replaceBlocks(ws: *Workspace, note_id: []const u8, blocks: []const CachedBlock) !void {
    try ws.db.begin();
    errdefer ws.db.rollback();

    try ws.db.run("DELETE FROM notion_blocks WHERE note_id = ?1", .{note_id});
    for (blocks) |b| {
        try ws.db.run(
            "INSERT INTO notion_blocks (note_id, block_id, ord, block_type, raw_json, recreatable) " ++
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            .{ note_id, b.block_id, b.ord, b.block_type, b.raw_json, b.recreatable },
        );
    }
    try ws.db.commit();
}

pub fn deleteBlocks(ws: *Workspace, note_id: []const u8) !void {
    try ws.db.run("DELETE FROM notion_blocks WHERE note_id = ?1", .{note_id});
}

// -- conflicts ---------------------------------------------------------------

pub const Conflict = struct {
    note_id: []const u8,
    page_id: ?[]const u8,
    kind: []const u8,
    title: []const u8,
    detected_ms: i64,

    pub fn deinit(self: Conflict, gpa: Allocator) void {
        gpa.free(self.note_id);
        if (self.page_id) |s| gpa.free(s);
        gpa.free(self.kind);
        gpa.free(self.title);
    }
};

pub fn freeConflicts(gpa: Allocator, items: []Conflict) void {
    for (items) |c| c.deinit(gpa);
    gpa.free(items);
}

/// Both sides as they stood when the conflict was found, so the resolver shows
/// what was actually compared even if either side has since moved on.
pub const ConflictDetail = struct {
    note_id: []const u8,
    page_id: ?[]const u8,
    kind: []const u8,
    local_content: ?[]const u8,
    remote_content: ?[]const u8,
    local_title: ?[]const u8,
    remote_title: ?[]const u8,
    detected_ms: i64,

    pub fn deinit(self: ConflictDetail, gpa: Allocator) void {
        gpa.free(self.note_id);
        if (self.page_id) |s| gpa.free(s);
        gpa.free(self.kind);
        inline for (.{ self.local_content, self.remote_content, self.local_title, self.remote_title }) |maybe| {
            if (maybe) |s| gpa.free(s);
        }
    }
};

pub fn upsertConflict(ws: *Workspace, detail: ConflictDetail) !void {
    try ws.db.run(
        "INSERT INTO notion_conflicts (note_id, page_id, kind, local_content, remote_content, " ++
            "local_title, remote_title, detected_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) " ++
            "ON CONFLICT(note_id) DO UPDATE SET page_id=excluded.page_id, kind=excluded.kind, " ++
            "local_content=excluded.local_content, remote_content=excluded.remote_content, " ++
            "local_title=excluded.local_title, remote_title=excluded.remote_title, " ++
            "detected_ms=excluded.detected_ms",
        .{
            detail.note_id,       detail.page_id,        detail.kind,
            detail.local_content, detail.remote_content, detail.local_title,
            detail.remote_title,  detail.detected_ms,
        },
    );
}

pub fn listConflicts(ws: *Workspace, gpa: Allocator) ![]Conflict {
    var st = try ws.db.prepare(
        "SELECT c.note_id, c.page_id, c.kind, COALESCE(n.title, c.local_title, c.remote_title, ''), " ++
            "c.detected_ms FROM notion_conflicts c " ++
            "LEFT JOIN notes n ON n.id = c.note_id ORDER BY c.detected_ms DESC",
    );
    defer st.deinit();

    var out: std.ArrayList(Conflict) = .empty;
    errdefer {
        for (out.items) |c| c.deinit(gpa);
        out.deinit(gpa);
    }
    while (try st.step()) {
        try out.append(gpa, .{
            .note_id = try st.textDupeOrEmpty(gpa, 0),
            .page_id = try st.textDupe(gpa, 1),
            .kind = try st.textDupeOrEmpty(gpa, 2),
            .title = try st.textDupeOrEmpty(gpa, 3),
            .detected_ms = st.int(4),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn countConflicts(ws: *Workspace) !i64 {
    return (try ws.db.queryInt("SELECT COUNT(*) FROM notion_conflicts", .{})) orelse 0;
}

pub fn getConflict(ws: *Workspace, gpa: Allocator, note_id: []const u8) !?ConflictDetail {
    var st = try ws.db.prepare(
        "SELECT note_id, page_id, kind, local_content, remote_content, local_title, " ++
            "remote_title, detected_ms FROM notion_conflicts WHERE note_id = ?1",
    );
    defer st.deinit();
    try st.bindAll(.{note_id});
    if (!try st.step()) return null;

    return .{
        .note_id = try st.textDupeOrEmpty(gpa, 0),
        .page_id = try st.textDupe(gpa, 1),
        .kind = try st.textDupeOrEmpty(gpa, 2),
        .local_content = try st.textDupe(gpa, 3),
        .remote_content = try st.textDupe(gpa, 4),
        .local_title = try st.textDupe(gpa, 5),
        .remote_title = try st.textDupe(gpa, 6),
        .detected_ms = st.int(7),
    };
}

pub fn deleteConflict(ws: *Workspace, note_id: []const u8) !void {
    try ws.db.run("DELETE FROM notion_conflicts WHERE note_id = ?1", .{note_id});
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const TestWorkspace = db.workspace.TestWorkspace;

test "the config starts at its defaults" {
    var t = try TestWorkspace.init(testing.allocator, "notion-cfg");
    defer t.deinit();

    const cfg = try getConfig(&t.ws, testing.allocator);
    defer cfg.deinit(testing.allocator);

    try testing.expect(!cfg.enabled);
    try testing.expect(cfg.sync_on_start);
    try testing.expect(cfg.auto_sync);
    try testing.expectEqual(default_interval_sec, cfg.interval_sec);
    try testing.expectEqualStrings("Name", cfg.title_prop);
    try testing.expect(!cfg.tokenSet());
}

test "an omitted token keeps the stored one" {
    var t = try TestWorkspace.init(testing.allocator, "notion-token");
    defer t.deinit();

    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .token = "ntn_secret" });
        defer cfg.deinit(testing.allocator);
        try testing.expect(cfg.tokenSet());
    }
    // A later update that says nothing about the token must not clear it.
    const cfg = try setConfig(&t.ws, testing.allocator, .{ .enabled = true });
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("ntn_secret", cfg.token.?);
    try testing.expect(cfg.enabled);
}

test "the token hint is the last four characters" {
    const cfg = Config{ .token = "ntn_abcd1234" };
    try testing.expectEqualStrings("1234", cfg.tokenHint());

    const short = Config{ .token = "ab" };
    try testing.expectEqualStrings("ab", short.tokenHint());
    try testing.expectEqualStrings("", (Config{}).tokenHint());
}

test "the interval is clamped" {
    try testing.expectEqual(min_interval_sec, clampInterval(1));
    try testing.expectEqual(max_interval_sec, clampInterval(999_999));
    try testing.expectEqual(@as(i64, 900), clampInterval(900));
}

test "switching database clears every mapping" {
    var t = try TestWorkspace.init(testing.allocator, "notion-switch");
    defer t.deinit();

    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .database_id = "db-1" });
        defer cfg.deinit(testing.allocator);
    }
    try upsertLink(&t.ws, .{ .note_id = "n1", .page_id = "p1" });
    try replaceBlocks(&t.ws, "n1", &.{
        .{ .block_id = "b1", .ord = 0, .block_type = "table", .raw_json = "{}", .recreatable = true },
    });
    {
        const before = try listLinks(&t.ws, testing.allocator);
        defer freeLinks(testing.allocator, before);
        try testing.expectEqual(@as(usize, 1), before.len);
    }

    // Old page ids mean nothing in a new database; keeping them would resolve
    // to "remote deleted" and trash the user's notes.
    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .database_id = "db-2" });
        defer cfg.deinit(testing.allocator);
    }
    const links = try listLinks(&t.ws, testing.allocator);
    defer freeLinks(testing.allocator, links);
    try testing.expectEqual(@as(usize, 0), links.len);

    const blocks = try listBlocks(&t.ws, testing.allocator, "n1");
    defer model.freeCachedBlocks(testing.allocator, blocks);
    try testing.expectEqual(@as(usize, 0), blocks.len);
}

test "setting the same database again keeps the mappings" {
    var t = try TestWorkspace.init(testing.allocator, "notion-same-db");
    defer t.deinit();
    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .database_id = "db-1" });
        defer cfg.deinit(testing.allocator);
    }
    try upsertLink(&t.ws, .{ .note_id = "n1", .page_id = "p1" });
    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .database_id = "db-1" });
        defer cfg.deinit(testing.allocator);
    }
    const links = try listLinks(&t.ws, testing.allocator);
    defer freeLinks(testing.allocator, links);
    try testing.expectEqual(@as(usize, 1), links.len);
}

test "an empty property name turns the column off" {
    var t = try TestWorkspace.init(testing.allocator, "notion-props");
    defer t.deinit();

    {
        const cfg = try setConfig(&t.ws, testing.allocator, .{ .created_prop = " Created " });
        defer cfg.deinit(testing.allocator);
        try testing.expectEqualStrings("Created", cfg.created_prop.?);
    }
    const cfg = try setConfig(&t.ws, testing.allocator, .{ .created_prop = "" });
    defer cfg.deinit(testing.allocator);
    try testing.expect(cfg.created_prop == null);
}

test "links round-trip and cascade into blocks" {
    var t = try TestWorkspace.init(testing.allocator, "notion-links");
    defer t.deinit();

    try upsertLink(&t.ws, .{
        .note_id = "n1",
        .page_id = "p1",
        .base_local_hash = "h1",
        .base_local_mtime_ms = 42,
        .base_remote_edited = "T",
        .push_mode = "blocked",
    });

    const link = (try getLink(&t.ws, testing.allocator, "n1")).?;
    defer link.deinit(testing.allocator);
    try testing.expectEqualStrings("p1", link.page_id.?);
    try testing.expectEqualStrings("h1", link.base_local_hash);
    try testing.expectEqual(@as(i64, 42), link.base_local_mtime_ms);
    try testing.expect(link.isBlocked());

    try replaceBlocks(&t.ws, "n1", &.{
        .{ .block_id = "b1", .ord = 0, .block_type = "table", .raw_json = "{\"x\":1}", .recreatable = false },
    });
    try deleteLink(&t.ws, "n1");

    try testing.expect((try getLink(&t.ws, testing.allocator, "n1")) == null);
    const blocks = try listBlocks(&t.ws, testing.allocator, "n1");
    defer model.freeCachedBlocks(testing.allocator, blocks);
    try testing.expectEqual(@as(usize, 0), blocks.len);
}

test "note rows include trashed notes" {
    var t = try TestWorkspace.init(testing.allocator, "notion-rows");
    defer t.deinit();
    try t.seedNote("a", "Alive", "x", 1);
    try t.seedNote("b", "Gone", "y", 2);
    try t.ws.trashNote("b", 100);

    const rows = try listNoteRows(&t.ws, testing.allocator);
    defer freeNoteRows(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);

    var trashed_seen = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.id, "b")) trashed_seen = r.trashed;
    }
    // The engine needs to see it to know the remote page should be archived.
    try testing.expect(trashed_seen);
}

test "conflicts round-trip and count" {
    var t = try TestWorkspace.init(testing.allocator, "notion-conflicts");
    defer t.deinit();
    try t.seedNote("n1", "Note", "body", 1);

    try upsertConflict(&t.ws, .{
        .note_id = "n1",
        .page_id = "p1",
        .kind = "both-changed",
        .local_content = "mine",
        .remote_content = "theirs",
        .local_title = "Note",
        .remote_title = "Note",
        .detected_ms = 500,
    });

    try testing.expectEqual(@as(i64, 1), try countConflicts(&t.ws));

    const list = try listConflicts(&t.ws, testing.allocator);
    defer freeConflicts(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("Note", list[0].title);

    const detail = (try getConflict(&t.ws, testing.allocator, "n1")).?;
    defer detail.deinit(testing.allocator);
    try testing.expectEqualStrings("mine", detail.local_content.?);
    try testing.expectEqualStrings("theirs", detail.remote_content.?);

    try deleteConflict(&t.ws, "n1");
    try testing.expectEqual(@as(i64, 0), try countConflicts(&t.ws));
}

test "credentials are required before a sync can run" {
    const none = Config{};
    try testing.expectError(error.TokenNotSet, none.credentials());

    const token_only = Config{ .token = "t" };
    try testing.expectError(error.DatabaseNotSelected, token_only.credentials());

    const both = Config{ .token = "t", .database_id = "db" };
    const creds = try both.credentials();
    try testing.expectEqualStrings("t", creds.token);
    try testing.expect(!both.ready()); // still needs `enabled`

    const on = Config{ .token = "t", .database_id = "db", .enabled = true };
    try testing.expect(on.ready());
}
