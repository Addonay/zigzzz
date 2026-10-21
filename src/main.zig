const std = @import("std");
const sdl = @import("sdl3");
const App = @import("app.zig").App;
const Renderer = @import("render.zig").Renderer;
const chrome = @import("window.zig");
const theme = @import("theme.zig");
const exporter = @import("export.zig");
const f = @import("geometry.zig").f;

pub fn main(init: std.process.Init) !void {
    try sdl.init(.{ .video = true });
    defer sdl.shutdown();

    const window = try sdl.video.Window.init("Workspace", theme.initial_width, theme.initial_height, .{
        .borderless = true,
        .resizable = true,
        .high_pixel_density = true,
        .transparent = true,
    });
    defer window.deinit();
    try window.setMinimumSize(theme.minimum_width, theme.minimum_height);

    var renderer = try Renderer.init(init.gpa, window);
    defer renderer.deinit();

    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);

    try app.init(init.gpa, init.io, window, &renderer);
    defer app.deinit();

    try window.setHitTest(chrome.Chrome, chrome.hitTest, &app.chrome);
    try sdl.keyboard.startTextInput(window);

    const arrow = sdl.mouse.Cursor.initSystem(.default) catch null;
    const pointer = sdl.mouse.Cursor.initSystem(.pointer) catch null;
    const text = sdl.mouse.Cursor.initSystem(.text) catch null;
    const resize = sdl.mouse.Cursor.initSystem(.east_west_resize) catch null;
    defer {
        if (arrow) |cursor| cursor.deinit();
        if (pointer) |cursor| cursor.deinit();
        if (text) |cursor| cursor.deinit();
        if (resize) |cursor| cursor.deinit();
    }

    var shape: chrome.Shape = .{};
    var previous = sdl.timer.getMillisecondsSinceInit();

    while (!app.quit) {
        const now = sdl.timer.getMillisecondsSinceInit();
        app.ui.delta_time = @min(0.05, f(now - previous) / 1000);
        previous = now;

        app.ui.resetEvents();
        _, app.ui.mouse_x, app.ui.mouse_y = sdl.mouse.getState();
        while (sdl.events.poll()) |event| app.event(event);

        if (window.getFlags().minimized) {
            sdl.timer.delayMilliseconds(40);
            continue;
        }

        try shape.update(init.gpa, window);

        const width, const height = try window.getSize();

        app.width = f(width);
        app.height = f(height);

        try renderer.begin(app.width, app.height, app.palette().background);
        app.draw();
        renderer.finish();

        if (app.pending_export) |images| {
            app.pending_export = null;
            app.busy = true;
            app.busy_progress = 0;

            exporter.write(app, images) catch |err| {
                if (err == error.ExportCancelled) app.notify("Export cancelled.") else app.failure(err);
            };

            app.busy = false;
            app.ui.resetEvents();
        }

        const cursor = if (app.hoveringSidebarEdge() or app.resize_sidebar)
            resize
        else if (app.ui.text_cursor)
            text
        else if (app.ui.hand)
            pointer
        else
            arrow;

        sdl.mouse.set(cursor) catch {};

        if (app.ui.released) app.ui.active = 0;

        if (!renderer.vsync) {
            const elapsed = sdl.timer.getMillisecondsSinceInit() - now;
            if (elapsed < 16) sdl.timer.delayMilliseconds(@intCast(16 - elapsed));
        }
    }
}

// Discover tests beside their implementations without running the application.
test {
    _ = @import("text.zig");
    _ = @import("preferences.zig");
    _ = @import("report.zig");
    _ = @import("kml.zig");
    _ = @import("png.zig");
    _ = @import("render.zig");
    _ = @import("ui.zig");
    _ = @import("chart_image.zig");
}
