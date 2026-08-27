//! The Notion HTTP client.
//!
//! Ported from `src-tauri/src/notion/client.rs`.
//!
//! The Rust version defined an 11-method async trait so tests could substitute
//! a fake. Here the seam is a single `Transport.send` -- every Notion call is
//! one JSON request, so one function covers all of them, and the fake becomes a
//! small dispatcher on (method, path) rather than eleven overrides. The typed
//! API sits on top as ordinary functions.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;

pub const api_base = "https://api.notion.com/v1";
pub const notion_version = "2022-06-28";

/// Notion's published budget is about 3 requests per second averaged; staying
/// just under it keeps normal-sized workspaces off the 429 path entirely.
pub const min_interval_ms: i64 = 340;
pub const request_timeout_ms: i64 = 30_000;
pub const max_retries: u32 = 3;
/// Notion rejects `append_children` payloads longer than this.
pub const append_chunk: usize = 100;

/// Byte ceiling for one request body.
///
/// Notion's limit is 500 KB and it answers an oversized body with 413 rather
/// than a validation error, so there is nothing useful to retry on. A hundred
/// blocks is small when the note is a checklist and far over the limit when it
/// is prose, so the block count alone cannot bound a request; the headroom is
/// for the JSON envelope around the blocks and for HTTP's own framing.
pub const max_body_bytes: usize = 400 * 1024;

/// Encoded size of a value, without keeping the bytes.
pub fn jsonSize(v: Value) usize {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(v, .{}, &discarding.writer) catch
        return std.math.maxInt(usize);
    return @intCast(discarding.fullCount());
}
/// A title is a rich_text run like any other, and capped the same way.
pub const title_limit: usize = 2000;

pub const Error = error{
    OutOfMemory,
    Transport,
    /// Notion answered with an error status. See `Client.last_error`.
    NotionError,
    BadResponse,
    Cancelled,
};

pub const Method = enum {
    get,
    post,
    patch,
    delete,

    fn toHttp(self: Method) std.http.Method {
        return switch (self) {
            .get => .GET,
            .post => .POST,
            .patch => .PATCH,
            .delete => .DELETE,
        };
    }
};

pub const Response = struct {
    status: u16,
    /// Owned by the caller.
    body: []u8,

    pub fn deinit(self: Response, gpa: Allocator) void {
        gpa.free(self.body);
    }

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// The seam between the sync engine and the network.
pub const Transport = struct {
    ptr: *anyopaque,
    sendFn: *const fn (
        ptr: *anyopaque,
        gpa: Allocator,
        method: Method,
        path: []const u8,
        body: ?[]const u8,
    ) Error!Response,

    pub fn send(
        self: Transport,
        gpa: Allocator,
        method: Method,
        path: []const u8,
        body: ?[]const u8,
    ) Error!Response {
        return self.sendFn(self.ptr, gpa, method, path, body);
    }
};

/// Exponential backoff: 1, 2, 4, 8, 16 seconds.
pub fn backoffMs(attempt: u32) i64 {
    const shift: u6 = @intCast(@min(attempt -| 1, 4));
    return @as(i64, 1000) << shift;
}

// -- the real transport ------------------------------------------------------

pub const Http = struct {
    gpa: Allocator,
    io: std.Io,
    client: std.http.Client,
    token: []u8,
    /// When the next request may go out, in epoch milliseconds.
    next_allowed_ms: i64 = 0,
    /// Set to true from another thread to abandon a sync in progress.
    cancelled: *std.atomic.Value(bool),
    /// Notion's own message from the last error status, for reporting.
    last_message: std.ArrayList(u8) = .empty,
    last_status: u16 = 0,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        token: []const u8,
        cancelled: *std.atomic.Value(bool),
    ) !Http {
        return .{
            .gpa = gpa,
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .token = try gpa.dupe(u8, token),
            .cancelled = cancelled,
        };
    }

    pub fn deinit(self: *Http) void {
        self.client.deinit();
        self.gpa.free(self.token);
        self.last_message.deinit(self.gpa);
    }

    pub fn transport(self: *Http) Transport {
        return .{ .ptr = self, .sendFn = sendImpl };
    }

    fn nowMs(self: *Http) i64 {
        return @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn sleepMs(self: *Http, ms: i64) Error!void {
        if (ms <= 0) return;
        std.Io.sleep(
            self.io,
            .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
            .awake,
        ) catch return error.Cancelled;
    }

    /// Hold off until the rate-limit window opens.
    fn throttle(self: *Http) Error!void {
        const now = self.nowMs();
        if (now < self.next_allowed_ms) try self.sleepMs(self.next_allowed_ms - now);
        self.next_allowed_ms = self.nowMs() + min_interval_ms;
    }

    fn sendImpl(
        ptr: *anyopaque,
        gpa: Allocator,
        method: Method,
        path: []const u8,
        body: ?[]const u8,
    ) Error!Response {
        const self: *Http = @ptrCast(@alignCast(ptr));

        const url = std.fmt.allocPrint(gpa, "{s}{s}", .{ api_base, path }) catch
            return error.OutOfMemory;
        defer gpa.free(url);

        const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{self.token}) catch
            return error.OutOfMemory;
        defer gpa.free(auth);

        var attempt: u32 = 0;
        while (true) {
            if (self.cancelled.load(.seq_cst)) return error.Cancelled;
            try self.throttle();

            const result = self.once(gpa, method, url, auth, body) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                // Transport errors (DNS, TLS, timeouts) are worth another shot;
                // a persistently offline machine still fails fast.
                if (attempt < max_retries) {
                    attempt += 1;
                    try self.sleepMs(backoffMs(attempt));
                    continue;
                }
                return error.Transport;
            };

            if (result.response.ok()) return result.response;

            if (result.response.status == 429 and attempt < max_retries) {
                defer result.response.deinit(gpa);
                attempt += 1;
                const wait = result.retry_after_ms orelse backoffMs(attempt);
                try self.sleepMs(wait);
                continue;
            }
            if (result.response.status >= 500 and attempt < max_retries) {
                defer result.response.deinit(gpa);
                attempt += 1;
                try self.sleepMs(backoffMs(attempt));
                continue;
            }
            // A 4xx (bad token, unshared database, malformed block) will not get
            // better by retrying. Surface Notion's own message.
            return result.response;
        }
    }

    const Once = struct { response: Response, retry_after_ms: ?i64 };

    /// One HTTP round trip. The error set is left inferred except for the
    /// cancellation the throttle can raise, which callers distinguish from a
    /// transport failure.
    fn once(
        self: *Http,
        gpa: Allocator,
        method: Method,
        url: []const u8,
        auth: []const u8,
        body: ?[]const u8,
    ) !Once {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(method.toHttp(), uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "Notion-Version", .value = notion_version },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var writer = try req.sendBody(&.{});
            try writer.writer.writeAll(payload);
            try writer.end();
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var retry_after_ms: ?i64 = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
                if (std.fmt.parseInt(i64, std.mem.trim(u8, h.value, " "), 10)) |secs| {
                    retry_after_ms = secs * 1000;
                } else |_| {}
            }
        }

        var transfer_buffer: [16384]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        var chunk: [16384]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(gpa, chunk[0..n]);
        }

        return .{
            .response = .{
                .status = @intFromEnum(response.head.status),
                .body = try out.toOwnedSlice(gpa),
            },
            .retry_after_ms = retry_after_ms,
        };
    }
};

// -- the typed API -----------------------------------------------------------

pub const Client = struct {
    gpa: Allocator,
    transport: Transport,
    /// Populated when a call fails with a Notion error status.
    last_status: u16 = 0,
    last_message: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, transport: Transport) Client {
        return .{ .gpa = gpa, .transport = transport };
    }

    pub fn deinit(self: *Client) void {
        self.last_message.deinit(self.gpa);
    }

    pub fn errorMessage(self: *const Client) []const u8 {
        return self.last_message.items;
    }

    fn recordError(self: *Client, status: u16, body: []const u8) void {
        self.last_status = status;
        self.last_message.clearRetainingCapacity();

        // Notion puts a human-readable explanation in `message`; fall back to
        // the raw body when it does not.
        if (std.json.parseFromSlice(Value, self.gpa, body, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("message")) |m| {
                    if (m == .string) {
                        self.last_message.appendSlice(self.gpa, m.string) catch {};
                        return;
                    }
                }
            }
        } else |_| {}
        self.last_message.appendSlice(self.gpa, body) catch {};
    }

    /// One request, parsed into `arena`.
    ///
    /// The result borrows from the arena rather than carrying its own, because
    /// callers keep references into a response long after the call -- a block
    /// tree is walked, spliced and re-rendered. Tying every response to one
    /// per-run arena removes that lifetime question entirely.
    pub fn call(
        self: *Client,
        arena: Allocator,
        method: Method,
        path: []const u8,
        body: ?Value,
    ) Error!Value {
        var payload: ?[]u8 = null;
        if (body) |b| {
            payload = std.json.Stringify.valueAlloc(arena, b, .{}) catch
                return error.OutOfMemory;
        }

        const response = try self.transport.send(self.gpa, method, path, payload);
        defer response.deinit(self.gpa);

        if (!response.ok()) {
            self.recordError(response.status, response.body);
            return error.NotionError;
        }
        // A 204 (delete_block) has no body.
        if (response.body.len == 0) return .{ .object = .empty };

        return std.json.parseFromSliceLeaky(Value, arena, response.body, .{}) catch
            return error.BadResponse;
    }
};

// -- the Notion endpoints ----------------------------------------------------
//
// Each returns a `Parsed(Value)` the caller owns. Typed extraction lives in
// `model.zig`, so the wire shape is described in exactly one place.

pub const Endpoints = struct {
    /// `GET /users/me` -- who the integration token belongs to.
    pub fn me(c: *Client, arena: Allocator) Error!Value {
        return c.call(arena, .get, "/users/me", null);
    }

    /// `POST /search` filtered to databases. A database that has not been
    /// shared with the integration is invisible here, which is the usual reason
    /// the picker comes back empty.
    pub fn searchDatabases(c: *Client, arena: Allocator) Error!Value {
        const body = obj(arena, &.{
            .{ "filter", try obj(arena, &.{
                .{ "property", .{ .string = "object" } },
                .{ "value", .{ .string = "database" } },
            }) },
            .{ "page_size", .{ .integer = 100 } },
        }) catch return error.OutOfMemory;
        return c.call(arena, .post, "/search", body);
    }

    pub fn retrieveDatabase(c: *Client, arena: Allocator, id: []const u8) Error!Value {
        const path = std.fmt.allocPrint(arena, "/databases/{s}", .{id}) catch
            return error.OutOfMemory;
        return c.call(arena, .get, path, null);
    }

    pub fn queryDatabase(
        c: *Client,
        arena: Allocator,
        id: []const u8,
        cursor: ?[]const u8,
    ) Error!Value {
        const path = std.fmt.allocPrint(arena, "/databases/{s}/query", .{id}) catch
            return error.OutOfMemory;
        var pairs: std.ArrayList(struct { []const u8, Value }) = .empty;
        pairs.append(arena, .{ "page_size", .{ .integer = 100 } }) catch
            return error.OutOfMemory;
        if (cursor) |cur| {
            pairs.append(arena, .{ "start_cursor", .{ .string = cur } }) catch
                return error.OutOfMemory;
        }
        const body = obj(arena, pairs.items) catch return error.OutOfMemory;
        return c.call(arena, .post, path, body);
    }

    pub fn retrievePage(c: *Client, arena: Allocator, id: []const u8) Error!Value {
        const path = std.fmt.allocPrint(arena, "/pages/{s}", .{id}) catch
            return error.OutOfMemory;
        return c.call(arena, .get, path, null);
    }

    pub fn listChildren(
        c: *Client,
        arena: Allocator,
        block: []const u8,
        cursor: ?[]const u8,
    ) Error!Value {
        const path = if (cursor) |cur|
            std.fmt.allocPrint(arena, "/blocks/{s}/children?page_size=100&start_cursor={s}", .{ block, cur }) catch
                return error.OutOfMemory
        else
            std.fmt.allocPrint(arena, "/blocks/{s}/children?page_size=100", .{block}) catch
                return error.OutOfMemory;
        return c.call(arena, .get, path, null);
    }

    /// One chunk of at most `append_chunk` children. The response preserves
    /// payload order, which is what lets a caller map new block ids back onto
    /// the placeholders it sent.
    pub fn appendChildren(
        c: *Client,
        arena: Allocator,
        block: []const u8,
        children: []const Value,
    ) Error!Value {
        const path = std.fmt.allocPrint(arena, "/blocks/{s}/children", .{block}) catch
            return error.OutOfMemory;
        const body = obj(arena, &.{
            .{ "children", arr(arena, children) catch return error.OutOfMemory },
        }) catch return error.OutOfMemory;
        return c.call(arena, .patch, path, body);
    }

    pub fn deleteBlock(c: *Client, arena: Allocator, block: []const u8) Error!Value {
        const path = std.fmt.allocPrint(arena, "/blocks/{s}", .{block}) catch
            return error.OutOfMemory;
        return c.call(arena, .delete, path, null);
    }

    pub fn createPage(
        c: *Client,
        arena: Allocator,
        database_id: []const u8,
        properties: Value,
        children: []const Value,
    ) Error!Value {
        const body = obj(arena, &.{
            .{ "parent", obj(arena, &.{.{ "database_id", .{ .string = database_id } }}) catch
                return error.OutOfMemory },
            .{ "properties", properties },
            .{ "children", arr(arena, children) catch return error.OutOfMemory },
        }) catch return error.OutOfMemory;
        return c.call(arena, .post, "/pages", body);
    }

    pub fn updatePage(
        c: *Client,
        arena: Allocator,
        page: []const u8,
        properties: ?Value,
        archived: ?bool,
    ) Error!Value {
        const path = std.fmt.allocPrint(arena, "/pages/{s}", .{page}) catch
            return error.OutOfMemory;
        var pairs: std.ArrayList(struct { []const u8, Value }) = .empty;
        if (properties) |p| pairs.append(arena, .{ "properties", p }) catch
            return error.OutOfMemory;
        if (archived) |a| pairs.append(arena, .{ "archived", .{ .bool = a } }) catch
            return error.OutOfMemory;
        const body = obj(arena, pairs.items) catch return error.OutOfMemory;
        return c.call(arena, .patch, path, body);
    }

    /// Add properties to the database schema, used to create the timestamp
    /// columns when they do not exist yet.
    pub fn addDatabaseProperties(
        c: *Client,
        arena: Allocator,
        database_id: []const u8,
        properties: Value,
    ) Error!Value {
        const path = std.fmt.allocPrint(arena, "/databases/{s}", .{database_id}) catch
            return error.OutOfMemory;
        const body = obj(arena, &.{.{ "properties", properties }}) catch
            return error.OutOfMemory;
        return c.call(arena, .patch, path, body);
    }
};

/// A `date` column definition, for `addDatabaseProperties`.
pub fn dateColumnSpec(arena: Allocator, name: []const u8) !Value {
    return obj(arena, &.{.{ name, try obj(arena, &.{.{ "date", try obj(arena, &.{}) }}) }});
}

/// A `rich_text` column definition.
pub fn textColumnSpec(arena: Allocator, name: []const u8) !Value {
    return obj(arena, &.{.{ name, try obj(arena, &.{.{ "rich_text", try obj(arena, &.{}) }}) }});
}

// -- property builders -------------------------------------------------------

fn obj(arena: Allocator, pairs: []const struct { []const u8, Value }) !Value {
    var map: std.json.ObjectMap = .empty;
    for (pairs) |pair| try map.put(arena, pair[0], pair[1]);
    return .{ .object = map };
}

fn arr(arena: Allocator, items: []const Value) !Value {
    var list = std.json.Array.init(arena);
    try list.appendSlice(items);
    return .{ .array = list };
}

/// Truncate to at most `max` code points, never splitting one.
fn truncateChars(s: []const u8, max: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < max) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + len > s.len) break;
        i += len;
    }
    return s[0..i];
}

pub fn titleProperty(arena: Allocator, title_prop: []const u8, title: []const u8) !Value {
    const trimmed = truncateChars(title, title_limit);
    return obj(arena, &.{.{ title_prop, try obj(arena, &.{
        .{ "title", try arr(arena, &.{try obj(arena, &.{
            .{ "type", .{ .string = "text" } },
            .{ "text", try obj(arena, &.{.{ "content", .{ .string = trimmed } }}) },
        })}) },
    }) }});
}

/// A `date` property carrying a single instant. No end and no time zone field:
/// the timestamp itself is UTC.
pub fn dateProperty(arena: Allocator, name: []const u8, ms: i64) !Value {
    const iso = try model.msToIso8601(arena, ms);
    return obj(arena, &.{.{ name, try obj(arena, &.{
        .{ "date", try obj(arena, &.{.{ "start", .{ .string = iso } }}) },
    }) }});
}

pub fn textProperty(arena: Allocator, name: []const u8, text: []const u8) !Value {
    return obj(arena, &.{.{ name, try obj(arena, &.{
        .{ "rich_text", try arr(arena, &.{try obj(arena, &.{
            .{ "type", .{ .string = "text" } },
            .{ "text", try obj(arena, &.{.{ "content", .{ .string = text } }}) },
        })}) },
    }) }});
}

/// Shallow merge of property objects, as the Notion API expects them.
pub fn mergeProperties(arena: Allocator, parts: []const Value) !Value {
    var map: std.json.ObjectMap = .empty;
    for (parts) |part| {
        if (part != .object) continue;
        var it = part.object.iterator();
        while (it.next()) |entry| try map.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .object = map };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "backoff grows and then caps" {
    try testing.expectEqual(@as(i64, 1000), backoffMs(1));
    try testing.expectEqual(@as(i64, 2000), backoffMs(2));
    try testing.expectEqual(@as(i64, 4000), backoffMs(3));
    try testing.expectEqual(@as(i64, 8000), backoffMs(4));
    try testing.expectEqual(@as(i64, 16000), backoffMs(5));
    // Capped, so a long outage does not push the wait into hours.
    try testing.expectEqual(@as(i64, 16000), backoffMs(9));
    try testing.expectEqual(@as(i64, 1000), backoffMs(0));
}

test "the title property is named and capped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try titleProperty(arena, "Heading", "My Note");
    const content = v.object.get("Heading").?.object.get("title").?.array
        .items[0].object.get("text").?.object.get("content").?.string;
    try testing.expectEqualStrings("My Note", content);

    var long: std.ArrayList(u8) = .empty;
    for (0..2500) |_| try long.appendSlice(arena, "가");
    const capped = try titleProperty(arena, "Name", long.items);
    const text = capped.object.get("Name").?.object.get("title").?.array
        .items[0].object.get("text").?.object.get("content").?.string;
    try testing.expectEqual(@as(usize, title_limit), try std.unicode.utf8CountCodepoints(text));
    // And never mid-syllable.
    try testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "date properties are UTC instants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try dateProperty(arena, "Updated", 1_704_164_645_000);
    const start = v.object.get("Updated").?.object.get("date").?.object.get("start").?.string;
    try testing.expectEqualStrings("2024-01-02T03:04:05.000Z", start);
}

test "properties merge shallowly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const merged = try mergeProperties(arena, &.{
        try titleProperty(arena, "Name", "T"),
        try dateProperty(arena, "Updated", 0),
        try textProperty(arena, "Nova Id", "uuid"),
    });
    try testing.expectEqual(@as(usize, 3), merged.object.count());
    try testing.expect(merged.object.get("Name") != null);
    try testing.expect(merged.object.get("Updated") != null);
    try testing.expect(merged.object.get("Nova Id") != null);
}
