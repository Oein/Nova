//! Tests for the two markdown converters.
//!
//! Ported from the test modules of `src-tauri/src/notion/md_to_blocks.rs` and
//! `blocks_to_md.rs`. The round-trip cases are the strongest check there is:
//! markdown -> blocks -> markdown has to come back byte-identical, or a sync
//! would rewrite the user's file every time it ran.

const std = @import("std");
const db = @import("db");
const model = @import("model.zig");
const b2m = @import("blocks_to_md.zig");
const m2b = @import("md_to_blocks.zig");

const testing = std.testing;
const Value = model.Value;

const Arena = struct {
    state: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(self: *Arena) void {
        self.state.deinit();
    }
    fn a(self: *Arena) std.mem.Allocator {
        return self.state.allocator();
    }
};

/// markdown -> blocks, asserting no placeholders appeared.
fn blocksOf(arena: std.mem.Allocator, md: []const u8) ![]Value {
    const desired = try m2b.parseBody(arena, md);
    var out: std.ArrayList(Value) = .empty;
    for (desired) |d| {
        switch (d) {
            .block => |v| try out.append(arena, v),
            .restore => return error.UnexpectedPlaceholder,
        }
    }
    return out.toOwnedSlice(arena);
}

fn expectRoundtrip(md: []const u8) !void {
    var arena = Arena.init();
    defer arena.deinit();

    const blocks = try blocksOf(arena.a(), md);
    const rendered = try b2m.renderBody(testing.allocator, blocks);
    defer rendered.deinit(testing.allocator);

    testing.expectEqualStrings(md, rendered.markdown) catch |err| {
        std.debug.print("\nround trip failed for:\n{s}\n", .{md});
        return err;
    };
}

test "canonical markdown round-trips" {
    for ([_][]const u8{
        "hello world\n",
        "para one\n\npara two\n",
        "multi line\nsame paragraph\n",
        "# H1\n\n## H2\n\n### H3\n",
        "- a\n- b\n- c\n",
        "1. one\n2. two\n3. three\n",
        "- [ ] todo\n- [x] done\n",
        "> quoted\n> lines\n",
        "---\n",
        "- top\n  - kid\n    - grandkid\n",
        "```rust\nfn main() {}\n```\n",
        "```\nplain\n```\n",
        // Indentation inside a fence is content, not layout.
        "```python\ndef f():\n    if x:\n        return 1\n```\n",
        "```yaml\nroot:\n  child: 1\n```\n",
        "![alt](https://x/y.png)\n",
        "text with **bold** and *italic* and ~~strike~~ and `code`\n",
        "a [link](https://x.dev) inline\n",
        "snake_case stays literal\n",
        "escaped \\* star and \\` tick\n",
        "한글 **강조** 테스트\n",
        "- a\n\nbreak\n\n- b\n",
    }) |md| try expectRoundtrip(md);
}

test "whole pages round-trip, title heading included" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    try long.appendSlice(testing.allocator, "# ");
    for (0..400) |_| try long.appendSlice(testing.allocator, "가");
    try long.appendSlice(testing.allocator, "\n\nbody\n");

    const cases = [_][]const u8{
        "# 제목입니다\n\n본문 첫 줄\n\n- 항목 *하나*\n- 항목 둘\n",
        "# Title\n\nbody\n",
        long.items,
    };

    for (cases) |md| {
        var arena = Arena.init();
        defer arena.deinit();

        // The title is derived from the body, and capped -- but the heading
        // line itself must survive whole, however long it is.
        const title = db.workspace.firstLineTitle(md, "Untitled");
        const blocks = try blocksOf(arena.a(), md);
        const rendered = try b2m.renderPage(testing.allocator, title, blocks);
        defer rendered.deinit(testing.allocator);

        testing.expectEqualStrings(md, rendered.markdown) catch |err| {
            std.debug.print("\npage round trip failed for:\n{s}\n", .{md});
            return err;
        };
    }
}

test "a Notion-authored page gains a title heading" {
    var arena = Arena.init();
    defer arena.deinit();

    const blocks = try blocksOf(arena.a(), "just a body\n");
    const rendered = try b2m.renderPage(testing.allocator, "Page Title", blocks);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("# Page Title\n\njust a body\n", rendered.markdown);
}

test "an untitled page still gets a heading" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "body\n");
    const rendered = try b2m.renderPage(testing.allocator, "", blocks);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("# Untitled\n\nbody\n", rendered.markdown);
}

test "a truncated Notion title still matches its full heading" {
    var arena = Arena.init();
    defer arena.deinit();

    // Notion caps the title property; the body keeps the whole line. Both go
    // through `firstLineTitle`, so the heading is not duplicated.
    const md = "# A very long heading that Notion had to shorten\n\nbody\n";
    const blocks = try blocksOf(arena.a(), md);
    const rendered = try b2m.renderPage(
        testing.allocator,
        "A very long heading that Notion had to shorten",
        blocks,
    );
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings(md, rendered.markdown);
}

test "placeholders become restores and keep their ids" {
    var arena = Arena.init();
    defer arena.deinit();

    const line = try b2m.placeholderLine(arena.a(), "table", "tbl-1");
    const md = try std.fmt.allocPrint(arena.a(), "# T\n\nbefore\n\n{s}\n\nafter\n", .{line});

    const desired = try m2b.parseBody(arena.a(), md);
    const ids = try m2b.referencedBlockIds(arena.a(), desired);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("tbl-1", ids[0]);
}

test "a mangled placeholder is treated as ordinary text" {
    // Deliberate: a broken marker means the user deleted the block.
    try testing.expect(b2m.parsePlaceholder("<!-- notion:unsupported type=table -->") == null);
    try testing.expect(b2m.parsePlaceholder("<!-- notion:unsupported id=x -->") == null);
    try testing.expect(b2m.parsePlaceholder("just a comment") == null);
    try testing.expect(b2m.parsePlaceholder("<!-- notion:unsupported type=a id=b junk -->") == null);

    const ok = b2m.parsePlaceholder("<!-- notion:unsupported type=table id=tbl-1 -->").?;
    try testing.expectEqualStrings("table", ok.block_type);
    try testing.expectEqualStrings("tbl-1", ok.id);
}

test "the read-only marker is skipped on the way back in" {
    var arena = Arena.init();
    defer arena.deinit();
    const md = b2m.readonly_marker ++ "\nbody\n";
    const blocks = try blocksOf(arena.a(), md);
    try testing.expectEqual(@as(usize, 1), blocks.len);
}

test "unknown code languages degrade to plain text" {
    var arena = Arena.init();
    defer arena.deinit();

    const blocks = try blocksOf(arena.a(), "```wingdings\nx\n```\n");
    const lang = blocks[0].object.get("code").?.object.get("language").?.string;
    try testing.expectEqualStrings("plain text", lang);

    const mapped = try blocksOf(arena.a(), "```rs\nx\n```\n");
    try testing.expectEqualStrings(
        "rust",
        mapped[0].object.get("code").?.object.get("language").?.string,
    );
}

test "a longer fence is emitted when the content holds backticks" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "```\nhas ``` inside\n```\n");
    const rendered = try b2m.renderBody(testing.allocator, blocks);
    defer rendered.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, rendered.markdown, "````"));
}

test "an over-indented list run is promoted rather than dropped" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "    - deep\n    - also deep\n");
    try testing.expectEqual(@as(usize, 2), blocks.len);
}

test "an empty paragraph is dropped" {
    var arena = Arena.init();
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"  "}}]}},
        \\ {"type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"real"}}]}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("real\n", rendered.markdown);
}

test "a mention escalates its block to a placeholder" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"id":"b1","type":"paragraph","paragraph":{"rich_text":[
        \\  {"type":"mention","mention":{"type":"page","page":{"id":"p1"}}}]}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.markdown, "notion:unsupported") != null);
    try testing.expectEqual(@as(usize, 1), rendered.unsupported.len);
    try testing.expectEqualStrings("b1", rendered.unsupported[0].block_id);
    // A paragraph is recreatable, so this does not force pull-only mode.
    try testing.expect(!rendered.has_unrecreatable);
}

test "an unrecreatable block puts the note into pull-only mode" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"id":"b1","type":"synced_block","synced_block":{}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expect(rendered.has_unrecreatable);
}

test "a block claiming unfetched children becomes a placeholder" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"id":"b1","type":"paragraph","has_children":true,
        \\  "paragraph":{"rich_text":[{"type":"text","text":{"content":"x"}}]}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, rendered.markdown, "notion:unsupported") != null);
}

test "adjacent runs with identical formatting merge" {
    // Notion splits runs at edit boundaries, not style boundaries, so without
    // merging this would render as `**a****b**`.
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"type":"paragraph","paragraph":{"rich_text":[
        \\  {"type":"text","text":{"content":"a"},"annotations":{"bold":true}},
        \\  {"type":"text","text":{"content":"b"},"annotations":{"bold":true}}]}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("**ab**\n", rendered.markdown);
}

test "a code annotation wins over other emphasis" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"type":"paragraph","paragraph":{"rich_text":[
        \\  {"type":"text","text":{"content":"x"},"annotations":{"bold":true,"code":true}}]}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("`x`\n", rendered.markdown);
}

test "escaping is minimal but sufficient" {
    var arena = Arena.init();
    defer arena.deinit();

    // `_` is left alone so snake_case survives.
    try testing.expectEqualStrings("snake_case", try b2m.escapeInline(arena.a(), "snake_case"));
    try testing.expectEqualStrings("a\\*b", try b2m.escapeInline(arena.a(), "a*b"));
    try testing.expectEqualStrings("a\\`b", try b2m.escapeInline(arena.a(), "a`b"));
    // `[` is escaped only when a `](` actually follows.
    try testing.expectEqualStrings("a[b", try b2m.escapeInline(arena.a(), "a[b"));
    try testing.expectEqualStrings("\\[a](b)", try b2m.escapeInline(arena.a(), "[a](b)"));
}

test "a line-leading block marker is disarmed" {
    var arena = Arena.init();
    defer arena.deinit();

    try testing.expectEqualStrings("\\- not a list", try b2m.escapeLineStart(arena.a(), "- not a list"));
    try testing.expectEqualStrings("\\# not a heading", try b2m.escapeLineStart(arena.a(), "# not a heading"));
    try testing.expectEqualStrings("\\> not a quote", try b2m.escapeLineStart(arena.a(), "> not a quote"));
    try testing.expectEqualStrings("\\---", try b2m.escapeLineStart(arena.a(), "---"));
    // An ordered marker is escaped at the dot: `\` only escapes punctuation.
    try testing.expectEqualStrings("1\\. not a list", try b2m.escapeLineStart(arena.a(), "1. not a list"));
    try testing.expectEqualStrings("ordinary text", try b2m.escapeLineStart(arena.a(), "ordinary text"));
}

test "an escaped delimiter does not close emphasis" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "*a\\*b*\n");
    const rt = blocks[0].object.get("paragraph").?.object.get("rich_text").?.array;
    try testing.expectEqual(@as(usize, 1), rt.items.len);
    try testing.expectEqualStrings("a*b", rt.items[0].object.get("text").?.object.get("content").?.string);
    try testing.expect(rt.items[0].object.get("annotations").?.object.get("italic").?.bool);
}

test "unterminated markup stays literal" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "**not closed\n");
    const rt = blocks[0].object.get("paragraph").?.object.get("rich_text").?.array;
    try testing.expectEqualStrings("**not closed", rt.items[0].object.get("text").?.object.get("content").?.string);
}

test "rich text is chunked at Notion's element limit" {
    var arena = Arena.init();
    defer arena.deinit();

    var long: std.ArrayList(u8) = .empty;
    for (0..2500) |_| try long.append(arena.a(), 'a');
    const items = try m2b.richText(arena.a(), long.items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(
        @as(usize, 2000),
        items[0].object.get("text").?.object.get("content").?.string.len,
    );
}

test "chunking counts code points, not bytes" {
    var arena = Arena.init();
    defer arena.deinit();

    // 2500 Hangul syllables is 7500 bytes but only 2500 code points.
    var long: std.ArrayList(u8) = .empty;
    for (0..2500) |_| try long.appendSlice(arena.a(), "가");
    const items = try m2b.richText(arena.a(), long.items);
    try testing.expectEqual(@as(usize, 2), items.len);

    const first = items[0].object.get("text").?.object.get("content").?.string;
    try testing.expectEqual(@as(usize, 2000), try std.unicode.utf8CountCodepoints(first));
    // And it never splits a syllable.
    try testing.expect(std.unicode.utf8ValidateSlice(first));
}

test "nested emphasis inside a link is preserved" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "[**bold link**](https://x.dev)\n");
    const rt = blocks[0].object.get("paragraph").?.object.get("rich_text").?.array;
    try testing.expectEqual(@as(usize, 1), rt.items.len);
    try testing.expect(rt.items[0].object.get("annotations").?.object.get("bold").?.bool);
    try testing.expectEqualStrings(
        "https://x.dev",
        rt.items[0].object.get("text").?.object.get("link").?.object.get("url").?.string,
    );
}

test "a numbered list restarts after a non-list sibling" {
    var arena = Arena.init();
    defer arena.deinit();
    const blocks = try blocksOf(arena.a(), "1. one\n2. two\n\nbreak\n\n1. again\n");
    const rendered = try b2m.renderBody(testing.allocator, blocks);
    defer rendered.deinit(testing.allocator);
    try testing.expectEqualStrings("1. one\n2. two\n\nbreak\n\n1. again\n", rendered.markdown);
}

test "a Notion-hosted image is not representable" {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator,
        \\[{"id":"b1","type":"image","image":{"type":"file","file":{"url":"https://s3/x"}}}]
    , .{});
    defer parsed.deinit();

    const rendered = try b2m.renderBody(testing.allocator, parsed.value.array.items);
    defer rendered.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, rendered.markdown, "notion:unsupported") != null);
    // Its URL expires and there is no upload API, so it also blocks pushing.
    try testing.expect(rendered.has_unrecreatable);
}
