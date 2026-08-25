//! An in-memory stand-in for the Notion API.
//!
//! Ported from `src-tauri/src/notion/fake.rs`. It implements `client.Transport`,
//! so the engine under test goes through exactly the same code path as it does
//! against the real API -- the substitution happens at the socket, not at an
//! eleven-method trait.
//!
//! Two behaviors are modelled precisely, because the engine depends on them:
//!
//!   * `append_children` assigns fresh block ids and returns them **in payload
//!     order**, which is how a push maps new ids back onto its placeholders.
//!   * Any mutation bumps `last_edited_time`, which is what makes the "our own
//!     push echoes back as a remote change" case testable at all.

const std = @import("std");
const client = @import("client.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;

pub const Block = struct {
    id: []const u8,
    json: []const u8,
};

pub const Page = struct {
    id: []const u8,
    title: []const u8,
    /// Extra properties beyond the title, as raw JSON objects keyed by name.
    props_json: []const u8 = "{}",
    last_edited: []const u8,
    archived: bool = false,
    blocks: std.ArrayList(Block) = .empty,
};

pub const Fake = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,

    database_id: []const u8 = "db-1",
    database_title: []const u8 = "Mock Notes",
    title_prop: []const u8 = "Name",
    /// Property name -> type, mirroring a real database schema.
    schema: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// When true, writing to a property the schema lacks fails like the real
    /// API rather than being silently accepted.
    reject_unknown_properties: bool = false,

    pages: std.ArrayList(Page) = .empty,
    next_id: usize = 1,
    /// Bumped on every mutation and used as the page timestamp, so "did the
    /// remote move" is deterministic.
    clock: usize = 1,

    /// Fail the nth `append_children` call (1-based). Models Notion rejecting
    /// one malformed block partway through a multi-chunk push.
    fail_append_at: ?usize = null,
    append_calls: usize = 0,

    /// Called once, before the next `listChildren` returns. Models the user
    /// saving the note while a fetch is in flight.
    once_during_fetch: ?*const fn (ctx: *anyopaque) void = null,
    fetch_ctx: ?*anyopaque = null,

    /// Every request the engine made, for assertions.
    calls: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator) Fake {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Fake) void {
        for (self.pages.items) |*p| p.blocks.deinit(self.gpa);
        self.pages.deinit(self.gpa);
        self.schema.deinit(self.gpa);
        self.calls.deinit(self.gpa);
        self.arena.deinit();
    }

    fn a(self: *Fake) Allocator {
        return self.arena.allocator();
    }

    /// Append formatted text. `std.ArrayList` is unmanaged in Zig 0.16 and has
    /// no `writer()`, and everything here is arena-allocated anyway.
    fn put(self: *Fake, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
        try list.appendSlice(self.a(), try std.fmt.allocPrint(self.a(), fmt, args));
    }

    pub fn transport(self: *Fake) client.Transport {
        return .{ .ptr = self, .sendFn = send };
    }

    // -- seeding -------------------------------------------------------------

    pub fn addSchemaProperty(self: *Fake, name: []const u8, ty: []const u8) !void {
        try self.schema.put(self.gpa, try self.a().dupe(u8, name), try self.a().dupe(u8, ty));
    }

    /// Add a page whose body is the given markdown-ish paragraph lines.
    pub fn addPage(self: *Fake, title: []const u8, lines: []const []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.a(), "page-{d}", .{self.next_id});
        self.next_id += 1;

        var page = Page{
            .id = id,
            .title = try self.a().dupe(u8, title),
            .last_edited = try self.stamp(),
        };
        for (lines) |line| {
            const block_id = try std.fmt.allocPrint(self.a(), "block-{d}", .{self.next_id});
            self.next_id += 1;
            try page.blocks.append(self.gpa, .{
                .id = block_id,
                .json = try self.paragraphJson(line),
            });
        }
        try self.pages.append(self.gpa, page);
        return id;
    }

    /// Exposed so tests can edit a page's blocks directly.
    pub fn paragraphJsonPublic(self: *Fake, text: []const u8) ![]const u8 {
        return self.paragraphJson(text);
    }

    /// Exposed so tests can move a page's timestamp.
    pub fn stampPublic(self: *Fake) ![]const u8 {
        return self.stamp();
    }

    fn paragraphJson(self: *Fake, text: []const u8) ![]const u8 {
        const escaped = try std.json.Stringify.valueAlloc(self.a(), Value{ .string = text }, .{});
        return std.fmt.allocPrint(
            self.a(),
            "{{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{{\"rich_text\":[{{\"type\":\"text\",\"text\":{{\"content\":{s}}}}}]}}}}",
            .{escaped},
        );
    }

    fn stamp(self: *Fake) ![]const u8 {
        self.clock += 1;
        return std.fmt.allocPrint(self.a(), "2024-01-01T00:00:{d:0>2}.000Z", .{self.clock});
    }

    pub fn findPage(self: *Fake, id: []const u8) ?*Page {
        for (self.pages.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    /// The page's body as plain text, one line per paragraph block.
    pub fn pageText(self: *Fake, gpa: Allocator, id: []const u8) ![]u8 {
        const page = self.findPage(id) orelse return gpa.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (page.blocks.items) |b| {
            const parsed = std.json.parseFromSlice(Value, gpa, b.json, .{}) catch continue;
            defer parsed.deinit();
            const para = switch (parsed.value) {
                .object => |o| o.get("paragraph") orelse continue,
                else => continue,
            };
            const rt = switch (para) {
                .object => |o| o.get("rich_text") orelse continue,
                else => continue,
            };
            const text = try model.richTextPlain(gpa, rt);
            defer gpa.free(text);
            try out.appendSlice(gpa, text);
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    // -- transport -----------------------------------------------------------

    fn respond(self: *Fake, gpa: Allocator, status: u16, body: []const u8) !client.Response {
        _ = self;
        return .{ .status = status, .body = try gpa.dupe(u8, body) };
    }

    fn send(
        ptr: *anyopaque,
        gpa: Allocator,
        method: client.Method,
        path: []const u8,
        body: ?[]const u8,
    ) client.Error!client.Response {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.calls.append(self.gpa, self.a().dupe(u8, path) catch return error.OutOfMemory) catch
            return error.OutOfMemory;

        // The fake only ever fails on allocation; anything else would be a bug
        // in the fake itself rather than a simulated network fault.
        return self.route(gpa, method, path, body) catch error.OutOfMemory;
    }

    fn route(
        self: *Fake,
        gpa: Allocator,
        method: client.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !client.Response {
        if (std.mem.eql(u8, path, "/users/me")) {
            return self.respond(gpa, 200,
                \\{"name":"Nova Bot","bot":{"workspace_name":"Test Workspace"}}
            );
        }
        if (std.mem.eql(u8, path, "/search")) return self.searchDatabases(gpa);
        if (std.mem.startsWith(u8, path, "/databases/")) {
            const rest = path["/databases/".len..];
            if (std.mem.endsWith(u8, rest, "/query")) return self.queryDatabase(gpa);
            if (method == .patch) return self.patchDatabase(gpa, body);
            return self.retrieveDatabase(gpa);
        }
        if (std.mem.startsWith(u8, path, "/pages")) return self.pagesRoute(gpa, method, path, body);
        if (std.mem.startsWith(u8, path, "/blocks/")) return self.blocksRoute(gpa, method, path, body);
        return self.respond(gpa, 404, "{\"message\":\"no route\"}");
    }

    fn searchDatabases(self: *Fake, gpa: Allocator) !client.Response {
        const json = try std.fmt.allocPrint(
            self.a(),
            "{{\"results\":[{{\"id\":\"{s}\",\"title\":[{{\"plain_text\":\"{s}\"}}],\"url\":null}}],\"has_more\":false}}",
            .{ self.database_id, self.database_title },
        );
        return self.respond(gpa, 200, json);
    }

    fn retrieveDatabase(self: *Fake, gpa: Allocator) !client.Response {
        var props: std.ArrayList(u8) = .empty;
        try self.put(&props, "{{\"{s}\":{{\"type\":\"title\"}}", .{self.title_prop});
        var it = self.schema.iterator();
        while (it.next()) |entry| {
            try self.put(&props, ",\"{s}\":{{\"type\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try props.appendSlice(self.a(), "}");

        const json = try std.fmt.allocPrint(
            self.a(),
            "{{\"id\":\"{s}\",\"title\":[{{\"plain_text\":\"{s}\"}}],\"properties\":{s}}}",
            .{ self.database_id, self.database_title, props.items },
        );
        return self.respond(gpa, 200, json);
    }

    fn patchDatabase(self: *Fake, gpa: Allocator, body: ?[]const u8) !client.Response {
        // Adding columns to the schema.
        if (body) |raw| {
            const parsed = std.json.parseFromSlice(Value, self.gpa, raw, .{}) catch
                return self.respond(gpa, 400, "{\"message\":\"bad json\"}");
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("properties")) |props| {
                    if (props == .object) {
                        var it = props.object.iterator();
                        while (it.next()) |entry| {
                            const spec = entry.value_ptr.*;
                            const ty: []const u8 = blk: {
                                if (spec == .object) {
                                    if (spec.object.get("date") != null) break :blk "date";
                                    if (spec.object.get("rich_text") != null) break :blk "rich_text";
                                }
                                break :blk "rich_text";
                            };
                            try self.addSchemaProperty(entry.key_ptr.*, ty);
                        }
                    }
                }
            }
        }
        return self.retrieveDatabase(gpa);
    }

    fn pageJson(self: *Fake, page: *const Page) ![]const u8 {
        const escaped = try std.json.Stringify.valueAlloc(self.a(), Value{ .string = page.title }, .{});

        // Merge the title property with whatever else the page carries.
        const extra = if (std.mem.eql(u8, page.props_json, "{}"))
            ""
        else
            page.props_json[1 .. page.props_json.len - 1];
        const sep: []const u8 = if (extra.len > 0) "," else "";

        return std.fmt.allocPrint(
            self.a(),
            "{{\"id\":\"{s}\",\"last_edited_time\":\"{s}\",\"created_time\":\"2024-01-01T00:00:00.000Z\"," ++
                "\"archived\":{s},\"properties\":{{\"{s}\":{{\"type\":\"title\",\"title\":[{{\"plain_text\":{s}}}]}}{s}{s}}}}}",
            .{
                page.id,
                page.last_edited,
                if (page.archived) "true" else "false",
                self.title_prop,
                escaped,
                sep,
                extra,
            },
        );
    }

    fn queryDatabase(self: *Fake, gpa: Allocator) !client.Response {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a(), "{\"results\":[");
        for (self.pages.items, 0..) |*p, i| {
            if (i > 0) try out.appendSlice(self.a(), ",");
            try out.appendSlice(self.a(), try self.pageJson(p));
        }
        try out.appendSlice(self.a(), "],\"has_more\":false,\"next_cursor\":null}");
        return self.respond(gpa, 200, out.items);
    }

    fn pagesRoute(
        self: *Fake,
        gpa: Allocator,
        method: client.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !client.Response {
        if (std.mem.eql(u8, path, "/pages")) return self.createPage(gpa, body);

        const id = path["/pages/".len..];
        const page = self.findPage(id) orelse
            return self.respond(gpa, 404, "{\"message\":\"page not found\"}");

        if (method == .patch) {
            const parsed = if (body) |raw|
                std.json.parseFromSlice(Value, self.gpa, raw, .{}) catch null
            else
                null;
            defer if (parsed) |p| p.deinit();

            if (parsed) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("archived")) |arch| {
                        if (arch == .bool) page.archived = arch.bool;
                    }
                    if (p.value.object.get("properties")) |props| {
                        if (try self.applyProperties(page, props)) |rejection| {
                            return self.respond(gpa, 400, rejection);
                        }
                    }
                }
            }
            page.last_edited = try self.stamp();
        }
        return self.respond(gpa, 200, try self.pageJson(page));
    }

    /// Returns an error body when a property is not in the schema.
    fn applyProperties(self: *Fake, page: *Page, props: Value) !?[]const u8 {
        if (props != .object) return null;

        var extras: std.ArrayList(u8) = .empty;
        try extras.appendSlice(self.a(), "{");
        var first = true;

        var it = props.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.eql(u8, name, self.title_prop)) {
                const title = try model.richTextPlain(self.a(), switch (entry.value_ptr.*) {
                    .object => |o| o.get("title"),
                    else => null,
                });
                page.title = title;
                continue;
            }
            if (self.reject_unknown_properties and !self.schema.contains(name)) {
                return try std.fmt.allocPrint(
                    self.a(),
                    "{{\"message\":\"{s} is not a property that exists\"}}",
                    .{name},
                );
            }
            if (!first) try extras.appendSlice(self.a(), ",");
            first = false;
            const encoded = try std.json.Stringify.valueAlloc(self.a(), entry.value_ptr.*, .{});
            try self.put(&extras, "\"{s}\":{s}", .{ name, encoded });
        }
        try extras.appendSlice(self.a(), "}");
        page.props_json = extras.items;
        return null;
    }

    fn createPage(self: *Fake, gpa: Allocator, body: ?[]const u8) !client.Response {
        const id = try std.fmt.allocPrint(self.a(), "page-{d}", .{self.next_id});
        self.next_id += 1;

        var page = Page{ .id = id, .title = "", .last_edited = try self.stamp() };

        if (body) |raw| {
            const parsed = std.json.parseFromSlice(Value, self.gpa, raw, .{}) catch null;
            defer if (parsed) |p| p.deinit();
            if (parsed) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("properties")) |props| {
                        if (try self.applyProperties(&page, props)) |rejection| {
                            return self.respond(gpa, 400, rejection);
                        }
                    }
                    if (p.value.object.get("children")) |kids| {
                        if (kids == .array) {
                            for (kids.array.items) |kid| try self.appendOne(&page, kid);
                        }
                    }
                }
            }
        }

        try self.pages.append(self.gpa, page);
        return self.respond(gpa, 200, try self.pageJson(&self.pages.items[self.pages.items.len - 1]));
    }

    fn appendOne(self: *Fake, page: *Page, block: Value) !void {
        const block_id = try std.fmt.allocPrint(self.a(), "block-{d}", .{self.next_id});
        self.next_id += 1;
        try page.blocks.append(self.gpa, .{
            .id = block_id,
            .json = try std.json.Stringify.valueAlloc(self.a(), block, .{}),
        });
    }

    fn blocksRoute(
        self: *Fake,
        gpa: Allocator,
        method: client.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !client.Response {
        const rest = path["/blocks/".len..];

        if (std.mem.indexOf(u8, rest, "/children")) |cut| {
            const page_id = rest[0..cut];
            if (method == .patch) return self.appendChildren(gpa, page_id, body);
            return self.listChildren(gpa, page_id);
        }

        if (method == .delete) {
            const block_id = rest;
            for (self.pages.items) |*p| {
                for (p.blocks.items, 0..) |b, i| {
                    if (std.mem.eql(u8, b.id, block_id)) {
                        _ = p.blocks.orderedRemove(i);
                        p.last_edited = try self.stamp();
                        return self.respond(gpa, 200, "{}");
                    }
                }
            }
            return self.respond(gpa, 404, "{\"message\":\"block not found\"}");
        }
        return self.respond(gpa, 404, "{\"message\":\"no route\"}");
    }

    fn listChildren(self: *Fake, gpa: Allocator, page_id: []const u8) !client.Response {
        if (self.once_during_fetch) |hook| {
            const ctx = self.fetch_ctx;
            self.once_during_fetch = null;
            if (ctx) |c| hook(c);
        }

        const page = self.findPage(page_id) orelse
            return self.respond(gpa, 404, "{\"message\":\"page not found\"}");

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a(), "{\"results\":[");
        for (page.blocks.items, 0..) |b, i| {
            if (i > 0) try out.appendSlice(self.a(), ",");
            // Splice the id in, so the block reads like a real API response.
            // `object` is already in the stored payload, and repeating it would
            // make a JSON object with a duplicate key.
            try self.put(&out, "{{\"id\":\"{s}\",", .{b.id});
            try out.appendSlice(self.a(), b.json[1..]);
        }
        try out.appendSlice(self.a(), "],\"has_more\":false,\"next_cursor\":null}");
        return self.respond(gpa, 200, out.items);
    }

    fn appendChildren(self: *Fake, gpa: Allocator, page_id: []const u8, body: ?[]const u8) !client.Response {
        self.append_calls += 1;
        if (self.fail_append_at) |n| {
            if (self.append_calls == n) {
                return self.respond(gpa, 400, "{\"message\":\"validation error\"}");
            }
        }

        const page = self.findPage(page_id) orelse
            return self.respond(gpa, 404, "{\"message\":\"page not found\"}");

        const raw = body orelse return self.respond(gpa, 400, "{\"message\":\"no body\"}");
        const parsed = std.json.parseFromSlice(Value, self.gpa, raw, .{}) catch
            return self.respond(gpa, 400, "{\"message\":\"bad json\"}");
        defer parsed.deinit();

        const children = switch (parsed.value) {
            .object => |o| o.get("children") orelse return self.respond(gpa, 400, "{\"message\":\"no children\"}"),
            else => return self.respond(gpa, 400, "{\"message\":\"bad body\"}"),
        };
        if (children != .array) return self.respond(gpa, 400, "{\"message\":\"bad children\"}");

        const first_new = page.blocks.items.len;
        for (children.array.items) |kid| try self.appendOne(page, kid);
        page.last_edited = try self.stamp();

        // The response echoes the created blocks **in payload order**.
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a(), "{\"results\":[");
        for (page.blocks.items[first_new..], 0..) |b, i| {
            if (i > 0) try out.appendSlice(self.a(), ",");
            try self.put(&out, "{{\"id\":\"{s}\",", .{b.id});
            try out.appendSlice(self.a(), b.json[1..]);
        }
        try out.appendSlice(self.a(), "]}");
        return self.respond(gpa, 200, out.items);
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn newClient(gpa: Allocator, fake: *Fake) client.Client {
    return client.Client.init(gpa, fake.transport());
}

test "the fake answers /users/me" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try client.Endpoints.me(&c, arena.allocator());
    try testing.expectEqualStrings("Nova Bot", parsed.object.get("name").?.string);
}

test "a seeded page appears in the query and lists its blocks" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    const page_id = try fake.addPage("Weekly sync", &.{ "first line", "second line" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const query = try client.Endpoints.queryDatabase(&c, arena.allocator(), "db-1", null);
    try testing.expectEqual(@as(usize, 1), query.object.get("results").?.array.items.len);

    const children = try client.Endpoints.listChildren(&c, arena.allocator(), page_id, null);
    try testing.expectEqual(@as(usize, 2), children.object.get("results").?.array.items.len);

    const text = try fake.pageText(testing.allocator, page_id);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("first line\nsecond line\n", text);
}

test "appending returns new ids in payload order and bumps the timestamp" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    const page_id = try fake.addPage("T", &.{});
    const before = fake.findPage(page_id).?.last_edited;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const payload = try m2bBlocks(arena.allocator(), "one\n\ntwo\n");
    const res = try client.Endpoints.appendChildren(&c, arena.allocator(), page_id, payload);
    const results = res.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 2), results.items.len);
    // Ids come back in the order the payload went out.
    try testing.expect(!std.mem.eql(
        u8,
        results.items[0].object.get("id").?.string,
        results.items[1].object.get("id").?.string,
    ));
    try testing.expect(!std.mem.eql(u8, before, fake.findPage(page_id).?.last_edited));
}

fn m2bBlocks(arena: Allocator, md: []const u8) ![]Value {
    const m2b = @import("md_to_blocks.zig");
    const desired = try m2b.parseBody(arena, md);
    var out: std.ArrayList(Value) = .empty;
    for (desired) |d| {
        switch (d) {
            .block => |v| try out.append(arena, v),
            .restore => {},
        }
    }
    return out.toOwnedSlice(arena);
}

test "append failure can be injected" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    fake.fail_append_at = 1;
    const page_id = try fake.addPage("T", &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const payload = try m2bBlocks(arena.allocator(), "x\n");
    try testing.expectError(
        error.NotionError,
        client.Endpoints.appendChildren(&c, arena.allocator(), page_id, payload),
    );
    try testing.expect(std.mem.indexOf(u8, c.errorMessage(), "validation error") != null);
}

test "writing an unknown property is rejected when asked" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    fake.reject_unknown_properties = true;
    const page_id = try fake.addPage("T", &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const props = try client.dateProperty(arena.allocator(), "Updated", 0);
    try testing.expectError(
        error.NotionError,
        client.Endpoints.updatePage(&c, arena.allocator(), page_id, props, null),
    );

    // Once the column exists, the same write succeeds.
    try fake.addSchemaProperty("Updated", "date");
    _ = try client.Endpoints.updatePage(&c, arena.allocator(), page_id, props, null);
}

test "deleting a block removes it and bumps the timestamp" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    const page_id = try fake.addPage("T", &.{ "a", "b" });
    const block_id = fake.findPage(page_id).?.blocks.items[0].id;
    const before = fake.findPage(page_id).?.last_edited;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    _ = try client.Endpoints.deleteBlock(&c, arena.allocator(), block_id);

    try testing.expectEqual(@as(usize, 1), fake.findPage(page_id).?.blocks.items.len);
    try testing.expect(!std.mem.eql(u8, before, fake.findPage(page_id).?.last_edited));
}

test "archiving a page is visible in the query" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    const page_id = try fake.addPage("T", &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const res = try client.Endpoints.updatePage(&c, arena.allocator(), page_id, null, true);
    try testing.expect(fake.findPage(page_id).?.archived);

    const page = (try model.parsePage(testing.allocator, res)).?;
    defer testing.allocator.free(page.title);
    try testing.expect(page.archived);
}

test "the database schema reports its title property and columns" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    fake.title_prop = "Heading";
    try fake.addSchemaProperty("Created", "date");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const parsed = try client.Endpoints.retrieveDatabase(&c, arena.allocator(), "db-1");
    var info = (try model.parseDbInfo(testing.allocator, parsed)).?;
    defer info.deinit(testing.allocator);
    defer testing.allocator.free(info.title);

    try testing.expectEqualStrings("Heading", info.title_prop);
    try testing.expectEqualStrings("date", info.propertyType("Created").?);
}

test "adding database properties extends the schema" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = newClient(testing.allocator, &fake);
    defer c.deinit();

    const spec = try client.dateColumnSpec(arena.allocator(), "Updated");
    _ = try client.Endpoints.addDatabaseProperties(&c, arena.allocator(), "db-1", spec);

    try testing.expectEqualStrings("date", fake.schema.get("Updated").?);
}
