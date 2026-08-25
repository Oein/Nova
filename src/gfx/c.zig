//! Raw bindings for the text stack.

pub const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftmodapi.h");
    // Synthetic bold for faces with no bold cut.
    @cInclude("freetype/ftsynth.h");
    @cInclude("freetype/ftoutln.h");
});

pub const hb = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
