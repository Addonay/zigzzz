//! Borderless window chrome: resize edges, the draggable top bar, window
//! controls, and the rounded window shape.

const std = @import("std");
const sdl = @import("sdl3");
const geo = @import("geometry.zig");
const theme = @import("theme.zig");

pub const Chrome = struct {
    sidebar_open: bool = true,
    sidebar_width: f32 = 240,

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

pub fn controlRect(width: f32, index: usize) geo.Rect {
    return .{
        .x = width - 10 - (3 - geo.f(index)) * (control_size + 2),
        .y = (theme.toolbar_height - control_size) / 2,
        .w = control_size,
        .h = control_size,
    };
}

/// Width reserved at the right of the top bar for the window controls.
pub const controls_width: f32 = 3 * (control_size + 2) + 18;

pub fn hitTest(
    window: sdl.video.Window,
    point: sdl.rect.IPoint,
    chrome_optional: ?*Chrome,
) sdl.video.HitTestResult {
    const chrome = chrome_optional orelse return .normal;
    const width, const height = window.getSize() catch return .normal;
    const flags = window.getFlags();
    const maximized = flags.maximized or flags.fullscreen;

    if (!maximized) {
        if (point.y < 4) {
            if (point.x < 12) return .resize_top_left;
            if (point.x > width - 12) return .resize_top_right;
            return .resize_top;
        }

        if (point.y > height - 4) {
            if (point.x < 12) return .resize_bottom_left;
            if (point.x > width - 12) return .resize_bottom_right;
            return .resize_bottom;
        }

        if (point.x < 4) return .resize_left;
        if (point.x > width - 4) return .resize_right;
    }

    const x = geo.f(point.x);
    const y = geo.f(point.y);

    if (y >= theme.toolbar_height) return .normal;

    for (0..3) |index| {
        if (controlRect(geo.f(width), index).contains(x, y)) return .normal;
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
    rounded: bool = false,

    pub fn update(self: *Shape, allocator: std.mem.Allocator, window: sdl.video.Window) !void {
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

        const unchanged = self.rounded and
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
        const radius = theme.corner_radius;
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
            .rounded = true,
        };
    }
};
