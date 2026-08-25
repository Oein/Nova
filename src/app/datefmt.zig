//! Grouping the note list by local day.
//!
//! Ported from `src/lib/dateGrouping.ts`.

const std = @import("std");
const db = @import("db");
const localtime = @import("platform").localtime;

const Note = db.workspace.Note;
const Allocator = std.mem.Allocator;

pub const key_len = "YYYY-MM-DD".len;
pub const Key = [key_len]u8;

pub fn bucketKey(mtime_ms: i64) Key {
    var out: Key = undefined;
    _ = localtime.dateOf(mtime_ms).writeKey(&out);
    return out;
}

/// Display label for a bucket: the two most recent days get names, older ones
/// show the raw date.
///
/// `key` is taken by pointer because the fallback label borrows from it -- a
/// by-value parameter would hand back a slice of the callee's own stack.
pub fn bucketLabel(key: *const Key, now_ms: i64) []const u8 {
    const today = bucketKey(now_ms);
    if (std.mem.eql(u8, key, &today)) return "Today";
    const yesterday = bucketKey(now_ms - std.time.ms_per_day);
    if (std.mem.eql(u8, key, &yesterday)) return "Yesterday";
    return key;
}

pub const Group = struct {
    key: Key,
    /// Borrowed from the caller's note list.
    entries: []const Note,

    pub fn count(self: Group) usize {
        return self.entries.len;
    }

    /// The display label.
    ///
    /// A method rather than a stored field: the fallback label is a slice of
    /// `key`, so storing it would alias the struct's own memory -- and copying
    /// the struct (into an array, out of a function) would leave the slice
    /// pointing at the original. Computing it from `self` is always right.
    pub fn label(self: *const Group, now_ms: i64) []const u8 {
        return bucketLabel(&self.key, now_ms);
    }
};

/// Sort `notes` in place (newest first, ties broken by id) and bucket them by
/// local day. Groups borrow from `notes`, which must outlive them.
pub fn groupByLocalDay(gpa: Allocator, notes: []Note, now_ms: i64) ![]Group {
    _ = now_ms;
    std.mem.sort(Note, notes, {}, struct {
        fn lessThan(_: void, a: Note, b: Note) bool {
            if (a.mtime_ms != b.mtime_ms) return a.mtime_ms > b.mtime_ms;
            // A stable tiebreak keeps the list from shuffling when two notes
            // share an mtime.
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(gpa);

    var start: usize = 0;
    while (start < notes.len) {
        const key = bucketKey(notes[start].mtime_ms);
        var end = start + 1;
        while (end < notes.len and std.mem.eql(u8, &bucketKey(notes[end].mtime_ms), &key)) {
            end += 1;
        }
        try groups.append(gpa, .{ .key = key, .entries = notes[start..end] });
        start = end;
    }
    return groups.toOwnedSlice(gpa);
}

// -- tests -------------------------------------------------------------------
// Ported from src/lib/dateGrouping.test.ts.

const testing = std.testing;

fn note(id: []const u8, mtime: i64) Note {
    return .{ .id = id, .title = id, .created_ms = mtime, .mtime_ms = mtime, .size = 0 };
}

test "bucketKey is stable within a local day" {
    // 09:00 and 21:00 on the same local day. Picking a midday base keeps this
    // true in every timezone.
    const base: i64 = 1_724_500_000_000;
    const morning = base - 6 * std.time.ms_per_hour;
    const evening = base + 6 * std.time.ms_per_hour;
    try testing.expectEqualSlices(u8, &bucketKey(morning), &bucketKey(evening));
}

test "bucketKey differs across a day boundary" {
    const base: i64 = 1_724_500_000_000;
    try testing.expect(!std.mem.eql(
        u8,
        &bucketKey(base),
        &bucketKey(base + std.time.ms_per_day),
    ));
}

test "bucketLabel names today and yesterday" {
    const now: i64 = 1_724_500_000_000;
    var today_key = bucketKey(now);
    try testing.expectEqualStrings("Today", bucketLabel(&today_key, now));
    var yesterday_key = bucketKey(now - std.time.ms_per_day);
    try testing.expectEqualStrings("Yesterday", bucketLabel(&yesterday_key, now));

    const older = bucketKey(now - 7 * std.time.ms_per_day);
    const label = bucketLabel(&older, now);
    try testing.expectEqual(@as(usize, key_len), label.len);
    try testing.expectEqualSlices(u8, &older, label);
}

test "groupByLocalDay sorts newest first and buckets by day" {
    const now: i64 = 1_724_500_000_000;
    const day = std.time.ms_per_day;

    var notes = [_]Note{
        note("old", now - 2 * day),
        note("today-a", now),
        note("yesterday", now - day),
        note("today-b", now - std.time.ms_per_hour),
    };

    const groups = try groupByLocalDay(testing.allocator, &notes, now);
    defer testing.allocator.free(groups);

    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("Today", groups[0].label(now));
    try testing.expectEqual(@as(usize, 2), groups[0].count());
    try testing.expectEqualStrings("today-a", groups[0].entries[0].id);
    try testing.expectEqualStrings("today-b", groups[0].entries[1].id);

    try testing.expectEqualStrings("Yesterday", groups[1].label(now));
    try testing.expectEqual(@as(usize, 1), groups[1].count());
    try testing.expectEqual(@as(usize, 1), groups[2].count());
}

test "ties break on id so the order is stable" {
    const now: i64 = 1_724_500_000_000;
    var notes = [_]Note{ note("b", now), note("a", now) };

    const groups = try groupByLocalDay(testing.allocator, &notes, now);
    defer testing.allocator.free(groups);

    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("a", groups[0].entries[0].id);
    try testing.expectEqualStrings("b", groups[0].entries[1].id);
}

test "an empty list yields no groups" {
    var notes = [_]Note{};
    const groups = try groupByLocalDay(testing.allocator, &notes, 0);
    defer testing.allocator.free(groups);
    try testing.expectEqual(@as(usize, 0), groups.len);
}

test "every note lands in exactly one group" {
    const now: i64 = 1_724_500_000_000;
    var notes = [_]Note{
        note("a", now),
        note("b", now - std.time.ms_per_day),
        note("c", now - 5 * std.time.ms_per_day),
        note("d", now),
    };
    const groups = try groupByLocalDay(testing.allocator, &notes, now);
    defer testing.allocator.free(groups);

    var total: usize = 0;
    for (groups) |g| total += g.count();
    try testing.expectEqual(notes.len, total);
}

test "a group's label survives being copied" {
    // Regression guard: the label used to be a stored slice of the group's own
    // `key`, so copying the struct left it pointing at the original's memory.
    const now: i64 = 1_724_500_000_000;
    var notes = [_]Note{note("a", now - 7 * std.time.ms_per_day)};

    const groups = try groupByLocalDay(testing.allocator, &notes, now);
    defer testing.allocator.free(groups);

    var copies: std.ArrayList(Group) = .empty;
    defer copies.deinit(testing.allocator);
    try copies.appendSlice(testing.allocator, groups);

    try testing.expectEqualSlices(u8, &groups[0].key, &copies.items[0].key);
    try testing.expectEqualSlices(
        u8,
        groups[0].label(now),
        copies.items[0].label(now),
    );
    // The label points into the copy, not the original.
    try testing.expectEqual(
        @intFromPtr(&copies.items[0].key),
        @intFromPtr(copies.items[0].label(now).ptr),
    );
}
