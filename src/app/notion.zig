//! Scheduling and running Notion syncs.
//!
//! Ported from `src/lib/notionSync.ts`.
//!
//! A sync makes many HTTP calls, each paced 340 ms apart, so it cannot run on
//! the UI thread. It runs on a worker with **its own workspace handle**: a
//! second SQLite connection to the same file rather than a lock shared with the
//! UI. SQLite serializes the writes itself, the connection's busy timeout
//! absorbs the rare collision, and the editor stays responsive throughout --
//! which a mutex held for the length of a sync would not allow.

const std = @import("std");
const db = @import("db");
const net = @import("net");

const Allocator = std.mem.Allocator;

/// Never sync more often than this, whatever the user sets.
pub const min_interval_sec: i64 = 60;
/// How long after opening a workspace the start-up sync runs.
pub const startup_delay_ms: i64 = 2000;

pub const State = enum(u8) { idle, running, finished };

/// What a finished sync produced, handed back to the UI thread.
pub const Outcome = struct {
    gpa: Allocator,
    summary: []u8,
    ok: bool,
    conflicts: usize,
    /// Notes whose files the sync rewrote, so their tabs can be reloaded.
    changed: [][]u8,

    pub fn deinit(self: Outcome) void {
        self.gpa.free(self.summary);
        for (self.changed) |c| self.gpa.free(c);
        self.gpa.free(self.changed);
    }
};

pub const Scheduler = struct {
    gpa: Allocator,
    io: std.Io,

    /// The handoff between the worker and the UI thread.
    ///
    /// One-way and written exactly once per run, so an atomic flag with
    /// release/acquire ordering is enough: the worker publishes `outcome` and
    /// *then* stores `.finished`; the UI observes `.finished` and only then
    /// reads `outcome`. No lock, and no chance of the UI blocking on a sync.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.idle),
    thread: ?std.Thread = null,
    outcome: ?Outcome = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// When the next periodic sync is due.
    next_due_ms: ?i64 = null,
    /// When the one-shot start-up sync is due.
    startup_due_ms: ?i64 = null,
    /// The workspace the start-up sync already ran for, so switching back and
    /// forth does not re-trigger it.
    startup_done_for: ?[]u8 = null,

    pub fn init(gpa: Allocator, io: std.Io) Scheduler {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Scheduler) void {
        self.cancel.store(true, .seq_cst);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.outcome) |o| o.deinit();
        if (self.startup_done_for) |s| self.gpa.free(s);
    }

    pub fn clampInterval(sec: i64) i64 {
        return @max(min_interval_sec, sec);
    }

    /// A workspace was opened. Arms the start-up sync unless it has already run
    /// for this path.
    pub fn workspaceOpened(self: *Scheduler, root: []const u8, now_ms: i64) !void {
        self.next_due_ms = null;
        if (self.startup_done_for) |done| {
            if (std.mem.eql(u8, done, root)) return;
            self.gpa.free(done);
        }
        self.startup_done_for = try self.gpa.dupe(u8, root);
        self.startup_due_ms = now_ms + startup_delay_ms;
    }

    pub fn workspaceClosed(self: *Scheduler) void {
        self.startup_due_ms = null;
        self.next_due_ms = null;
    }

    /// Re-arm after a settings change, so a shorter interval takes effect from
    /// now rather than from the old deadline.
    pub fn rearm(self: *Scheduler, cfg: net.notion.store.Config, now_ms: i64) void {
        if (!cfg.ready() or !cfg.auto_sync) {
            self.next_due_ms = null;
            return;
        }
        self.next_due_ms = now_ms + clampInterval(cfg.interval_sec) * 1000;
    }

    pub fn isRunning(self: *Scheduler) bool {
        return self.state.load(.acquire) == .running;
    }

    /// Whether a sync should start now.
    pub fn due(self: *Scheduler, cfg: net.notion.store.Config, now_ms: i64) bool {
        if (self.isRunning()) return false;
        if (!cfg.ready()) return false;

        if (self.startup_due_ms) |at| {
            if (now_ms >= at) return cfg.sync_on_start;
        }
        if (!cfg.auto_sync) return false;
        if (self.next_due_ms) |at| return now_ms >= at;
        return false;
    }

    /// Collect a finished sync's result, if there is one. Caller owns it.
    pub fn takeOutcome(self: *Scheduler) ?Outcome {
        if (self.state.load(.acquire) != .finished) return null;

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        const result = self.outcome;
        self.outcome = null;
        self.state.store(.idle, .release);
        return result;
    }

    const Job = struct {
        scheduler: *Scheduler,
        root: []u8,
    };

    /// Start a sync on a worker thread.
    ///
    /// `root` is the workspace path; the worker opens its own handle to it.
    pub fn start(self: *Scheduler, root: []const u8, cfg: net.notion.store.Config, now_ms: i64) !void {
        if (self.isRunning()) return;

        self.startup_due_ms = null;
        if (cfg.auto_sync) {
            self.next_due_ms = now_ms + clampInterval(cfg.interval_sec) * 1000;
        }

        const job = try self.gpa.create(Job);
        job.* = .{ .scheduler = self, .root = try self.gpa.dupe(u8, root) };

        self.state.store(.running, .release);
        self.cancel.store(false, .seq_cst);

        self.thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
            self.state.store(.idle, .release);
            self.gpa.free(job.root);
            self.gpa.destroy(job);
            return err;
        };
    }

    pub fn requestCancel(self: *Scheduler) void {
        self.cancel.store(true, .seq_cst);
    }

    fn worker(job: *Job) void {
        const self = job.scheduler;
        const gpa = self.gpa;
        defer {
            gpa.free(job.root);
            gpa.destroy(job);
        }

        const outcome = runOnce(gpa, self.io, job.root, &self.cancel) catch |err| blk: {
            break :blk Outcome{
                .gpa = gpa,
                .summary = std.fmt.allocPrint(gpa, "Notion sync failed: {s}", .{@errorName(err)}) catch
                    gpa.dupe(u8, "Notion sync failed") catch &.{},
                .ok = false,
                .conflicts = 0,
                .changed = gpa.alloc([]u8, 0) catch &.{},
            };
        };

        if (self.outcome) |old| old.deinit();
        self.outcome = outcome;
        // Published last: the UI only reads `outcome` after seeing `.finished`.
        self.state.store(.finished, .release);
    }

    /// One sync, start to finish, on its own workspace handle.
    fn runOnce(
        gpa: Allocator,
        io: std.Io,
        root: []const u8,
        cancel: *std.atomic.Value(bool),
    ) !Outcome {
        var ws = try db.workspace.Workspace.open(gpa, io, root);
        defer ws.close();

        var cfg = try net.notion.store.getConfig(&ws, gpa);
        defer cfg.deinit(gpa);
        const creds = try cfg.credentials();

        var http = try net.notion.client.Http.init(gpa, io, creds.token, cancel);
        defer http.deinit();
        var api = net.notion.client.Client.init(gpa, http.transport());
        defer api.deinit();

        var engine = net.notion.engine.Engine.init(gpa, io, &ws, &api, cancel);
        var report = try engine.run();
        defer report.deinit();

        const status: []const u8 = if (report.cancelled)
            "cancelled"
        else if (report.errors > 0)
            "partial"
        else
            "ok";
        const now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
        try net.notion.store.setLastSync(&ws, now, status);

        var changed = try gpa.alloc([]u8, report.changed_note_ids.items.len);
        for (report.changed_note_ids.items, 0..) |id, i| changed[i] = try gpa.dupe(u8, id);

        return .{
            .gpa = gpa,
            .summary = try report.summarize(gpa),
            .ok = report.errors == 0 and !report.cancelled,
            .conflicts = report.conflicts,
            .changed = changed,
        };
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn testConfig() net.notion.store.Config {
    return .{
        .token = "t",
        .database_id = "db",
        .enabled = true,
        .auto_sync = true,
        .sync_on_start = true,
        .interval_sec = 900,
    };
}

test "the interval never goes below the floor" {
    try testing.expectEqual(min_interval_sec, Scheduler.clampInterval(1));
    try testing.expectEqual(min_interval_sec, Scheduler.clampInterval(-5));
    try testing.expectEqual(@as(i64, 900), Scheduler.clampInterval(900));
}

test "the start-up sync runs once per workspace" {
    var env = try db.fsx.TestEnv.init(testing.allocator, "notion-sched");
    defer env.deinit();

    var s = Scheduler.init(testing.allocator, env.io);
    defer s.deinit();
    const cfg = testConfig();

    try s.workspaceOpened("/ws/a", 0);
    try testing.expect(!s.due(cfg, startup_delay_ms - 1));
    try testing.expect(s.due(cfg, startup_delay_ms));

    // Re-opening the same workspace does not re-arm it.
    s.startup_due_ms = null;
    try s.workspaceOpened("/ws/a", 10_000);
    try testing.expect(!s.due(cfg, 20_000));

    // A different workspace does.
    try s.workspaceOpened("/ws/b", 10_000);
    try testing.expect(s.due(cfg, 10_000 + startup_delay_ms));
}

test "sync_on_start off suppresses the start-up run" {
    var env = try db.fsx.TestEnv.init(testing.allocator, "notion-sched-off");
    defer env.deinit();

    var s = Scheduler.init(testing.allocator, env.io);
    defer s.deinit();
    var cfg = testConfig();
    cfg.sync_on_start = false;

    try s.workspaceOpened("/ws/a", 0);
    try testing.expect(!s.due(cfg, startup_delay_ms + 1000));
}

test "the periodic timer re-arms from now, not from the old deadline" {
    var env = try db.fsx.TestEnv.init(testing.allocator, "notion-rearm");
    defer env.deinit();

    var s = Scheduler.init(testing.allocator, env.io);
    defer s.deinit();
    var cfg = testConfig();

    cfg.interval_sec = 3600;
    s.rearm(cfg, 0);
    try testing.expect(!s.due(cfg, 60_000));

    // A shorter interval takes effect immediately.
    cfg.interval_sec = 60;
    s.rearm(cfg, 60_000);
    try testing.expect(!s.due(cfg, 100_000));
    try testing.expect(s.due(cfg, 120_000));
}

test "an incomplete or disabled config never becomes due" {
    var env = try db.fsx.TestEnv.init(testing.allocator, "notion-idle");
    defer env.deinit();

    var s = Scheduler.init(testing.allocator, env.io);
    defer s.deinit();
    try s.workspaceOpened("/ws/a", 0);

    var no_token = testConfig();
    no_token.token = null;
    try testing.expect(!s.due(no_token, 1_000_000));

    var disabled = testConfig();
    disabled.enabled = false;
    try testing.expect(!s.due(disabled, 1_000_000));

    var manual = testConfig();
    manual.auto_sync = false;
    s.rearm(manual, 0);
    // Manual mode still allows the start-up run, but never a periodic one.
    s.startup_due_ms = null;
    try testing.expect(!s.due(manual, 1_000_000));
}

test "closing a workspace disarms both timers" {
    var env = try db.fsx.TestEnv.init(testing.allocator, "notion-close");
    defer env.deinit();

    var s = Scheduler.init(testing.allocator, env.io);
    defer s.deinit();
    try s.workspaceOpened("/ws/a", 0);
    s.rearm(testConfig(), 0);

    s.workspaceClosed();
    try testing.expect(!s.due(testConfig(), 10_000_000));
}
