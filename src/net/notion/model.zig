//! The slice of Notion's API shape Nova actually reads.
//!
//! Ported from `src-tauri/src/notion/model.rs`. Anything not modelled here stays
//! as a raw `std.json.Value`, so an unknown block type survives a round trip
//! byte for byte -- which is what lets a page keep its callouts and toggles
//! through a push that rebuilds the body.

const std = @import("std");

const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

/// A block Nova cannot express as markdown, kept verbatim so a later push can
/// replay it. Stored in `notion_blocks`.
pub const CachedBlock = struct {
    block_id: []const u8,
    ord: i64,
    block_type: []const u8,
    raw_json: []const u8,
    recreatable: bool,

    pub fn deinit(self: CachedBlock, gpa: Allocator) void {
        gpa.free(self.block_id);
        gpa.free(self.block_type);
        gpa.free(self.raw_json);
    }
};

pub fn freeCachedBlocks(gpa: Allocator, blocks: []CachedBlock) void {
    for (blocks) |b| b.deinit(gpa);
    gpa.free(blocks);
}

pub const BotInfo = struct {
    name: []const u8,
    workspace_name: ?[]const u8,
};

pub const DbSummary = struct {
    id: []const u8,
    title: []const u8,
    url: ?[]const u8,
};

pub const DbInfo = struct {
    id: []const u8,
    title: []const u8,
    /// Name of the property whose type is `title`. Notion defaults it to "Name"
    /// but users rename it freely, and writing to the wrong property fails
    /// *silently*, so it is always read back rather than assumed.
    title_prop: []const u8,
    /// Property name -> type, so a configured timestamp column can be checked
    /// for existence and for actually being a `date`.
    properties: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *DbInfo, gpa: Allocator) void {
        self.properties.deinit(gpa);
    }

    pub fn propertyType(self: *const DbInfo, name: []const u8) ?[]const u8 {
        return self.properties.get(name);
    }
};

pub const PageMeta = struct {
    id: []const u8,
    title: []const u8,
    last_edited_time: []const u8,
    created_time: []const u8,
    archived: bool,
    url: ?[]const u8,
    /// The page's raw properties, so a configured column can be read without
    /// threading names through the API layer.
    properties: Value,
};

// -- reading JSON ------------------------------------------------------------

fn get(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?Value) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string, .number_string => |s| s,
        else => null,
    };
}

fn boolean(v: ?Value) bool {
    const value = v orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

/// Concatenate a `rich_text` array's plain text. Used for titles and code
/// bodies, where annotations have no markdown spelling anyway.
///
/// Falls back to `text.content`, because payloads *we* build carry no
/// `plain_text` -- that field is response-only, and the round-trip tests feed
/// our own output straight back in.
pub fn richTextPlain(gpa: Allocator, v: ?Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const value = v orelse return out.toOwnedSlice(gpa);
    const arr = switch (value) {
        .array => |a| a,
        else => return out.toOwnedSlice(gpa),
    };
    for (arr.items) |rt| {
        if (str(get(rt, "plain_text"))) |s| {
            try out.appendSlice(gpa, s);
            continue;
        }
        if (get(rt, "text")) |t| {
            if (str(get(t, "content"))) |s| try out.appendSlice(gpa, s);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The page's title, found by scanning its properties for the one of type
/// `title`. Scanning beats trusting the configured name: a page fetched before
/// the database schema was read still resolves.
pub fn pageTitle(gpa: Allocator, page: Value) ![]u8 {
    const props = get(page, "properties") orelse return gpa.dupe(u8, "");
    const obj = switch (props) {
        .object => |o| o,
        else => return gpa.dupe(u8, ""),
    };

    var it = obj.iterator();
    while (it.next()) |entry| {
        const prop = entry.value_ptr.*;
        if (str(get(prop, "type"))) |ty| {
            if (!std.mem.eql(u8, ty, "title")) continue;
            const raw = try richTextPlain(gpa, get(prop, "title"));
            defer gpa.free(raw);
            return gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        }
    }
    return gpa.dupe(u8, "");
}

/// Parse a page object. Strings borrow from `page`, except `title`, which the
/// caller owns.
pub fn parsePage(gpa: Allocator, page: Value) !?PageMeta {
    const id = str(get(page, "id")) orelse return null;
    return .{
        .id = id,
        .title = try pageTitle(gpa, page),
        .last_edited_time = str(get(page, "last_edited_time")) orelse "",
        .created_time = str(get(page, "created_time")) orelse "",
        // `archived` is the legacy flag; newer responses also carry `in_trash`.
        // Either means the page is gone as far as Nova is concerned.
        .archived = boolean(get(page, "archived")) or boolean(get(page, "in_trash")),
        .url = str(get(page, "url")),
        .properties = get(page, "properties") orelse .null,
    };
}

/// Parse a database summary. `title` is owned by the caller.
pub fn parseDbSummary(gpa: Allocator, database: Value) !?DbSummary {
    const id = str(get(database, "id")) orelse return null;
    const raw = try richTextPlain(gpa, get(database, "title"));
    defer gpa.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return .{
        .id = id,
        .title = try gpa.dupe(u8, if (trimmed.len == 0) "Untitled" else trimmed),
        .url = str(get(database, "url")),
    };
}

pub fn parseDbInfo(gpa: Allocator, database: Value) !?DbInfo {
    const summary = (try parseDbSummary(gpa, database)) orelse return null;
    errdefer gpa.free(summary.title);

    var properties: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer properties.deinit(gpa);

    var title_prop: []const u8 = "Name";
    if (get(database, "properties")) |props| {
        if (props == .object) {
            var it = props.object.iterator();
            while (it.next()) |entry| {
                const ty = str(get(entry.value_ptr.*, "type")) orelse "";
                try properties.put(gpa, entry.key_ptr.*, ty);
                if (std.mem.eql(u8, ty, "title")) title_prop = entry.key_ptr.*;
            }
        }
    }

    return .{
        .id = summary.id,
        .title = summary.title,
        .title_prop = title_prop,
        .properties = properties,
    };
}

/// Plain text of a named `rich_text` (or title) property on a page.
pub fn pagePropertyPlain(gpa: Allocator, page_props: Value, name: []const u8) !?[]u8 {
    const prop = get(page_props, name) orelse return null;
    // Responses carry a `type` discriminator; a payload we built ourselves does
    // not, so fall back to the shapes we know how to read.
    const body = if (str(get(prop, "type"))) |ty|
        get(prop, ty) orelse return null
    else
        get(prop, "rich_text") orelse get(prop, "title") orelse return null;

    const raw = try richTextPlain(gpa, body);
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

// -- writing JSON ------------------------------------------------------------

/// Fields Notion computes and rejects on write.
const read_only_fields = [_][]const u8{
    "id",           "object",         "created_time", "last_edited_time",
    "created_by",   "last_edited_by", "has_children", "archived",
    "in_trash",     "parent",         "request_id",
};

fn isReadOnly(key: []const u8) bool {
    for (read_only_fields) |f| {
        if (std.mem.eql(u8, key, f)) return true;
    }
    return false;
}

/// Turn a block fetched from the API back into a payload `append_children` will
/// accept.
///
/// Strips only the block's own top-level keys and recurses solely through
/// `children` arrays, which hold blocks. A blanket recursion would reach into
/// `rich_text` too and delete the `id` a page, user or database mention needs --
/// producing a payload Notion rejects with a 400.
pub fn stripReadOnly(arena: Allocator, block: Value) error{OutOfMemory}!Value {
    const obj = switch (block) {
        .object => |o| o,
        else => return block,
    };

    var out: std.json.ObjectMap = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (isReadOnly(entry.key_ptr.*)) continue;
        try out.put(arena, entry.key_ptr.*, try stripNestedChildren(arena, entry.value_ptr.*));
    }
    return .{ .object = out };
}

/// Rewrite a block's type payload so nested `children` are themselves stripped.
/// Everything else (`rich_text`, `icon`, `external`, ...) passes through.
fn stripNestedChildren(arena: Allocator, payload: Value) error{OutOfMemory}!Value {
    const obj = switch (payload) {
        .object => |o| o,
        else => return payload,
    };
    const kids = obj.get("children") orelse return payload;
    if (kids != .array) return payload;

    var out: std.json.ObjectMap = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    var stripped = std.json.Array.init(arena);
    for (kids.array.items) |kid| try stripped.append(try stripReadOnly(arena, kid));
    try out.put(arena, "children", .{ .array = stripped });
    return .{ .object = out };
}

/// Block types that cannot be recreated from their JSON, so a page containing
/// one can never be safely rebuilt:
///
///   * `synced_block` -- the payload references a source block by id
///   * `child_page` / `child_database` -- recreating makes a *different* page
///   * `unsupported` -- Notion itself refuses to describe it
pub fn isRecreatable(block_type: []const u8, block: Value) bool {
    for ([_][]const u8{ "synced_block", "child_page", "child_database", "unsupported" }) |t| {
        if (std.mem.eql(u8, block_type, t)) return false;
    }
    // Notion-hosted files carry expiring S3 URLs and there is no upload API that
    // would let us re-attach them. `external`-hosted media is fine.
    for ([_][]const u8{ "file", "image", "video", "pdf", "audio" }) |t| {
        if (!std.mem.eql(u8, block_type, t)) continue;
        const inner = get(block, block_type) orelse return true;
        if (str(get(inner, "type"))) |kind| {
            if (std.mem.eql(u8, kind, "file")) return false;
        }
    }
    return true;
}

// -- timestamps --------------------------------------------------------------

/// Milliseconds since the epoch for a Notion timestamp
/// (`2024-01-02T03:04:05.000Z`).
///
/// Only `created_time` needs this, so a fixed-format parser beats a date
/// library; `last_edited_time` is compared as an opaque string and never
/// parsed.
pub fn iso8601ToMs(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const num = struct {
        fn f(text: []const u8, a: usize, b: usize) ?i64 {
            if (b > text.len) return null;
            return std.fmt.parseInt(i64, text[a..b], 10) catch null;
        }
    }.f;

    const y = num(s, 0, 4) orelse return null;
    const mo = num(s, 5, 7) orelse return null;
    const d = num(s, 8, 10) orelse return null;
    const h = num(s, 11, 13) orelse return null;
    const mi = num(s, 14, 16) orelse return null;
    const sec = num(s, 17, 19) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;

    const millis: i64 = if (s.len > 19 and s[19] == '.') (num(s, 20, 23) orelse 0) else 0;
    return (daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec) * 1000 + millis;
}

/// Inverse of `iso8601ToMs`, in UTC. Used to write Nova's note timestamps into
/// Notion `date` properties. Caller owns the result.
pub fn msToIso8601(gpa: Allocator, ms: i64) ![]u8 {
    const days = @divFloor(ms, 86_400_000);
    const rem = @mod(ms, 86_400_000);
    const civil = civilFromDays(days);
    return std.fmt.allocPrint(
        gpa,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            @as(u32, @intCast(@max(civil.y, 0))),
            @as(u32, @intCast(civil.m)),
            @as(u32, @intCast(civil.d)),
            @as(u32, @intCast(@divTrunc(rem, 3_600_000))),
            @as(u32, @intCast(@mod(@divTrunc(rem, 60_000), 60))),
            @as(u32, @intCast(@mod(@divTrunc(rem, 1000), 60))),
            @as(u32, @intCast(@mod(rem, 1000))),
        },
    );
}

const Civil = struct { y: i64, m: i64, d: i64 };

/// Howard Hinnant's civil-from-days.
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Howard Hinnant's days-from-civil.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// -- tests -------------------------------------------------------------------
// Ported from the `mod tests` block in src-tauri/src/notion/model.rs.

const testing = std.testing;

fn parse(gpa: Allocator, text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, text, .{});
}

test "epoch and known dates" {
    try testing.expectEqual(@as(?i64, 0), iso8601ToMs("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1_704_164_645_000), iso8601ToMs("2024-01-02T03:04:05.000Z"));
    // A leap day, and a timestamp with no millis component.
    try testing.expectEqual(@as(?i64, 1_709_164_800_000), iso8601ToMs("2024-02-29T00:00:00Z"));
}

test "timestamps round-trip, including before the epoch" {
    for ([_]i64{ 0, 1_704_164_645_123, -86_400_000, 1_709_164_800_000 }) |ms| {
        const text = try msToIso8601(testing.allocator, ms);
        defer testing.allocator.free(text);
        testing.expectEqual(@as(?i64, ms), iso8601ToMs(text)) catch |err| {
            std.debug.print("ms={d} -> {s}\n", .{ ms, text });
            return err;
        };
    }
}

test "garbage timestamps are rejected" {
    try testing.expect(iso8601ToMs("") == null);
    try testing.expect(iso8601ToMs("not a date at all") == null);
    try testing.expect(iso8601ToMs("2024-13-01T00:00:00Z") == null);
    try testing.expect(iso8601ToMs("2024-01-32T00:00:00Z") == null);
}

test "the title is found by property type, not by name" {
    const parsed = try parse(testing.allocator,
        \\{"properties":{"Renamed Column":{"type":"title","title":[{"plain_text":"My Page"}]},
        \\ "Other":{"type":"rich_text","rich_text":[{"plain_text":"nope"}]}}}
    );
    defer parsed.deinit();

    const title = try pageTitle(testing.allocator, parsed.value);
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("My Page", title);
}

test "in_trash counts as archived" {
    const parsed = try parse(testing.allocator,
        \\{"id":"p1","in_trash":true,"properties":{}}
    );
    defer parsed.deinit();

    const page = (try parsePage(testing.allocator, parsed.value)).?;
    defer testing.allocator.free(page.title);
    try testing.expect(page.archived);
}

test "a renamed title property is reported by parseDbInfo" {
    const parsed = try parse(testing.allocator,
        \\{"id":"db1","title":[{"plain_text":"Notes"}],
        \\ "properties":{"Heading":{"type":"title"},"Created":{"type":"date"}}}
    );
    defer parsed.deinit();

    var info = (try parseDbInfo(testing.allocator, parsed.value)).?;
    defer info.deinit(testing.allocator);
    defer testing.allocator.free(info.title);

    try testing.expectEqualStrings("Notes", info.title);
    try testing.expectEqualStrings("Heading", info.title_prop);
    try testing.expectEqualStrings("date", info.propertyType("Created").?);
    try testing.expect(info.propertyType("Missing") == null);
}

test "an untitled database gets a placeholder name" {
    const parsed = try parse(testing.allocator, "{\"id\":\"db1\",\"title\":[]}");
    defer parsed.deinit();
    const summary = (try parseDbSummary(testing.allocator, parsed.value)).?;
    defer testing.allocator.free(summary.title);
    try testing.expectEqualStrings("Untitled", summary.title);
}

test "stripReadOnly removes computed fields and recurses into children" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse(testing.allocator,
        \\{"id":"b1","object":"block","created_time":"x","has_children":true,
        \\ "type":"bulleted_list_item",
        \\ "bulleted_list_item":{"rich_text":[{"type":"text"}],
        \\   "children":[{"id":"b2","object":"block","type":"paragraph","paragraph":{}}]}}
    );
    defer parsed.deinit();

    const stripped = try stripReadOnly(arena, parsed.value);
    const out = stripped.object;
    try testing.expect(out.get("id") == null);
    try testing.expect(out.get("object") == null);
    try testing.expect(out.get("has_children") == null);
    try testing.expect(out.get("type") != null);

    const kids = out.get("bulleted_list_item").?.object.get("children").?.array;
    try testing.expect(kids.items[0].object.get("id") == null);
    try testing.expect(kids.items[0].object.get("type") != null);
}

test "stripReadOnly leaves a mention's id alone" {
    // A blanket recursion would delete this and Notion would answer 400.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse(testing.allocator,
        \\{"id":"b1","type":"paragraph",
        \\ "paragraph":{"rich_text":[{"type":"mention","mention":{"type":"page","page":{"id":"keep-me"}}}]}}
    );
    defer parsed.deinit();

    const stripped = try stripReadOnly(arena, parsed.value);
    const rt = stripped.object.get("paragraph").?.object.get("rich_text").?.array;
    const page_id = rt.items[0].object.get("mention").?.object.get("page").?.object.get("id").?;
    try testing.expectEqualStrings("keep-me", page_id.string);
}

test "recreatability" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expect(isRecreatable("paragraph", .null));
    try testing.expect(!isRecreatable("synced_block", .null));
    try testing.expect(!isRecreatable("child_page", .null));
    try testing.expect(!isRecreatable("unsupported", .null));

    const hosted = try parse(testing.allocator, "{\"image\":{\"type\":\"file\"}}");
    defer hosted.deinit();
    try testing.expect(!isRecreatable("image", hosted.value));

    const external = try parse(testing.allocator, "{\"image\":{\"type\":\"external\"}}");
    defer external.deinit();
    try testing.expect(isRecreatable("image", external.value));
}

test "richTextPlain falls back to text.content" {
    const parsed = try parse(testing.allocator,
        \\[{"plain_text":"a"},{"text":{"content":"b"}},{"nothing":1}]
    );
    defer parsed.deinit();

    const out = try richTextPlain(testing.allocator, parsed.value);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ab", out);
}

test "pagePropertyPlain reads both response and payload shapes" {
    const response = try parse(testing.allocator,
        \\{"Nova Id":{"type":"rich_text","rich_text":[{"plain_text":"uuid-here"}]}}
    );
    defer response.deinit();
    const a = (try pagePropertyPlain(testing.allocator, response.value, "Nova Id")).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("uuid-here", a);

    const payload = try parse(testing.allocator,
        \\{"Nova Id":{"rich_text":[{"text":{"content":"uuid-here"}}]}}
    );
    defer payload.deinit();
    const b = (try pagePropertyPlain(testing.allocator, payload.value, "Nova Id")).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("uuid-here", b);

    try testing.expect((try pagePropertyPlain(testing.allocator, payload.value, "Absent")) == null);
}
