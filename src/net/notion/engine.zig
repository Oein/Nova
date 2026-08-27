//! The sync executor.
//!
//! Ported from the `Executor` half of `src-tauri/src/notion/sync.rs`.
//!
//! Ordering rules that are load-bearing and easy to lose:
//!
//!   * A push **appends before it deletes**. Deleting first and then failing to
//!     append would leave the user an empty page and nothing but Notion's trash.
//!   * The local file is settled **before** properties are published, so the
//!     "Updated" column describes the mtime the push actually left behind.
//!   * A pull re-reads the file and compares its hash before applying: fetching
//!     a page takes seconds, and the user may have saved in the meantime.
//!   * A conflict is cleared **after** its resolution succeeds, never before.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");
const client = @import("client.zig");
const store = @import("store.zig");
const b2m = @import("blocks_to_md.zig");
const m2b = @import("md_to_blocks.zig");
const classify = @import("classify.zig");
const sync = @import("sync.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;
const Workspace = db.workspace.Workspace;
const Action = classify.Action;
const Report = sync.Report;
const Props = sync.Props;
const Endpoints = client.Endpoints;

pub const Error = sync.Error;

/// One unit of work produced by planning.
const Task = struct {
    note_id: ?[]const u8,
    page_id: ?[]const u8,
    title: []const u8,
    action: Action,
    /// Present when the note was read during planning (its mtime had moved).
    local_content: ?[]const u8 = null,
};

pub const Engine = struct {
    gpa: Allocator,
    io: std.Io,
    ws: *Workspace,
    api: *client.Client,
    cancel: *std.atomic.Value(bool),
    dry_run: bool = false,

    /// Scratch for one run; freed wholesale when the run ends.
    arena: std.heap.ArenaAllocator = undefined,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        ws: *Workspace,
        api: *client.Client,
        cancel: *std.atomic.Value(bool),
    ) Engine {
        return .{ .gpa = gpa, .io = io, .ws = ws, .api = api, .cancel = cancel };
    }

    fn a(self: *Engine) Allocator {
        return self.arena.allocator();
    }

    fn nowMs(self: *Engine) i64 {
        return @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn cancelled(self: *Engine) bool {
        return self.cancel.load(.seq_cst);
    }

    // -- entry point ---------------------------------------------------------

    pub fn run(self: *Engine) Error!Report {
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        defer self.arena.deinit();

        var report = Report.init(self.gpa);
        errdefer report.deinit();
        report.dry_run = self.dry_run;

        const cfg = try store.getConfig(self.ws, self.a());
        const creds = try cfg.credentials();

        // Read the title property back rather than assuming it: writing to a
        // renamed title column fails *silently*.
        const database = try Endpoints.retrieveDatabase(self.api, self.a(), creds.database_id);
        var info = (try model.parseDbInfo(self.a(), database)) orelse return error.BadResponse;
        defer info.deinit(self.a());

        try store.setTitleProp(self.ws, info.title_prop);
        try store.setDatabaseTitle(self.ws, info.title);

        const props = try self.resolveProps(&report, cfg, info, creds.database_id);

        const remote = try self.fetchRemoteIndex(creds.database_id);
        if (self.cancelled()) {
            report.cancelled = true;
            return report;
        }

        const tasks = try self.plan(&report, cfg, props, remote.items);
        for (tasks) |task| {
            if (self.cancelled()) {
                report.cancelled = true;
                break;
            }
            self.execute(&report, props, creds.database_id, task) catch |err| {
                // One note failing must not abandon the rest.
                try self.recordFailure(&report, task, err);
            };
        }
        return report;
    }

    fn recordFailure(self: *Engine, report: *Report, task: Task, err: anyerror) !void {
        if (task.note_id) |id| {
            store.setLinkState(self.ws, id, "error", self.api.errorMessage()) catch {};
        }
        const message = if (self.api.errorMessage().len > 0)
            self.api.errorMessage()
        else
            @errorName(err);
        try report.push(.err, task.note_id, task.page_id, task.title, message);
    }

    // -- the Nova-owned columns ----------------------------------------------

    /// Check the configured timestamp columns against the schema, creating any
    /// that are missing.
    ///
    /// A column that exists with the *wrong* type is left completely alone and
    /// reported: repurposing a column the user keeps something else in would
    /// destroy data.
    fn resolveProps(
        self: *Engine,
        report: *Report,
        cfg: store.Config,
        info: model.DbInfo,
        database_id: []const u8,
    ) Error!Props {
        var props = Props{ .title_prop = try self.a().dupe(u8, info.title_prop) };

        const wanted = [_]struct { ?[]const u8, []const u8, *?[]const u8 }{
            .{ cfg.created_prop, "date", &props.created },
            .{ cfg.updated_prop, "date", &props.updated },
            .{ cfg.id_prop, "rich_text", &props.id },
        };

        var to_create: std.ArrayList(Value) = .empty;
        for (wanted) |w| {
            const name = w[0] orelse continue;
            const want_type = w[1];

            if (info.propertyType(name)) |existing| {
                if (std.mem.eql(u8, existing, want_type)) {
                    w[2].* = try self.a().dupe(u8, name);
                    continue;
                }
                const message = try std.fmt.allocPrint(
                    self.a(),
                    "Column \"{s}\" is a {s}, not a {s} -- leaving it alone",
                    .{ name, existing, want_type },
                );
                try report.push(.blocked, null, null, name, message);
                continue;
            }

            // A dry run never touches the schema, but still reports what would
            // happen -- otherwise the preview would be misleading.
            if (self.dry_run) {
                w[2].* = try self.a().dupe(u8, name);
                continue;
            }
            const spec = if (std.mem.eql(u8, want_type, "date"))
                try client.dateColumnSpec(self.a(), name)
            else
                try client.textColumnSpec(self.a(), name);
            try to_create.append(self.a(), spec);
            w[2].* = try self.a().dupe(u8, name);
        }

        if (to_create.items.len > 0) {
            const merged = try client.mergeProperties(self.a(), to_create.items);
            _ = try Endpoints.addDatabaseProperties(self.api, self.a(), database_id, merged);
        }
        return props;
    }

    // -- the remote side -----------------------------------------------------

    const RemoteIndex = struct { items: []model.PageMeta };

    /// Page through the whole database once.
    fn fetchRemoteIndex(self: *Engine, database_id: []const u8) Error!RemoteIndex {
        var pages: std.ArrayList(model.PageMeta) = .empty;

        var cursor: ?[]const u8 = null;
        while (true) {
            if (self.cancelled()) break;
            const parsed = try Endpoints.queryDatabase(self.api, self.a(), database_id, cursor);

            const results = switch (parsed) {
                .object => |o| o.get("results") orelse break,
                else => break,
            };
            if (results != .array) break;
            for (results.array.items) |page| {
                if (try model.parsePage(self.a(), page)) |meta| try pages.append(self.a(), meta);
            }

            const has_more = switch (parsed) {
                .object => |o| o.get("has_more"),
                else => null,
            };
            const more = has_more != null and has_more.? == .bool and has_more.?.bool;
            if (!more) break;

            const next = switch (parsed) {
                .object => |o| o.get("next_cursor"),
                else => null,
            };
            cursor = if (next != null and next.? == .string) next.?.string else break;
        }

        return .{ .items = try pages.toOwnedSlice(self.a()) };
    }

    /// All of a page's blocks, with children inlined to `fetch_depth`.
    fn fetchBlocks(self: *Engine, block_id: []const u8, depth: usize) Error![]Value {
        var out: std.ArrayList(Value) = .empty;
        var cursor: ?[]const u8 = null;

        while (true) {
            const parsed = try Endpoints.listChildren(self.api, self.a(), block_id, cursor);
            const results = switch (parsed) {
                .object => |o| o.get("results") orelse break,
                else => break,
            };
            if (results != .array) break;

            for (results.array.items) |block| {
                var enriched = block;
                if (depth > 1 and hasChildren(block)) {
                    if (blockTypeOf(block)) |ty| {
                        const kids = try self.fetchBlocks(idOf(block) orelse "", depth - 1);
                        enriched = try inlineChildren(self.a(), block, ty, kids);
                    }
                }
                try out.append(self.a(), enriched);
            }

            const has_more = switch (parsed) {
                .object => |o| o.get("has_more"),
                else => null,
            };
            if (!(has_more != null and has_more.? == .bool and has_more.?.bool)) break;
            const next = switch (parsed) {
                .object => |o| o.get("next_cursor"),
                else => null,
            };
            cursor = if (next != null and next.? == .string) next.?.string else break;
        }
        return out.toOwnedSlice(self.a());
    }

    fn hasChildren(block: Value) bool {
        const v = switch (block) {
            .object => |o| o.get("has_children") orelse return false,
            else => return false,
        };
        return v == .bool and v.bool;
    }

    fn blockTypeOf(block: Value) ?[]const u8 {
        const v = switch (block) {
            .object => |o| o.get("type") orelse return null,
            else => return null,
        };
        return if (v == .string) v.string else null;
    }

    fn idOf(block: Value) ?[]const u8 {
        const v = switch (block) {
            .object => |o| o.get("id") orelse return null,
            else => return null,
        };
        return if (v == .string) v.string else null;
    }

    /// Put fetched children under `block[type].children`, the shape the
    /// renderer expects.
    fn inlineChildren(arena: Allocator, block: Value, ty: []const u8, kids: []Value) !Value {
        if (block != .object) return block;
        const inner = block.object.get(ty) orelse return block;
        if (inner != .object) return block;

        var kid_array = std.json.Array.init(arena);
        try kid_array.appendSlice(kids);

        var new_inner = inner.object;
        try new_inner.put(arena, "children", .{ .array = kid_array });

        var out = block.object;
        try out.put(arena, ty, .{ .object = new_inner });
        return .{ .object = out };
    }

    /// A page's blocks rendered to markdown and hashed.
    fn fetchRendered(self: *Engine, page: model.PageMeta) Error!sync.Fetched {
        const blocks = try self.fetchBlocks(page.id, sync.fetch_depth);
        return sync.renderFetched(self.gpa, page.title, blocks);
    }

    // -- planning ------------------------------------------------------------

    fn plan(
        self: *Engine,
        report: *Report,
        cfg: store.Config,
        props: Props,
        remote: []const model.PageMeta,
    ) Error![]Task {
        _ = cfg;
        var tasks: std.ArrayList(Task) = .empty;

        const rows = try store.listNoteRows(self.ws, self.a());
        const links = try store.listLinks(self.ws, self.a());

        var by_page: std.StringHashMapUnmanaged(model.PageMeta) = .empty;
        for (remote) |p| try by_page.put(self.a(), p.id, p);

        var linked_pages: std.StringHashMapUnmanaged(void) = .empty;
        var linked_notes: std.StringHashMapUnmanaged(void) = .empty;

        for (links) |link| {
            if (link.page_id) |pid| try linked_pages.put(self.a(), pid, {});
            try linked_notes.put(self.a(), link.note_id, {});

            const row = findRow(rows, link.note_id);
            const local = try self.localStateFor(report, row, link);
            // A note we could not read is left strictly alone. Classifying it
            // as absent would archive its page, which is exactly the wrong
            // response to a transient filesystem problem.
            if (local.unreadable) continue;
            const page: ?model.PageMeta = if (link.page_id) |pid| by_page.get(pid) else null;

            const action = classify.stageOne(
                local.state,
                if (page) |p| .{ .last_edited = p.last_edited_time, .archived = p.archived } else null,
                .{
                    .local_hash = link.base_local_hash,
                    .remote_edited = link.base_remote_edited,
                    .state = link.state,
                },
            );

            // A clean note whose Nova-owned columns are stale still needs one
            // write -- this is what backfills a column the user just turned on,
            // rather than waiting for the next edit.
            var final = action;
            if (action == .skip and props.anyConfigured()) {
                if (page) |p| {
                    if (row) |r| {
                        if (!try props.matches(self.a(), p, r.created_ms, r.mtime_ms, r.id)) {
                            final = .update_props;
                        }
                    }
                }
            }
            if (final == .skip) continue;

            try tasks.append(self.a(), .{
                .note_id = link.note_id,
                .page_id = link.page_id,
                .title = if (row) |r| r.title else "",
                .action = final,
                .local_content = local.content,
            });
        }

        // Adopt pass: a page carrying a Nova id that names a live, unlinked
        // note means the mapping was lost, not that the note is new. Runs
        // before CreateRemote so a lost mapping does not publish a duplicate.
        var adopted: std.StringHashMapUnmanaged(void) = .empty;
        if (props.id) |id_prop| {
            for (remote) |p| {
                if (p.archived) continue;
                if (linked_pages.contains(p.id)) continue;
                const note_id = (try model.pagePropertyPlain(self.a(), p.properties, id_prop)) orelse
                    continue;
                const row = findRow(rows, note_id) orelse continue;
                if (row.trashed or linked_notes.contains(note_id)) continue;

                try adopted.put(self.a(), note_id, {});
                try linked_pages.put(self.a(), p.id, {});
                try tasks.append(self.a(), .{
                    .note_id = note_id,
                    .page_id = p.id,
                    .title = row.title,
                    .action = .adopt,
                });
            }
        }

        // Unlinked live notes become pages.
        for (rows) |row| {
            if (row.trashed or linked_notes.contains(row.id) or adopted.contains(row.id)) continue;
            try tasks.append(self.a(), .{
                .note_id = row.id,
                .page_id = null,
                .title = row.title,
                .action = .create_remote,
            });
        }

        // Unlinked live pages become notes.
        for (remote) |p| {
            if (p.archived or linked_pages.contains(p.id)) continue;
            try tasks.append(self.a(), .{
                .note_id = null,
                .page_id = p.id,
                .title = p.title,
                .action = .create_local,
            });
        }

        const sorted = try tasks.toOwnedSlice(self.a());
        std.mem.sort(Task, sorted, {}, struct {
            fn lessThan(_: void, x: Task, y: Task) bool {
                return x.action.priority() < y.action.priority();
            }
        }.lessThan);
        return sorted;
    }

    fn findRow(rows: []const store.NoteRow, id: []const u8) ?store.NoteRow {
        for (rows) |r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    const LocalRead = struct {
        state: ?classify.LocalState,
        content: ?[]const u8,
        /// The note exists but its file could not be read. Distinct from
        /// "absent": an absent note means the user deleted it and the page
        /// should follow, while an unreadable one means we simply do not know,
        /// and doing anything at all would risk destroying the page.
        unreadable: bool = false,
    };

    /// Read a note's current hash, skipping the file entirely when its mtime
    /// says nothing has changed.
    ///
    /// A note whose file cannot be read is recorded as *unreadable*, never as
    /// empty: an empty hash would read as "the user cleared this note" and push
    /// a blank page over their content.
    fn localStateFor(
        self: *Engine,
        report: *Report,
        row: ?store.NoteRow,
        link: store.Link,
    ) Error!LocalRead {
        const r = row orelse return .{ .state = null, .content = null };
        if (r.trashed) {
            return .{ .state = .{ .hash = link.base_local_hash, .trashed = true }, .content = null };
        }

        const path = self.ws.notePath(r.id);
        // Fast path: an untouched mtime plus a non-empty stored hash means the
        // file need not be read at all. The existence check stops a vanished
        // file being reported as "unchanged" forever.
        if (link.base_local_mtime_ms == r.mtime_ms and
            link.base_local_hash.len > 0 and
            self.ws.fs.exists(path.slice()))
        {
            return .{ .state = .{ .hash = link.base_local_hash, .trashed = false }, .content = null };
        }

        const content = self.ws.fs.read(self.a(), path.slice()) catch |err| {
            const message = if (err == error.NotFound)
                "The note's file is missing. Delete the note to clear this warning."
            else
                @errorName(err);
            const kind: sync.ItemKind = if (err == error.NotFound) .blocked else .err;
            try report.push(kind, r.id, link.page_id, r.title, message);
            return .{ .state = null, .content = null, .unreadable = true };
        };

        const hash = try self.a().dupe(u8, &sync.sha256Hex(content));
        return .{ .state = .{ .hash = hash, .trashed = false }, .content = content };
    }

    // -- executing -----------------------------------------------------------

    fn execute(
        self: *Engine,
        report: *Report,
        props: Props,
        database_id: []const u8,
        task: Task,
    ) Error!void {
        if (self.dry_run) return self.previewOnly(report, task);

        switch (task.action) {
            .skip, .maybe_pull => try self.settleMaybePull(report, props, task),
            .pull => try self.settleMaybePull(report, props, task),
            .push => try self.doPush(report, props, task),
            .create_remote => try self.doCreateRemote(report, props, database_id, task),
            .create_local => try self.doCreateLocal(report, task),
            .archive_remote => try self.doArchiveRemote(report, task),
            .trash_local => try self.doTrashLocal(report, task),
            .drop_link => {
                try store.deleteLink(self.ws, task.note_id.?);
            },
            .adopt => try self.doAdopt(report, props, task),
            .update_props => try self.doUpdateProps(props, task),
            .conflict => |kind| try self.recordConflict(report, task, kind, null, null),
        }
    }

    /// A dry run reports what would happen and touches nothing.
    fn previewOnly(self: *Engine, report: *Report, task: Task) Error!void {
        _ = self;
        const kind: sync.ItemKind = switch (task.action) {
            .pull, .maybe_pull => .pulled,
            .push => .pushed,
            .create_remote => .created_remote,
            .create_local => .created_local,
            .archive_remote => .archived_remote,
            .trash_local => .trashed_local,
            .conflict => .conflict,
            else => .info,
        };
        try report.push(kind, task.note_id, task.page_id, task.title, "dry run");
    }

    /// Stage two: fetch the page and re-decide now that the content is known.
    fn settleMaybePull(self: *Engine, report: *Report, props: Props, task: Task) Error!void {
        const note_id = task.note_id orelse return;
        const page_id = task.page_id orelse return;

        const link = (try store.getLink(self.ws, self.a(), note_id)) orelse return;
        const parsed = try Endpoints.retrievePage(self.api, self.a(), page_id);
        const page = (try model.parsePage(self.a(), parsed)) orelse return error.BadResponse;

        var fetched = try self.fetchRendered(page);
        defer fetched.deinit(self.gpa);

        const local_content = task.local_content orelse
            try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
        const local_hash = sync.sha256Hex(local_content);

        const local_changed = !std.mem.eql(u8, &local_hash, link.base_local_hash);
        const remote_changed = !std.mem.eql(u8, &fetched.hash, link.base_remote_hash);

        switch (classify.stageTwo(local_changed, remote_changed)) {
            .skip => try self.rebaseOnly(note_id, page, fetched),
            .pull => try self.applyPull(report, note_id, page, &fetched, local_content),
            .push => try self.doPush(report, props, task),
            .conflict => |kind| try self.recordConflict(
                report,
                task,
                kind,
                local_content,
                fetched.markdown,
            ),
            else => {},
        }
    }

    /// Content agrees; only the baseline needs to catch up with the timestamp.
    fn rebaseOnly(self: *Engine, note_id: []const u8, page: model.PageMeta, fetched: sync.Fetched) Error!void {
        var link = (try store.getLink(self.ws, self.a(), note_id)) orelse return;
        link.base_remote_hash = &fetched.hash;
        link.base_remote_edited = page.last_edited_time;
        link.last_synced_ms = self.nowMs();
        link.push_mode = fetched.push_mode;
        try store.upsertLink(self.ws, link);
        try store.replaceBlocks(self.ws, note_id, fetched.unsupported);
    }

    /// Write the remote content over the local note.
    ///
    /// `expect_local` guards against the user having saved while the fetch was
    /// in flight: if the file moved, nothing is applied and the caller raises a
    /// conflict instead.
    fn applyPull(
        self: *Engine,
        report: *Report,
        note_id: []const u8,
        page: model.PageMeta,
        fetched: *sync.Fetched,
        expect_local: ?[]const u8,
    ) Error!void {
        if (expect_local) |expected| {
            const current = try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
            if (!std.mem.eql(u8, current, expected)) {
                // The file moved under us; treat it as a conflict rather than
                // overwriting an edit the user just made.
                try self.recordConflict(
                    report,
                    .{ .note_id = note_id, .page_id = page.id, .title = page.title, .action = .{ .conflict = .both_changed } },
                    .both_changed,
                    current,
                    fetched.markdown,
                );
                return;
            }
        }

        const title = db.workspace.firstLineTitle(fetched.markdown, db.workspace.default_title);
        _ = try self.ws.applyRemoteContent(note_id, fetched.markdown, title);
        try store.replaceBlocks(self.ws, note_id, fetched.unsupported);

        var link = (try store.getLink(self.ws, self.a(), note_id)) orelse
            store.Link{ .note_id = note_id, .page_id = page.id };
        // Both sides now render to the same markdown, which is exactly what a
        // baseline means.
        link.page_id = page.id;
        link.base_local_hash = &fetched.hash;
        link.base_local_mtime_ms = (self.ws.fs.statMeta(self.ws.notePath(note_id).slice()) catch
            db.fsx.Meta{ .mtime_ms = 0, .size = 0 }).mtime_ms;
        link.base_remote_hash = &fetched.hash;
        link.base_remote_edited = page.last_edited_time;
        link.last_synced_ms = self.nowMs();
        link.push_mode = fetched.push_mode;
        link.state = "ok";
        link.last_error = null;
        try store.upsertLink(self.ws, link);

        try report.noteChanged(note_id);
        try report.push(.pulled, note_id, page.id, title, null);
    }

    fn doPush(self: *Engine, report: *Report, props: Props, task: Task) Error!void {
        const note_id = task.note_id orelse return;
        const page_id = task.page_id orelse return;

        const link = (try store.getLink(self.ws, self.a(), note_id)) orelse return;
        if (link.isBlocked()) {
            try report.push(
                .blocked,
                note_id,
                page_id,
                task.title,
                "This page holds a block Nova cannot recreate, so it is pull-only.",
            );
            return;
        }

        const content = task.local_content orelse
            try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
        try self.rebuildPage(report, props, note_id, page_id, content);
        try report.push(.pushed, note_id, page_id, task.title, null);
    }

    /// Rewrite a page's body from the note's markdown.
    ///
    /// How far the next `append_children` request can reach.
    ///
    /// Bounded by Notion's block count and by its body size, whichever runs out
    /// first. One block is always taken even when it is over the ceiling on its
    /// own: a paragraph can be long enough that nothing else fits beside it,
    /// and stalling would be worse than letting the API refuse it and say so.
    pub fn appendChunkEnd(payload: []const Value, offset: usize) usize {
        const hard = @min(offset + client.append_chunk, payload.len);
        var size = client.jsonSize(payload[offset]);
        var end = offset + 1;
        while (end < hard) : (end += 1) {
            const next = client.jsonSize(payload[end]);
            if (size + next > client.max_body_bytes) break;
            size += next;
        }
        return end;
    }

    /// Notion has no block-move API and `append_children` cannot insert at the
    /// front, so writing a body means writing *all* of it and removing all of
    /// the old.
    fn rebuildPage(
        self: *Engine,
        report: *Report,
        props: Props,
        note_id: []const u8,
        page_id: []const u8,
        content: []const u8,
    ) Error!void {
        const title = db.workspace.firstLineTitle(content, db.workspace.default_title);
        const desired = try m2b.parseBody(self.a(), content);

        const cached = try store.listBlocks(self.ws, self.a(), note_id);

        // Entries stay 1:1 with the payload, so `append_children`'s ordered
        // response maps new ids back onto the placeholders.
        var payload: std.ArrayList(Value) = .empty;
        var restored: std.ArrayList(?[]const u8) = .empty;
        for (desired) |d| {
            switch (d) {
                .block => |v| {
                    try payload.append(self.a(), v);
                    try restored.append(self.a(), null);
                },
                .restore => |old_id| {
                    // A placeholder with no cache entry refers to a block that
                    // no longer exists -- copied in from another note, say.
                    // Dropping it is the only honest option.
                    const hit = findCached(cached, old_id) orelse continue;
                    const raw = std.json.parseFromSlice(Value, self.a(), hit.raw_json, .{}) catch
                        continue;
                    try payload.append(self.a(), try model.stripReadOnly(self.a(), raw.value));
                    try restored.append(self.a(), old_id);
                },
            }
        }

        // Snapshot the existing children first, so we know exactly what to
        // remove and what to roll back to.
        const existing = try self.childIds(page_id);

        var created: std.ArrayList(Value) = .empty;
        if (payload.items.len > 0) {
            var offset: usize = 0;
            while (offset < payload.items.len) {
                const end = appendChunkEnd(payload.items, offset);
                const res = Endpoints.appendChildren(
                    self.api,
                    self.a(),
                    page_id,
                    payload.items[offset..end],
                ) catch |err| {
                    // A multi-chunk append can fail partway. Remove whatever
                    // landed so the page is left as we found it, then report
                    // the original error.
                    self.discardBlocksNotIn(page_id, existing) catch {};
                    return err;
                };
                const results = switch (res) {
                    .object => |o| o.get("results"),
                    else => null,
                };
                if (results != null and results.? == .array) {
                    try created.appendSlice(self.a(), results.?.array.items);
                }
                offset = end;
            }
        }

        // Now the old copy can go. A failure here is not data loss -- the new
        // content is already on the page -- so keep going and let the freshly
        // read baseline describe whatever actually survived.
        var orphaned: usize = 0;
        for (existing) |id| {
            _ = Endpoints.deleteBlock(self.api, self.a(), id) catch {
                orphaned += 1;
                continue;
            };
        }

        // Placeholders now point at freed ids; rewrite them before hashing, or
        // the next sync sees a phantom local change.
        var id_map: sync.IdMap = .empty;
        for (restored.items, 0..) |maybe_old, i| {
            const old = maybe_old orelse continue;
            if (i >= created.items.len) continue;
            const new_id = idOf(created.items[i]) orelse continue;
            if (!std.mem.eql(u8, old, new_id)) try id_map.put(self.a(), old, new_id);
        }

        // What actually went to Notion, expressed as local markdown. This --
        // not whatever is on disk right now -- is the state the remote matches.
        const pushed = try sync.rewritePlaceholderIds(self.a(), content, id_map);
        const pushed_hash = sync.sha256Hex(pushed);

        // Settle the local file BEFORE publishing properties, so the "Updated"
        // column describes the mtime the push leaves behind. Otherwise every
        // following sync would see a stale value and rewrite it forever.
        const write_back = try self.writeBack(note_id, content, pushed);

        const row = findRow(try store.listNoteRows(self.ws, self.a()), note_id);
        const created_ms = if (row) |r| r.created_ms else 0;

        const payload_props = try props.payload(
            self.a(),
            title,
            created_ms,
            write_back.mtime_ms,
            note_id,
        );
        _ = try Endpoints.updatePage(self.api, self.a(), page_id, payload_props, null);

        const parsed = try Endpoints.retrievePage(self.api, self.a(), page_id);
        const page = (try model.parsePage(self.a(), parsed)) orelse return error.BadResponse;

        var fetched = try self.fetchRendered(page);
        defer fetched.deinit(self.gpa);

        try store.replaceBlocks(self.ws, note_id, fetched.unsupported);

        var link = (try store.getLink(self.ws, self.a(), note_id)) orelse
            store.Link{ .note_id = note_id, .page_id = page_id };
        link.page_id = page.id;
        link.base_local_hash = &pushed_hash;
        // Zeroing the mtime defeats the planner's fast path, forcing a re-read
        // next time so the racing edit is noticed.
        link.base_local_mtime_ms = if (write_back.raced) 0 else write_back.mtime_ms;
        link.base_remote_hash = &fetched.hash;
        link.base_remote_edited = page.last_edited_time;
        link.last_synced_ms = self.nowMs();
        link.push_mode = fetched.push_mode;
        link.state = "ok";
        link.last_error = null;
        try store.upsertLink(self.ws, link);

        if (orphaned > 0) {
            const message = try std.fmt.allocPrint(
                self.a(),
                "{d} old block(s) could not be removed; the next sync will clear them",
                .{orphaned},
            );
            try report.push(.info, note_id, page_id, title, message);
        }
        if (write_back.rewritten) try report.noteChanged(note_id);
    }

    /// Entry points the conflict resolver drives directly. Each assumes the
    /// caller has already set up `arena`.
    pub fn rebuildPageForResolve(
        self: *Engine,
        report: *Report,
        props: Props,
        note_id: []const u8,
        page_id: []const u8,
        content: []const u8,
    ) Error!void {
        return self.rebuildPage(report, props, note_id, page_id, content);
    }

    pub fn createRemoteForResolve(
        self: *Engine,
        report: *Report,
        props: Props,
        database_id: []const u8,
        note_id: []const u8,
    ) Error!void {
        return self.doCreateRemote(report, props, database_id, .{
            .note_id = note_id,
            .page_id = null,
            .title = "",
            .action = .create_remote,
        });
    }

    /// Take the remote version outright. No `expect_local` guard: the user has
    /// looked at both sides, so a newer local save loses on purpose.
    pub fn pullForResolve(
        self: *Engine,
        report: *Report,
        note_id: []const u8,
        page_id: []const u8,
    ) Error!void {
        const parsed = try Endpoints.retrievePage(self.api, self.a(), page_id);
        const page = (try model.parsePage(self.a(), parsed)) orelse return error.BadResponse;
        var fetched = try self.fetchRendered(page);
        defer fetched.deinit(self.gpa);
        try self.applyPull(report, note_id, page, &fetched, null);
    }

    fn findCached(blocks: []const model.CachedBlock, id: []const u8) ?model.CachedBlock {
        for (blocks) |b| {
            if (std.mem.eql(u8, b.block_id, id)) return b;
        }
        return null;
    }

    fn childIds(self: *Engine, page_id: []const u8) Error![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const parsed = try Endpoints.listChildren(self.api, self.a(), page_id, cursor);
            const results = switch (parsed) {
                .object => |o| o.get("results") orelse break,
                else => break,
            };
            if (results != .array) break;
            for (results.array.items) |block| {
                if (idOf(block)) |id| try out.append(self.a(), id);
            }
            const has_more = switch (parsed) {
                .object => |o| o.get("has_more"),
                else => null,
            };
            if (!(has_more != null and has_more.? == .bool and has_more.?.bool)) break;
            const next = switch (parsed) {
                .object => |o| o.get("next_cursor"),
                else => null,
            };
            cursor = if (next != null and next.? == .string) next.?.string else break;
        }
        return out.toOwnedSlice(self.a());
    }

    /// Roll a partial append back by removing anything not in `keep`.
    fn discardBlocksNotIn(self: *Engine, page_id: []const u8, keep: []const []const u8) Error!void {
        const current = try self.childIds(page_id);
        for (current) |id| {
            var kept = false;
            for (keep) |k| {
                if (std.mem.eql(u8, k, id)) kept = true;
            }
            if (kept) continue;
            _ = Endpoints.deleteBlock(self.api, self.a(), id) catch continue;
        }
    }

    const WriteBack = struct { rewritten: bool, mtime_ms: i64, raced: bool };

    /// Write the pushed markdown back, rewriting placeholder ids.
    ///
    /// `raced` means the file changed while the push was in flight: the user's
    /// newer text is kept, but the baseline still describes what went to Notion
    /// so the edit stays queued for the next run.
    fn writeBack(self: *Engine, note_id: []const u8, original: []const u8, pushed: []const u8) Error!WriteBack {
        const path = self.ws.notePath(note_id);
        const current = try self.ws.fs.readOrEmpty(self.a(), path.slice());
        const raced = !std.mem.eql(u8, current, original);

        if (std.mem.eql(u8, current, pushed)) {
            const meta = self.ws.fs.statMeta(path.slice()) catch
                db.fsx.Meta{ .mtime_ms = 0, .size = 0 };
            return .{ .rewritten = false, .mtime_ms = meta.mtime_ms, .raced = raced };
        }
        if (raced) {
            // Keep the user's newer text; only report the race.
            const meta = self.ws.fs.statMeta(path.slice()) catch
                db.fsx.Meta{ .mtime_ms = 0, .size = 0 };
            return .{ .rewritten = false, .mtime_ms = meta.mtime_ms, .raced = true };
        }

        const title = db.workspace.firstLineTitle(pushed, db.workspace.default_title);
        const meta = try self.ws.applyRemoteContent(note_id, pushed, title);
        return .{ .rewritten = true, .mtime_ms = meta.mtime_ms, .raced = false };
    }

    fn doCreateRemote(
        self: *Engine,
        report: *Report,
        props: Props,
        database_id: []const u8,
        task: Task,
    ) Error!void {
        const note_id = task.note_id orelse return;
        const content = try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
        const title = db.workspace.firstLineTitle(content, db.workspace.default_title);

        const row = findRow(try store.listNoteRows(self.ws, self.a()), note_id);
        const created_ms = if (row) |r| r.created_ms else 0;
        const mtime_ms = if (row) |r| r.mtime_ms else 0;

        const payload = try props.payload(self.a(), title, created_ms, mtime_ms, note_id);
        const parsed = try Endpoints.createPage(self.api, self.a(), database_id, payload, &.{});
        const page = (try model.parsePage(self.a(), parsed)) orelse return error.BadResponse;

        try store.upsertLink(self.ws, .{ .note_id = note_id, .page_id = page.id });
        // The body goes on through the normal push path, so placeholders and
        // baselines are handled in exactly one place.
        try self.rebuildPage(report, props, note_id, page.id, content);
        try report.push(.created_remote, note_id, page.id, title, null);
    }

    fn doCreateLocal(self: *Engine, report: *Report, task: Task) Error!void {
        const page_id = task.page_id orelse return;

        const parsed = try Endpoints.retrievePage(self.api, self.a(), page_id);
        const page = (try model.parsePage(self.a(), parsed)) orelse return error.BadResponse;

        var fetched = try self.fetchRendered(page);
        defer fetched.deinit(self.gpa);

        const note = try self.ws.createNote();
        defer note.deinit(self.gpa);

        const title = db.workspace.firstLineTitle(fetched.markdown, db.workspace.default_title);
        _ = try self.ws.applyRemoteContent(note.id, fetched.markdown, title);
        try store.replaceBlocks(self.ws, note.id, fetched.unsupported);

        const meta = self.ws.fs.statMeta(self.ws.notePath(note.id).slice()) catch
            db.fsx.Meta{ .mtime_ms = 0, .size = 0 };

        try store.upsertLink(self.ws, .{
            .note_id = note.id,
            .page_id = page.id,
            .base_local_hash = &fetched.hash,
            .base_local_mtime_ms = meta.mtime_ms,
            .base_remote_hash = &fetched.hash,
            .base_remote_edited = page.last_edited_time,
            .last_synced_ms = self.nowMs(),
            .push_mode = fetched.push_mode,
        });

        try report.noteChanged(note.id);
        try report.push(.created_local, note.id, page.id, title, null);
    }

    fn doArchiveRemote(self: *Engine, report: *Report, task: Task) Error!void {
        const page_id = task.page_id orelse return;
        _ = try Endpoints.updatePage(self.api, self.a(), page_id, null, true);
        if (task.note_id) |note_id| try store.deleteLink(self.ws, note_id);
        try report.push(.archived_remote, task.note_id, page_id, task.title, null);
    }

    fn doTrashLocal(self: *Engine, report: *Report, task: Task) Error!void {
        const note_id = task.note_id orelse return;
        try self.ws.trashNote(note_id, self.nowMs());
        try store.deleteLink(self.ws, note_id);
        try report.push(.trashed_local, note_id, task.page_id, task.title, null);
    }

    /// Re-attach a page to the note whose id it carries.
    fn doAdopt(self: *Engine, report: *Report, props: Props, task: Task) Error!void {
        const note_id = task.note_id orelse return;
        const page_id = task.page_id orelse return;

        try store.upsertLink(self.ws, .{ .note_id = note_id, .page_id = page_id });
        // Re-linking two sides that have diverged must raise a conflict, not
        // silently pick one, so this goes through stage two.
        try self.settleMaybePull(report, props, .{
            .note_id = note_id,
            .page_id = page_id,
            .title = task.title,
            .action = .maybe_pull,
        });
    }

    fn doUpdateProps(self: *Engine, props: Props, task: Task) Error!void {
        const note_id = task.note_id orelse return;
        const page_id = task.page_id orelse return;

        const content = try self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice());
        const title = db.workspace.firstLineTitle(content, db.workspace.default_title);
        const row = findRow(try store.listNoteRows(self.ws, self.a()), note_id);

        const payload = try props.payload(
            self.a(),
            title,
            if (row) |r| r.created_ms else 0,
            if (row) |r| r.mtime_ms else 0,
            note_id,
        );
        const res = try Endpoints.updatePage(self.api, self.a(), page_id, payload, null);

        // Our own write moved the timestamp; rebase so the next run does not
        // read it as a remote edit.
        if (try model.parsePage(self.a(), res)) |page| {
            var link = (try store.getLink(self.ws, self.a(), note_id)) orelse return;
            link.base_remote_edited = page.last_edited_time;
            link.last_synced_ms = self.nowMs();
            try store.upsertLink(self.ws, link);
        }
    }

    /// Snapshot both sides and freeze the note until the user decides.
    fn recordConflict(
        self: *Engine,
        report: *Report,
        task: Task,
        kind: classify.ConflictKind,
        local_content: ?[]const u8,
        remote_content: ?[]const u8,
    ) Error!void {
        const note_id = task.note_id orelse return;

        const local = local_content orelse
            self.ws.fs.readOrEmpty(self.a(), self.ws.notePath(note_id).slice()) catch null;

        try store.upsertConflict(self.ws, .{
            .note_id = note_id,
            .page_id = task.page_id,
            .kind = kind.toString(),
            .local_content = local,
            .remote_content = remote_content,
            .local_title = task.title,
            .remote_title = task.title,
            .detected_ms = self.nowMs(),
        });
        // Freezing is what keeps every later sync from touching either side.
        try store.setLinkState(self.ws, note_id, "conflict", null);
        try report.push(.conflict, note_id, task.page_id, task.title, kind.toString());
    }
};
