//! Stage 2: workspace storage.

pub const sqlite = @import("sqlite.zig");
pub const fsx = @import("fsx.zig");
pub const schema = @import("schema.zig");
pub const workspace = @import("workspace.zig");
pub const search = @import("search.zig");

test {
    _ = sqlite;
    _ = fsx;
    _ = schema;
    _ = workspace;
    _ = search;
}
