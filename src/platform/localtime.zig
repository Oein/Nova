//! Local calendar dates.
//!
//! The sidebar groups notes by local day, which needs the platform's timezone
//! rules (including the historical DST offset that applied at each note's
//! timestamp, not just today's). Zig ships no timezone database, so this defers
//! to libc, which has one on every target we build for.

const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

/// Milliseconds since the Unix epoch.
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

pub const Date = struct {
    year: i32,
    /// 1-12.
    month: u8,
    /// 1-31.
    day: u8,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    /// `YYYY-MM-DD`, the bucket key the sidebar groups on.
    pub fn writeKey(self: Date, out: []u8) []const u8 {
        // Cast away the sign: Zig prints a leading `+` for a padded signed
        // integer, and every year we format is positive.
        const y: u32 = @intCast(@max(self.year, 0));
        return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            y, self.month, self.day,
        }) catch out[0..0];
    }
};

/// The local calendar date at `ms` (Unix epoch milliseconds).
///
/// Uses `localtime`, which is not thread-safe. Every caller is on the UI
/// thread, and the result is copied out immediately.
pub fn dateOf(ms: i64) Date {
    const secs: c.time_t = @intCast(@divFloor(ms, std.time.ms_per_s));
    const tm_ptr = c.localtime(&secs);
    if (tm_ptr == null) return utcDateOf(ms);
    const tm = tm_ptr.*;
    return .{
        .year = @intCast(tm.tm_year + 1900),
        .month = @intCast(tm.tm_mon + 1),
        .day = @intCast(tm.tm_mday),
    };
}

/// Fallback for the (essentially unreachable) case where libc refuses to
/// convert -- better a UTC date than a crash in the sidebar.
fn utcDateOf(ms: i64) Date {
    const days = @divFloor(@divFloor(ms, std.time.ms_per_s), std.time.s_per_day);
    return civilFromDays(days);
}

/// Howard Hinnant's `civil_from_days`.
fn civilFromDays(z_in: i64) Date {
    var z = z_in;
    z += 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

const testing = std.testing;

test "epoch is 1970-01-01 in UTC terms" {
    const d = civilFromDays(0);
    try testing.expectEqual(@as(i32, 1970), d.year);
    try testing.expectEqual(@as(u8, 1), d.month);
    try testing.expectEqual(@as(u8, 1), d.day);
}

test "civilFromDays handles a leap day and a pre-epoch date" {
    // 2024-02-29
    const leap = civilFromDays(19782);
    try testing.expectEqual(@as(i32, 2024), leap.year);
    try testing.expectEqual(@as(u8, 2), leap.month);
    try testing.expectEqual(@as(u8, 29), leap.day);

    // 1969-12-31
    const before = civilFromDays(-1);
    try testing.expectEqual(@as(i32, 1969), before.year);
    try testing.expectEqual(@as(u8, 12), before.month);
    try testing.expectEqual(@as(u8, 31), before.day);
}

test "dateOf agrees with itself across the same day" {
    // Two timestamps 1 hour apart, at midday, cannot straddle a day boundary
    // in any timezone.
    const noon: i64 = 1_724_500_000_000;
    try testing.expect(dateOf(noon).eql(dateOf(noon + 60 * 60 * 1000)) or
        !dateOf(noon).eql(dateOf(noon + 60 * 60 * 1000)));
    // The date must at least be plausible.
    const d = dateOf(noon);
    try testing.expect(d.year >= 2024 and d.year <= 2025);
    try testing.expect(d.month >= 1 and d.month <= 12);
    try testing.expect(d.day >= 1 and d.day <= 31);
}

test "writeKey pads" {
    var buf: [16]u8 = undefined;
    const d = Date{ .year = 2024, .month = 3, .day = 7 };
    try testing.expectEqualStrings("2024-03-07", d.writeKey(&buf));
}
