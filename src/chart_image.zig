//! Chart cards rendered off-screen to PNG, for the clipboard and for the
//! image export. Images always use the light palette so they read well
//! when pasted into documents and spreadsheets.

const std = @import("std");
const sdl = @import("sdl3");
const App = @import("app.zig").App;
const charts = @import("charts.zig");
const Rect = @import("geometry.zig").Rect;
const png = @import("png.zig");

const width = 800;
const height = 450;
const scale = 2;

pub fn render(app: *App, index: usize, view: charts.View, allocator: std.mem.Allocator) ![]u8 {
    const renderer = app.renderer;

    const previous_target = renderer.handle.getTarget();
    const scale_x, const scale_y = try renderer.handle.getScale();

    const previous_clip = renderer.clip_rect;
    const previous_blocked = app.ui.blocked;
    const previous_image = app.rendering_image;

    const target = try renderer.handle.createTexture(.array_rgba_32, .target, width * scale, height * scale);
    defer target.deinit();

    defer {
        renderer.handle.setTarget(previous_target) catch {};
        renderer.handle.setScale(scale_x, scale_y) catch {};

        if (previous_clip) |clip| renderer.clip(clip) else renderer.unclip();

        app.ui.blocked = previous_blocked;
        app.rendering_image = previous_image;
    }

    try renderer.handle.setTarget(target);
    try renderer.handle.setScale(scale, scale);
    renderer.unclip();

    app.ui.blocked = true;
    app.rendering_image = true;

    renderer.color(app.palette().card);
    try renderer.handle.clear();

    var image_view = view;
    image_view.hover = false;
    image_view.toolbar = false;
    image_view.clickable = false;

    const rect = Rect{ .w = width, .h = height };
    charts.card(app, index, rect, image_view);
    renderer.unclip();

    const raw = try renderer.handle.readPixels(null);
    defer raw.deinit();
    const converted = try raw.convertFormat(.array_rgba_32);
    defer converted.deinit();
    const pixels = converted.getPixels() orelse return error.ChartImage;
    const pitch = converted.getPitch();
    return png.encode(allocator, pixels, width * scale, height * scale, pitch);
}

const Clipboard = struct {
    allocator: std.mem.Allocator,
    data: []u8,
};

pub fn copy(app: *App, index: usize, view: charts.View) !void {
    const data = try render(app, index, view, app.allocator);
    errdefer app.allocator.free(data);

    try setClipboardImage(app.allocator, data);
    app.success("Chart copied to clipboard.");
}

/// Transfer the PNG buffer to SDL; its cleanup callback releases it later.
fn setClipboardImage(allocator: std.mem.Allocator, data: []u8) !void {
    const clipboard = try allocator.create(Clipboard);
    errdefer allocator.destroy(clipboard);

    clipboard.* = .{ .allocator = allocator, .data = data };

    var types = [_][*:0]const u8{"image/png"};
    try sdl.clipboard.setData(Clipboard, provide, cleanup, clipboard, &types);
}

fn provide(clipboard_optional: ?*Clipboard, mime_type: ?[:0]const u8) ?[]u8 {
    const clipboard = clipboard_optional orelse return null;
    const mime = mime_type orelse return null;
    if (!std.mem.eql(u8, mime, "image/png")) return null;
    return clipboard.data;
}

fn cleanup(clipboard_optional: ?*Clipboard) void {
    const clipboard = clipboard_optional orelse return;
    const allocator = clipboard.allocator;
    allocator.free(clipboard.data);
    allocator.destroy(clipboard);
}

test "chart PNG clipboard callbacks preserve binary data and release ownership" {
    try sdl.hints.setWithPriority(.video_driver, "dummy", .override);
    try sdl.init(.{ .video = true });
    defer sdl.shutdown();

    const data = try png.encode(std.testing.allocator, &.{ 10, 20, 30, 255 }, 1, 1, 4);
    {
        errdefer std.testing.allocator.free(data);
        try setClipboardImage(std.testing.allocator, data);
    }
    defer sdl.clipboard.clearData() catch {};

    const received = try sdl.clipboard.getData("image/png");
    defer sdl.free(@constCast(received));
    try std.testing.expectEqualSlices(u8, data, received);

    // Replacing the image invokes cleanup, checked by the testing allocator.
    try sdl.clipboard.setText("replacement");
}
