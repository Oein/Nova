//! The workspace: notes on disk, their index in SQLite, and the open session.
//!
//! Ported from `src-tauri/src/workspace.rs` and `src-tauri/src/commands/workspace.rs`.
//! The Tauri split between a "workspace module" and "command handlers" existed
//! only because commands had to cross an IPC boundary; in-process they are one
//! layer.
//!
//! On-disk layout, unchanged from the original so an existing workspace opens:
//!
//!     <root>/notes/<slug>-<id8>.md
//!     <root>/trash/<slug>-<id8>.md
//!     <root>/workspace.db

const std = @import("std");
const core = @import("core");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const fsx = @import("fsx.zig");

const Allocator = std.mem.Allocator;

pub const Error = sqlite.Error || fsx.Error || error{
    NoteNotFound,
    MtimeMismatch,
};

/// Trashed notes are kept for 30 days, then purged on the next workspace open.
pub const trash_retention_ms: i64 = 30 * 24 * 60 * 60 * 1000;

/// Cap on a derived note title, in code points.
pub const title_max_chars: usize = 120;

/// Cap on a filename slug, in code points.
pub const slug_max_chars: usize = 50;

pub const default_title = "Untitled";

// -- paths -------------------------------------------------------------------

/// A workspace-relative path. Bounded because a filename is a 50-code-point
/// slug plus a short id and an extension.
pub const PathBuf = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const PathBuf) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *PathBuf, comptime fmt: []const u8, args: anytype) void {
        const w = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // Only reachable with a pathological id; truncating still yields a
            // usable, unique-enough path.
            break :blk self.buf[0..self.buf.len];
        };
        self.len = w.len;
    }
};

// -- titles and filenames ----------------------------------------------------

/// The note title is always derived from the body's first line, never stored
/// separately. Leading `#`s are stripped so a markdown heading reads as a title.
///
/// The result borrows from `content` (or from `fallback`).
pub fn firstLineTitle(content: []const u8, fallback: []const u8) []const u8 {
    const eol = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    var first = content[0..eol];
    first = std.mem.trimStart(u8, first, "#");
    first = std.mem.trim(u8, first, " \t\r\n");
    if (first.len == 0) return fallback;
    return truncateChars(first, title_max_chars);
}

/// Truncate to at most `max` code points, never splitting one.
fn truncateChars(s: []const u8, max: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < max) : (n += 1) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + l > s.len) break;
        i += l;
    }
    return s[0..i];
}

/// Filesystem-safe, readable stem for a title.
///
/// Hangul and CJK survive (they are letters); everything else becomes `-`, with
/// repeats collapsed and trailing dashes trimmed. Empty input yields "untitled".
pub fn slugify(title: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var prev_dash = true;
    var chars: usize = 0;

    var i: usize = 0;
    while (i < title.len and chars < slug_max_chars) {
        const l = std.unicode.utf8ByteSequenceLength(title[i]) catch 1;
        if (i + l > title.len) break;
        const cp = std.unicode.utf8Decode(title[i..][0..l]) catch 0xFFFD;
        i += l;

        if (core.word.isLetterOrNumber(cp) or cp == '_') {
            if (w + l > out.len) break;
            @memcpy(out[w..][0..l], title[i - l ..][0..l]);
            w += l;
            prev_dash = false;
            chars += 1;
        } else if (!prev_dash) {
            if (w + 1 > out.len) break;
            out[w] = '-';
            w += 1;
            prev_dash = true;
            chars += 1;
        }
    }
    while (w > 0 and out[w - 1] == '-') w -= 1;
    if (w == 0) {
        const fallback = "untitled";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    return out[0..w];
}

/// Canonical filename: `{slug}-{first 8 ascii-alnum of id}.md`.
///
/// The id suffix keeps two notes with the same title apart; taking only ASCII
/// alphanumerics stops the dashes in a UUID leaking into the name.
pub fn filenameFor(title: []const u8, id: []const u8, out: *PathBuf) void {
    var slug_buf: [256]u8 = undefined;
    const slug = slugify(title, &slug_buf);

    var short: [8]u8 = undefined;
    var n: usize = 0;
    for (id) |ch| {
        if (n == short.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            short[n] = ch;
            n += 1;
        }
    }
    if (n == 0) {
        out.set("{s}.md", .{slug});
    } else {
        out.set("{s}-{s}.md", .{ slug, short[0..n] });
    }
}

fn splitExt(name: []const u8) struct { stem: []const u8, ext: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return .{ .stem = name, .ext = "md" };
    return .{ .stem = name[0..dot], .ext = name[dot + 1 ..] };
}

// -- records -----------------------------------------------------------------

pub const Note = struct {
    id: []const u8,
    title: []const u8,
    created_ms: i64,
    mtime_ms: i64,
    size: i64,

    pub fn deinit(self: Note, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.title);
    }
};

pub fn freeNotes(gpa: Allocator, notes: []Note) void {
    for (notes) |n| n.deinit(gpa);
    gpa.free(notes);
}

pub const TrashedNote = struct {
    id: []const u8,
    title: []const u8,
    deleted_at_ms: i64,
    size: i64,

    pub fn deinit(self: TrashedNote, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.title);
    }
};

pub fn freeTrashedNotes(gpa: Allocator, notes: []TrashedNote) void {
    for (notes) |n| n.deinit(gpa);
    gpa.free(notes);
}

pub const NoteContent = struct {
    content: []const u8,
    mtime_ms: i64,
    size: i64,

    pub fn deinit(self: NoteContent, gpa: Allocator) void {
        gpa.free(self.content);
    }
};

pub const SessionTab = struct {
    note_id: []const u8,
    position: i64 = 0,
    cursor_line: i64 = 0,
    /// Byte offset within the line. See `schema.current_version`.
    cursor_col: i64 = 0,
    scroll_top: i64 = 0,
    unsaved_content: ?[]const u8 = null,
    undo_log: ?[]const u8 = null,

    pub fn deinit(self: SessionTab, gpa: Allocator) void {
        gpa.free(self.note_id);
        if (self.unsaved_content) |s| gpa.free(s);
        if (self.undo_log) |s| gpa.free(s);
    }
};

pub const Session = struct {
    tabs: []SessionTab,
    active_tab: ?[]const u8,

    pub fn deinit(self: Session, gpa: Allocator) void {
        for (self.tabs) |t| t.deinit(gpa);
        gpa.free(self.tabs);
        if (self.active_tab) |s| gpa.free(s);
    }
};

// -- workspace ---------------------------------------------------------------

pub const Workspace = struct {
    /// A fixed clock, for tests. See `nowMs`.
    clock: ?i64 = null,
    gpa: Allocator,
    io: std.Io,
    fs: fsx.Fs,
    db: sqlite.Db,
    /// Absolute-or-relative root as the user gave it. Kept for display and for
    /// revealing a note in the OS file manager.
    root: []const u8,

    pub fn open(gpa: Allocator, io: std.Io, root: []const u8) !Workspace {
        var fs = try fsx.Fs.openRoot(io, root);
        errdefer fs.close();

        const db_path = try std.fmt.allocPrintSentinel(gpa, "{s}/workspace.db", .{root}, 0);
        defer gpa.free(db_path);

        var db = try sqlite.Db.open(db_path);
        errdefer db.close();
        try schema.migrate(&db);

        const root_owned = try gpa.dupe(u8, root);
        errdefer gpa.free(root_owned);

        var ws = Workspace{
            .gpa = gpa,
            .io = io,
            .fs = fs,
            .db = db,
            .root = root_owned,
        };
        try ws.backfillFtsIfEmpty();
        try ws.backfillFilenames();
        _ = ws.purgeOldTrash(fsx.nowMs(io) -| trash_retention_ms) catch 0;
        return ws;
    }

    pub fn close(self: *Workspace) void {
        self.db.close();
        self.fs.close();
        self.gpa.free(self.root);
    }

    /// Wall clock, or a frozen one.
    ///
    /// Tests set `clock` so that note timestamps -- and the date headings the
    /// sidebar derives from them -- do not change with the day the suite runs
    /// on. A golden image compared byte for byte is otherwise good only until
    /// midnight.
    pub fn nowMs(self: *const Workspace) i64 {
        return self.clock orelse fsx.nowMs(self.io);
    }

    // -- path resolution -----------------------------------------------------

    const FileRef = struct {
        name: PathBuf,
        deleted: bool,
    };

    /// Filename recorded for `id`, falling back to `{id}.md` for rows that
    /// predate the `filename` column.
    fn fileRef(self: *Workspace, id: []const u8) FileRef {
        var out = FileRef{ .name = .{}, .deleted = false };
        var st = self.db.prepare(
            "SELECT filename, deleted_at_ms FROM notes WHERE id = ?1",
        ) catch {
            out.name.set("{s}.md", .{id});
            return out;
        };
        defer st.deinit();
        st.bindAll(.{id}) catch {};
        const found = st.step() catch false;
        if (found) {
            out.deleted = !st.isNull(1);
            if (st.text(0)) |name| {
                if (name.len > 0) {
                    out.name.set("{s}", .{name});
                    return out;
                }
            }
        }
        out.name.set("{s}.md", .{id});
        return out;
    }

    /// Where the note currently lives -- `trash/` when soft-deleted, else
    /// `notes/`. Callers reading or writing content need not care which.
    pub fn notePath(self: *Workspace, id: []const u8) PathBuf {
        const ref = self.fileRef(id);
        var p = PathBuf{};
        p.set("{s}/{s}", .{ if (ref.deleted) "trash" else "notes", ref.name.slice() });
        return p;
    }

    /// Path under `notes/` regardless of trash state.
    fn activePath(self: *Workspace, id: []const u8) PathBuf {
        const ref = self.fileRef(id);
        var p = PathBuf{};
        p.set("notes/{s}", .{ref.name.slice()});
        return p;
    }

    /// Path under `trash/` regardless of trash state.
    fn trashPath(self: *Workspace, id: []const u8) PathBuf {
        const ref = self.fileRef(id);
        var p = PathBuf{};
        p.set("trash/{s}", .{ref.name.slice()});
        return p;
    }

    /// Absolute-ish path for handing to the OS file manager.
    pub fn absoluteNotePath(self: *Workspace, gpa: Allocator, id: []const u8) ![]u8 {
        const rel = self.notePath(id);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, rel.slice() });
    }

    fn filenameTaken(self: *Workspace, candidate: []const u8, exclude_id: ?[]const u8) bool {
        const n = if (exclude_id) |ex|
            self.db.queryInt(
                "SELECT COUNT(*) FROM notes WHERE filename = ?1 AND id != ?2",
                .{ candidate, ex },
            ) catch @as(?i64, 0)
        else
            self.db.queryInt(
                "SELECT COUNT(*) FROM notes WHERE filename = ?1",
                .{candidate},
            ) catch @as(?i64, 0);
        return (n orelse 0) > 0;
    }

    /// A filename for `title` that no other row already claims.
    ///
    /// `exclude_id` skips one row, so re-picking a note's own name during a
    /// rename does not collide with itself.
    pub fn pickFilename(
        self: *Workspace,
        title: []const u8,
        id: []const u8,
        exclude_id: ?[]const u8,
    ) PathBuf {
        var base = PathBuf{};
        filenameFor(title, id, &base);
        if (!self.filenameTaken(base.slice(), exclude_id)) return base;

        // Reaching here needs a matching slug *and* a matching 8-hex id prefix,
        // so this loop is defensive rather than expected.
        const parts = splitExt(base.slice());
        var stem_buf: [512]u8 = undefined;
        const stem = std.fmt.bufPrint(&stem_buf, "{s}", .{parts.stem}) catch parts.stem;
        var ext_buf: [16]u8 = undefined;
        const ext = std.fmt.bufPrint(&ext_buf, "{s}", .{parts.ext}) catch parts.ext;

        var n: u32 = 2;
        while (n < 1000) : (n += 1) {
            var candidate = PathBuf{};
            candidate.set("{s}-{d}.{s}", .{ stem, n, ext });
            if (!self.filenameTaken(candidate.slice(), exclude_id)) return candidate;
        }
        return base;
    }

    // -- full-text index -----------------------------------------------------

    fn ftsUpsert(self: *Workspace, id: []const u8, title: []const u8, body: []const u8) !void {
        const gpa = self.gpa;
        const title_jamo = try core.jamo.toJamo(gpa, title, true);
        defer gpa.free(title_jamo);
        const body_tight = try core.jamo.toJamo(gpa, body, false);
        defer gpa.free(body_tight);
        const body_loose = try core.jamo.toJamo(gpa, body, true);
        defer gpa.free(body_loose);

        try self.db.run("DELETE FROM notes_fts WHERE id = ?1", .{id});
        try self.db.run(
            "INSERT INTO notes_fts (id, title_jamo, body_jamo_tight, body_jamo_loose) VALUES (?1, ?2, ?3, ?4)",
            .{ id, title_jamo, body_tight, body_loose },
        );
    }

    fn ftsDelete(self: *Workspace, id: []const u8) !void {
        try self.db.run("DELETE FROM notes_fts WHERE id = ?1", .{id});
    }

    /// First-open migration for workspaces that predate the FTS index.
    fn backfillFtsIfEmpty(self: *Workspace) !void {
        const fts_count = (self.db.queryInt("SELECT COUNT(*) FROM notes_fts", .{}) catch @as(?i64, 0)) orelse 0;
        const notes_count = (self.db.queryInt("SELECT COUNT(*) FROM notes", .{}) catch @as(?i64, 0)) orelse 0;
        if (notes_count == 0 or fts_count >= notes_count) return;

        const rows = try self.collectIdTitle("SELECT id, title FROM notes");
        defer self.freeIdTitles(rows);

        for (rows) |r| {
            const path = self.notePath(r.id);
            const body = try self.fs.readOrEmpty(self.gpa, path.slice());
            defer self.gpa.free(body);
            try self.ftsUpsert(r.id, r.title, body);
        }
    }

    /// First-open migration for notes that predate the `filename` column:
    /// rename `notes/{uuid}.md` to `notes/{slug}-{short}.md`.
    fn backfillFilenames(self: *Workspace) !void {
        const rows = try self.collectIdTitle(
            "SELECT id, title FROM notes WHERE filename IS NULL OR filename = ''",
        );
        defer self.freeIdTitles(rows);

        for (rows) |r| {
            const new_name = self.pickFilename(r.title, r.id, r.id);
            var old_path = PathBuf{};
            old_path.set("notes/{s}.md", .{r.id});
            var new_path = PathBuf{};
            new_path.set("notes/{s}", .{new_name.slice()});

            if (self.fs.exists(old_path.slice()) and
                !std.mem.eql(u8, old_path.slice(), new_path.slice()))
            {
                self.fs.rename(old_path.slice(), new_path.slice()) catch {};
            }
            try self.db.run(
                "UPDATE notes SET filename = ?1 WHERE id = ?2",
                .{ new_name.slice(), r.id },
            );
        }
    }

    const IdTitle = struct { id: []const u8, title: []const u8 };

    fn collectIdTitle(self: *Workspace, sql: []const u8) ![]IdTitle {
        var st = try self.db.prepare(sql);
        defer st.deinit();
        var out: std.ArrayList(IdTitle) = .empty;
        errdefer {
            for (out.items) |r| {
                self.gpa.free(r.id);
                self.gpa.free(r.title);
            }
            out.deinit(self.gpa);
        }
        while (try st.step()) {
            try out.append(self.gpa, .{
                .id = try st.textDupeOrEmpty(self.gpa, 0),
                .title = try st.textDupeOrEmpty(self.gpa, 1),
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    fn freeIdTitles(self: *Workspace, rows: []IdTitle) void {
        for (rows) |r| {
            self.gpa.free(r.id);
            self.gpa.free(r.title);
        }
        self.gpa.free(rows);
    }

    // -- notes ---------------------------------------------------------------

    fn readNoteRow(self: *Workspace, st: *sqlite.Stmt) !Note {
        return .{
            .id = try st.textDupeOrEmpty(self.gpa, 0),
            .title = try st.textDupeOrEmpty(self.gpa, 1),
            .created_ms = st.int(2),
            .mtime_ms = st.int(3),
            .size = st.int(4),
        };
    }

    /// Active (non-trashed) notes, most recently modified first.
    pub fn listNotes(self: *Workspace) ![]Note {
        var st = try self.db.prepare(
            "SELECT id, title, created_ms, mtime_ms, size FROM notes " ++
                "WHERE deleted_at_ms IS NULL ORDER BY mtime_ms DESC",
        );
        defer st.deinit();

        var out: std.ArrayList(Note) = .empty;
        errdefer {
            for (out.items) |n| n.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        while (try st.step()) try out.append(self.gpa, try self.readNoteRow(&st));
        return out.toOwnedSlice(self.gpa);
    }

    pub fn getNote(self: *Workspace, id: []const u8) !Note {
        var st = try self.db.prepare(
            "SELECT id, title, created_ms, mtime_ms, size FROM notes WHERE id = ?1",
        );
        defer st.deinit();
        try st.bindAll(.{id});
        if (!try st.step()) return error.NoteNotFound;
        return self.readNoteRow(&st);
    }

    /// Create an empty note and its backing file.
    ///
    /// The row goes in first so `notePath` resolves to the slug-based filename
    /// rather than the `{id}.md` fallback when the file is created.
    pub fn createNote(self: *Workspace) !Note {
        const uuid = fsx.uuidV4(self.io);
        const id = try self.gpa.dupe(u8, uuid.slice());
        errdefer self.gpa.free(id);

        const now = self.nowMs();
        const filename = self.pickFilename(default_title, id, null);

        try self.db.run(
            "INSERT INTO notes (id, title, created_ms, mtime_ms, size, filename) VALUES (?1, ?2, ?3, ?4, 0, ?5)",
            .{ id, default_title, now, now, filename.slice() },
        );
        try self.ftsUpsert(id, default_title, "");

        var path = PathBuf{};
        path.set("notes/{s}", .{filename.slice()});
        try self.fs.write(path.slice(), "");

        const meta = try self.fs.statMeta(path.slice());
        try self.db.run(
            "UPDATE notes SET created_ms = ?1, mtime_ms = ?2 WHERE id = ?3",
            .{ meta.mtime_ms, meta.mtime_ms, id },
        );

        return .{
            .id = id,
            .title = try self.gpa.dupe(u8, default_title),
            .created_ms = meta.mtime_ms,
            .mtime_ms = meta.mtime_ms,
            .size = 0,
        };
    }

    /// Insert a note row (and index its body) without touching the filesystem.
    ///
    /// Used by the Notion pull path, which writes the file itself, and by tests.
    /// Returns the filename chosen for the note.
    pub fn insertNote(self: *Workspace, note: Note, content: []const u8) !PathBuf {
        const filename = self.pickFilename(note.title, note.id, null);
        try self.db.run(
            "INSERT INTO notes (id, title, created_ms, mtime_ms, size, filename) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            .{ note.id, note.title, note.created_ms, note.mtime_ms, note.size, filename.slice() },
        );
        try self.ftsUpsert(note.id, note.title, content);
        return filename;
    }

    pub fn readNote(self: *Workspace, id: []const u8) !NoteContent {
        const path = self.notePath(id);
        const content = try self.fs.read(self.gpa, path.slice());
        errdefer self.gpa.free(content);
        const meta = try self.fs.statMeta(path.slice());
        return .{ .content = content, .mtime_ms = meta.mtime_ms, .size = meta.size };
    }

    /// Save a note.
    ///
    /// `expected_mtime_ms`, when given, is checked against the file on disk
    /// first -- optimistic concurrency, so a save cannot silently clobber an
    /// edit made outside the app.
    pub fn writeNote(
        self: *Workspace,
        id: []const u8,
        content: []const u8,
        expected_mtime_ms: ?i64,
    ) !Note {
        const path = self.notePath(id);
        if (expected_mtime_ms) |expected| {
            if (self.fs.statMeta(path.slice())) |meta| {
                if (meta.mtime_ms != expected) return error.MtimeMismatch;
            } else |_| {}
        }
        try self.fs.write(path.slice(), content);

        const title = firstLineTitle(content, default_title);
        // Renaming may move the file, so stat the path the rename returns --
        // that mtime is what the caller will treat as the save baseline.
        const final_path = try self.renameFileIfTitleChanged(id, title);
        const meta = try self.fs.statMeta(final_path.slice());
        try self.updateNoteMeta(id, title, meta.mtime_ms, meta.size, content);

        return .{
            .id = try self.gpa.dupe(u8, id),
            .title = try self.gpa.dupe(u8, title),
            // The original returned 0 here; creation time never changes on save
            // and the caller already has it.
            .created_ms = 0,
            .mtime_ms = meta.mtime_ms,
            .size = meta.size,
        };
    }

    fn updateNoteMeta(
        self: *Workspace,
        id: []const u8,
        title: []const u8,
        mtime_ms: i64,
        size: i64,
        content: []const u8,
    ) !void {
        try self.db.run(
            "UPDATE notes SET title = ?1, mtime_ms = ?2, size = ?3 WHERE id = ?4",
            .{ title, mtime_ms, size, id },
        );
        try self.ftsUpsert(id, title, content);
    }

    /// Keep the on-disk name in step with the title. Returns the (possibly new)
    /// path; a no-op when the name already matches.
    fn renameFileIfTitleChanged(self: *Workspace, id: []const u8, new_title: []const u8) !PathBuf {
        const old_path = self.notePath(id);
        var desired = PathBuf{};
        filenameFor(new_title, id, &desired);

        const current = self.fileRef(id);
        if (std.mem.eql(u8, current.name.slice(), desired.slice())) return old_path;

        const unique = self.pickFilename(new_title, id, id);
        var new_path = PathBuf{};
        new_path.set("notes/{s}", .{unique.slice()});

        if (!std.mem.eql(u8, new_path.slice(), old_path.slice()) and
            self.fs.exists(old_path.slice()))
        {
            try self.fs.rename(old_path.slice(), new_path.slice());
        }
        try self.db.run(
            "UPDATE notes SET filename = ?1 WHERE id = ?2",
            .{ unique.slice(), id },
        );
        return new_path;
    }

    /// Overwrite a note from an external source (a Notion pull) without the
    /// optimistic-concurrency check -- the caller has already decided this
    /// content wins. Goes through the same rename, meta and FTS path as a
    /// normal save so name, index and list stay consistent.
    pub fn applyRemoteContent(
        self: *Workspace,
        id: []const u8,
        content: []const u8,
        title: []const u8,
    ) !fsx.Meta {
        const path = self.notePath(id);
        try self.fs.write(path.slice(), content);
        const final_path = try self.renameFileIfTitleChanged(id, title);
        const meta = try self.fs.statMeta(final_path.slice());
        try self.updateNoteMeta(id, title, meta.mtime_ms, meta.size, content);
        return meta;
    }

    // -- trash ---------------------------------------------------------------

    /// Soft-delete: move the file to `trash/`, hide the row, drop any open tab.
    ///
    /// The move happens before the database update so a filesystem failure
    /// cannot leave the row pointing at a path that is not there. A file that
    /// has already vanished is tolerated -- restore handles that too.
    pub fn trashNote(self: *Workspace, id: []const u8, now_ms: i64) !void {
        const src = self.activePath(id);
        const dst = self.trashPath(id);
        if (self.fs.exists(src.slice())) {
            try self.fs.rename(src.slice(), dst.slice());
        }
        try self.db.run("UPDATE notes SET deleted_at_ms = ?1 WHERE id = ?2", .{ now_ms, id });
        try self.db.run("DELETE FROM session_tabs WHERE note_id = ?1", .{id});
    }

    /// Hard-delete every trashed note deleted before `cutoff_ms`.
    pub fn purgeOldTrash(self: *Workspace, cutoff_ms: i64) !usize {
        var ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (ids.items) |i| self.gpa.free(i);
            ids.deinit(self.gpa);
        }
        {
            var st = try self.db.prepare(
                "SELECT id FROM notes WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < ?1",
            );
            defer st.deinit();
            try st.bindAll(.{cutoff_ms});
            while (try st.step()) {
                try ids.append(self.gpa, try st.textDupeOrEmpty(self.gpa, 0));
            }
        }
        for (ids.items) |id| {
            const path = self.notePath(id);
            self.fs.deleteIfExists(path.slice());
            try self.db.run("DELETE FROM notes WHERE id = ?1", .{id});
            try self.ftsDelete(id);
        }
        return ids.items.len;
    }

    /// Remove a note outright, bypassing the trash. Used when a note that was
    /// never saved is closed -- nothing the user committed would be lost.
    pub fn hardDeleteNote(self: *Workspace, id: []const u8) !void {
        // Resolve the path before deleting the row; `notePath` reads the row.
        const path = self.notePath(id);
        self.fs.deleteIfExists(path.slice());
        try self.db.run("DELETE FROM notes WHERE id = ?1", .{id});
        try self.db.run("DELETE FROM session_tabs WHERE note_id = ?1", .{id});
        try self.ftsDelete(id);
    }

    pub fn listTrashedNotes(self: *Workspace) ![]TrashedNote {
        var st = try self.db.prepare(
            "SELECT id, title, deleted_at_ms, size FROM notes " ++
                "WHERE deleted_at_ms IS NOT NULL ORDER BY deleted_at_ms DESC",
        );
        defer st.deinit();

        var out: std.ArrayList(TrashedNote) = .empty;
        errdefer {
            for (out.items) |n| n.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        while (try st.step()) {
            try out.append(self.gpa, .{
                .id = try st.textDupeOrEmpty(self.gpa, 0),
                .title = try st.textDupeOrEmpty(self.gpa, 1),
                .deleted_at_ms = st.int(2),
                .size = st.int(3),
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Move a note back out of the trash. Its mtime is bumped so it surfaces at
    /// the top of the list, and a fresh filename is picked in case another note
    /// claimed the old one meanwhile.
    pub fn restoreNote(self: *Workspace, id: []const u8, now_ms: i64) !void {
        const title = (try self.db.queryText(
            self.gpa,
            "SELECT title FROM notes WHERE id = ?1",
            .{id},
        )) orelse try self.gpa.dupe(u8, "");
        defer self.gpa.free(title);

        const src = self.trashPath(id);
        const current = self.fileRef(id);
        const new_name = self.pickFilename(title, id, id);

        var dst = PathBuf{};
        dst.set("notes/{s}", .{new_name.slice()});

        if (self.fs.exists(src.slice())) {
            try self.fs.rename(src.slice(), dst.slice());
        }
        if (!std.mem.eql(u8, current.name.slice(), new_name.slice())) {
            try self.db.run(
                "UPDATE notes SET filename = ?1 WHERE id = ?2",
                .{ new_name.slice(), id },
            );
        }
        try self.db.run(
            "UPDATE notes SET deleted_at_ms = NULL, mtime_ms = ?1 WHERE id = ?2",
            .{ now_ms, id },
        );
    }

    // -- session -------------------------------------------------------------

    pub fn loadSession(self: *Workspace) !Session {
        var tabs: std.ArrayList(SessionTab) = .empty;
        errdefer {
            for (tabs.items) |t| t.deinit(self.gpa);
            tabs.deinit(self.gpa);
        }
        {
            var st = try self.db.prepare(
                "SELECT note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log " ++
                    "FROM session_tabs ORDER BY position ASC",
            );
            defer st.deinit();
            while (try st.step()) {
                try tabs.append(self.gpa, .{
                    .note_id = try st.textDupeOrEmpty(self.gpa, 0),
                    .position = st.int(1),
                    .cursor_line = st.int(2),
                    .cursor_col = st.int(3),
                    .scroll_top = st.int(4),
                    .unsaved_content = try st.textDupe(self.gpa, 5),
                    .undo_log = try st.textDupe(self.gpa, 6),
                });
            }
        }
        const active = try self.db.queryText(
            self.gpa,
            "SELECT value FROM session_meta WHERE key = 'active_tab'",
            .{},
        );
        return .{ .tabs = try tabs.toOwnedSlice(self.gpa), .active_tab = active };
    }

    /// Replace the whole session in one transaction.
    ///
    /// Tab order comes from the array index, not `tab.position` -- the caller's
    /// array *is* the tab bar order.
    pub fn saveSession(self: *Workspace, session: Session) !void {
        try self.db.begin();
        errdefer self.db.rollback();

        try self.db.run("DELETE FROM session_tabs", .{});
        for (session.tabs, 0..) |tab, i| {
            try self.db.run(
                "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                .{
                    tab.note_id,          @as(i64, @intCast(i)), tab.cursor_line,
                    tab.cursor_col,       tab.scroll_top,        tab.unsaved_content,
                    tab.undo_log,
                },
            );
        }
        try self.db.run(
            "INSERT OR REPLACE INTO session_meta (key, value) VALUES ('active_tab', ?1)",
            .{session.active_tab},
        );
        try self.db.commit();
    }

    /// Upsert one tab, honouring its own `position`.
    pub fn saveTab(self: *Workspace, tab: SessionTab) !void {
        try self.db.run(
            "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log) " ++
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) " ++
                "ON CONFLICT(note_id) DO UPDATE SET position=excluded.position, cursor_line=excluded.cursor_line, " ++
                "cursor_col=excluded.cursor_col, scroll_top=excluded.scroll_top, " ++
                "unsaved_content=excluded.unsaved_content, undo_log=excluded.undo_log",
            .{
                tab.note_id,    tab.position,   tab.cursor_line,
                tab.cursor_col, tab.scroll_top, tab.unsaved_content,
                tab.undo_log,
            },
        );
    }

    pub fn setActiveTab(self: *Workspace, active: ?[]const u8) !void {
        try self.db.run(
            "INSERT OR REPLACE INTO session_meta (key, value) VALUES ('active_tab', ?1)",
            .{active},
        );
    }

    pub fn removeTab(self: *Workspace, note_id: []const u8) !void {
        try self.db.run("DELETE FROM session_tabs WHERE note_id = ?1", .{note_id});
    }
};

// -- test support ------------------------------------------------------------

const testing = std.testing;

/// A workspace in a scratch directory, with a deterministic RNG.
pub const TestWorkspace = struct {
    env: fsx.TestEnv,
    ws: Workspace,
    gpa: Allocator,

    pub fn init(gpa: Allocator, name: []const u8) !TestWorkspace {
        var env = try fsx.TestEnv.init(gpa, name);
        errdefer env.deinit();

        const root = try std.fmt.allocPrint(gpa, "{s}/ws", .{env.path});
        defer gpa.free(root);
        return .{
            .env = env,
            .ws = try Workspace.open(gpa, env.io, root),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *TestWorkspace) void {
        self.ws.close();
        self.env.deinit();
    }

    /// Insert a note row, index it, and write its file.
    pub fn seedNote(
        self: *TestWorkspace,
        id: []const u8,
        title: []const u8,
        body: []const u8,
        mtime: i64,
    ) !void {
        const filename = try self.ws.insertNote(.{
            .id = id,
            .title = title,
            .created_ms = mtime,
            .mtime_ms = mtime,
            .size = @intCast(body.len),
        }, body);
        var path = PathBuf{};
        path.set("notes/{s}", .{filename.slice()});
        try self.ws.fs.write(path.slice(), body);
    }
};

// -- tests -------------------------------------------------------------------
// Ported from the `mod tests` block in src-tauri/src/workspace.rs and the
// `first_line_title` tests in src-tauri/src/commands/workspace.rs.

test "firstLineTitle strips hashes and trims" {
    try testing.expectEqualStrings("Hello", firstLineTitle("# Hello\nbody", "fallback"));
    try testing.expectEqualStrings("spaced", firstLineTitle("###   spaced   \n", "fallback"));
    try testing.expectEqualStrings("fallback", firstLineTitle("", "fallback"));
    try testing.expectEqualStrings("fallback", firstLineTitle("   \nbody", "fallback"));
    try testing.expectEqualStrings("plain line", firstLineTitle("plain line", "fallback"));
}

test "firstLineTitle caps at 120 code points without splitting one" {
    var buf: [400]u8 = undefined;
    var i: usize = 0;
    while (i < 300) : (i += 1) buf[i] = 'a';
    try testing.expectEqual(@as(usize, 120), firstLineTitle(buf[0..300], "x").len);

    // 200 Hangul syllables: 120 of them, 3 bytes each.
    var korean: std.ArrayList(u8) = .empty;
    defer korean.deinit(testing.allocator);
    for (0..200) |_| try korean.appendSlice(testing.allocator, "가");
    const title = firstLineTitle(korean.items, "x");
    try testing.expectEqual(@as(usize, 360), title.len);
    try testing.expectEqual(@as(usize, 120), try std.unicode.utf8CountCodepoints(title));
}

test "slugify keeps Hangul and replaces punctuation" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Meeting-with-Alex", slugify("Meeting with Alex!", &buf));
    try testing.expectEqualStrings("프로젝트-노트-1", slugify("프로젝트 노트 #1", &buf));
    try testing.expectEqualStrings("untitled", slugify("   ", &buf));
    try testing.expectEqualStrings("untitled", slugify("---", &buf));

    var long: [100]u8 = @splat('a');
    try testing.expectEqual(@as(usize, 50), slugify(&long, &buf).len);
}

test "filenameFor uses the slug and a short id" {
    var p = PathBuf{};
    filenameFor("Meeting with Alex", "a3f29b14-1234-5678-9abc-def012345678", &p);
    try testing.expectEqualStrings("Meeting-with-Alex-a3f29b14.md", p.slice());
}

test "open creates the directories and the database" {
    var t = try TestWorkspace.init(testing.allocator, "open");
    defer t.deinit();
    try testing.expect(t.ws.fs.exists("workspace.db"));
    // Writing into notes/ proves the directory is there.
    try t.ws.fs.write("notes/probe", "x");
    try testing.expect(t.ws.fs.exists("notes/probe"));
    try t.ws.fs.write("trash/probe", "x");
    try testing.expect(t.ws.fs.exists("trash/probe"));
}

test "note CRUD round trip" {
    var t = try TestWorkspace.init(testing.allocator, "crud");
    defer t.deinit();

    _ = try t.ws.insertNote(.{
        .id = "abc",
        .title = "Hello",
        .created_ms = 100,
        .mtime_ms = 200,
        .size = 5,
    }, "");

    {
        const got = try t.ws.getNote("abc");
        defer got.deinit(testing.allocator);
        try testing.expectEqualStrings("Hello", got.title);
    }

    try t.ws.updateNoteMeta("abc", "Updated", 300, 7, "body");
    {
        const after = try t.ws.getNote("abc");
        defer after.deinit(testing.allocator);
        try testing.expectEqualStrings("Updated", after.title);
        try testing.expectEqual(@as(i64, 300), after.mtime_ms);
    }
    {
        const listed = try t.ws.listNotes();
        defer freeNotes(testing.allocator, listed);
        try testing.expectEqual(@as(usize, 1), listed.len);
    }

    try t.ws.hardDeleteNote("abc");
    const listed = try t.ws.listNotes();
    defer freeNotes(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 0), listed.len);
}

test "createNote materializes a row and a file" {
    var t = try TestWorkspace.init(testing.allocator, "create");
    defer t.deinit();

    const note = try t.ws.createNote();
    defer note.deinit(testing.allocator);
    try testing.expectEqualStrings(default_title, note.title);
    try testing.expect(note.mtime_ms > 0);

    const path = t.ws.notePath(note.id);
    try testing.expect(t.ws.fs.exists(path.slice()));
    try testing.expect(std.mem.startsWith(u8, path.slice(), "notes/Untitled-"));
}

test "writeNote derives the title and renames the file" {
    var t = try TestWorkspace.init(testing.allocator, "write");
    defer t.deinit();

    const created = try t.ws.createNote();
    defer created.deinit(testing.allocator);

    const saved = try t.ws.writeNote(created.id, "# Real Title\n\nbody", null);
    defer saved.deinit(testing.allocator);
    try testing.expectEqualStrings("Real Title", saved.title);

    const path = t.ws.notePath(created.id);
    try testing.expect(std.mem.startsWith(u8, path.slice(), "notes/Real-Title-"));

    const read = try t.ws.readNote(created.id);
    defer read.deinit(testing.allocator);
    try testing.expectEqualStrings("# Real Title\n\nbody", read.content);
}

test "writeNote enforces the expected mtime" {
    var t = try TestWorkspace.init(testing.allocator, "mtime");
    defer t.deinit();

    const created = try t.ws.createNote();
    defer created.deinit(testing.allocator);

    try testing.expectError(
        error.MtimeMismatch,
        t.ws.writeNote(created.id, "x", created.mtime_ms + 9999),
    );
    // A null expectation always overwrites.
    const ok = try t.ws.writeNote(created.id, "x", null);
    defer ok.deinit(testing.allocator);
}

test "trash moves the file into the trash folder" {
    var t = try TestWorkspace.init(testing.allocator, "trash");
    defer t.deinit();
    try t.seedNote("abc", "Hello", "hello", 200);

    const active = t.ws.activePath("abc");
    try testing.expect(t.ws.fs.exists(active.slice()));

    try t.ws.trashNote("abc", 500);

    const listed = try t.ws.listNotes();
    defer freeNotes(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 0), listed.len);
    try testing.expect(!t.ws.fs.exists(active.slice()));

    const trashed = t.ws.trashPath("abc");
    try testing.expect(t.ws.fs.exists(trashed.slice()));

    const body = try t.ws.fs.read(testing.allocator, trashed.slice());
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);

    // notePath follows the file into trash/.
    try testing.expectEqualStrings(trashed.slice(), t.ws.notePath("abc").slice());
}

test "trash and purge respect the cutoff" {
    var t = try TestWorkspace.init(testing.allocator, "purge");
    defer t.deinit();
    try t.seedNote("abc", "Hello", "hello", 200);
    try t.ws.trashNote("abc", 500);

    const trashed = t.ws.trashPath("abc");
    try testing.expect(t.ws.fs.exists(trashed.slice()));

    try testing.expectEqual(@as(usize, 0), try t.ws.purgeOldTrash(400));
    try testing.expect(t.ws.fs.exists(trashed.slice()));

    try testing.expectEqual(@as(usize, 1), try t.ws.purgeOldTrash(600));
    try testing.expect(!t.ws.fs.exists(trashed.slice()));
}

test "restore moves the file back and bumps mtime" {
    var t = try TestWorkspace.init(testing.allocator, "restore");
    defer t.deinit();
    try t.seedNote("abc", "Hello", "hello", 200);

    const active = t.ws.activePath("abc");
    try t.ws.trashNote("abc", 500);
    try testing.expect(!t.ws.fs.exists(active.slice()));

    try t.ws.restoreNote("abc", 900);

    const listed = try t.ws.listNotes();
    defer freeNotes(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expect(!t.ws.fs.exists(t.ws.trashPath("abc").slice()));
    try testing.expect(t.ws.fs.exists(active.slice()));

    const got = try t.ws.getNote("abc");
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 900), got.mtime_ms);
}

test "restore picks a fresh name when the old one was taken" {
    var t = try TestWorkspace.init(testing.allocator, "restore-collide");
    defer t.deinit();
    try t.seedNote("aaaaaaaa-1", "Same Title", "first", 1);
    try t.ws.trashNote("aaaaaaaa-1", 100);

    // Another note grabs the filename the trashed one would restore to.
    var taken = PathBuf{};
    filenameFor("Same Title", "aaaaaaaa-1", &taken);
    try t.ws.db.run(
        "INSERT INTO notes (id, title, created_ms, mtime_ms, size, filename) VALUES ('other', 'Same Title', 2, 2, 0, ?1)",
        .{taken.slice()},
    );

    try t.ws.restoreNote("aaaaaaaa-1", 200);

    const restored = t.ws.notePath("aaaaaaaa-1");
    try testing.expect(t.ws.fs.exists(restored.slice()));
    try testing.expect(!std.mem.endsWith(u8, restored.slice(), taken.slice()));

    const body = try t.ws.fs.read(testing.allocator, restored.slice());
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("first", body);
}

test "list is sorted by mtime, newest first" {
    var t = try TestWorkspace.init(testing.allocator, "sort");
    defer t.deinit();
    try t.seedNote("old", "old", "", 1);
    try t.seedNote("new", "new", "", 10);

    const listed = try t.ws.listNotes();
    defer freeNotes(testing.allocator, listed);
    try testing.expectEqualStrings("new", listed[0].id);
    try testing.expectEqualStrings("old", listed[1].id);
}

test "insertNote stores a readable filename" {
    var t = try TestWorkspace.init(testing.allocator, "filename");
    defer t.deinit();
    try t.seedNote("a3f29b14-deadbeef", "My Note", "", 1);
    try testing.expectEqualStrings(
        "notes/My-Note-a3f29b14.md",
        t.ws.notePath("a3f29b14-deadbeef").slice(),
    );
}

test "renaming on a title change moves the file and updates the row" {
    var t = try TestWorkspace.init(testing.allocator, "rename");
    defer t.deinit();
    const id = "abcdef01-5678-90ab-cdef-0123456789ab";
    try t.seedNote(id, "First", "hi", 1);

    const old_path = t.ws.notePath(id);
    _ = try t.ws.renameFileIfTitleChanged(id, "Second Title");
    const new_path = t.ws.notePath(id);

    try testing.expect(!std.mem.eql(u8, old_path.slice(), new_path.slice()));
    try testing.expect(!t.ws.fs.exists(old_path.slice()));
    try testing.expectEqualStrings("notes/Second-Title-abcdef01.md", new_path.slice());

    const body = try t.ws.fs.read(testing.allocator, new_path.slice());
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hi", body);
}

test "reopening backfills filenames for legacy uuid files" {
    var env = try fsx.TestEnv.init(testing.allocator, "backfill");
    defer env.deinit();

    const root = try std.fmt.allocPrint(testing.allocator, "{s}/ws", .{env.path});
    defer testing.allocator.free(root);

    const legacy_id = "legacy01-2345-6789";
    {
        var ws = try Workspace.open(testing.allocator, env.io, root);
        defer ws.close();

        _ = try ws.insertNote(.{
            .id = legacy_id,
            .title = "Legacy Note",
            .created_ms = 1,
            .mtime_ms = 1,
            .size = 0,
        }, "");

        // Recreate the pre-migration state: the file sits at notes/{uuid}.md
        // and the filename column is NULL.
        const current = ws.notePath(legacy_id);
        ws.fs.deleteIfExists(current.slice());
        try ws.fs.write("notes/" ++ legacy_id ++ ".md", "payload");
        try ws.db.run("UPDATE notes SET filename = NULL WHERE id = ?1", .{legacy_id});
    }

    var ws = try Workspace.open(testing.allocator, env.io, root);
    defer ws.close();

    const p = ws.notePath(legacy_id);
    try testing.expectEqualStrings("notes/Legacy-Note-legacy01.md", p.slice());

    const body = try ws.fs.read(testing.allocator, p.slice());
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("payload", body);
    try testing.expect(!ws.fs.exists("notes/" ++ legacy_id ++ ".md"));
}

test "session round trip" {
    var t = try TestWorkspace.init(testing.allocator, "session");
    defer t.deinit();

    var tabs = [_]SessionTab{
        .{
            .note_id = "a",
            .position = 0,
            .cursor_line = 1,
            .cursor_col = 2,
            .scroll_top = 40,
            .unsaved_content = "hi",
        },
        .{ .note_id = "b", .position = 1, .undo_log = "[]" },
    };
    try t.ws.saveSession(.{ .tabs = &tabs, .active_tab = "a" });

    const loaded = try t.ws.loadSession();
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), loaded.tabs.len);
    try testing.expectEqualStrings("a", loaded.tabs[0].note_id);
    try testing.expectEqualStrings("b", loaded.tabs[1].note_id);
    try testing.expectEqualStrings("hi", loaded.tabs[0].unsaved_content.?);
    try testing.expect(loaded.tabs[0].undo_log == null);
    try testing.expectEqualStrings("[]", loaded.tabs[1].undo_log.?);
    try testing.expectEqualStrings("a", loaded.active_tab.?);
}

test "saveSession renumbers positions from array order" {
    var t = try TestWorkspace.init(testing.allocator, "session-order");
    defer t.deinit();

    // Deliberately wrong positions -- the array order is the tab bar order.
    var tabs = [_]SessionTab{
        .{ .note_id = "x", .position = 99 },
        .{ .note_id = "y", .position = 5 },
    };
    try t.ws.saveSession(.{ .tabs = &tabs, .active_tab = null });

    const loaded = try t.ws.loadSession();
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), loaded.tabs[0].position);
    try testing.expectEqual(@as(i64, 1), loaded.tabs[1].position);
    try testing.expect(loaded.active_tab == null);
}

test "saveTab upserts and removeTab deletes" {
    var t = try TestWorkspace.init(testing.allocator, "session-tab");
    defer t.deinit();

    try t.ws.saveTab(.{ .note_id = "a", .position = 3, .cursor_line = 4 });
    try t.ws.saveTab(.{ .note_id = "a", .position = 3, .cursor_line = 9 });
    {
        const loaded = try t.ws.loadSession();
        defer loaded.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), loaded.tabs.len);
        try testing.expectEqual(@as(i64, 9), loaded.tabs[0].cursor_line);
    }

    try t.ws.setActiveTab("a");
    try t.ws.removeTab("a");
    const loaded = try t.ws.loadSession();
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.tabs.len);
    try testing.expectEqualStrings("a", loaded.active_tab.?);
}

test "trashing a note drops its session tab" {
    var t = try TestWorkspace.init(testing.allocator, "session-trash");
    defer t.deinit();
    try t.seedNote("a", "A", "body", 1);
    try t.ws.saveTab(.{ .note_id = "a" });

    try t.ws.trashNote("a", 100);

    const loaded = try t.ws.loadSession();
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.tabs.len);
}

test "listTrashedNotes is newest deletion first" {
    var t = try TestWorkspace.init(testing.allocator, "trash-list");
    defer t.deinit();
    try t.seedNote("a", "A", "", 1);
    try t.seedNote("b", "B", "", 2);
    try t.ws.trashNote("a", 100);
    try t.ws.trashNote("b", 200);

    const trashed = try t.ws.listTrashedNotes();
    defer freeTrashedNotes(testing.allocator, trashed);
    try testing.expectEqual(@as(usize, 2), trashed.len);
    try testing.expectEqualStrings("b", trashed[0].id);
    try testing.expectEqualStrings("a", trashed[1].id);
}

test "applyRemoteContent overwrites without the mtime check" {
    var t = try TestWorkspace.init(testing.allocator, "remote");
    defer t.deinit();
    try t.seedNote("a", "Old", "old body", 1);

    _ = try t.ws.applyRemoteContent("a", "# New\nbody", "New");

    const read = try t.ws.readNote("a");
    defer read.deinit(testing.allocator);
    try testing.expectEqualStrings("# New\nbody", read.content);

    const got = try t.ws.getNote("a");
    defer got.deinit(testing.allocator);
    try testing.expectEqualStrings("New", got.title);
}
