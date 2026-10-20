const std = @import("std");
const sdl = @import("zsdl3");
const App = @import("app.zig").App;
const Renderer = @import("render.zig").Renderer;
const chrome = @import("window.zig");
const theme = @import("theme.zig");
const exporter = @import("export.zig");
const f = @import("geometry.zig").f;

pub fn main(init: std.process.Init) !void {
    if (!sdl.init(sdl.core.SDL_INIT_VIDEO)) return error.SdlInit;
    defer sdl.quit();

    const flags = sdl.video.SDL_WINDOW_BORDERLESS |
        sdl.video.SDL_WINDOW_RESIZABLE |
        sdl.video.SDL_WINDOW_HIGH_PIXEL_DENSITY |
        sdl.video.SDL_WINDOW_TRANSPARENT;

    const window = sdl.video.createWindow("Workspace", theme.initial_width, theme.initial_height, flags) orelse
        return error.Window;
    defer sdl.video.destroyWindow(window);

    _ = sdl.video.setWindowMinimumSize(window, theme.minimum_width, theme.minimum_height);

    var renderer = try Renderer.init(init.gpa, window);
    defer renderer.deinit();

    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);

    try app.init(init.gpa, init.io, window, &renderer);
    defer app.deinit();

    _ = sdl.video.setWindowHitTest(window, chrome.hitTest, &app.chrome);
    _ = sdl.input.startTextInput(window);

    const arrow = sdl.input.createSystemCursor(.SDL_SYSTEM_CURSOR_DEFAULT);
    const pointer = sdl.input.createSystemCursor(.SDL_SYSTEM_CURSOR_POINTER);
    const text = sdl.input.createSystemCursor(.SDL_SYSTEM_CURSOR_TEXT);
    const resize = sdl.input.createSystemCursor(.SDL_SYSTEM_CURSOR_EW_RESIZE);

    defer {
        if (arrow) |cursor| sdl.input.destroyCursor(cursor);
        if (pointer) |cursor| sdl.input.destroyCursor(cursor);
        if (text) |cursor| sdl.input.destroyCursor(cursor);
        if (resize) |cursor| sdl.input.destroyCursor(cursor);
    }

    var shape: chrome.Shape = .{};
    var previous = sdl.time.getTicks();

    while (!app.quit) {
        const now = sdl.time.getTicks();
        app.ui.delta_time = @min(0.05, f(now - previous) / 1000);
        previous = now;

        app.ui.resetEvents();
        _ = sdl.input.getMouseState(&app.ui.mouse_x, &app.ui.mouse_y);

        var event: sdl.core.SDL_Event = undefined;
        while (sdl.events.pollEvent(&event)) app.event(event);

        if (sdl.video.getWindowFlags(window) & sdl.video.SDL_WINDOW_MINIMIZED != 0) {
            sdl.time.delay(40);
            continue;
        }

        try shape.update(init.gpa, window);

        var width: c_int = 0;
        var height: c_int = 0;
        _ = sdl.video.getWindowSize(window, &width, &height);

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

        _ = sdl.input.setCursor(cursor);

        if (app.ui.released) app.ui.active = 0;

        if (!renderer.vsync) {
            const elapsed = sdl.time.getTicks() - now;
            if (elapsed < 16) sdl.time.delay(@intCast(16 - elapsed));
        }
    }
}
