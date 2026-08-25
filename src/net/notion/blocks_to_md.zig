//! Notion blocks -> markdown.
//!
//! Ported from `src-tauri/src/notion/blocks_to_md.rs`.
//!
//! Anything Nova cannot represent becomes a one-line placeholder comment and
//! its raw JSON is cached, so a later push can replay it verbatim. The
//! all-or-nothing rule matters: if *any* descendant of a top-level block is
//! unrepresentable, the whole top-level block becomes a placeholder. A push
//! rebuilds a page's top-level children, so a placeholder buried inside a list
//! item could never be restored -- keeping them at top level is what makes
//! restoration possible at all.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;
const CachedBlock = model.CachedBlock;

/// Three levels of list nesting (0, 1, 2). Deeper items render flattened onto
/// the last level rather than being dropped.
const max_depth: usize = 2;
const indent = "  ";

pub const readonly_marker = "<!-- notion:readonly-body -->";

pub const Rendered = struct {
    markdown: []u8,
    unsupported: []CachedBlock,
    /// True when at least one cached block can never be recreated, which puts
    /// the whole note into pull-only mode.
    has_unrecreatable: bool,

    pub fn deinit(self: Rendered, gpa: Allocator) void {
        gpa.free(self.markdown);
        model.freeCachedBlocks(gpa, self.unsupported);
    }
};

pub fn placeholderLine(gpa: Allocator, block_type: []const u8, block_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "<!-- notion:unsupported type={s} id={s} -->",
        .{ block_type, block_id },
    );
}

pub const Placeholder = struct { block_type: []const u8, id: []const u8 };

/// Parse a placeholder line back into its type and id.
///
/// Returns null for anything else -- including a half-deleted placeholder,
/// which is intentional: a mangled marker means "the user removed this block".
pub fn parsePlaceholder(line: []const u8) ?Placeholder {
    var s = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "<!--")) return null;
    if (!std.mem.endsWith(u8, s, "-->")) return null;
    s = std.mem.trim(u8, s[4 .. s.len - 3], " \t");
    if (!std.mem.startsWith(u8, s, "notion:unsupported")) return null;
    s = std.mem.trim(u8, s["notion:unsupported".len..], " \t");

    var ty: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "type=")) {
            ty = tok["type=".len..];
        } else if (std.mem.startsWith(u8, tok, "id=")) {
            id = tok["id=".len..];
        } else return null;
    }
    return .{ .block_type = ty orelse return null, .id = id orelse return null };
}

// -- JSON helpers ------------------------------------------------------------

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

fn blockType(block: Value) []const u8 {
    return str(get(block, "type")) orelse "unsupported";
}

// -- page rendering ----------------------------------------------------------

/// The page as local markdown.
///
/// The title lives **in the body**, as a leading `# ` heading, so nothing is
/// lost to the 120-character cap `firstLineTitle` puts on the note title (or
/// the 2000-character cap Notion puts on a title property). Those caps only ever
/// apply to a label derived from the text, never to the text itself.
///
/// A page whose body already opens with that heading renders as-is. One that
/// does not -- anything authored in Notion -- gets the heading prepended, so its
/// title survives the trip. After one push the two agree and this is a no-op.
pub fn renderPage(gpa: Allocator, title: []const u8, blocks: []const Value) !Rendered {
    var r = try renderBody(gpa, blocks);
    errdefer r.deinit(gpa);

    const flat = try gpa.dupe(u8, title);
    defer gpa.free(flat);
    for (flat) |*c| {
        if (c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    const t = std.mem.trim(u8, flat, " \t");

    if (bodyLeadsWithTitle(r.markdown, t)) return r;

    const heading = if (t.len == 0) "Untitled" else t;
    const md = if (r.markdown.len == 0)
        try std.fmt.allocPrint(gpa, "# {s}\n", .{heading})
    else
        try std.fmt.allocPrint(gpa, "# {s}\n\n{s}", .{ heading, r.markdown });

    gpa.free(r.markdown);
    r.markdown = md;
    return r;
}

/// True when the body's first line is a heading the page title came from.
///
/// Both sides go through `firstLineTitle`, so a title Notion stored truncated
/// still matches the full heading it was derived from.
fn bodyLeadsWithTitle(md: []const u8, title: []const u8) bool {
    const eol = std.mem.indexOfScalar(u8, md, '\n') orelse md.len;
    const first = md[0..eol];
    if (first.len == 0 or first[0] != '#') return false;

    const from_body = db.workspace.firstLineTitle(first, "");
    if (from_body.len == 0) return false;
    return std.mem.eql(u8, from_body, db.workspace.firstLineTitle(title, ""));
}

const Chunk = struct { lines: [][]const u8, is_list: bool };

pub fn renderBody(gpa: Allocator, blocks: []const Value) !Rendered {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var unsupported: std.ArrayList(CachedBlock) = .empty;
    errdefer {
        for (unsupported.items) |b| b.deinit(gpa);
        unsupported.deinit(gpa);
    }

    var chunks: std.ArrayList(Chunk) = .empty;
    defer chunks.deinit(arena);

    var has_unrecreatable = false;
    var counter = ListCounter{};

    for (blocks) |block| {
        const ty = blockType(block);
        const is_list = isListType(ty);
        if (!is_list) counter.reset();

        if (try renderBlock(arena, block, 0, &counter)) |lines| {
            if (lines.len > 0) try chunks.append(arena, .{ .lines = lines, .is_list = is_list });
            continue;
        }

        counter.reset();
        const id = str(get(block, "id")) orelse "";
        const recreatable = model.isRecreatable(ty, block);
        if (!recreatable) has_unrecreatable = true;

        const line = try placeholderLine(arena, ty, id);
        const one = try arena.alloc([]const u8, 1);
        one[0] = line;
        try chunks.append(arena, .{ .lines = one, .is_list = false });

        const raw = try std.json.Stringify.valueAlloc(gpa, block, .{});
        errdefer gpa.free(raw);
        try unsupported.append(gpa, .{
            .block_id = try gpa.dupe(u8, id),
            .ord = @intCast(unsupported.items.len),
            .block_type = try gpa.dupe(u8, ty),
            .raw_json = raw,
            .recreatable = recreatable,
        });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var prev_list = false;
    for (chunks.items, 0..) |chunk, i| {
        // Consecutive list items sit on adjacent lines; everything else gets a
        // blank line between it and its neighbour.
        if (i > 0 and !(prev_list and chunk.is_list)) try out.append(gpa, '\n');
        for (chunk.lines) |l| {
            try out.appendSlice(gpa, l);
            try out.append(gpa, '\n');
        }
        prev_list = chunk.is_list;
    }

    return .{
        .markdown = try out.toOwnedSlice(gpa),
        .unsupported = try unsupported.toOwnedSlice(gpa),
        .has_unrecreatable = has_unrecreatable,
    };
}

fn isListType(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "bulleted_list_item") or
        std.mem.eql(u8, ty, "numbered_list_item") or
        std.mem.eql(u8, ty, "to_do");
}

/// Ordinals for numbered lists at each nesting depth. Notion stores no numbers
/// of its own, so they are generated here and reset when a non-numbered sibling
/// breaks the run.
const ListCounter = struct {
    stack: [max_depth + 2]usize = @splat(0),
    len: usize = 0,

    fn next(self: *ListCounter, depth: usize) usize {
        const d = @min(depth, self.stack.len - 1);
        while (self.len <= d) : (self.len += 1) self.stack[self.len] = 0;
        self.len = d + 1;
        self.stack[d] += 1;
        return self.stack[d];
    }
    fn reset(self: *ListCounter) void {
        self.len = 0;
    }
    fn resetAt(self: *ListCounter, depth: usize) void {
        self.len = @min(self.len, depth);
    }
};

fn padding(arena: Allocator, depth: usize) ![]const u8 {
    const n = @min(depth, max_depth);
    const out = try arena.alloc(u8, n * indent.len);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(out[i * indent.len ..][0..indent.len], indent);
    return out;
}

/// Null means "this block, or something under it, cannot be represented".
fn renderBlock(
    arena: Allocator,
    block: Value,
    depth: usize,
    counter: *ListCounter,
) error{OutOfMemory}!?[][]const u8 {
    const ty = blockType(block);
    const inner = get(block, ty);
    const pad = try padding(arena, depth);

    // Only list items nest. An indented code fence or divider would be
    // ambiguous to re-parse, so a non-list child escalates its whole top-level
    // ancestor to a placeholder rather than being rendered wrong.
    if (depth > 0 and !isListType(ty)) return null;

    // A block that claims children we never fetched cannot be rendered
    // faithfully, so bail rather than silently drop them.
    const declares_children = boolean(get(block, "has_children"));
    const children: ?std.json.Array = blk: {
        const kids = if (inner) |v| get(v, "children") else null;
        if (kids) |k| {
            if (k == .array) break :blk k.array;
        }
        break :blk null;
    };
    if (declares_children and children == null) return null;
    const has_children = children != null and children.?.items.len > 0;

    if (std.mem.eql(u8, ty, "paragraph") and !has_children) {
        const text = (try richTextToMd(arena, if (inner) |v| get(v, "rich_text") else null)) orelse
            return null;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            // Spacer paragraphs are dropped; markdown says the same thing with
            // the blank line between blocks.
            return try arena.alloc([]const u8, 0);
        }
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            try lines.append(arena, try std.fmt.allocPrint(
                arena,
                "{s}{s}",
                .{ pad, try escapeLineStart(arena, l) },
            ));
        }
        return try lines.toOwnedSlice(arena);
    }

    if (!has_children and (std.mem.eql(u8, ty, "heading_1") or
        std.mem.eql(u8, ty, "heading_2") or std.mem.eql(u8, ty, "heading_3")))
    {
        if (boolean(if (inner) |v| get(v, "is_toggleable") else null)) return null;
        const text = (try richTextToMd(arena, if (inner) |v| get(v, "rich_text") else null)) orelse
            return null;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return null;

        const hashes = if (std.mem.eql(u8, ty, "heading_1"))
            "#"
        else if (std.mem.eql(u8, ty, "heading_2"))
            "##"
        else
            "###";
        return try single(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ hashes, text }));
    }

    if (std.mem.eql(u8, ty, "quote") and !has_children) {
        const text = (try richTextToMd(arena, if (inner) |v| get(v, "rich_text") else null)) orelse
            return null;
        return try prefixLines(arena, text, pad, "> ");
    }

    if (std.mem.eql(u8, ty, "divider")) {
        return try single(arena, try std.fmt.allocPrint(arena, "{s}---", .{pad}));
    }

    if (isListType(ty)) {
        const text = (try richTextToMd(arena, if (inner) |v| get(v, "rich_text") else null)) orelse
            return null;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return null;

        const marker = blk: {
            if (std.mem.eql(u8, ty, "bulleted_list_item")) {
                counter.resetAt(depth);
                break :blk try arena.dupe(u8, "- ");
            }
            if (std.mem.eql(u8, ty, "numbered_list_item")) {
                break :blk try std.fmt.allocPrint(arena, "{d}. ", .{counter.next(depth)});
            }
            counter.resetAt(depth);
            const checked = boolean(if (inner) |v| get(v, "checked") else null);
            break :blk try arena.dupe(u8, if (checked) "- [x] " else "- [ ] ");
        };

        var lines: std.ArrayList([]const u8) = .empty;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ pad, marker, text }));
        if (children) |kids| {
            var child_counter = ListCounter{};
            for (kids.items) |kid| {
                const sub = (try renderBlock(arena, kid, depth + 1, &child_counter)) orelse return null;
                try lines.appendSlice(arena, sub);
            }
        }
        return try lines.toOwnedSlice(arena);
    }

    if (std.mem.eql(u8, ty, "code") and !has_children) {
        const body = inner orelse return null;
        // A caption has nowhere to live in a fenced block; preserving the block
        // wholesale beats silently dropping the user's note.
        const caption = try model.richTextPlain(arena, get(body, "caption"));
        if (caption.len > 0) return null;

        const content = try model.richTextPlain(arena, get(body, "rich_text") orelse return null);
        const lang = str(get(body, "language")) orelse "plain text";
        const info = if (std.mem.eql(u8, lang, "plain text")) "" else lang;

        const fence_len = @max(longestBacktickRun(content), 2) + 1;
        const fence = try arena.alloc(u8, fence_len);
        @memset(fence, '`');

        var lines: std.ArrayList([]const u8) = .empty;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ pad, fence, info }));
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |l| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ pad, l }));
        }
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ pad, fence }));
        return try lines.toOwnedSlice(arena);
    }

    if (std.mem.eql(u8, ty, "image") and !has_children) {
        const img = inner orelse return null;
        // Notion-hosted files have expiring URLs and no re-upload path.
        const kind = str(get(img, "type")) orelse return null;
        if (!std.mem.eql(u8, kind, "external")) return null;
        const url = str(get(get(img, "external") orelse return null, "url")) orelse return null;
        if (std.mem.indexOfScalar(u8, url, ')') != null) return null;
        for (url) |ch| {
            if (std.ascii.isWhitespace(ch)) return null;
        }

        const alt = try model.richTextPlain(arena, get(img, "caption"));
        if (std.mem.indexOfScalar(u8, alt, ']') != null) return null;
        if (std.mem.indexOfScalar(u8, alt, '\n') != null) return null;

        return try single(arena, try std.fmt.allocPrint(arena, "{s}![{s}]({s})", .{ pad, alt, url }));
    }

    return null;
}

fn single(arena: Allocator, line: []const u8) ![][]const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = line;
    return out;
}

fn prefixLines(arena: Allocator, text: []const u8, pad: []const u8, marker: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ pad, marker, l }));
    }
    return lines.toOwnedSlice(arena);
}

fn longestBacktickRun(s: []const u8) usize {
    var best: usize = 0;
    var cur: usize = 0;
    for (s) |c| {
        if (c == '`') {
            cur += 1;
            best = @max(best, cur);
        } else cur = 0;
    }
    return best;
}

// -- rich text -> inline markdown --------------------------------------------

pub const Ann = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,

    pub fn eql(a: Ann, b: Ann) bool {
        return a.bold == b.bold and a.italic == b.italic and
            a.strike == b.strike and a.code == b.code;
    }
};

fn annOf(item: Value) Ann {
    const a = get(item, "annotations");
    const f = struct {
        fn get_(ann: ?Value, key: []const u8) bool {
            const v = ann orelse return false;
            return boolean(get(v, key));
        }
    }.get_;
    return .{
        .bold = f(a, "bold"),
        .italic = f(a, "italic"),
        .strike = f(a, "strikethrough"),
        .code = f(a, "code"),
    };
}

fn linkOf(item: Value) ?[]const u8 {
    if (str(get(item, "href"))) |h| {
        if (h.len > 0) return h;
    }
    const text = get(item, "text") orelse return null;
    const link = get(text, "link") orelse return null;
    return str(get(link, "url"));
}

const Run = struct { text: []const u8, ann: Ann, link: ?[]const u8 };

/// Null when the array contains anything other than plain text -- mentions and
/// inline equations have no markdown spelling, so the owning block escalates to
/// a placeholder rather than losing them.
pub fn richTextToMd(arena: Allocator, v: ?Value) !?[]const u8 {
    const value = v orelse return null;
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };

    // Merge adjacent runs sharing formatting first, so `**a****b**` cannot
    // happen -- Notion splits runs at edit boundaries, not style boundaries.
    var merged: std.ArrayList(Run) = .empty;
    for (arr.items) |item| {
        const ty = str(get(item, "type")) orelse return null;
        if (!std.mem.eql(u8, ty, "text")) return null;

        const content = blk: {
            if (get(item, "text")) |t| {
                if (str(get(t, "content"))) |c| break :blk c;
            }
            break :blk str(get(item, "plain_text")) orelse "";
        };
        if (content.len == 0) continue;

        const ann = annOf(item);
        const link = linkOf(item);
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            const same_link = (last.link == null and link == null) or
                (last.link != null and link != null and std.mem.eql(u8, last.link.?, link.?));
            if (last.ann.eql(ann) and same_link) {
                last.text = try std.mem.concat(arena, u8, &.{ last.text, content });
                continue;
            }
        }
        try merged.append(arena, .{ .text = content, .ann = ann, .link = link });
    }

    var out: std.ArrayList(u8) = .empty;
    for (merged.items) |run| {
        const body = if (run.ann.code) blk: {
            // Inside a code span markdown cannot express any other emphasis, so
            // the code annotation wins and the rest is dropped.
            const fence_len = longestBacktickRun(run.text) + 1;
            const fence = try arena.alloc(u8, fence_len);
            @memset(fence, '`');
            const pad_it = run.text.len > 0 and
                (run.text[0] == '`' or run.text[run.text.len - 1] == '`');
            break :blk if (pad_it)
                try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ fence, run.text, fence })
            else
                try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ fence, run.text, fence });
        } else blk: {
            var b = try escapeInline(arena, run.text);
            if (run.ann.strike) b = try std.fmt.allocPrint(arena, "~~{s}~~", .{b});
            if (run.ann.italic) b = try std.fmt.allocPrint(arena, "*{s}*", .{b});
            if (run.ann.bold) b = try std.fmt.allocPrint(arena, "**{s}**", .{b});
            break :blk b;
        };

        const spellable = blk: {
            const url = run.link orelse break :blk false;
            if (std.mem.indexOfScalar(u8, url, ')') != null) break :blk false;
            for (url) |ch| {
                if (std.ascii.isWhitespace(ch)) break :blk false;
            }
            break :blk true;
        };
        if (spellable) {
            try out.appendSlice(arena, try std.fmt.allocPrint(
                arena,
                "[{s}]({s})",
                .{ body, run.link.? },
            ));
        } else {
            // A URL that cannot be spelled inline degrades to plain text rather
            // than producing markdown that reparses wrong.
            try out.appendSlice(arena, body);
        }
    }
    return try out.toOwnedSlice(arena);
}

/// Escape only what would otherwise reparse as markup.
///
/// `_` is deliberately left alone -- Nova does not treat it as emphasis -- so
/// `snake_case` survives unmangled, and `[` is escaped only when a `](`
/// actually follows.
pub fn escapeInline(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len);
    for (s, 0..) |c, i| {
        const needs = switch (c) {
            '\\', '*', '`', '~' => true,
            '[' => looksLikeLink(s[i..]),
            else => false,
        };
        if (needs) try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

fn looksLikeLink(rest: []const u8) bool {
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        switch (rest[i]) {
            ']' => return i + 1 < rest.len and rest[i + 1] == '(',
            '\n' => return false,
            else => {},
        }
    }
    return false;
}

/// Escape a leading marker that would make a paragraph line parse as some other
/// block (`- foo`, `# foo`, `> foo`, `1. foo`, `---`, `<!-- ... -->`).
///
/// Runs *after* `escapeInline`, which has already dealt with `*` and backticks,
/// so a line can never legitimately start with an unescaped backslash here and
/// re-escaping one would corrupt it.
pub fn escapeLineStart(arena: Allocator, line: []const u8) ![]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    const lead = line[0 .. line.len - t.len];

    // An ordered marker is disarmed at the dot: `1. x` -> `1\. x`. Escaping the
    // leading digit would not work, since `\` only escapes punctuation.
    if (orderedMarkerDigits(t)) |digits| {
        return std.fmt.allocPrint(arena, "{s}{s}\\{s}", .{ lead, t[0..digits], t[digits..] });
    }

    var hashes: usize = 0;
    while (hashes < t.len and t[hashes] == '#') hashes += 1;

    const all_dashes = t.len >= 3 and blk: {
        for (t) |c| {
            if (c != '-') break :blk false;
        }
        break :blk true;
    };
    const is_marker = std.mem.startsWith(u8, t, "- ") or
        std.mem.startsWith(u8, t, "* ") or
        std.mem.startsWith(u8, t, "> ") or
        (hashes > 0 and hashes < t.len and t[hashes] == ' ') or
        std.mem.startsWith(u8, t, "<!--") or
        all_dashes;

    if (!is_marker) return line;
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ lead, t });
}

/// Number of leading digits when the string starts with a `123. ` marker.
fn orderedMarkerDigits(s: []const u8) ?usize {
    var digits: usize = 0;
    while (digits < s.len and std.ascii.isDigit(s[digits])) digits += 1;
    if (digits == 0 or digits > 9) return null;
    if (std.mem.startsWith(u8, s[digits..], ". ")) return digits;
    return null;
}
