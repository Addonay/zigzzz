//! Chart cards rendered off-screen to PNG, for the clipboard and for the
//! image export. Images always use the light palette so they read well
//! when pasted into documents and spreadsheets.

const std = @import("std");
const sdl = @import("zsdl3");
const App = @import("app.zig").App;
const charts = @import("charts.zig");
const Rect = @import("geometry.zig").Rect;
const png = @import("png.zig");

const width = 800;
const height = 450;
const scale = 2;

pub fn render(app: *App, index: usize, view: charts.View, allocator: std.mem.Allocator) ![]u8 {
    const renderer = app.renderer;
    const api = sdl.render;

    const previous_target = api.getRenderTarget(renderer.handle);
    var scale_x: f32 = 1;
    var scale_y: f32 = 1;
    _ = api.getRenderScale(renderer.handle, &scale_x, &scale_y);

    const previous_clip = renderer.clip_rect;
    const previous_blocked = app.ui.blocked;
    const previous_image = app.rendering_image;

    const target = api.createTexture(
        renderer.handle,
        sdl.pixels.SDL_PIXELFORMAT_RGBA32,
        api.SDL_TEXTUREACCESS_TARGET,
        width * scale,
        height * scale,
    ) orelse return error.ChartImage;
    defer api.destroyTexture(target);

    defer {
        _ = api.setRenderTarget(renderer.handle, previous_target);
        _ = api.setRenderScale(renderer.handle, scale_x, scale_y);

        if (previous_clip) |clip| renderer.clip(clip) else renderer.unclip();

        app.ui.blocked = previous_blocked;
        app.rendering_image = previous_image;
    }

    _ = api.setRenderTarget(renderer.handle, target);
    _ = api.setRenderScale(renderer.handle, scale, scale);
    renderer.unclip();

    app.ui.blocked = true;
    app.rendering_image = true;

    renderer.color(app.palette().card);
    _ = api.renderClear(renderer.handle);

    var image_view = view;
    image_view.hover = false;
    image_view.toolbar = false;
    image_view.clickable = false;

    const rect = Rect{ .w = width, .h = height };
    charts.card(app, index, rect, image_view);
    renderer.unclip();

    const raw = api.renderReadPixels(renderer.handle, null) orelse return error.ChartImage;
    defer sdl.surface.destroySurface(@ptrCast(raw));

    const converted = sdl.surface.convertSurface(@ptrCast(raw), sdl.pixels.SDL_PIXELFORMAT_RGBA32) orelse return error.ChartImage;
    defer sdl.surface.destroySurface(converted);

    const pixels: [*]const u8 = @ptrCast(converted.pixels.?);
    const pitch: usize = @intCast(converted.pitch);

    return png.encode(allocator, pixels[0 .. pitch * height * scale], width * scale, height * scale, pitch);
}

const Clipboard = struct {
    allocator: std.mem.Allocator,
    data: []u8,
};

pub fn copy(app: *App, index: usize, view: charts.View) !void {
    const data = try render(app, index, view, app.allocator);
    errdefer app.allocator.free(data);

    const clipboard = try app.allocator.create(Clipboard);
    errdefer app.allocator.destroy(clipboard);

    clipboard.* = .{ .allocator = app.allocator, .data = data };

    var types = [_]?[*:0]const u8{"image/png"};
    if (!sdl.clipboard.setClipboardData(provide, cleanup, clipboard, &types, types.len)) return error.ClipboardUnavailable;

    app.success("Chart copied to clipboard.");
}

fn provide(user_data: ?*anyopaque, _: [*:0]const u8, size: ?*usize) callconv(.c) ?*const anyopaque {
    const clipboard: *Clipboard = @ptrCast(@alignCast(user_data.?));

    if (size) |output| output.* = clipboard.data.len;
    return clipboard.data.ptr;
}

fn cleanup(user_data: ?*anyopaque) callconv(.c) void {
    const clipboard: *Clipboard = @ptrCast(@alignCast(user_data.?));
    const allocator = clipboard.allocator;

    allocator.free(clipboard.data);
    allocator.destroy(clipboard);
}
