//! Stage 4: networking.

pub const updater = @import("updater.zig");

pub const notion = struct {
    pub const model = @import("notion/model.zig");
    pub const blocks_to_md = @import("notion/blocks_to_md.zig");
    pub const md_to_blocks = @import("notion/md_to_blocks.zig");
    pub const client = @import("notion/client.zig");
    pub const classify = @import("notion/classify.zig");
    pub const store = @import("notion/store.zig");
    pub const sync = @import("notion/sync.zig");
    pub const fake = @import("notion/fake.zig");
    pub const engine = @import("notion/engine.zig");
    pub const resolve = @import("notion/resolve.zig");
};

test {
    _ = updater;
    _ = notion.model;
    _ = notion.blocks_to_md;
    _ = notion.md_to_blocks;
    _ = notion.client;
    _ = notion.classify;
    _ = notion.store;
    _ = notion.sync;
    _ = notion.fake;
    _ = notion.engine;
    _ = notion.resolve;
    _ = @import("notion/convert_test.zig");
    _ = @import("notion/engine_test.zig");
}
