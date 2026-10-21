const std = @import("std");
const sdl = @import("sdl3");
const gfx = @import("render.zig");
const geo = @import("geometry.zig");
const theme = @import("theme.zig");
const chrome_module = @import("window.zig");
const Layout = @import("layout.zig").Layout;
const Ui = @import("ui.zig").Ui;
const prefs = @import("preferences.zig");
const Text = @import("text.zig").Text;
const Workbook = @import("workbook.zig").Workbook;
const reports = @import("report.zig");
const settings = @import("settings.zig");
const charts = @import("charts.zig");
const kml = @import("kml.zig");
const regex = @import("regex.zig");

const Rect = geo.Rect;
const Color = geo.Color;
const f = geo.f;
const fade = geo.fade;

pub const Page = enum { home, qos, kml, settings };

pub const ToastKind = enum { info, success, failure };

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    window: sdl.video.Window,
    renderer: *gfx.Renderer,
    ui: Ui,
    layout: Layout,
    chrome: chrome_module.Chrome = .{},

    width: f32 = 1280,
    height: f32 = 820,
    quit: bool = false,
    page: Page = .home,
    settings_tab: usize = 0,

    saved: prefs.Preferences,
    draft: prefs.Preferences,
    settings_path: []const u8,

    path: Text = .{},
    qos_path: Text = .{},
    kml_path: Text = .{},
    show_path_field: bool = false,
    dragging: bool = false,

    toast: Text = .{},
    toast_kind: ToastKind = .info,
    toast_since: u64 = 0,
    toast_until: u64 = 0,

    scroll: f32 = 0,
    scroll_target: f32 = 0,
    scroll_max: f32 = 0,

    report: ?reports.Report = null,
    book: ?Workbook = null,
    area: usize = 0,
    status_filter: usize = 0,
    group_filter: usize = 0,

    focus_chart: ?usize = null,
    focus_days: u32 = 30,
    focus_overlays: [16]usize = undefined,
    focus_overlay_count: usize = 0,
    focus_amount: f32 = 0,

    search: Text = .{},
    new_name: Text = .{},
    bulk_value: Text = .init("0"),
    bulk_operator: usize = 0,
    group_members: [prefs.max_kpis]bool = @splat(false),
    editing_group: ?usize = null,
    overlay_primary: usize = 0,
    overlay_members: [prefs.max_kpis]bool = @splat(false),

    mapping: kml.Mapping = .{},
    popup: Popup = .{},
    resize_sidebar: bool = false,
    rendering_image: bool = false,

    busy: bool = false,
    busy_message: Text = .{},
    busy_progress: f32 = 0,
    pending_export: ?bool = null,

    dialog_path: Text = .{},
    dialog_state: std.atomic.Value(u8) = .init(0),
    dialog_page: Page = .qos,
    dialog_kind: DialogKind = .file,
    dialog_location: [1024:0]u8 = @splat(0),

    /// Scrollable part of the sidebar's context section, if any.
    sidebar_list: Rect = .{},
    sidebar_scroll: f32 = 0,
    sidebar_scroll_max: f32 = 0,

    /// Saved settings changed outside the Settings page (KML defaults);
    /// written once no text field is being edited.
    persist_pending: bool = false,

    pub fn init(self: *App, allocator: std.mem.Allocator, io: std.Io, window: sdl.video.Window, renderer: *gfx.Renderer) !void {
        const path = try settingsPath(allocator);
        errdefer allocator.free(path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .window = window,
            .renderer = renderer,
            .ui = .{ .renderer = renderer },
            .layout = try Layout.init(allocator),
            .saved = undefined,
            .draft = undefined,
            .settings_path = path,
        };

        self.saved.load(allocator, io, path) catch |err| {
            try self.saved.defaults(allocator);
            self.failure(err);
        };

        self.draft = self.saved;
        self.chrome.sidebar_open = self.saved.sidebar_open;
        try renderer.setTextSize(self.saved.textSize());
    }

    fn settingsPath(allocator: std.mem.Allocator) ![]const u8 {
        if (std.c.getenv("ZIGZZZ_SETTINGS_PATH")) |value| {
            return allocator.dupe(u8, std.mem.span(value));
        }

        if (std.c.getenv("XDG_CONFIG_HOME")) |value| {
            return allocator.print("{s}/zigzzz/settings.json", .{std.mem.span(value)});
        }

        const home_dir = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/tmp";
        return allocator.print("{s}/.config/zigzzz/settings.json", .{home_dir});
    }

    pub fn deinit(self: *App) void {
        self.flushSave();

        if (self.report) |*report| report.deinit();
        if (self.book) |*book| book.deinit();

        self.layout.deinit(self.allocator);
        self.allocator.free(self.settings_path);
    }

    pub fn palette(self: *const App) theme.Palette {
        if (self.rendering_image) return theme.light;
        return if (self.saved.dark) theme.dark else theme.light;
    }

    pub fn navigate(self: *App, page: Page) void {
        if (self.page == .qos) self.qos_path = self.path;
        if (self.page == .kml) self.kml_path = self.path;

        self.page = page;

        if (page == .qos) self.path = self.qos_path;
        if (page == .kml) self.path = self.kml_path;

        self.resetScroll();
        self.popup.open = false;
        self.show_path_field = false;
        self.ui.focused_text = null;

        if (page == .settings) self.draft = self.saved;
    }

    pub fn resetScroll(self: *App) void {
        self.scroll = 0;
        self.scroll_target = 0;
        self.scroll_max = 0;
    }

    // ── Notifications ──────────────────────────────────────────────────

    pub fn notify(self: *App, message: []const u8) void {
        self.showToast(message, .info);
    }

    pub fn success(self: *App, message: []const u8) void {
        self.showToast(message, .success);
    }

    fn showToast(self: *App, message: []const u8, kind: ToastKind) void {
        const now = sdl.timer.getMillisecondsSinceInit();

        self.toast.set(message);
        self.toast_kind = kind;
        self.toast_since = now;
        self.toast_until = now + 5000;
    }

    pub fn failure(self: *App, err: anyerror) void {
        const friendly: ?[]const u8 = switch (err) {
            error.FileNotFound => "File not found. Check the path and try again.",
            error.AccessDenied => "Permission denied. Choose a readable file or writable output folder.",
            error.NotAnXlsxWorkbook => "Choose an XLSX, XLSM, or CSV workbook. Save legacy spreadsheets as XLSX first.",
            error.NoDatesInFirstRow => "Put dates on row 1, starting in column C.",
            error.NoNumericKpiValues => "No numeric KPI data found. Put KPI names in column B.",
            error.MapAllRequiredColumns => "Map the cell name, unique ID, latitude, and longitude columns first.",
            error.InvalidSiteCoordinates => "A site has missing or invalid latitude or longitude.",
            error.TextSizeMustBe12To24 => "Text size must be between 12 and 24 px.",
            error.DaysMustBe7To180 => "Date ranges must be between 7 and 180 days.",
            error.InvalidThreshold => "Enter a finite number for each enabled threshold.",
            error.OverrideNeedsAName => "Enter a name for each date range override.",
            error.NoChartsToExport => "No charts match the current export filters.",
            error.ClipboardUnavailable => "The clipboard is not available right now.",
            else => null,
        };

        if (friendly) |message| {
            self.showToast(message, .failure);
            return;
        }

        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Something went wrong: {s}", .{@errorName(err)}) catch
            "Could not complete the action.";

        self.showToast(message, .failure);
    }

    // ── Events ─────────────────────────────────────────────────────────

    pub fn event(self: *App, event_value: sdl.events.Event) void {
        switch (event_value) {
            .quit, .window_close_requested => self.quit = true,
            .mouse_button_down => |button| {
                if (button.button != .left) return;
                self.ui.press(button.x, button.y);
                if (self.atSidebarEdge(button.x)) self.resize_sidebar = true;
            },
            .mouse_button_up => |button| {
                if (button.button != .left) return;
                self.ui.release(button.x, button.y);
                self.resize_sidebar = false;
            },
            .mouse_motion => |motion| {
                if (self.resize_sidebar) self.chrome.sidebar_width = std.math.clamp(motion.x, 200, 360);
            },
            .mouse_wheel => |wheel| {
                if (self.popup.open) {
                    self.popup.scroll = @max(0, self.popup.scroll - wheel.scroll_y * 40);
                } else if (self.chrome.sidebar_open and self.sidebar_list.contains(self.ui.mouse_x, self.ui.mouse_y)) {
                    self.sidebar_scroll = std.math.clamp(self.sidebar_scroll - wheel.scroll_y * 40, 0, self.sidebar_scroll_max);
                } else if (self.focus_chart == null) {
                    self.scroll_target = std.math.clamp(self.scroll_target - wheel.scroll_y * 64, 0, self.scroll_max);
                }
            },
            .text_input => |text| self.ui.insert(text.text),
            .key_down => |key| self.keyDown(key),
            .drop_begin, .drop_position => self.dragging = true,
            .drop_complete => self.dragging = false,
            .drop_file => |file| {
                self.dragging = false;
                if (self.page == .home or self.page == .settings) self.navigate(.qos);
                self.path.set(file.file_name);
                self.importFile();
            },
            else => {},
        }
    }

    fn keyDown(self: *App, key: sdl.events.Keyboard) void {
        const escape = key.key == .escape;

        if (escape and self.popup.open) {
            self.popup.open = false;
            self.ui.focused_text = null;
            return;
        }

        if (self.ui.keyboard(key)) return;

        const ctrl = key.mod.left_control or key.mod.right_control;

        if (ctrl and key.key == .b) self.chrome.sidebar_open = !self.chrome.sidebar_open;

        if (escape) {
            if (self.focus_chart != null) {
                charts.closeFocus(self);
            } else if (self.show_path_field) {
                self.show_path_field = false;
            }
        }
    }

    fn atSidebarEdge(self: *const App, x: f32) bool {
        return self.chrome.sidebar_open and @abs(x - self.chrome.sidebar_width) < 4;
    }

    pub fn hoveringSidebarEdge(self: *const App) bool {
        return self.atSidebarEdge(self.ui.mouse_x) and self.ui.mouse_y > theme.toolbar_height;
    }

    // ── Files ──────────────────────────────────────────────────────────

    pub fn importFile(self: *App) void {
        const trimmed = std.mem.trim(u8, self.path.slice(), " \"\r\n");

        if (self.page == .kml and !std.ascii.endsWithIgnoreCase(trimmed, ".xlsx")) {
            self.notify("Choose an XLSX workbook for KML generation.");
            return;
        }

        var book = Workbook.load(self.allocator, self.io, trimmed) catch |err| {
            self.failure(err);
            return;
        };

        if (self.page == .kml) {
            if (self.book) |*previous| previous.deinit();

            self.book = book;
            self.kml_path = self.path;
            self.mapping = kml.Mapping.initWith(&self.book.?, &self.saved);
        } else {
            defer book.deinit();

            const report = reports.Report.parse(self.allocator, &book) catch |err| {
                self.failure(err);
                return;
            };

            if (self.report) |*previous| previous.deinit();

            self.report = report;
            self.qos_path = self.path;

            // New KPIs join their default group, like the built-in ones.
            const known = self.saved.rule_count;

            for (report.names) |name| _ = self.saved.include(name) catch continue;
            for (known..self.saved.rule_count) |index| self.saved.groupByDefault(index);

            if (self.saved.rule_count > known) self.queueSave();

            self.area = 0;
            self.status_filter = 0;
            self.focus_chart = null;

            var buffer: [128]u8 = undefined;
            self.success(std.fmt.bufPrint(&buffer, "Loaded {d} areas with {d} KPIs.", .{
                report.areas.len,
                report.names.len,
            }) catch "Report loaded.");
        }

        self.resetScroll();
        self.show_path_field = false;
        self.ui.focused_text = null;
    }

    pub fn closeReport(self: *App) void {
        if (self.report) |*report| report.deinit();

        self.report = null;
        self.focus_chart = null;
        self.path.set("");
        self.resetScroll();
    }

    pub fn closeBook(self: *App) void {
        if (self.book) |*book| book.deinit();

        self.book = null;
        self.path.set("");
        self.resetScroll();
    }

    pub fn browse(self: *App) void {
        if (self.dialog_state.load(.acquire) != 0) return;

        self.dialog_page = self.page;
        self.dialog_state.store(1, .release);

        const filters = [_]sdl.dialog.FileFilter{
            .{ .name = "Spreadsheets", .pattern = "xlsx;xlsm;csv" },
            .{ .name = "All files", .pattern = "*" },
        };

        self.dialog_kind = .file;
        sdl.dialog.showOpenFile(App, pickedFile, self, self.window, &filters, null, false);
    }

    /// Pick a folder for the KML output, starting in `location`.
    pub fn browseFolder(self: *App, location: []const u8) void {
        if (self.dialog_state.load(.acquire) != 0) return;

        self.dialog_page = self.page;
        self.dialog_kind = .folder;
        self.dialog_state.store(1, .release);

        const length = @min(location.len, self.dialog_location.len);
        @memcpy(self.dialog_location[0..length], location[0..length]);
        self.dialog_location[length] = 0;

        const start: ?[:0]const u8 = if (length > 0) self.dialog_location[0..length :0] else null;
        sdl.dialog.showOpenFolder(App, pickedFile, self, self.window, start, false);
    }

    /// Mirror saved settings into the draft and write them soon.
    pub fn queueSave(self: *App) void {
        self.draft = self.saved;
        self.persist_pending = true;
    }

    pub fn flushSave(self: *App) void {
        if (!self.persist_pending) return;

        self.persist_pending = false;
        self.saved.save(self.allocator, self.io, self.settings_path) catch |err| self.failure(err);
    }

    pub fn toggleTheme(self: *App) void {
        self.saved.dark = !self.saved.dark;
        self.draft.dark = self.saved.dark;

        self.saved.save(self.allocator, self.io, self.settings_path) catch |err| self.failure(err);
    }

    // ── Frame ──────────────────────────────────────────────────────────

    pub fn draw(self: *App) void {
        if (self.dialog_state.load(.acquire) == 2) {
            if (self.dialog_kind == .folder) {
                if (self.book != null) self.mapping.folder = self.dialog_path;
            } else {
                self.navigate(self.dialog_page);
                self.path = self.dialog_path;
                self.importFile();
            }

            self.dialog_state.store(0, .release);
        }

        if (self.ui.focused_text == null) self.flushSave();

        const p = self.palette();
        const r = self.renderer;

        self.chrome.sidebar_width = @min(self.chrome.sidebar_width, @max(200, self.width - 520));
        self.scroll_target = std.math.clamp(self.scroll_target, 0, self.scroll_max);
        self.scroll = geo.approach(self.scroll, self.scroll_target, self.ui.delta_time, 22);
        if (@abs(self.scroll - self.scroll_target) < 0.5) self.scroll = self.scroll_target;

        const modal = self.focus_chart != null;
        self.ui.begin(p, self.popup.open or self.busy or modal);
        self.layout.update(self.width, self.height, self.chrome.sidebar_open, self.chrome.sidebar_width);

        self.sidebar_list = .{};
        if (self.chrome.sidebar_open) self.drawSidebar();

        const content = self.layout.rect("content");

        switch (self.page) {
            .home => self.home(content),
            .qos => if (self.report != null) charts.page(self, content) else self.picker(content, false),
            .kml => if (self.book != null) kml.page(self, content) else self.picker(content, true),
            .settings => settings.page(self, content),
        }

        r.unclip();
        self.drawTopbar();

        if (modal) {
            self.ui.blocked = self.popup.open or self.busy;
            self.ui.layer = 2;
            charts.drawFocus(self);
            self.ui.layer = 0;
        }

        if (self.popup.open) self.drawPopup();

        self.drawToast();
        self.ui.drawTooltip(self.width, self.height);

        if (self.busy) self.drawBusy();

        self.chrome.capture(self.ui.widgets[0..self.ui.widget_count]);
    }

    /// Keep the native event queue and export feedback responsive between
    /// areas. Rendering stays on the SDL thread; no GPU work crosses threads.
    pub fn exportProgress(self: *App, area_index: usize, total: usize) !void {
        while (sdl.events.poll()) |event_value| {
            switch (event_value) {
                .quit, .window_close_requested => {
                    self.quit = true;
                    return error.ExportCancelled;
                },
                .key_down => |key| if (key.key == .escape) {
                    return error.ExportCancelled;
                },
                else => {},
            }
        }

        var buffer: [128]u8 = undefined;
        self.busy_message.set(try std.fmt.bufPrint(&buffer, "Exporting area {d} of {d}", .{ area_index + 1, total }));
        self.busy_progress = f(area_index + 1) / f(@max(1, total));

        self.ui.resetEvents();
        try self.renderer.begin(self.width, self.height, self.palette().background);
        self.draw();
        self.renderer.finish();
    }

    // ── Sidebar ────────────────────────────────────────────────────────

    fn drawSidebar(self: *App) void {
        const r = self.renderer;
        const p = self.palette();
        const sidebar = self.layout.rect("sidebar");

        r.box(sidebar, p.sidebar, 0);
        r.vline(sidebar.right() - 1, 0, self.height, p.sidebar_border);

        // Brand
        const brand = self.layout.rect("brand");
        const mark = Rect{ .x = brand.x + 16, .y = brand.centerY() - 14, .w = 28, .h = 28 };

        r.shadow(mark, 8, 6, 2, fade(p.brand, 0.35));
        r.box(mark, p.brand, 8);
        r.icon(.activity, mark.centered(16), .{ 255, 255, 255, 255 });
        r.text("Workspace", mark.right() + 10, brand.centerY() - r.textHeight(.heading) / 2, p.sidebar_foreground, .heading);

        const collapse = Rect{ .x = brand.right() - 44, .y = brand.centerY() - 16, .w = 32, .h = 32 };
        if (self.ui.iconButton(.panel_close, collapse, p.muted_foreground, "Collapse sidebar  ·  Ctrl+B")) {
            self.chrome.sidebar_open = false;
        }

        // Navigation
        const labels = [_][]const u8{ "Home", "QoS KPIs", "KML Generator" };
        const icons = [_]gfx.Icon{ .home, .chart, .map };

        for (labels, icons, 0..) |label, icon, index| {
            const rect = self.layout.indexed("nav-item", index);
            const active = @backingInt(self.page) == index;

            if (self.navItem(rect, icon, label, active, null)) self.navigate(@fromBackingInt(@intCast(index)));
        }

        // Context for the current tool
        const context = self.layout.rect("sidebar-context");

        if (self.page == .qos and self.report != null) charts.sidebar(self, context);
        if (self.page == .kml and self.book != null) kml.sidebar(self, context);

        // Footer
        const footer = self.layout.rect("sidebar-footer");
        r.hline(footer.x, footer.right() - 1, footer.y, p.sidebar_border);

        if (self.navItem(self.layout.rect("settings-nav"), .settings, "Settings", self.page == .settings, null)) {
            self.navigate(.settings);
        }

        const toggle_rect = self.layout.rect("theme-toggle");
        const tooltip = if (self.saved.dark) "Switch to light mode" else "Switch to dark mode";

        if (self.ui.iconButton(if (self.saved.dark) .sun else .moon, toggle_rect, p.muted_foreground, tooltip)) {
            self.toggleTheme();
        }
    }

    /// Sidebar menu button. Returns true when clicked.
    pub fn navItem(self: *App, rect: Rect, icon: gfx.Icon, label: []const u8, active: bool, badge: ?Badge) bool {
        const r = self.renderer;
        const p = self.palette();
        const clicked = self.ui.hit(rect);
        const amount = self.ui.hoverAmount(rect);

        if (active) {
            r.box(rect, p.sidebar_accent, theme.radius);
        } else if (amount > 0.01) {
            r.box(rect, fade(p.sidebar_accent, amount * 0.7), theme.radius);
        }

        const foreground = if (active) p.sidebar_accent_foreground else geo.blend(p.muted_foreground, p.sidebar_foreground, @max(amount, 0.35));
        const icon_color = if (active) p.brand else foreground;

        r.icon(icon, .{ .x = rect.x + 10, .y = rect.centerY() - 8, .w = 16, .h = 16 }, icon_color);

        var text_right = rect.right() - 10;

        if (badge) |value| {
            const width = self.ui.badgeWidth(value.text);
            const badge_rect = Rect{ .x = rect.right() - 8 - width, .y = rect.centerY() - 9, .w = width, .h = 18 };

            self.ui.badge(value.text, badge_rect, value.foreground, value.background);
            text_right = badge_rect.x - 6;
        }

        var buffer: [256]u8 = undefined;
        const fitted = r.fit(&buffer, label, text_right - rect.x - 36, if (active) .strong else .body);

        r.leading(fitted, .{ .x = rect.x + 36, .y = rect.y, .w = rect.w, .h = rect.h }, foreground, if (active) .strong else .body);

        return clicked;
    }

    pub const Badge = struct { text: []const u8, foreground: Color, background: Color };

    /// Uppercase muted caption above a sidebar or page section.
    pub fn sectionLabel(self: *App, label: []const u8, x: f32, y: f32) void {
        var buffer: [128]u8 = undefined;
        const upper = std.ascii.upperString(buffer[0..@min(label.len, buffer.len)], label[0..@min(label.len, buffer.len)]);

        self.renderer.tracked(upper, x, y, self.palette().muted_foreground, .tiny, 0.8);
    }

    // ── Top bar ────────────────────────────────────────────────────────

    fn drawTopbar(self: *App) void {
        const r = self.renderer;
        const p = self.palette();
        const bar = self.layout.rect("topbar");

        r.hline(bar.x, bar.right(), bar.bottom() - 1, p.border);

        var left = bar.x + 20;

        if (!self.chrome.sidebar_open) {
            const expand = Rect{ .x = bar.x + 12, .y = bar.centerY() - 16, .w = 32, .h = 32 };

            if (self.ui.iconButton(.panel_open, expand, p.muted_foreground, "Expand sidebar  ·  Ctrl+B")) {
                self.chrome.sidebar_open = true;
            }

            left = expand.right() + 8;
        }

        const area = Rect{
            .x = left,
            .y = bar.y,
            .w = @max(0, self.width - chrome_module.controls_width - left),
            .h = bar.h,
        };

        switch (self.page) {
            .home => self.topbarTitle(area, "Home", ""),
            .qos => if (self.report != null) charts.topbar(self, area) else self.topbarTitle(area, "QoS KPIs", ""),
            .kml => if (self.book != null) kml.topbar(self, area) else self.topbarTitle(area, "KML Generator", ""),
            .settings => settings.topbar(self, area),
        }

        self.windowControls();
    }

    /// Page title with an optional muted subtitle on the same line.
    pub fn topbarTitle(self: *App, area: Rect, title: []const u8, subtitle: []const u8) void {
        const r = self.renderer;
        const p = self.palette();
        const y = area.y + (area.h - r.textHeight(.heading)) / 2;

        r.text(title, area.x, y, p.foreground, .heading);

        if (subtitle.len > 0) {
            const x = area.x + r.textWidth(title, .heading) + 10;
            r.text(subtitle, x, area.y + (area.h - r.textHeight(.small)) / 2 + 1, p.muted_foreground, .small);
        }
    }

    fn windowControls(self: *App) void {
        const r = self.renderer;
        const p = self.palette();
        const maximized = self.window.getFlags().maximized;

        for (0..3) |index| {
            const rect = chrome_module.controlRect(self.width, index);
            const icon: gfx.Icon = switch (index) {
                0 => .minimize,
                1 => if (maximized) .restore else .maximize,
                else => .window_close,
            };

            const clicked = self.ui.hit(rect);
            const amount = self.ui.hoverAmount(rect);
            const closing = index == 2;

            if (amount > 0.01) {
                const fill = if (closing) p.destructive else p.accent;
                r.box(rect.inset(2), fade(fill, amount), theme.radius);
            }

            const tint = if (closing and amount > 0.5) p.destructive_foreground else p.muted_foreground;
            r.icon(icon, rect.centered(16), tint);

            if (clicked) {
                switch (index) {
                    0 => self.window.minimize() catch {},
                    1 => if (maximized) {
                        self.window.restore() catch {};
                    } else {
                        self.window.maximize() catch {};
                    },
                    else => self.quit = true,
                }
            }
        }
    }

    // ── Home ───────────────────────────────────────────────────────────

    fn home(self: *App, content: Rect) void {
        const r = self.renderer;
        const p = self.palette();

        const column_width = @min(880, content.w - 64);
        const x = content.x + (content.w - column_width) / 2;
        var y = content.y + @max(40, (content.h - 420) / 2.6);

        self.sectionLabel("Workspace", x, y);
        y += 24;

        r.text("What would you like to work on?", x, y, p.foreground, .title);
        y += r.textHeight(.title) + 4;

        y += r.wrappedText(
            "Analyse QoS KPI trends against their thresholds, or turn a site workbook into a KML map layer.",
            x,
            y,
            column_width,
            p.muted_foreground,
            .body,
        );
        y += 28;

        const stacked = column_width < 560;
        const gap: f32 = 16;
        const card_width = if (stacked) column_width else (column_width - gap) / 2;
        const card_height: f32 = 196;

        const tools = [_]struct { icon: gfx.Icon, title: []const u8, text: []const u8, action: []const u8, page: Page }{
            .{
                .icon = .chart,
                .title = "QoS KPIs",
                .text = "Chart every KPI by area, compare overlays, and export failing charts to Excel.",
                .action = "Open dashboard",
                .page = .qos,
            },
            .{
                .icon = .map,
                .title = "KML Generator",
                .text = "Map spreadsheet columns to site fields and export placemarks with sector polygons.",
                .action = "Create a map layer",
                .page = .kml,
            },
        };

        for (tools, 0..) |tool, index| {
            const card = Rect{
                .x = if (stacked) x else x + f(index) * (card_width + gap),
                .y = if (stacked) y + f(index) * (card_height + gap) else y,
                .w = card_width,
                .h = card_height,
            };

            if (self.toolCard(card, tool.icon, tool.title, tool.text, tool.action)) self.navigate(tool.page);
        }

        y += if (stacked) (card_height + gap) * 2 else card_height + gap;
        y += 20;

        // Keyboard hints
        const hints = [_][2][]const u8{
            .{ "Ctrl B", "Toggle sidebar" },
            .{ "Tab", "Move focus" },
            .{ "Esc", "Close dialogs" },
        };

        var hint_x = x;

        for (hints) |hint| {
            const key_width = r.textWidth(hint[0], .tiny) + 12;
            const key = Rect{ .x = hint_x, .y = y, .w = key_width, .h = 20 };

            r.border(key, p.muted, p.border, theme.radius_small);
            r.centered(hint[0], key, p.muted_foreground, .tiny);
            r.leading(hint[1], .{ .x = key.right() + 8, .y = y, .w = 200, .h = 20 }, p.muted_foreground, .small);

            hint_x = key.right() + 8 + r.textWidth(hint[1], .small) + 24;
        }
    }

    fn toolCard(self: *App, card: Rect, icon: gfx.Icon, title: []const u8, description: []const u8, action: []const u8) bool {
        const r = self.renderer;
        const p = self.palette();
        const clicked = self.ui.hit(card);
        const amount = self.ui.hoverAmount(card);
        const lifted = card.offset(0, -2 * amount);

        r.shadow(lifted, theme.radius_large, 6 + 10 * amount, 2 + 4 * amount, fade(p.shadow, 0.6 + 0.6 * amount));
        r.box(lifted, p.card, theme.radius_large);
        r.outline(lifted, geo.blend(p.border, fade(p.brand, 0.6), amount), theme.radius_large);

        const tile = Rect{ .x = lifted.x + 24, .y = lifted.y + 24, .w = 40, .h = 40 };
        r.box(tile, fade(p.brand, 0.12 + 0.06 * amount), theme.radius_large);
        r.icon(icon, tile.centered(20), p.brand);

        r.text(title, lifted.x + 24, tile.bottom() + 16, p.card_foreground, .heading);
        _ = r.wrappedText(description, lifted.x + 24, tile.bottom() + 42, lifted.w - 48, p.muted_foreground, .small);

        const action_y = lifted.bottom() - 24 - r.textHeight(.small_strong);
        r.text(action, lifted.x + 24, action_y, p.brand, .small_strong);

        const arrow_x = lifted.x + 24 + r.textWidth(action, .small_strong) + 6 + 4 * amount;
        r.icon(.forward, .{ .x = arrow_x, .y = action_y + (r.textHeight(.small_strong) - 14) / 2, .w = 14, .h = 14 }, p.brand);

        return clicked;
    }

    // ── File picker ────────────────────────────────────────────────────

    fn picker(self: *App, content: Rect, is_kml: bool) void {
        const r = self.renderer;
        const p = self.palette();

        const zone_width = @min(560, content.w - 80);
        const zone_height = @min(340, content.h - 160);
        const zone = Rect{
            .x = content.x + (content.w - zone_width) / 2,
            .y = content.y + (content.h - zone_height) / 2 - 24,
            .w = zone_width,
            .h = zone_height,
        };

        const clicked = self.ui.hit(zone);
        const hover = self.ui.hoverAmount(zone);
        const highlight = if (self.dragging) 1 else hover;

        r.box(zone, fade(p.brand, 0.03 + 0.05 * highlight), 16);
        r.dashedRect(zone, 16, 1.6, 7, 6, geo.blend(fade(p.muted_foreground, 0.55), p.brand, highlight));

        const icon_size: f32 = 64;
        const lift = 4 * highlight;
        const icon_rect = Rect{
            .x = zone.centerX() - icon_size / 2,
            .y = zone.centerY() - icon_size / 2 - 34 - lift,
            .w = icon_size,
            .h = icon_size,
        };

        r.icon(.cloud_upload, icon_rect, p.brand);

        const headline = if (self.dragging)
            "Drop to open"
        else if (is_kml)
            "Drag and drop a site workbook (.xlsx) here"
        else
            "Drag and drop an .xlsx report here";

        r.centered(headline, .{ .x = zone.x, .y = icon_rect.bottom() + 14, .w = zone.w, .h = 24 }, p.foreground, .strong);

        const detail = if (is_kml) "or click to browse  ·  XLSX" else "or click to browse  ·  XLSX, XLSM, CSV";
        r.centered(detail, .{ .x = zone.x, .y = icon_rect.bottom() + 40, .w = zone.w, .h = 20 }, p.muted_foreground, .small);

        if (clicked) self.browse();

        // Optional path entry, tucked away under a quiet link.
        const below = zone.bottom() + 20;

        if (self.show_path_field) {
            const width = zone.w;
            const field_rect = Rect{ .x = zone.x, .y = below, .w = width - 84, .h = 36 };

            _ = self.ui.iconField(.file, &self.path, "/path/to/report.xlsx", field_rect);

            const open = self.ui.button("Open", .{ .x = field_rect.right() + 8, .y = below, .w = 76, .h = 36 }, .primary, false);

            if (open or (self.ui.submitted and self.ui.focused_text == &self.path)) self.importFile();
        } else {
            const label = "Enter a file path instead";
            const width = r.textWidth(label, .small) + 16;
            const link = Rect{ .x = zone.centerX() - width / 2, .y = below, .w = width, .h = 28 };
            const amount = self.ui.hoverAmount(link);

            if (self.ui.hit(link)) {
                self.show_path_field = true;
                self.ui.focused_text = &self.path;
                self.ui.caret = self.path.length;
            }

            const color = geo.blend(p.muted_foreground, p.foreground, amount);
            r.centered(label, link, color, .small);

            if (amount > 0.05) {
                const text_width = r.textWidth(label, .small);
                r.hline(link.centerX() - text_width / 2, link.centerX() + text_width / 2, link.bottom() - 5, fade(color, amount));
            }
        }
    }

    // ── Dropdowns ──────────────────────────────────────────────────────

    pub fn dropdown(self: *App, label: []const u8, rect: Rect, target: Target, row: usize) void {
        const r = self.renderer;
        const p = self.palette();
        const open = self.popup.open and self.popup.target == target and self.popup.row == row;

        if (open) r.box(rect.expand(3), fade(p.ring, 0.25), theme.radius + 3);

        if (self.ui.button("", rect, .outline, false)) self.openPopup(rect, target, row);

        if (open) r.outline(rect, p.ring, theme.radius);

        var buffer: [256]u8 = undefined;
        const fitted = r.fit(&buffer, label, rect.w - 40, .body);

        r.leading(fitted, .{ .x = rect.x + 12, .y = rect.y, .w = rect.w, .h = rect.h }, p.foreground, .body);
        r.icon(.chevron_down, .{ .x = rect.right() - 26, .y = rect.centerY() - 7, .w = 14, .h = 14 }, p.muted_foreground);
    }

    pub fn openPopup(self: *App, anchor: Rect, target: Target, row: usize) void {
        self.popup = .{ .open = true, .anchor = anchor, .target = target, .row = row };

        if (target != .export_menu) {
            self.ui.focused_text = &self.popup.query;
            self.ui.caret = 0;
        }
    }

    fn popupCount(self: *const App) usize {
        return switch (self.popup.target) {
            .area => if (self.report) |report| report.areas.len else 0,
            .group => self.saved.group_count + 1,
            .operator => prefs.operators.len,
            .column => if (self.book) |book| book.column_count + 1 else 0,
            .primary => self.draft.rule_count,
            .overlay, .focus_overlay => if (self.report) |report| report.names.len else 0,
            .export_menu => 2,
        };
    }

    fn popupLabel(self: *const App, index: usize) []const u8 {
        return switch (self.popup.target) {
            .area => self.report.?.areas[index].name,
            .group => if (index == 0) "All groups" else self.saved.groups[index - 1].name.slice(),
            .operator => prefs.operators[index],
            .column => if (index == 0) "(none)" else self.book.?.cell(0, index - 1),
            .primary => self.draft.rules[index].name.slice(),
            .overlay, .focus_overlay => self.report.?.names[index],
            .export_menu => if (index == 0) "Editable Excel charts" else "Failing chart images",
        };
    }

    fn popupSelected(self: *const App, index: usize) bool {
        const row = self.popup.row;

        return switch (self.popup.target) {
            .area => self.area == index,
            .group => self.group_filter == index,
            .operator => if (row == prefs.max_kpis) self.bulk_operator == index else self.draft.rules[row].operator == index,
            .column => if (self.mapping.columns[row]) |column| column + 1 == index else index == 0,
            .primary => self.overlay_primary == index,
            .overlay => charts.hasOverlay(self, row, self.report.?.names[index]),
            .focus_overlay => charts.hasFocusOverlay(self, index),
            .export_menu => false,
        };
    }

    fn choosePopup(self: *App, index: usize) void {
        switch (self.popup.target) {
            .area => {
                self.area = index;
                self.group_filter = 0;
                self.resetScroll();
            },

            .group => {
                self.group_filter = index;
                self.resetScroll();
            },

            .operator => {
                if (self.popup.row == prefs.max_kpis) {
                    self.bulk_operator = index;
                } else {
                    self.draft.rules[self.popup.row].operator = index;
                }
            },

            .column => {
                self.mapping.columns[self.popup.row] = if (index == 0) null else index - 1;
                kml.remember(self, self.popup.row);
            },

            .primary => self.overlay_primary = index,

            .overlay => charts.addOverlay(self, self.popup.row, self.report.?.names[index]),

            .focus_overlay => charts.toggleFocusOverlay(self, index),

            .export_menu => self.pending_export = index == 1,
        }
    }

    /// A popup row that matched the search, with its closeness score.
    const Ranked = struct { index: usize, score: f32, span: regex.Span };

    fn rankedBefore(_: void, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score < b.score;
        return a.index < b.index;
    }

    /// First non-empty value under a column header, to help recognise it.
    fn columnSample(self: *const App, index: usize) []const u8 {
        if (self.popup.target != .column or index == 0) return "";

        const book = &(self.book orelse return "");

        for (1..@min(book.row_count, 8)) |row| {
            const value = std.mem.trim(u8, book.cell(row, index - 1), " \t\r\n");
            if (value.len > 0) return value;
        }

        return "";
    }

    fn drawPopup(self: *App) void {
        const p = self.palette();
        const r = self.renderer;
        const ui = &self.ui;

        ui.blocked = self.busy;
        ui.layer = 1;
        defer ui.layer = 0;

        const is_menu = self.popup.target == .export_menu;
        const is_column = self.popup.target == .column;
        const total = self.popupCount();
        const searchable = !is_menu and total > 7;
        const row_height: f32 = if (is_menu) 48 else 32;

        // Rank every item against the search. The query is a regular
        // expression; invalid patterns fall back to plain text.
        const query = regex.Query.init(self.popup.query.slice());

        var ranked: [1024]Ranked = undefined;
        var count: usize = 0;

        for (0..total) |index| {
            if (count == ranked.len) break;

            const label = self.popupLabel(index);
            const score = query.score(label) orelse continue;

            ranked[count] = .{ .index = index, .score = score, .span = query.find(label).? };
            count += 1;
        }

        if (query.text.len > 0) std.sort.pdq(Ranked, ranked[0..count], {}, rankedBefore);

        const header: f32 = if (searchable) 48 else 4;
        const minimum: f32 = if (is_menu) 260 else if (is_column) 380 else 220;
        const width = @min(@max(minimum, self.popup.anchor.w), self.width - 16);
        const wanted = header + @max(1, f(count)) * row_height + 4;
        const height = @min(@min(if (is_column) @as(f32, 420) else 340, wanted), self.height - 48);

        var x = self.popup.anchor.x;
        if (is_menu or is_column) x = self.popup.anchor.right() - width;

        const rect = Rect{
            .x = std.math.clamp(x, 8, self.width - width - 8),
            .y = std.math.clamp(self.popup.anchor.bottom() + 6, 8, self.height - height - 8),
            .w = width,
            .h = height,
        };

        ui.sink(rect);
        r.shadow(rect, theme.radius_large, 16, 6, fade(p.shadow, 1.4));
        r.border(rect, p.popover, p.border, theme.radius_large);

        if (searchable) {
            var placeholder_buffer: [96]u8 = undefined;
            const noun = if (is_column) "columns" else "items";
            const placeholder = std.fmt.bufPrint(&placeholder_buffer, "Search {d} {s} — regex works", .{ total, noun }) catch "Search…";

            _ = ui.iconField(.search, &self.popup.query, placeholder, .{ .x = rect.x + 6, .y = rect.y + 6, .w = rect.w - 12, .h = 34 });
            r.hline(rect.x, rect.right(), rect.y + header - 2, p.border);
        }

        const list = Rect{ .x = rect.x + 4, .y = rect.y + header, .w = rect.w - 8, .h = rect.h - header - 4 };
        const previous = r.clipWithin(list);

        var chosen: ?usize = null;

        for (ranked[0..count], 0..) |item, position| {
            const index = item.index;
            const label = self.popupLabel(index);
            const row = Rect{ .x = list.x, .y = list.y + f(position) * row_height - self.popup.scroll, .w = list.w, .h = row_height };

            if (row.bottom() < list.y or row.y > list.bottom()) continue;

            const clicked = ui.hit(row);
            const amount = ui.hoverAmount(row);
            const top_match = position == 0 and query.text.len > 0;

            if (amount > 0.01) {
                r.box(row, fade(p.accent, amount), theme.radius);
            } else if (top_match) {
                r.box(row, fade(p.accent, 0.5), theme.radius);
            }

            if (is_menu) {
                const icon: gfx.Icon = if (index == 0) .file_down else .image;
                const detail = if (index == 0) "One sheet, every area, current filters" else "PNG charts of failing KPIs per area";

                r.icon(icon, .{ .x = row.x + 10, .y = row.y + 9, .w = 16, .h = 16 }, p.muted_foreground);
                r.text(label, row.x + 36, row.y + 4, p.popover_foreground, .strong);
                r.text(detail, row.x + 36, row.y + 24, p.muted_foreground, .small);
            } else {
                // Sample value on the right for spreadsheet columns.
                var label_room = row.w - 44;
                const sample = self.columnSample(index);

                if (sample.len > 0) {
                    var sample_buffer: [128]u8 = undefined;
                    const fitted_sample = r.fit(&sample_buffer, sample, row.w * 0.36, .small);
                    const sample_width = r.textWidth(fitted_sample, .small);

                    r.leading(fitted_sample, .{ .x = row.right() - 34 - sample_width, .y = row.y, .w = sample_width, .h = row.h }, p.muted_foreground, .small);
                    label_room -= sample_width + 12;
                }

                var buffer: [256]u8 = undefined;
                const fitted = r.fit(&buffer, label, label_room, .body);
                const truncated = fitted.ptr != label.ptr;
                const visible_end = if (truncated) fitted.len -| "…".len else fitted.len;

                const span = item.span;
                const highlight = query.text.len > 0 and span.end > span.start and span.end <= visible_end;
                const text_y = row.y + (row.h - r.textHeight(.body)) / 2;

                if (highlight) {
                    // Matched part in the brand color.
                    var cursor = row.x + 10;
                    const pieces = [_]struct { text: []const u8, matched: bool }{
                        .{ .text = fitted[0..span.start], .matched = false },
                        .{ .text = fitted[span.start..span.end], .matched = true },
                        .{ .text = fitted[span.end..], .matched = false },
                    };

                    for (pieces) |piece| {
                        const role: gfx.FontRole = if (piece.matched) .strong else .body;

                        r.text(piece.text, cursor, text_y, if (piece.matched) p.brand else p.popover_foreground, role);
                        cursor += r.textWidth(piece.text, role);
                    }
                } else {
                    r.text(fitted, row.x + 10, text_y, p.popover_foreground, .body);
                }

                if (self.popupSelected(index)) {
                    r.icon(.check, .{ .x = row.right() - 26, .y = row.centerY() - 8, .w = 16, .h = 16 }, p.brand);
                }
            }

            if (clicked) chosen = index;
        }

        // Enter picks the closest match.
        const typing = ui.focused_text == &self.popup.query;
        if (searchable and typing and ui.submitted and count > 0) chosen = ranked[0].index;

        if (chosen) |index| {
            self.choosePopup(index);

            const keep_open = self.popup.target == .overlay or self.popup.target == .focus_overlay;

            if (!keep_open) {
                self.popup.open = false;
                ui.focused_text = null;
            }
        }

        if (count == 0) r.centered("No matches", list, p.muted_foreground, .small);

        self.popup.scroll = @min(self.popup.scroll, @max(0, f(count) * row_height - list.h));
        r.restoreClip(previous);

        const outside = !rect.contains(ui.mouse_x, ui.mouse_y) and !self.popup.anchor.contains(ui.mouse_x, ui.mouse_y);

        if (ui.released and outside) {
            self.popup.open = false;
            ui.focused_text = null;
        }
    }

    // ── Overlays ───────────────────────────────────────────────────────

    fn drawToast(self: *App) void {
        if (self.toast.length == 0) return;

        const now = sdl.timer.getMillisecondsSinceInit();
        if (now >= self.toast_until) return;

        const r = self.renderer;
        const p = self.palette();

        const entering = std.math.clamp(f(now - self.toast_since) / 180, 0, 1);
        const leaving = std.math.clamp(f(self.toast_until - now) / 220, 0, 1);
        const amount = @min(entering, leaving);
        const eased = 1 - (1 - amount) * (1 - amount);

        const icon: gfx.Icon = switch (self.toast_kind) {
            .info => .info,
            .success => .circle_check,
            .failure => .alert,
        };

        const icon_color = switch (self.toast_kind) {
            .info => p.brand,
            .success => p.success,
            .failure => p.destructive,
        };

        const max_width = @min(420, self.width - 48);
        const text_height = r.wrappedHeight(self.toast.slice(), max_width - 64, .body);
        const width = @min(max_width, r.textWidth(self.toast.slice(), .body) + 64);
        const height = text_height + 28;

        const rect = Rect{
            .x = self.width - width - 20,
            .y = self.height - height - 20 + (1 - eased) * 16,
            .w = width,
            .h = height,
        };

        r.shadow(rect, theme.radius_large, 18, 8, fade(p.shadow, 1.4 * eased));
        r.box(rect, fade(p.popover, eased), theme.radius_large);
        r.outline(rect, fade(p.border, eased), theme.radius_large);
        r.icon(icon, .{ .x = rect.x + 16, .y = rect.y + 14 + 2, .w = 18, .h = 18 }, fade(icon_color, eased));
        _ = r.wrappedText(self.toast.slice(), rect.x + 44, rect.y + 14, rect.w - 60, fade(p.popover_foreground, eased), .body);
    }

    fn drawBusy(self: *App) void {
        const r = self.renderer;
        const p = self.palette();

        r.blurFrame();
        r.box(.{ .w = self.width, .h = self.height }, fade(p.scrim, 0.7), 0);

        const dialog = Rect{ .x = (self.width - 380) / 2, .y = (self.height - 156) / 2, .w = 380, .h = 156 };

        r.shadow(dialog, theme.radius_large, 24, 10, fade(p.shadow, 1.6));
        r.border(dialog, p.popover, p.border, theme.radius_large);

        const degrees: f64 = @floatFromInt(sdl.timer.getMillisecondsSinceInit() % 1000 * 360 / 1000);
        r.rotatedIcon(.loader, .{ .x = dialog.x + 24, .y = dialog.y + 26, .w = 20, .h = 20 }, p.brand, degrees);
        r.text(self.busy_message.slice(), dialog.x + 54, dialog.y + 24, p.popover_foreground, .strong);
        r.text("Rendering charts and writing the workbook.", dialog.x + 24, dialog.y + 58, p.muted_foreground, .small);

        const track = Rect{ .x = dialog.x + 24, .y = dialog.y + 92, .w = dialog.w - 48, .h = 6 };
        r.box(track, p.muted, 3);
        r.box(.{ .x = track.x, .y = track.y, .w = track.w * self.busy_progress, .h = track.h }, p.brand, 3);

        r.text("Press Esc to cancel", dialog.x + 24, dialog.y + 114, p.muted_foreground, .small);
    }
};

const DialogKind = enum { file, folder };

pub const Target = enum { area, group, operator, column, primary, overlay, focus_overlay, export_menu };

const Popup = struct {
    open: bool = false,
    anchor: Rect = .{},
    target: Target = .area,
    row: usize = 0,
    query: Text = .{},
    scroll: f32 = 0,
};

fn pickedFile(self_optional: ?*App, paths: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
    const self = self_optional orelse return;
    if (!failed) {
        if (paths) |list| {
            if (list.len > 0) {
                self.dialog_path.set(std.mem.span(list[0]));
                self.dialog_state.store(2, .release);
                return;
            }
        }
    }
    self.dialog_state.store(0, .release);
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }

    return false;
}
