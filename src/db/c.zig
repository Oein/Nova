//! Raw SQLite C bindings.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
