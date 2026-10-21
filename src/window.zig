//! Borderless window chrome: resize edges, the draggable top bar, window
//! controls, and the rounded window shape.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const geo = @import("geometry.zig");
const theme = @import("theme.zig");

/// Windows 11 caption buttons are 46 px wide, span the whole title bar,
/// and sit flush against the window corner. Elsewhere the controls are
/// compact rounded buttons inset from the edge.
pub const native_caption = builtin.os.tag == .windows;

pub const Chrome = struct {
    sidebar_open: bool = true,
    sidebar_width: f32 = 240,

    /// Window coordinates per logical pixel (see scale.zig). The hit-test
    /// callback receives window coordinates and converts them.
    scale: f32 = 1,

    /// Widgets inside the top bar, captured at the end of every frame so
    /// clicks on them are not swallowed by window dragging.
    interactive: [96]geo.Rect = undefined,
    interactive_count: usize = 0,

    pub fn capture(self: *Chrome, widgets: anytype) void {
        self.interactive_count = 0;

        for (widgets) |widget| {
            if (widget.rect.y >= theme.toolbar_height) continue;
            if (self.interactive_count == self.interactive.len) break;

            self.interactive[self.interactive_count] = widget.rect;
            self.interactive_count += 1;
        }
    }
};

pub const control_size: f32 = 32;
const caption_width: f32 = 46;

/// Minimise (0), maximise/restore (1), and close (2), in logical pixels.
pub fn controlRect(width: f32, index: usize) geo.Rect {
    if (native_caption) {
        return .{
            .x = width - (3 - geo.f(index)) * caption_width,
            .y = 0,
            .w = caption_width,
            .h = theme.toolbar_height,
        };
    }

    return .{
        .x = width - 10 - (3 - geo.f(index)) * (control_size + 2),
        .y = (theme.toolbar_height - control_size) / 2,
        .w = control_size,
        .h = control_size,
    };
}

/// Width reserved at the right of the top bar for the window controls.
pub const controls_width: f32 = if (native_caption) 3 * caption_width + 12 else 3 * (control_size + 2) + 18;

pub fn hitTest(
    window: sdl.video.Window,
    point: sdl.rect.IPoint,
    chrome_optional: ?*Chrome,
) sdl.video.HitTestResult {
    const chrome = chrome_optional orelse return .normal;
    const window_width, const window_height = window.getSize() catch return .normal;
    const flags = window.getFlags();
    const maximized = flags.maximized or flags.fullscreen;

    // Work in logical pixels, like the rest of the interface.
    const scale = if (chrome.scale > 0) chrome.scale else 1;
    const x = geo.f(point.x) / scale;
    const y = geo.f(point.y) / scale;
    const width = geo.f(window_width) / scale;
    const height = geo.f(window_height) / scale;

    if (!maximized) {
        const edge: f32 = 4;
        const corner: f32 = 12;

        if (y < edge) {
            // Leave the caption buttons clickable right up to the edge.
            if (native_caption and x > width - 3 * caption_width) return .normal;
            if (x < corner) return .resize_top_left;
            if (x > width - corner) return .resize_top_right;
            return .resize_top;
        }

        if (y > height - edge) {
            if (x < corner) return .resize_bottom_left;
            if (x > width - corner) return .resize_bottom_right;
            return .resize_bottom;
        }

        if (x < edge) return .resize_left;
        if (x > width - edge and !(native_caption and y < theme.toolbar_height)) return .resize_right;
    }

    if (y >= theme.toolbar_height) return .normal;

    for (0..3) |index| {
        if (controlRect(width, index).contains(x, y)) return .normal;
    }

    for (chrome.interactive[0..chrome.interactive_count]) |rect| {
        if (rect.contains(x, y)) return .normal;
    }

    return .draggable;
}

pub const Shape = struct {
    pixel_width: usize = 0,
    pixel_height: usize = 0,
    logical_width: usize = 0,
    logical_height: usize = 0,
    scale: f32 = 1,
    rounded: bool = false,

    /// `scale` is window coordinates per logical pixel.
    pub fn update(self: *Shape, allocator: std.mem.Allocator, window: sdl.video.Window, scale: f32) !void {
        const flags = window.getFlags();

        if (flags.maximized or flags.fullscreen) {
            if (self.rounded) {
                try window.setShape(null);
                self.rounded = false;
            }

            return;
        }

        const logical_width, const logical_height = try window.getSize();
        const width, const height = try window.getSizeInPixels();

        if (width <= 0 or height <= 0 or logical_width <= 0 or logical_height <= 0) return;

        const unchanged = self.rounded and self.scale == scale and
            width == self.pixel_width and height == self.pixel_height and
            logical_width == self.logical_width and logical_height == self.logical_height;

        if (unchanged) return;

        const w: usize = @intCast(width);
        const h: usize = @intCast(height);

        const pixels = try allocator.alloc(u8, w * h * 4);
        defer allocator.free(pixels);
        @memset(pixels, 255);

        const scale_x = geo.f(width) / geo.f(logical_width);
        const scale_y = geo.f(height) / geo.f(logical_height);
        // Radius in window coordinates.
        const radius = theme.corner_radius * scale;
        const corner_width: usize = @intFromFloat(@ceil(radius * scale_x + 1));
        const corner_height: usize = @intFromFloat(@ceil(radius * scale_y + 1));

        for (0..@min(corner_height, h / 2)) |y| {
            for (0..@min(corner_width, w / 2)) |x| {
                const dx = @max(0, radius - (geo.f(x) + 0.5) / scale_x);
                const dy = @max(0, radius - (geo.f(y) + 0.5) / scale_y);
                const distance = radius - @sqrt(dx * dx + dy * dy);
                const coverage = std.math.clamp(0.5 + distance * @min(scale_x, scale_y), 0, 1);
                const alpha: u8 = @intFromFloat(coverage * 255);

                pixels[(y * w + x) * 4 + 3] = alpha;
                pixels[(y * w + w - x - 1) * 4 + 3] = alpha;
                pixels[((h - y - 1) * w + x) * 4 + 3] = alpha;
                pixels[((h - y - 1) * w + w - x - 1) * 4 + 3] = alpha;
            }
        }

        const surface = try sdl.surface.Surface.initFrom(width, height, .array_rgba_32, pixels);
        defer surface.deinit();
        try window.setShape(surface);

        self.* = .{
            .pixel_width = width,
            .pixel_height = height,
            .logical_width = logical_width,
            .logical_height = logical_height,
            .scale = scale,
            .rounded = true,
        };
    }
};
