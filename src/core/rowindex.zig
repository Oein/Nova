//! Maps buffer lines to visual rows and back, under soft wrap.
//!
//! Replaces the `lineYOffset` prefix-sum array in `Editor.svelte`. That array
//! was rebuilt from the edit point to the end of the document on *every*
//! keystroke (`rebuildLineYOffsetFrom`, :276) -- an O(lines) walk per character
//! typed, and the main reason typing degraded on large notes.
//!
//! Structure: a blocked prefix sum. Lines are partitioned into blocks of about
//! `block_target` entries, each caching its own sum.
//!
//!   * `setRowCount` -- O(blocks) to locate, O(1) to apply
//!   * `firstRow` / `lineAtRow` -- O(blocks + block size)
//!   * `replaceRange` -- O(block size) plus the spliced lines
//!
//! A Fenwick tree gives O(log n) for the first three but cannot insert or
//! remove a line, which is exactly what pressing Enter does. Blocking keeps
//! splices cheap and is flat and cache-friendly: a 200k-line note is ~200
//! blocks, so a lookup adds ~200 u64s instead of walking 200,000 entries.

const std = @import("std");

const block_target: usize = 1024;
const block_max: usize = block_target * 2;

const Block = struct {
    counts: std.ArrayList(u32),
    sum: u64,

    fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }

    fn recomputeSum(self: *Block) void {
        var s: u64 = 0;
        for (self.counts.items) |c| s += c;
        self.sum = s;
    }
};

pub const RowIndex = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,

    pub fn init(gpa: std.mem.Allocator) RowIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RowIndex) void {
        for (self.blocks.items) |*b| b.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
    }

    fn clear(self: *RowIndex) void {
        for (self.blocks.items) |*b| b.deinit(self.gpa);
        self.blocks.clearRetainingCapacity();
    }

    /// Replace the whole index with `counts` (one sub-row count per line).
    pub fn rebuild(self: *RowIndex, counts: []const u32) !void {
        self.clear();
        var i: usize = 0;
        while (i < counts.len) {
            const end = @min(i + block_target, counts.len);
            var b = Block{ .counts = .empty, .sum = 0 };
            errdefer b.deinit(self.gpa);
            try b.counts.appendSlice(self.gpa, counts[i..end]);
            b.recomputeSum();
            try self.blocks.append(self.gpa, b);
            i = end;
        }
    }

    /// Number of lines.
    pub fn len(self: *const RowIndex) usize {
        var n: usize = 0;
        for (self.blocks.items) |b| n += b.counts.items.len;
        return n;
    }

    /// Total visual rows in the document.
    pub fn totalRows(self: *const RowIndex) u64 {
        var n: u64 = 0;
        for (self.blocks.items) |b| n += b.sum;
        return n;
    }

    const Located = struct { block: usize, offset: usize };

    fn locate(self: *const RowIndex, line: usize) ?Located {
        var remaining = line;
        for (self.blocks.items, 0..) |b, bi| {
            if (remaining < b.counts.items.len) return .{ .block = bi, .offset = remaining };
            remaining -= b.counts.items.len;
        }
        return null;
    }

    pub fn rowCount(self: *const RowIndex, line: usize) u32 {
        const at = self.locate(line) orelse return 0;
        return self.blocks.items[at.block].counts.items[at.offset];
    }

    pub fn setRowCount(self: *RowIndex, line: usize, n: u32) void {
        const at = self.locate(line) orelse return;
        const b = &self.blocks.items[at.block];
        const old = b.counts.items[at.offset];
        b.counts.items[at.offset] = n;
        b.sum = b.sum - old + n;
    }

    /// Visual row where `line` starts. `line == len()` yields `totalRows()`.
    pub fn firstRow(self: *const RowIndex, line: usize) u64 {
        var remaining = line;
        var acc: u64 = 0;
        for (self.blocks.items) |b| {
            if (remaining >= b.counts.items.len) {
                acc += b.sum;
                remaining -= b.counts.items.len;
                continue;
            }
            for (b.counts.items[0..remaining]) |c| acc += c;
            return acc;
        }
        return acc;
    }

    /// The line owning visual row `row`.
    ///
    /// Rows past the end clamp to the last line, matching
    /// `bufferLineAtVisualRow` in the original.
    pub fn lineAtRow(self: *const RowIndex, row: u64) usize {
        var remaining = row;
        var line: usize = 0;
        for (self.blocks.items) |b| {
            if (remaining >= b.sum and b.sum > 0) {
                // The row is past this whole block -- unless this is the last
                // block, in which case we clamp inside it below.
                if (line + b.counts.items.len < self.len()) {
                    remaining -= b.sum;
                    line += b.counts.items.len;
                    continue;
                }
            }
            for (b.counts.items, 0..) |c, i| {
                if (remaining < c) return line + i;
                remaining -= c;
            }
            // Everything in this block consumed; clamp to its last line.
            if (b.counts.items.len > 0) return line + b.counts.items.len - 1;
        }
        const total = self.len();
        return if (total == 0) 0 else total - 1;
    }

    /// Replace `count` lines starting at `from` with `new_counts`.
    ///
    /// This is the splice a buffer edit produces: `Change.replace` says lines
    /// `[from_line, to_line)` became `new_line_count` lines.
    pub fn replaceRange(
        self: *RowIndex,
        from: usize,
        count: usize,
        new_counts: []const u32,
    ) !void {
        // Flatten, splice, re-block. Blocks are only ~1024 entries, but a
        // splice can cross several of them, and keeping the block invariant
        // straight across a partial overlap is where bugs live. Rebuilding is
        // O(lines) which is the same order as the wrap recomputation the caller
        // just did for the same range -- except when the splice is confined to
        // one block, handled below.
        if (count == new_counts.len) {
            // Pure in-place update -- the common case for a single-line edit.
            for (new_counts, 0..) |c, i| self.setRowCount(from + i, c);
            return;
        }

        var flat: std.ArrayList(u32) = .empty;
        defer flat.deinit(self.gpa);
        try flat.ensureTotalCapacity(self.gpa, self.len() + new_counts.len);
        for (self.blocks.items) |b| try flat.appendSlice(self.gpa, b.counts.items);

        const end = @min(from + count, flat.items.len);
        const start = @min(from, flat.items.len);
        try flat.replaceRange(self.gpa, start, end - start, new_counts);
        try self.rebuild(flat.items);
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

/// Naive reference: a plain array of per-line counts.
const Ref = struct {
    counts: std.ArrayList(u32) = .empty,

    fn deinit(self: *Ref, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }
    fn firstRow(self: *const Ref, line: usize) u64 {
        var acc: u64 = 0;
        for (self.counts.items[0..@min(line, self.counts.items.len)]) |c| acc += c;
        return acc;
    }
    fn totalRows(self: *const Ref) u64 {
        return self.firstRow(self.counts.items.len);
    }
    fn lineAtRow(self: *const Ref, row: u64) usize {
        var remaining = row;
        for (self.counts.items, 0..) |c, i| {
            if (remaining < c) return i;
            remaining -= c;
        }
        return if (self.counts.items.len == 0) 0 else self.counts.items.len - 1;
    }
};

test "empty index" {
    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    try ix.rebuild(&.{});
    try testing.expectEqual(@as(usize, 0), ix.len());
    try testing.expectEqual(@as(u64, 0), ix.totalRows());
    try testing.expectEqual(@as(usize, 0), ix.lineAtRow(0));
}

test "prefix sums and inverse lookup" {
    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    try ix.rebuild(&.{ 1, 3, 1, 2 }); // rows: [0], [1,2,3], [4], [5,6]

    try testing.expectEqual(@as(u64, 7), ix.totalRows());
    try testing.expectEqual(@as(u64, 0), ix.firstRow(0));
    try testing.expectEqual(@as(u64, 1), ix.firstRow(1));
    try testing.expectEqual(@as(u64, 4), ix.firstRow(2));
    try testing.expectEqual(@as(u64, 5), ix.firstRow(3));
    try testing.expectEqual(@as(u64, 7), ix.firstRow(4)); // one past the end

    const expect_line = [_]usize{ 0, 1, 1, 1, 2, 3, 3 };
    for (expect_line, 0..) |want, row| {
        try testing.expectEqual(want, ix.lineAtRow(row));
    }
    // Past the end clamps to the last line.
    try testing.expectEqual(@as(usize, 3), ix.lineAtRow(99));
}

test "setRowCount updates sums" {
    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    try ix.rebuild(&.{ 1, 1, 1 });
    ix.setRowCount(1, 5);
    try testing.expectEqual(@as(u32, 5), ix.rowCount(1));
    try testing.expectEqual(@as(u64, 7), ix.totalRows());
    try testing.expectEqual(@as(u64, 6), ix.firstRow(2));
}

test "replaceRange splices lines" {
    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    try ix.rebuild(&.{ 1, 2, 3 });

    // Pressing Enter on line 1 turns it into two lines.
    try ix.replaceRange(1, 1, &.{ 1, 1 });
    try testing.expectEqual(@as(usize, 4), ix.len());
    try testing.expectEqual(@as(u64, 6), ix.totalRows());
    try testing.expectEqual(@as(u32, 3), ix.rowCount(3));

    // Joining lines 0..2 back into one.
    try ix.replaceRange(0, 3, &.{4});
    try testing.expectEqual(@as(usize, 2), ix.len());
    try testing.expectEqual(@as(u64, 7), ix.totalRows());
}

test "spans multiple blocks" {
    var counts: [5000]u32 = undefined;
    for (&counts, 0..) |*c, i| c.* = @intCast(1 + (i % 3));

    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    try ix.rebuild(&counts);
    try testing.expect(ix.blocks.items.len > 1);
    try testing.expectEqual(@as(usize, 5000), ix.len());

    var ref = Ref{};
    defer ref.deinit(testing.allocator);
    try ref.counts.appendSlice(testing.allocator, &counts);

    try testing.expectEqual(ref.totalRows(), ix.totalRows());
    for ([_]usize{ 0, 1, 1023, 1024, 1025, 2048, 4999, 5000 }) |line| {
        try testing.expectEqual(ref.firstRow(line), ix.firstRow(line));
    }
    for ([_]u64{ 0, 1, 100, 2047, 2048, ref.totalRows() - 1 }) |row| {
        try testing.expectEqual(ref.lineAtRow(row), ix.lineAtRow(row));
    }
}

test "fuzz: random splices and updates match the naive reference" {
    var s: u32 = 0x1234_5678;
    const rand = struct {
        fn next(state: *u32) u32 {
            state.* ^= state.* << 13;
            state.* ^= state.* >> 17;
            state.* ^= state.* << 5;
            return state.*;
        }
    }.next;

    var ix = RowIndex.init(testing.allocator);
    defer ix.deinit();
    var ref = Ref{};
    defer ref.deinit(testing.allocator);

    // Start with enough lines to cross several blocks.
    var seed_counts: [3000]u32 = undefined;
    for (&seed_counts, 0..) |*c, i| c.* = @intCast(1 + (i % 4));
    try ix.rebuild(&seed_counts);
    try ref.counts.appendSlice(testing.allocator, &seed_counts);

    var op: usize = 0;
    while (op < 600) : (op += 1) {
        const n = ref.counts.items.len;
        const choice = rand(&s) % 3;
        if (choice == 0 and n > 0) {
            // Point update.
            const line = rand(&s) % n;
            const val = 1 + rand(&s) % 5;
            ix.setRowCount(line, val);
            ref.counts.items[line] = val;
        } else if (choice == 1 and n > 4) {
            // Delete a run of lines.
            const from = rand(&s) % (n - 3);
            const count = 1 + rand(&s) % 3;
            try ix.replaceRange(from, count, &.{});
            try ref.counts.replaceRange(testing.allocator, from, count, &.{});
        } else {
            // Insert a run of lines.
            const from = rand(&s) % (n + 1);
            var buf: [3]u32 = undefined;
            const k = 1 + rand(&s) % 3;
            for (buf[0..k]) |*c| c.* = 1 + rand(&s) % 4;
            try ix.replaceRange(from, 0, buf[0..k]);
            try ref.counts.replaceRange(testing.allocator, from, 0, buf[0..k]);
        }

        try testing.expectEqual(ref.counts.items.len, ix.len());
        try testing.expectEqual(ref.totalRows(), ix.totalRows());

        if (op % 37 == 0 and ref.counts.items.len > 0) {
            const line = rand(&s) % ref.counts.items.len;
            try testing.expectEqual(ref.firstRow(line), ix.firstRow(line));
            const total = ref.totalRows();
            if (total > 0) {
                const row = rand(&s) % total;
                try testing.expectEqual(ref.lineAtRow(row), ix.lineAtRow(row));
            }
        }
    }
}
