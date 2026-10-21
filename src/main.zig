const std = @import("std");
const sdl = @import("sdl3");
const App = @import("app.zig").App;
const Renderer = @import("render.zig").Renderer;
const chrome = @import("window.zig");
const theme = @import("theme.zig");
const exporter = @import("export.zig");
const Scale = @import("scale.zig").Scale;
const f = @import("geometry.zig").f;
const assets = @import("assets");
const build_options = @import("build_options");

/// Reverse-DNS identifier; also the Wayland app_id, which desktops match
/// against `io.github.addonay.zigzzz.desktop` to find the icon.
pub const app_id = "io.github.addonay.zigzzz";

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        reportFatal(err);
        return err;
    };
}

/// A GUI build has no console on Windows, so a startup failure would just
/// vanish. Show SDL's own explanation in a dialog and on stderr.
fn reportFatal(err: anyerror) void {
    var buffer: [1024]u8 = undefined;
    const detail = sdl.errors.get() orelse "";
    const message = std.fmt.bufPrintSentinel(&buffer, "Workspace could not start ({s}).\n\n{s}", .{ @errorName(err), detail }, 0) catch
        "Workspace could not start.";

    std.debug.print("{s}\n", .{message});
    sdl.message_box.showSimple(.{ .error_dialog = true }, "Workspace", message, null) catch {};
}

fn run(init: std.process.Init) !void {
    // Must precede SDL_Init so the identifier reaches the windowing system.
    try sdl.setAppMetadata("Workspace", build_options.version, app_id);

    try sdl.init(.{ .video = true });
    defer sdl.shutdown();

    const window = try sdl.video.Window.init("Workspace", theme.initial_width, theme.initial_height, .{
        .borderless = true,
        .resizable = true,
        .high_pixel_density = true,
        .transparent = true,
    });
    defer window.deinit();

    setWindowIcon(window);

    // Size the window for the display's scaling before showing anything.
    var scale = Scale.read(window);
    fitWindow(window, scale);

    var renderer = try Renderer.init(init.gpa, window, .{ .system = scale.text, .pixels = scale.pixels });
    defer renderer.deinit();

    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);

    try app.init(init.gpa, init.io, window, &renderer);
    defer app.deinit();

    app.scale = scale;
    app.chrome.scale = scale.ui;

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

        const mouse_x, const mouse_y = blk: {
            _, const x, const y = sdl.mouse.getState();
            break :blk .{ x, y };
        };

        app.ui.mouse_x = mouse_x / app.scale.ui;
        app.ui.mouse_y = mouse_y / app.scale.ui;

        while (sdl.events.poll()) |event| app.event(event);

        if (app.scale_changed) {
            app.scale_changed = false;

            // Moved to another monitor, or the system scale changed.
            const latest = Scale.read(window);

            if (!latest.eql(scale)) {
                scale = latest;
                app.scale = scale;
                app.chrome.scale = scale.ui;
                setMinimumSize(window, scale);

                var text_settings = renderer.text_settings;
                text_settings.system = scale.text;
                text_settings.pixels = scale.pixels;
                renderer.configureText(text_settings) catch |err| app.failure(err);
            }
        }

        if (window.getFlags().minimized) {
            sdl.timer.delayMilliseconds(40);
            continue;
        }

        try shape.update(init.gpa, window, scale.ui);

        // Lay out in logical pixels; the renderer scales them to the window.
        const width, const height = try window.getSize();

        app.width = f(width) / scale.ui;
        app.height = f(height) / scale.ui;

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

/// Open at the design size scaled for the display, never larger than the
/// usable screen area, and centred.
fn fitWindow(window: sdl.video.Window, scale: Scale) void {
    var width = f(theme.initial_width) * scale.ui;
    var height = f(theme.initial_height) * scale.ui;

    if (window.getDisplayForWindow()) |display| {
        if (display.getUsableBounds()) |bounds| {
            width = @min(width, f(bounds.w) * 0.92);
            height = @min(height, f(bounds.h) * 0.92);
        } else |_| {}
    } else |_| {}

    setMinimumSize(window, scale);

    const minimum_width = f(theme.minimum_width) * scale.ui;
    const minimum_height = f(theme.minimum_height) * scale.ui;

    window.setSize(@intFromFloat(@max(width, minimum_width)), @intFromFloat(@max(height, minimum_height))) catch {};
    window.setPosition(.{ .centered = null }, .{ .centered = null }) catch {};
}

fn setMinimumSize(window: sdl.video.Window, scale: Scale) void {
    const width: usize = @intFromFloat(@round(f(theme.minimum_width) * scale.ui));
    const height: usize = @intFromFloat(@round(f(theme.minimum_height) * scale.ui));

    window.setMinimumSize(width, height) catch {};
}

/// Taskbar and title icon from the embedded logo. Purely cosmetic, so a
/// failure leaves the platform default in place.
fn setWindowIcon(window: sdl.video.Window) void {
    const stream = sdl.io_stream.Stream.initFromConstMem(assets.app_icon) catch return;
    defer stream.deinit() catch {};

    const icon = sdl.image.loadPngIo(stream) catch return;
    defer icon.deinit();

    window.setIcon(icon) catch {};
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
    _ = @import("regex.zig");
    _ = @import("scale.zig");
}
