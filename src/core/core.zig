//! Stage 1 of the Zig rewrite: pure editor and search logic.
//!
//! Nothing in this module may depend on a platform, a renderer, or I/O. That
//! constraint is what lets the whole thing be tested on a headless machine.

pub const jamo = @import("jamo.zig");
pub const grapheme = @import("grapheme.zig");
pub const width = @import("width.zig");
pub const wrap = @import("wrap.zig");
pub const buffer = @import("buffer.zig");
pub const selection = @import("selection.zig");
pub const word = @import("word.zig");
pub const commands = @import("commands.zig");
pub const markdown = @import("markdown.zig");
pub const rowindex = @import("rowindex.zig");

test {
    _ = jamo;
    _ = grapheme;
    _ = width;
    _ = wrap;
    _ = buffer;
    _ = selection;
    _ = word;
    _ = commands;
    _ = markdown;
    _ = rowindex;
}
