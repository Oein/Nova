//! Anchor/head text selection.
//!
//! Ported from `src/lib/editor/selection.ts`. The original carried a
//! `selections: Selection[]` array with a `primary` index, but nothing ever
//! pushed a second entry -- multi-cursor was structural, never wired up. This
//! collapses to a single selection; reintroducing multi-cursor later means
//! adding an array here rather than unpicking dead generality.

const std = @import("std");
const buffer = @import("buffer.zig");
const Pos = buffer.Pos;

pub const Selection = struct {
    anchor: Pos,
    head: Pos,

    pub const initial: Selection = .{
        .anchor = .{ .line = 0, .col = 0 },
        .head = .{ .line = 0, .col = 0 },
    };

    pub fn isEmpty(self: Selection) bool {
        return self.anchor.eql(self.head);
    }

    /// The selection as a forward range.
    pub fn ordered(self: Selection) struct { from: Pos, to: Pos } {
        if (Pos.before(self.anchor, self.head)) {
            return .{ .from = self.anchor, .to = self.head };
        }
        return .{ .from = self.head, .to = self.anchor };
    }

    /// Collapse to a single point.
    pub fn at(p: Pos) Selection {
        return .{ .anchor = p, .head = p };
    }

    /// Move the head, keeping the anchor if `extend`.
    pub fn moveTo(self: Selection, p: Pos, extend: bool) Selection {
        return .{ .anchor = if (extend) self.anchor else p, .head = p };
    }
};

const testing = std.testing;

test "isEmpty" {
    try testing.expect(Selection.initial.isEmpty());
    try testing.expect(!(Selection{
        .anchor = .{ .line = 0, .col = 0 },
        .head = .{ .line = 0, .col = 1 },
    }).isEmpty());
}

test "ordered normalizes a backwards selection" {
    const s = Selection{
        .anchor = .{ .line = 2, .col = 1 },
        .head = .{ .line = 0, .col = 3 },
    };
    const r = s.ordered();
    try testing.expectEqual(Pos{ .line = 0, .col = 3 }, r.from);
    try testing.expectEqual(Pos{ .line = 2, .col = 1 }, r.to);
}

test "moveTo respects extend" {
    const s = Selection.at(.{ .line = 0, .col = 0 });
    const extended = s.moveTo(.{ .line = 0, .col = 5 }, true);
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, extended.anchor);
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, extended.head);

    const collapsed = s.moveTo(.{ .line = 0, .col = 5 }, false);
    try testing.expect(collapsed.isEmpty());
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, collapsed.head);
}
