//! Layout constants.
//!
//! Transcribed from the CSS in `src/app.css` and the component `<style>` blocks
//! so the native UI keeps the same proportions.

const std = @import("std");
const gfx = @import("gfx");

pub const palette = gfx.palette;

/// Base UI font size (`body { font-size: 13px }`).
pub const ui_font_px: u32 = 13;
/// Default editor font size (`nova:editorFontSize`, default 13).
pub const editor_font_default: u32 = 13;
pub const editor_font_min: u32 = 8;
pub const editor_font_max: u32 = 48;

pub const sidebar_default_w: i32 = 260;
pub const sidebar_min_w: i32 = 160;
pub const sidebar_max_w: i32 = 600;
/// Dragging narrower than this collapses the sidebar (`App.svelte:180`).
pub const sidebar_collapse_w: i32 = sidebar_min_w - 40;
pub const resizer_w: i32 = 4;
/// Hover strip that reveals a collapsed sidebar.
pub const edge_trigger_w: i32 = 6;

pub const statusbar_h: i32 = 22;

/// Rows moved per notch of a stepped mouse wheel, as most desktops scroll.
pub const wheel_rows_per_notch: f64 = 3;
/// Logical points per unit of a precise (trackpad) delta.
///
/// SDL's Cocoa backend scales `scrollingDeltaY` by a tenth before reporting
/// it, so ten recovers the distance the fingers actually travelled and the
/// content follows them one to one.
pub const wheel_points_per_precise_unit: f64 = 10;
/// How long a gesture is still assumed to be coming from a trackpad after the
/// last fractional delta. See `Root.handleWheel`.
pub const precise_wheel_grace_ms: i64 = 250;
pub const tabbar_h: i32 = 32;
pub const tab_max_w: i32 = 200;
pub const sidebar_row_h: i32 = 22;
/// `.entry { font-size: 12px }` -- note titles are a step below the body.
pub const sidebar_entry_font_px: u32 = 12;
/// `.header { font-size: 11px; letter-spacing: 0.5px }`.
pub const sidebar_group_font_px: u32 = 11;
/// `.count { font-size: 10px }`, in a `border-radius: 8px` pill.
pub const sidebar_count_font_px: u32 = 10;
/// `footer { font-size: 11px }`.
pub const status_font_px: u32 = 11;
pub const sidebar_group_h: i32 = 22;

/// Extra space around the gutter's digits (`Editor.svelte:946`).
pub const gutter_pad: f64 = 24;
/// Gap between the gutter and the first text column.
pub const gutter_gap: i32 = 4;
/// Rows rendered beyond the viewport, either side.
pub const overscan_rows: i32 = 10;
pub const tab_size: u8 = 4;
pub const caret_w: i32 = 2;

pub const modal_radius: i32 = 6;
pub const spotlight_w: i32 = 560;
pub const spotlight_top_ratio: f32 = 0.15;
/// Search input debounce (`Spotlight.svelte:37`).
pub const search_debounce_ms: i64 = 120;
/// Toast lifetime (`stores/ui.ts:47`).
pub const toast_ms: i64 = 3000;
/// Caret blink period.
pub const caret_blink_ms: i64 = 1000;

pub fn clampEditorFont(px: u32) u32 {
    return std.math.clamp(px, editor_font_min, editor_font_max);
}

pub fn clampSidebarWidth(w: i32) i32 {
    return std.math.clamp(w, sidebar_min_w, sidebar_max_w);
}

const testing = std.testing;

test "clamping" {
    try testing.expectEqual(@as(u32, editor_font_min), clampEditorFont(1));
    try testing.expectEqual(@as(u32, editor_font_max), clampEditorFont(999));
    try testing.expectEqual(@as(u32, 13), clampEditorFont(13));
    try testing.expectEqual(@as(i32, sidebar_min_w), clampSidebarWidth(10));
    try testing.expectEqual(@as(i32, sidebar_max_w), clampSidebarWidth(9999));
}
