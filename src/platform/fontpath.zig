//! Where the platform keeps its interface and monospace faces.
//!
//! The original was a web app and let the stylesheet name families --
//! `-apple-system` for the interface, `ui-monospace` for note text -- leaving
//! the OS to find them. A native build has to name files. None of these are
//! required: every list ends at the bundled face, so a font that is missing is
//! a cosmetic difference rather than a failure, which is why nothing here
//! reports an error.
//!
//! Apple's faces are not redistributable, so they are read from the running
//! system rather than bundled.

const builtin = @import("builtin");

pub const Face = struct {
    path: []const u8,
    /// Index within a TrueType collection (`.ttc`), which is how macOS ships
    /// most of its families.
    index: u32 = 0,
};

/// The interface face, in preference order: `-apple-system` and friends.
pub const ui: []const Face = switch (builtin.os.tag) {
    .macos => &.{
        // SF Pro, as the variable font shipped since Big Sur, then the older
        // split optical sizes, then the pre-El-Capitan system face.
        .{ .path = "/System/Library/Fonts/SFNS.ttf" },
        .{ .path = "/System/Library/Fonts/SFNSText.ttf" },
        .{ .path = "/System/Library/Fonts/SFNSDisplay.ttf" },
        .{ .path = "/System/Library/Fonts/HelveticaNeue.ttc" },
    },
    .windows => &.{
        .{ .path = "C:\\Windows\\Fonts\\segoeui.ttf" },
        .{ .path = "C:\\Windows\\Fonts\\tahoma.ttf" },
    },
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf" },
        .{ .path = "/usr/share/fonts/TTF/DejaVuSans.ttf" },
    },
};

/// The monospace face for note text: `ui-monospace, SFMono-Regular, ...`.
pub const mono: []const Face = switch (builtin.os.tag) {
    .macos => &.{
        .{ .path = "/System/Library/Fonts/SFNSMono.ttf" },
        // Where SF Mono lived before it was a system font: inside Terminal.
        .{ .path = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SFMono-Regular.otf" },
        .{ .path = "/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SFMono-Regular.otf" },
        .{ .path = "/System/Library/Fonts/Menlo.ttc" },
    },
    .windows => &.{
        .{ .path = "C:\\Windows\\Fonts\\consola.ttf" },
        .{ .path = "C:\\Windows\\Fonts\\cour.ttf" },
    },
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf" },
        .{ .path = "/usr/share/fonts/TTF/DejaVuSansMono.ttf" },
    },
};

/// Hangul, which neither SF Pro nor SF Mono covers. Without this the bundled
/// face supplies Korean text everywhere, which is legible but is not what the
/// browser used to pick.
pub const korean: []const Face = switch (builtin.os.tag) {
    .macos => &.{
        .{ .path = "/System/Library/Fonts/AppleSDGothicNeo.ttc" },
    },
    .windows => &.{
        .{ .path = "C:\\Windows\\Fonts\\malgun.ttf" },
    },
    else => &.{
        .{ .path = "/usr/share/fonts/truetype/nanum/NanumGothic.ttf" },
        .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc" },
    },
};
