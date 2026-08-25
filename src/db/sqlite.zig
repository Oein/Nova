//! A thin, typed wrapper over the SQLite C API.
//!
//! Replaces `rusqlite`. Deliberately small: the workspace layer wants prepared
//! statements, positional binding, typed column reads and transactions, and
//! nothing else.

const std = @import("std");
const c = @import("c.zig").c;

pub const Error = error{
    SqliteError,
    OutOfMemory,
};

/// A SQLite failure with its message attached, for reporting.
pub const Diagnostic = struct {
    code: c_int = 0,
    message: [256]u8 = @splat(0),

    pub fn text(self: *const Diagnostic) []const u8 {
        return std.mem.sliceTo(&self.message, 0);
    }
};

pub const Db = struct {
    handle: ?*c.sqlite3 = null,
    diag: Diagnostic = .{},

    /// Open (creating if needed) the database at `path`, which must be
    /// NUL-terminated.
    pub fn open(path: [:0]const u8) Error!Db {
        var self = Db{};
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &self.handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK) {
            self.capture(rc);
            // sqlite3_open_v2 hands back a handle even on failure so the error
            // can be read off it; it still has to be closed.
            _ = c.sqlite3_close(self.handle);
            self.handle = null;
            return error.SqliteError;
        }
        // Busy handling matters once the sync worker and the UI thread share a
        // file; five seconds is well past any write this app makes.
        _ = c.sqlite3_busy_timeout(self.handle, 5000);
        return self;
    }

    /// An in-memory database. Used by tests.
    pub fn openMemory() Error!Db {
        return open(":memory:");
    }

    pub fn close(self: *Db) void {
        if (self.handle) |h| _ = c.sqlite3_close(h);
        self.handle = null;
    }

    fn capture(self: *Db, rc: c_int) void {
        self.diag.code = rc;
        const msg = if (self.handle) |h|
            c.sqlite3_errmsg(h)
        else
            c.sqlite3_errstr(rc);
        const slice = std.mem.sliceTo(msg, 0);
        const n = @min(slice.len, self.diag.message.len - 1);
        @memcpy(self.diag.message[0..n], slice[0..n]);
        self.diag.message[n] = 0;
    }

    pub fn errorMessage(self: *const Db) []const u8 {
        return self.diag.text();
    }

    /// Run one or more statements, discarding any rows.
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        var err: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &err);
        if (err != null) c.sqlite3_free(err);
        if (rc != c.SQLITE_OK) {
            self.capture(rc);
            return error.SqliteError;
        }
    }

    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) {
            self.capture(rc);
            return error.SqliteError;
        }
        return .{ .stmt = stmt.?, .db = self };
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Rows touched by the most recent INSERT/UPDATE/DELETE.
    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes64(self.handle);
    }

    // -- convenience ---------------------------------------------------------

    /// Execute `sql` with `args` bound, ignoring any result rows.
    pub fn run(self: *Db, sql: []const u8, args: anytype) Error!void {
        var st = try self.prepare(sql);
        defer st.deinit();
        try st.bindAll(args);
        _ = try st.step();
    }

    /// Fetch a single integer, or null if the query returns no row.
    pub fn queryInt(self: *Db, sql: []const u8, args: anytype) Error!?i64 {
        var st = try self.prepare(sql);
        defer st.deinit();
        try st.bindAll(args);
        if (!try st.step()) return null;
        return st.int(0);
    }

    /// Fetch a single text column, duplicated into `gpa`. Null if no row, or if
    /// the column is NULL.
    pub fn queryText(
        self: *Db,
        gpa: std.mem.Allocator,
        sql: []const u8,
        args: anytype,
    ) Error!?[]u8 {
        var st = try self.prepare(sql);
        defer st.deinit();
        try st.bindAll(args);
        if (!try st.step()) return null;
        const t = st.text(0) orelse return null;
        return try gpa.dupe(u8, t);
    }

    // -- transactions --------------------------------------------------------

    pub fn begin(self: *Db) Error!void {
        try self.exec("BEGIN IMMEDIATE");
    }
    pub fn commit(self: *Db) Error!void {
        try self.exec("COMMIT");
    }
    pub fn rollback(self: *Db) void {
        self.exec("ROLLBACK") catch {};
    }
};

/// `SQLITE_TRANSIENT` tells SQLite to copy the bound bytes, so the caller's
/// buffer may go away. sqlite3.h spells it `((sqlite3_destructor_type)-1)`: a
/// sentinel SQLite compares against, never an address it calls. translate-c
/// cannot cast it at comptime on targets where function pointers carry an
/// alignment requirement -- aarch64 rejects it, x86_64 happens not to -- so the
/// two binders that take a destructor are redeclared here with that parameter
/// as an opaque pointer, which has no alignment to violate. The ABI is
/// unchanged.
const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

extern fn sqlite3_bind_text(
    stmt: *c.sqlite3_stmt,
    index: c_int,
    text: [*]const u8,
    n: c_int,
    destructor: ?*const anyopaque,
) c_int;

extern fn sqlite3_bind_blob(
    stmt: *c.sqlite3_stmt,
    index: c_int,
    value: *const anyopaque,
    n: c_int,
    destructor: ?*const anyopaque,
) c_int;

pub const Stmt = struct {
    stmt: *c.sqlite3_stmt,
    db: *Db,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    /// Rewind so the statement can be re-bound and stepped again.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.stmt);
        _ = c.sqlite3_clear_bindings(self.stmt);
    }

    /// Advance one row. Returns false when the statement is done.
    pub fn step(self: *Stmt) Error!bool {
        const rc = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                self.db.capture(rc);
                return error.SqliteError;
            },
        };
    }

    // -- binding -------------------------------------------------------------
    //
    // Parameter indices are 1-based, matching SQLite's `?1`.

    pub fn bindNull(self: *Stmt, i: c_int) Error!void {
        try self.check(c.sqlite3_bind_null(self.stmt, i));
    }

    pub fn bindInt(self: *Stmt, i: c_int, v: i64) Error!void {
        try self.check(c.sqlite3_bind_int64(self.stmt, i, v));
    }

    pub fn bindText(self: *Stmt, i: c_int, v: []const u8) Error!void {
        try self.check(sqlite3_bind_text(self.stmt, i, v.ptr, @intCast(v.len), transient));
    }

    pub fn bindBlob(self: *Stmt, i: c_int, v: []const u8) Error!void {
        try self.check(sqlite3_bind_blob(self.stmt, i, v.ptr, @intCast(v.len), transient));
    }

    /// Bind a tuple of values positionally.
    ///
    /// Accepts integers, floats, bools, `[]const u8` / string literals,
    /// optionals (null binds NULL), and enums (bound by name).
    pub fn bindAll(self: *Stmt, args: anytype) Error!void {
        const info = @typeInfo(@TypeOf(args));
        const fields = switch (info) {
            .@"struct" => |s| s.fields,
            else => @compileError("bindAll expects a tuple"),
        };
        inline for (fields, 0..) |f, idx| {
            try self.bindOne(@intCast(idx + 1), @field(args, f.name));
        }
    }

    fn bindOne(self: *Stmt, i: c_int, v: anytype) Error!void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .null => try self.bindNull(i),
            .optional => {
                if (v) |inner| try self.bindOne(i, inner) else try self.bindNull(i);
            },
            .int, .comptime_int => try self.bindInt(i, @intCast(v)),
            .bool => try self.bindInt(i, if (v) 1 else 0),
            .float, .comptime_float => try self.check(
                c.sqlite3_bind_double(self.stmt, i, @floatCast(v)),
            ),
            .@"enum" => try self.bindText(i, @tagName(v)),
            .pointer => |p| switch (p.size) {
                .slice => try self.bindText(i, v),
                .one => try self.bindText(i, v), // *const [N]u8 string literal
                else => @compileError("cannot bind " ++ @typeName(T)),
            },
            .array => try self.bindText(i, &v),
            else => @compileError("cannot bind " ++ @typeName(T)),
        }
    }

    fn check(self: *Stmt, rc: c_int) Error!void {
        if (rc != c.SQLITE_OK) {
            self.db.capture(rc);
            return error.SqliteError;
        }
    }

    // -- reading -------------------------------------------------------------
    //
    // Column indices are 0-based, matching SQLite's result API.

    pub fn isNull(self: *Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.stmt, col) == c.SQLITE_NULL;
    }

    pub fn int(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, col);
    }

    pub fn float(self: *Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.stmt, col);
    }

    /// Borrowed text, valid only until the next `step` or `deinit`.
    pub fn text(self: *Stmt, col: c_int) ?[]const u8 {
        if (self.isNull(col)) return null;
        const ptr = c.sqlite3_column_text(self.stmt, col);
        if (ptr == null) return null;
        const n: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
        return ptr[0..n];
    }

    /// Owned copy of a text column.
    pub fn textDupe(self: *Stmt, gpa: std.mem.Allocator, col: c_int) Error!?[]u8 {
        const t = self.text(col) orelse return null;
        return try gpa.dupe(u8, t);
    }

    /// Owned copy of a text column, empty string when NULL.
    pub fn textDupeOrEmpty(self: *Stmt, gpa: std.mem.Allocator, col: c_int) Error![]u8 {
        return (try self.textDupe(gpa, col)) orelse try gpa.dupe(u8, "");
    }
};

/// SQLite's compiled-in version, for diagnostics.
pub fn version() []const u8 {
    return std.mem.sliceTo(c.sqlite3_libversion(), 0);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "open, create, insert, query" {
    var db = try Db.openMemory();
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)");
    try db.run("INSERT INTO t (name, n) VALUES (?1, ?2)", .{ "alpha", 42 });
    try db.run("INSERT INTO t (name, n) VALUES (?1, ?2)", .{ "beta", 7 });

    try testing.expectEqual(@as(?i64, 2), try db.queryInt("SELECT COUNT(*) FROM t", .{}));

    const name = try db.queryText(testing.allocator, "SELECT name FROM t WHERE n = ?1", .{42});
    defer if (name) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("alpha", name.?);
}

test "binds optionals and NULL" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (a TEXT, b INTEGER)");

    const nothing: ?[]const u8 = null;
    try db.run("INSERT INTO t VALUES (?1, ?2)", .{ nothing, @as(?i64, 5) });

    var st = try db.prepare("SELECT a, b FROM t");
    defer st.deinit();
    try testing.expect(try st.step());
    try testing.expect(st.isNull(0));
    try testing.expectEqual(@as(i64, 5), st.int(1));
}

test "iterating rows" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER)");
    for (0..5) |i| try db.run("INSERT INTO t VALUES (?1)", .{i});

    var st = try db.prepare("SELECT n FROM t ORDER BY n");
    defer st.deinit();
    var seen: i64 = 0;
    while (try st.step()) : (seen += 1) {
        try testing.expectEqual(seen, st.int(0));
    }
    try testing.expectEqual(@as(i64, 5), seen);
}

test "transactions roll back" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER)");

    try db.begin();
    try db.run("INSERT INTO t VALUES (1)", .{});
    db.rollback();
    try testing.expectEqual(@as(?i64, 0), try db.queryInt("SELECT COUNT(*) FROM t", .{}));

    try db.begin();
    try db.run("INSERT INTO t VALUES (1)", .{});
    try db.commit();
    try testing.expectEqual(@as(?i64, 1), try db.queryInt("SELECT COUNT(*) FROM t", .{}));
}

test "errors carry a message" {
    var db = try Db.openMemory();
    defer db.close();
    try testing.expectError(error.SqliteError, db.exec("SELECT * FROM nope"));
    try testing.expect(std.mem.indexOf(u8, db.errorMessage(), "nope") != null);
}

test "FTS5 with the trigram tokenizer is available" {
    // The whole search design depends on this being compiled in.
    var db = try Db.openMemory();
    defer db.close();
    try db.exec(
        \\CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram');
    );
    try db.run("INSERT INTO f (body) VALUES (?1)", .{"ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ"});
    const hits = try db.queryInt(
        "SELECT COUNT(*) FROM f WHERE f MATCH ?1",
        .{"\"ㄴㄴㅕㅇ\""},
    );
    try testing.expectEqual(@as(?i64, 1), hits);
}

test "queryInt returns null for no rows" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER)");
    try testing.expectEqual(@as(?i64, null), try db.queryInt("SELECT n FROM t", .{}));
}
