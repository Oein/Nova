//! Markdown -> Notion block payloads.
//!
//! Ported from `src-tauri/src/notion/md_to_blocks.rs`.
//!
//! The output is a list of `Desired` entries rather than plain JSON, because a
//! placeholder line does not become a *new* block -- it means "replay the cached
//! JSON for this block id". A push consumes both kinds in order.
//!
//! The inline parser works on bytes rather than code points. Every delimiter it
//! recognises is ASCII, and a UTF-8 continuation byte can never be mistaken for
//! one, so byte indices are exactly equivalent to the original's char indices --
//! except in `chunk`, which counts code points because Notion's limit does.

const std = @import("std");
const model = @import("model.zig");
const b2m = @import("blocks_to_md.zig");

const Allocator = std.mem.Allocator;
const Value = model.Value;
const Ann = b2m.Ann;

/// Notion accepts a block plus two levels of nested children per request, which
/// matches the three list levels the renderer emits.
const max_depth: usize = 2;
/// Hard limit on a single `rich_text` element's content, in code points.
const rich_text_limit: usize = 2000;

pub const Desired = union(enum) {
    /// A block to create from scratch.
    block: Value,
    /// Replay the cached JSON for this original block id.
    restore: []const u8,
};

// -- JSON construction -------------------------------------------------------

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

fn s(text: []const u8) Value {
    return .{ .string = text };
}

// -- block parsing -----------------------------------------------------------

pub fn parseBody(arena: Allocator, md: []const u8) ![]Desired {
    var lines: std.ArrayList([]const u8) = .empty;
    var line_it = std.mem.splitScalar(u8, md, '\n');
    while (line_it.next()) |l| try lines.append(arena, l);
    // `splitScalar` yields a trailing empty piece for text ending in a newline;
    // Rust's `lines()` does not.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0 and md.len > 0) {
        _ = lines.pop();
    }

    var out: std.ArrayList(Desired) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, b2m.readonly_marker)) {
            i += 1;
            continue;
        }
        if (b2m.parsePlaceholder(line)) |ph| {
            try out.append(arena, .{ .restore = ph.id });
            i += 1;
            continue;
        }
        if (fenceLen(trimmed)) |fence| {
            const info = std.mem.trim(u8, trimmed[fence..], " \t\r");
            var body: std.ArrayList([]const u8) = .empty;
            i += 1;
            while (i < lines.items.len) {
                const t = std.mem.trim(u8, lines.items[i], " \t\r");
                if (fenceLen(t)) |n| {
                    if (n >= fence and std.mem.trim(u8, t[n..], " \t\r").len == 0) {
                        i += 1;
                        break;
                    }
                }
                // Verbatim: leading whitespace inside a fence is content, and
                // trimming it silently destroys indented code.
                try body.append(arena, lines.items[i]);
                i += 1;
            }
            const joined = try std.mem.join(arena, "\n", body.items);
            try out.append(arena, .{ .block = try codeBlock(arena, joined, info) });
            continue;
        }
        if (isDivider(trimmed)) {
            try out.append(arena, .{ .block = try obj(arena, &.{
                .{ "object", s("block") },
                .{ "type", s("divider") },
                .{ "divider", try obj(arena, &.{}) },
            }) });
            i += 1;
            continue;
        }
        if (headingOf(trimmed)) |h| {
            try out.append(arena, .{ .block = try headingBlock(arena, h.level, h.text) });
            i += 1;
            continue;
        }
        if (trimmed.len > 0 and trimmed[0] == '>') {
            var parts: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len) {
                const t = std.mem.trimStart(u8, lines.items[i], " \t");
                if (t.len == 0 or t[0] != '>') break;
                const rest = t[1..];
                try parts.append(arena, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest);
                i += 1;
            }
            const joined = try std.mem.join(arena, "\n", parts.items);
            try out.append(arena, .{ .block = try simpleBlock(arena, "quote", joined) });
            continue;
        }
        if (try imageBlock(arena, trimmed)) |img| {
            try out.append(arena, .{ .block = img });
            i += 1;
            continue;
        }
        if ((try listMarker(arena, line)) != null) {
            var items: std.ArrayList(Item) = .empty;
            while (i < lines.items.len) {
                const item = (try listMarker(arena, lines.items[i])) orelse break;
                try items.append(arena, item);
                i += 1;
            }
            var idx: usize = 0;
            for (try nest(arena, items.items, &idx, 0)) |block| {
                try out.append(arena, .{ .block = block });
            }
            continue;
        }

        // Everything else is a paragraph; consecutive plain lines belong to the
        // same one, matching how a multi-line rich_text renders.
        var parts: std.ArrayList([]const u8) = .empty;
        while (i < lines.items.len) {
            const t = std.mem.trim(u8, lines.items[i], " \t\r");
            if (t.len == 0 or
                std.mem.eql(u8, t, b2m.readonly_marker) or
                b2m.parsePlaceholder(lines.items[i]) != null or
                fenceLen(t) != null or
                isDivider(t) or
                headingOf(t) != null or
                (t.len > 0 and t[0] == '>') or
                (try listMarker(arena, lines.items[i])) != null or
                (try imageBlock(arena, t)) != null) break;
            try parts.append(arena, lines.items[i]);
            i += 1;
        }
        const joined = try std.mem.join(arena, "\n", parts.items);
        try out.append(arena, .{ .block = try simpleBlock(arena, "paragraph", joined) });
    }
    return out.toOwnedSlice(arena);
}

/// Every block id referenced by a placeholder, in document order.
pub fn referencedBlockIds(arena: Allocator, desired: []const Desired) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (desired) |d| {
        switch (d) {
            .restore => |id| try out.append(arena, id),
            .block => {},
        }
    }
    return out.toOwnedSlice(arena);
}

// -- line classification -----------------------------------------------------

fn fenceLen(trimmed: []const u8) ?usize {
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == '`') n += 1;
    return if (n >= 3) n else null;
}

fn isDivider(t: []const u8) bool {
    if (t.len < 3) return false;
    const all = struct {
        fn f(text: []const u8, c: u8) bool {
            for (text) |x| {
                if (x != c) return false;
            }
            return true;
        }
    }.f;
    return all(t, '-') or all(t, '*');
}

const Heading = struct { level: usize, text: []const u8 };

fn headingOf(t: []const u8) ?Heading {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0) return null;
    const rest = t[n..];
    if (rest.len == 0 or rest[0] != ' ') return null;
    return .{ .level = @min(n, 3), .text = rest[1..] };
}

fn imageBlock(arena: Allocator, t: []const u8) !?Value {
    if (!std.mem.startsWith(u8, t, "![")) return null;
    const rest = t[2..];
    const close = std.mem.indexOf(u8, rest, "](") orelse return null;
    const alt = rest[0..close];
    if (!std.mem.endsWith(u8, rest, ")")) return null;
    const url = rest[close + 2 .. rest.len - 1];
    if (url.len == 0) return null;
    for (url) |ch| {
        if (std.ascii.isWhitespace(ch)) return null;
    }

    var img_pairs: std.ArrayList(struct { []const u8, Value }) = .empty;
    try img_pairs.append(arena, .{ "type", s("external") });
    try img_pairs.append(arena, .{ "external", try obj(arena, &.{.{ "url", s(url) }}) });
    if (alt.len > 0) {
        try img_pairs.append(arena, .{ "caption", try arr(arena, try richText(arena, alt)) });
    }

    return try obj(arena, &.{
        .{ "object", s("block") },
        .{ "type", s("image") },
        .{ "image", try obj(arena, img_pairs.items) },
    });
}

const Item = struct { depth: usize, block: Value };

/// A list item of any flavour, with its nesting depth.
fn listMarker(arena: Allocator, line: []const u8) !?Item {
    const t = std.mem.trimStart(u8, line, " \t");
    const lead = line.len - t.len;
    const depth = @min(lead / 2, max_depth);

    if (std.mem.startsWith(u8, t, "- [ ] ")) {
        return .{ .depth = depth, .block = try todoBlock(arena, t[6..], false) };
    }
    if (std.mem.startsWith(u8, t, "- [x] ") or std.mem.startsWith(u8, t, "- [X] ")) {
        return .{ .depth = depth, .block = try todoBlock(arena, t[6..], true) };
    }
    if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) {
        return .{ .depth = depth, .block = try simpleBlock(arena, "bulleted_list_item", t[2..]) };
    }
    if (orderedMarkerLen(t)) |n| {
        return .{ .depth = depth, .block = try simpleBlock(arena, "numbered_list_item", t[n..]) };
    }
    return null;
}

fn orderedMarkerLen(t: []const u8) ?usize {
    var digits: usize = 0;
    while (digits < t.len and std.ascii.isDigit(t[digits])) digits += 1;
    if (digits == 0 or digits > 9) return null;
    if (std.mem.startsWith(u8, t[digits..], ". ")) return digits + 2;
    return null;
}

/// Turn a flat `(depth, block)` sequence into a nested one. A run that starts
/// over-indented is promoted rather than dropped.
fn nest(arena: Allocator, items: []const Item, idx: *usize, depth: usize) error{OutOfMemory}![]Value {
    var out: std.ArrayList(Value) = .empty;
    while (idx.* < items.len) {
        const item = items[idx.*];
        if (item.depth < depth) break;
        if (item.depth > depth) {
            const children = try nest(arena, items, idx, depth + 1);
            if (out.items.len > 0) {
                try attachChildren(arena, &out.items[out.items.len - 1], children);
            } else {
                try out.appendSlice(arena, children);
            }
            continue;
        }
        try out.append(arena, item.block);
        idx.* += 1;
    }
    return out.toOwnedSlice(arena);
}

fn attachChildren(arena: Allocator, block: *Value, children: []Value) !void {
    if (children.len == 0) return;
    const map = switch (block.*) {
        .object => |o| o,
        else => return,
    };
    const ty = switch (map.get("type") orelse return) {
        .string => |x| x,
        else => return,
    };
    var inner = switch (map.get(ty) orelse return) {
        .object => |o| o,
        else => return,
    };
    try inner.put(arena, "children", try arr(arena, children));

    var outer = map;
    try outer.put(arena, ty, .{ .object = inner });
    block.* = .{ .object = outer };
}

// -- block builders ----------------------------------------------------------

fn simpleBlock(arena: Allocator, ty: []const u8, text: []const u8) !Value {
    return obj(arena, &.{
        .{ "object", s("block") },
        .{ "type", s(ty) },
        .{ ty, try obj(arena, &.{.{ "rich_text", try arr(arena, try richText(arena, text)) }}) },
    });
}

fn todoBlock(arena: Allocator, text: []const u8, checked: bool) !Value {
    return obj(arena, &.{
        .{ "object", s("block") },
        .{ "type", s("to_do") },
        .{ "to_do", try obj(arena, &.{
            .{ "rich_text", try arr(arena, try richText(arena, text)) },
            .{ "checked", .{ .bool = checked } },
        }) },
    });
}

fn headingBlock(arena: Allocator, level: usize, text: []const u8) !Value {
    const ty = try std.fmt.allocPrint(arena, "heading_{d}", .{level});
    return obj(arena, &.{
        .{ "object", s("block") },
        .{ "type", s(ty) },
        .{ ty, try obj(arena, &.{.{ "rich_text", try arr(arena, try richText(arena, text)) }}) },
    });
}

fn codeBlock(arena: Allocator, content: []const u8, info: []const u8) !Value {
    return obj(arena, &.{
        .{ "object", s("block") },
        .{ "type", s("code") },
        .{ "code", try obj(arena, &.{
            .{ "rich_text", try arr(arena, try plainRichText(arena, content)) },
            .{ "language", s(try notionLanguage(arena, info)) },
        }) },
    });
}

/// Notion validates `language` against a fixed enum and answers 400 on anything
/// else, so an unknown info string degrades to plain text rather than failing
/// the whole push.
fn notionLanguage(arena: Allocator, info: []const u8) ![]const u8 {
    const key = try std.ascii.allocLowerString(arena, std.mem.trim(u8, info, " \t\r"));

    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "", "plain text" },        .{ "text", "plain text" },   .{ "txt", "plain text" },
        .{ "plain", "plain text" },   .{ "plaintext", "plain text" },
        .{ "js", "javascript" },      .{ "jsx", "javascript" },    .{ "node", "javascript" },
        .{ "ts", "typescript" },      .{ "tsx", "typescript" },
        .{ "py", "python" },          .{ "rs", "rust" },
        .{ "sh", "shell" },           .{ "zsh", "shell" },         .{ "bash", "shell" },
        .{ "shell", "shell" },        .{ "yml", "yaml" },          .{ "md", "markdown" },
        .{ "rb", "ruby" },            .{ "kt", "kotlin" },         .{ "cs", "c#" },
        .{ "cpp", "c++" },            .{ "cc", "c++" },            .{ "cxx", "c++" },
        .{ "objc", "objective-c" },   .{ "golang", "go" },         .{ "htm", "html" },
        .{ "psql", "sql" },           .{ "postgres", "sql" },      .{ "dockerfile", "docker" },
    };
    for (aliases) |a| {
        if (std.mem.eql(u8, key, a[0])) return a[1];
    }
    for (notion_languages) |lang| {
        if (std.mem.eql(u8, key, lang)) return lang;
    }
    return "plain text";
}

const notion_languages = [_][]const u8{
    "abap",       "arduino",     "bash",        "basic",     "c",           "c#",
    "c++",        "clojure",     "coffeescript", "css",      "dart",        "diff",
    "docker",     "elixir",      "elm",         "erlang",    "flow",        "fortran",
    "f#",         "gherkin",     "glsl",        "go",        "graphql",     "groovy",
    "haskell",    "html",        "java",        "javascript", "json",       "julia",
    "kotlin",     "latex",       "less",        "lisp",      "livescript",  "lua",
    "makefile",   "markdown",    "markup",      "matlab",    "mermaid",     "nix",
    "objective-c", "ocaml",      "pascal",      "perl",      "php",         "plain text",
    "powershell", "prolog",      "protobuf",    "python",    "r",           "reason",
    "ruby",       "rust",        "sass",        "scala",     "scheme",      "scss",
    "shell",      "sql",         "swift",       "typescript", "vb.net",     "verilog",
    "vhdl",       "visual basic", "webassembly", "xml",      "yaml",
};

// -- inline parsing ----------------------------------------------------------

const Seg = struct { text: []const u8, ann: Ann, link: ?[]const u8 };

/// Code content is literal -- no escape or emphasis processing.
fn plainRichText(arena: Allocator, text: []const u8) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (try chunk(arena, text)) |piece| {
        try out.append(arena, try rtItem(arena, piece, .{}, null));
    }
    return out.toOwnedSlice(arena);
}

pub fn richText(arena: Allocator, text: []const u8) ![]Value {
    var segs: std.ArrayList(Seg) = .empty;
    try parseRun(arena, text, .{}, null, &segs);

    var merged: std.ArrayList(Seg) = .empty;
    for (segs.items) |seg| {
        if (seg.text.len == 0) continue;
        if (merged.items.len > 0) {
            const prev = &merged.items[merged.items.len - 1];
            const same_link = (prev.link == null and seg.link == null) or
                (prev.link != null and seg.link != null and std.mem.eql(u8, prev.link.?, seg.link.?));
            if (prev.ann.eql(seg.ann) and same_link) {
                prev.text = try std.mem.concat(arena, u8, &.{ prev.text, seg.text });
                continue;
            }
        }
        try merged.append(arena, seg);
    }

    var out: std.ArrayList(Value) = .empty;
    for (merged.items) |seg| {
        for (try chunk(arena, seg.text)) |piece| {
            try out.append(arena, try rtItem(arena, piece, seg.ann, seg.link));
        }
    }
    return out.toOwnedSlice(arena);
}

/// Split at Notion's per-element limit, counting code points and never
/// splitting one.
fn chunk(arena: Allocator, text: []const u8) ![][]const u8 {
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (count <= rich_text_limit) {
        const one = try arena.alloc([]const u8, 1);
        one[0] = text;
        return one;
    }

    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i = @min(i + len, text.len);
        n += 1;
        if (n == rich_text_limit) {
            try out.append(arena, text[start..i]);
            start = i;
            n = 0;
        }
    }
    if (start < text.len) try out.append(arena, text[start..]);
    return out.toOwnedSlice(arena);
}

fn rtItem(arena: Allocator, text: []const u8, ann: Ann, link: ?[]const u8) !Value {
    const link_value: Value = if (link) |u|
        try obj(arena, &.{.{ "url", s(u) }})
    else
        .null;

    return obj(arena, &.{
        .{ "type", s("text") },
        .{ "text", try obj(arena, &.{
            .{ "content", s(text) },
            .{ "link", link_value },
        }) },
        .{ "annotations", try obj(arena, &.{
            .{ "bold", .{ .bool = ann.bold } },
            .{ "italic", .{ .bool = ann.italic } },
            .{ "strikethrough", .{ .bool = ann.strike } },
            .{ "underline", .{ .bool = false } },
            .{ "code", .{ .bool = ann.code } },
            .{ "color", s("default") },
        }) },
    });
}

fn parseRun(
    arena: Allocator,
    text: []const u8,
    ann: Ann,
    link: ?[]const u8,
    out: *std.ArrayList(Seg),
) error{OutOfMemory}!void {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    const flush = struct {
        fn f(a: Allocator, b: *std.ArrayList(u8), o: *std.ArrayList(Seg), an: Ann, li: ?[]const u8) !void {
            if (b.items.len == 0) return;
            try o.append(a, .{ .text = try a.dupe(u8, b.items), .ann = an, .link = li });
            b.clearRetainingCapacity();
        }
    }.f;

    while (i < text.len) {
        const c = text[i];

        if (c == '\\' and i + 1 < text.len and isAsciiPunctuation(text[i + 1])) {
            try buf.append(arena, text[i + 1]);
            i += 2;
            continue;
        }

        if (c == '`') {
            const n = runLen(text, i, '`');
            if (findRun(text, i + n, '`', n)) |j| {
                const raw = text[i + n .. j];
                // CommonMark's "one space on each side is padding" rule -- the
                // renderer adds it when the content itself starts or ends with a
                // backtick.
                const content = if (raw.len >= 2 and raw[0] == ' ' and raw[raw.len - 1] == ' ' and
                    std.mem.trim(u8, raw, " ").len > 0)
                    raw[1 .. raw.len - 1]
                else
                    raw;

                try flush(arena, &buf, out, ann, link);
                var code_ann = ann;
                code_ann.code = true;
                try out.append(arena, .{ .text = content, .ann = code_ann, .link = link });
                i = j + n;
                continue;
            }
        }

        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (findPair(text, i + 2, '*')) |j| {
                if (j > i + 2) {
                    try flush(arena, &buf, out, ann, link);
                    var inner = ann;
                    inner.bold = true;
                    try parseRun(arena, text[i + 2 .. j], inner, link, out);
                    i = j + 2;
                    continue;
                }
            }
        }

        if (c == '~' and i + 1 < text.len and text[i + 1] == '~') {
            if (findPair(text, i + 2, '~')) |j| {
                if (j > i + 2) {
                    try flush(arena, &buf, out, ann, link);
                    var inner = ann;
                    inner.strike = true;
                    try parseRun(arena, text[i + 2 .. j], inner, link, out);
                    i = j + 2;
                    continue;
                }
            }
        }

        if (c == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (findChar(text, i + 1, '*')) |j| {
                if (j > i + 1) {
                    try flush(arena, &buf, out, ann, link);
                    var inner = ann;
                    inner.italic = true;
                    try parseRun(arena, text[i + 1 .. j], inner, link, out);
                    i = j + 1;
                    continue;
                }
            }
        }

        if (c == '[') {
            if (tryLink(text, i)) |l| {
                try flush(arena, &buf, out, ann, link);
                try parseRun(arena, text[i + 1 .. l.label_end], ann, l.url, out);
                i = l.end;
                continue;
            }
        }

        try buf.append(arena, c);
        i += 1;
    }
    try flush(arena, &buf, out, ann, link);
}

fn isAsciiPunctuation(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

fn runLen(text: []const u8, start: usize, target: u8) usize {
    var n: usize = 0;
    while (start + n < text.len and text[start + n] == target) n += 1;
    return n;
}

/// Index of the next run of exactly `n` `target` bytes at or after `from`.
fn findRun(text: []const u8, from: usize, target: u8, n: usize) ?usize {
    var i = from;
    while (i < text.len) {
        if (text[i] == target) {
            const len = runLen(text, i, target);
            if (len == n) return i;
            i += len;
        } else i += 1;
    }
    return null;
}

/// Scan forward honouring backslash escapes, so `*a\*b*` closes at the right
/// asterisk.
fn findChar(text: []const u8, from: usize, target: u8) ?usize {
    var i = from;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == target) return i;
        i += 1;
    }
    return null;
}

/// Same, but for a doubled delimiter (`**`, `~~`).
fn findPair(text: []const u8, from: usize, target: u8) ?usize {
    var i = from;
    while (i + 1 < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == target and text[i + 1] == target) return i;
        i += 1;
    }
    return null;
}

const Link = struct { label_end: usize, url: []const u8, end: usize };

fn tryLink(text: []const u8, start: usize) ?Link {
    const close = findChar(text, start + 1, ']') orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = findChar(text, close + 2, ')') orelse return null;
    const url = text[close + 2 .. end];
    if (url.len == 0) return null;
    for (url) |ch| {
        if (std.ascii.isWhitespace(ch)) return null;
    }
    return .{ .label_end = close, .url = url, .end = end + 1 };
}
