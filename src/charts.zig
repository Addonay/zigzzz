//! QoS KPI dashboard and charts.
//!
//! The chart card and plot replicate ldd's `kpi-chart.svelte`, which uses
//! Chart.js: a time x-axis with daily ticks, "nice" linear y ticks, smooth
//! lines with tension 0.3, a dashed threshold annotation, and an index-mode
//! tooltip. The dashboard layout follows ldd's `dashboard.svelte`.

const std = @import("std");
const sdl = @import("sdl3");
const gfx = @import("render.zig");
const App = @import("app.zig").App;
const report = @import("report.zig");
const prefs = @import("preferences.zig");
const theme = @import("theme.zig");
const geo = @import("geometry.zig");
const chart_image = @import("chart_image.zig");

const Rect = geo.Rect;
const Color = geo.Color;
const Point = gfx.Point;
const f = geo.f;
const fade = geo.fade;

const card_height: f32 = 248;
const grid_gap: f32 = 12;
const day_options = [_]u32{ 7, 14, 30, 60, 90, 180 };
const day_labels = [_][]const u8{ "7d", "14d", "30d", "60d", "90d", "180d" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// How a chart card is drawn.
pub const View = struct {
    /// Days to show instead of the configured range (focus view).
    days: ?u32 = null,
    /// Overlay KPI names to use instead of the saved overlays.
    overlays: ?[]const []const u8 = null,
    /// Hover tooltips and points.
    hover: bool = true,
    /// Floating toolbar with overlay and copy actions.
    toolbar: bool = true,
    /// Clicking the card opens the focus view.
    clickable: bool = true,

    pub const image: View = .{ .hover = false, .toolbar = false, .clickable = false };
};

const Dataset = struct {
    name: []const u8,
    points: []const report.Point,
    color: Color,
};

// ── Formatting ─────────────────────────────────────────────────────────

/// ldd's `formatFloat`: integers as-is, otherwise up to four decimals
/// with trailing zeros removed.
pub fn formatFloat(buffer: []u8, value: f64) []const u8 {
    if (value == @round(value) and @abs(value) < 1e15) {
        return std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch "";
    }

    const text = std.fmt.bufPrint(buffer, "{d:.4}", .{value}) catch return "";
    var end = text.len;

    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;

    return text[0..end];
}

fn shortDate(buffer: []u8, day: i32) []const u8 {
    const parts = report.dateParts(day);
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ months[@intCast(parts.month - 1)], parts.day }) catch "";
}

fn longDate(buffer: []u8, day: i32) []const u8 {
    const parts = report.dateParts(day);
    return std.fmt.bufPrint(buffer, "{s} {d}, {d}", .{ months[@intCast(parts.month - 1)], parts.day, parts.year }) catch "";
}

pub fn statusColor(p: theme.Palette, status: report.Status) Color {
    return switch (status) {
        .passing => p.success,
        .failing => p.destructive,
        .no_threshold => fade(p.muted_foreground, 0.3),
    };
}

pub fn threshold(app: *const App, name: []const u8) ?f64 {
    const index = app.saved.find(name) orelse return null;
    const rule = &app.saved.rules[index];

    if (!rule.enabled) return null;
    return std.fmt.parseFloat(f64, rule.value.slice()) catch null;
}

/// "NAME OP VALUE" when a threshold is set, otherwise the KPI name.
pub fn thresholdLabel(app: *const App, buffer: []u8, name: []const u8) []const u8 {
    const index = app.saved.find(name) orelse return name;
    const rule = &app.saved.rules[index];
    const value = threshold(app, name) orelse return name;

    var number: [64]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s} {s} {s}", .{
        name,
        prefs.operators[rule.operator],
        formatFloat(&number, value),
    }) catch name;
}

// ── Overlays ───────────────────────────────────────────────────────────

fn overlaySlot(app: *const App, primary: usize) ?usize {
    for (app.saved.overlays[0..app.saved.overlay_count], 0..) |overlay, index| {
        if (overlay.primary == primary) return index;
    }

    return null;
}

pub fn hasOverlay(app: *const App, primary: usize, name: []const u8) bool {
    const member = app.saved.find(name) orelse return false;
    const slot = overlaySlot(app, primary) orelse return false;

    return app.saved.overlays[slot].members[member];
}

/// Toggle `name` as an overlay on the chart whose rule index is `primary`.
/// Overlays are saved immediately, like ldd keeps them in local storage.
pub fn addOverlay(app: *App, primary: usize, name: []const u8) void {
    const member = app.saved.find(name) orelse return;
    if (member == primary) return;

    const slot = overlaySlot(app, primary) orelse blk: {
        if (app.saved.overlay_count == app.saved.overlays.len) return;

        app.saved.overlays[app.saved.overlay_count] = .{ .primary = primary };
        app.saved.overlay_count += 1;
        break :blk app.saved.overlay_count - 1;
    };

    const overlay = &app.saved.overlays[slot];
    overlay.members[member] = !overlay.members[member];

    if (std.mem.indexOfScalar(bool, &overlay.members, true) == null) {
        const count = app.saved.overlay_count;
        std.mem.copyForwards(prefs.Overlay, app.saved.overlays[slot .. count - 1], app.saved.overlays[slot + 1 .. count]);
        app.saved.overlay_count -= 1;
    }

    persist(app);
}

fn removeOverlay(app: *App, primary: usize, name: []const u8) void {
    if (hasOverlay(app, primary, name)) addOverlay(app, primary, name);
}

pub fn hasFocusOverlay(app: *const App, index: usize) bool {
    for (app.focus_overlays[0..app.focus_overlay_count]) |existing| {
        if (existing == index) return true;
    }

    return false;
}

pub fn toggleFocusOverlay(app: *App, index: usize) void {
    if (app.focus_chart == index) return;

    for (app.focus_overlays[0..app.focus_overlay_count], 0..) |existing, at| {
        if (existing == index) {
            const count = app.focus_overlay_count;
            std.mem.copyForwards(usize, app.focus_overlays[at .. count - 1], app.focus_overlays[at + 1 .. count]);
            app.focus_overlay_count -= 1;
            return;
        }
    }

    if (app.focus_overlay_count < app.focus_overlays.len) {
        app.focus_overlays[app.focus_overlay_count] = index;
        app.focus_overlay_count += 1;
    }
}

fn persist(app: *App) void {
    app.draft = app.saved;
    app.saved.save(app.allocator, app.io, app.settings_path) catch |err| app.failure(err);
}

fn savedOverlayNames(app: *const App, name: []const u8, output: [][]const u8) [][]const u8 {
    const primary = app.saved.find(name) orelse return output[0..0];
    const slot = overlaySlot(app, primary) orelse return output[0..0];
    var count: usize = 0;

    for (app.saved.overlays[slot].members[0..app.saved.rule_count], 0..) |selected, member| {
        if (!selected or count == output.len) continue;

        output[count] = app.saved.rules[member].name.slice();
        count += 1;
    }

    return output[0..count];
}

// ── Sidebar and top bar ────────────────────────────────────────────────

fn failingCount(app: *const App, area: usize) usize {
    const data = &app.report.?;
    var count: usize = 0;

    for (data.names) |name| {
        if (data.status(area, name, &app.saved) == .failing) count += 1;
    }

    return count;
}

/// Areas and KPI groups, like ldd's `qos-sidebar.svelte`.
pub fn sidebar(app: *App, context: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const data = &app.report.?;

    const previous = r.clipWithin(context);
    defer r.restoreClip(previous);

    var y = context.y + 10;
    r.hline(context.x, context.right(), context.y, p.sidebar_border);

    app.sectionLabel("Areas", context.x + 10, y + 4);
    y += 28;

    for (data.areas, 0..) |area, index| {
        const row = Rect{ .x = context.x, .y = y, .w = context.w, .h = 32 };

        var count_buffer: [16]u8 = undefined;
        const failing = failingCount(app, index);
        const badge: ?App.Badge = if (failing > 0) .{
            .text = std.fmt.bufPrint(&count_buffer, "{d}", .{failing}) catch "",
            .foreground = p.destructive,
            .background = fade(p.destructive, 0.14),
        } else null;

        if (app.navItem(row, .map_pin, area.name, app.area == index, badge)) {
            app.area = index;
            app.group_filter = 0;
            app.resetScroll();
        }

        y += 34;
    }

    if (app.saved.group_count > 0) {
        y += 12;
        app.sectionLabel("KPI groups", context.x + 10, y + 4);
        y += 28;

        if (app.navItem(.{ .x = context.x, .y = y, .w = context.w, .h = 32 }, .layers, "All groups", app.group_filter == 0, null)) {
            app.group_filter = 0;
            app.resetScroll();
        }

        y += 34;

        for (app.saved.groups[0..app.saved.group_count], 0..) |*group, index| {
            var count_buffer: [16]u8 = undefined;
            const members = std.mem.count(bool, &group.members, &.{true});
            const badge = App.Badge{
                .text = std.fmt.bufPrint(&count_buffer, "{d}", .{members}) catch "",
                .foreground = p.muted_foreground,
                .background = p.muted,
            };

            const row = Rect{ .x = context.x, .y = y, .w = context.w, .h = 32 };

            if (app.navItem(row, .folder, group.name.slice(), app.group_filter == index + 1, badge)) {
                app.group_filter = if (app.group_filter == index + 1) 0 else index + 1;
                app.resetScroll();
            }

            y += 34;
        }
    }

    const new_file = Rect{ .x = context.x, .y = @max(y + 12, context.bottom() - 38), .w = context.w, .h = 32 };

    if (app.navItem(new_file, .rotate, "Open another report", false, null)) app.closeReport();
}

pub fn topbar(app: *App, area: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;
    const data = &app.report.?;

    // Left: area switcher and source.
    const name = data.areas[app.area].name;
    const switcher = Rect{
        .x = area.x - 8,
        .y = area.centerY() - 16,
        .w = 8 + 24 + r.textWidth(name, .heading) + 6 + 14 + 8,
        .h = 32,
    };

    const switcher_open = app.popup.open and app.popup.target == .area;

    if (ui.button("", switcher, .ghost, switcher_open)) app.openPopup(switcher, .area, 0);
    ui.setTooltip(switcher, "Switch area");

    r.icon(.map_pin, .{ .x = area.x, .y = area.centerY() - 8, .w = 16, .h = 16 }, p.brand);

    const name_x = area.x + 24;
    r.text(name, name_x, area.y + (area.h - r.textHeight(.heading)) / 2, p.foreground, .heading);
    r.icon(.chevron_down, .{ .x = name_x + r.textWidth(name, .heading) + 6, .y = area.centerY() - 7, .w = 14, .h = 14 }, p.muted_foreground);

    var buffer: [256]u8 = undefined;
    const source = std.fmt.bufPrint(&buffer, "{s}  ·  {d} KPIs", .{ data.source, data.names.len }) catch data.source;
    const source_x = switcher.right() + 8;

    // Right: actions.
    const height: f32 = 32;
    const y = area.centerY() - height / 2;
    var right = area.right() - 8;

    const settings_rect = Rect{ .x = right - height, .y = y, .w = height, .h = height };
    if (ui.iconButton(.sliders, settings_rect, p.muted_foreground, "Thresholds and groups")) {
        app.navigate(.settings);
        app.settings_tab = 2;
        return;
    }

    right = settings_rect.x - 6;

    // Export menu: one outline button with icon, label, and chevron.
    const export_width = 12 + 16 + 8 + r.textWidth("Export", .strong) + 8 + 14 + 10;
    const export_rect = Rect{ .x = right - export_width, .y = y, .w = export_width, .h = height };
    const menu_open = app.popup.open and app.popup.target == .export_menu;

    if (ui.button("", export_rect, .outline, menu_open)) app.openPopup(export_rect, .export_menu, 0);

    r.icon(.download, .{ .x = export_rect.x + 12, .y = area.centerY() - 8, .w = 16, .h = 16 }, p.foreground);
    r.leading("Export", .{ .x = export_rect.x + 36, .y = y, .w = 80, .h = height }, p.foreground, .strong);
    r.icon(.chevron_down, .{ .x = export_rect.right() - 24, .y = area.centerY() - 7, .w = 14, .h = 14 }, p.muted_foreground);
    ui.setTooltip(export_rect, "Export charts for every area to Excel");

    const source_width = export_rect.x - 16 - source_x;
    if (source_width > 40) {
        var fit_buffer: [256]u8 = undefined;
        const fitted = r.fit(&fit_buffer, source, source_width, .small);
        r.text(fitted, source_x, area.y + (area.h - r.textHeight(.small)) / 2 + 1, p.muted_foreground, .small);
    }
}

// ── Dashboard ──────────────────────────────────────────────────────────

fn statusOf(app: *const App, name: []const u8) report.Status {
    return app.report.?.status(app.area, name, &app.saved);
}

fn groupOf(app: *const App, name: []const u8) usize {
    const rule = app.saved.find(name) orelse return 0;

    for (app.saved.groups[0..app.saved.group_count], 0..) |*group, index| {
        if (group.members[rule]) return index + 1;
    }

    return 0;
}

pub fn page(app: *App, content: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const data = &app.report.?;

    if (app.group_filter > app.saved.group_count) app.group_filter = 0;
    if (app.area >= data.areas.len) app.area = 0;

    const x = content.x + 24;
    const w = content.w - 48;

    // Filter row: status pills and date range.
    const bar_y = content.y + 16;
    const filters_bottom = filterRow(app, x, bar_y, w);

    const body = Rect{ .x = content.x, .y = filters_bottom + 12, .w = content.w, .h = content.bottom() - filters_bottom - 12 };
    r.hline(content.x, content.right(), body.y - 1, fade(p.border, 0.6));

    const previous = r.clipWithin(body);

    var y = body.y + 20 - app.scroll;
    const columns: usize = if (w >= 900) 3 else if (w >= 560) 2 else 1;
    const card_width = (w - f(columns - 1) * grid_gap) / f(columns);

    var members: [prefs.max_kpis]usize = undefined;
    var drawn_any = false;

    if (app.status_filter != 0) {
        // One section with the filtered KPIs, like ldd.
        const length = collect(app, &members, null);

        var title_buffer: [160]u8 = undefined;
        const base = switch (app.status_filter) {
            1 => "Passing KPIs",
            2 => "Failing KPIs",
            else => "KPIs without threshold",
        };

        const title = if (app.group_filter > 0)
            std.fmt.bufPrint(&title_buffer, "{s} — {s}", .{ base, app.saved.groups[app.group_filter - 1].name.slice() }) catch base
        else
            base;

        if (length > 0) {
            y = section(app, title, members[0..length], x, y, card_width, columns, body);
            drawn_any = true;
        }
    } else {
        for (0..app.saved.group_count) |group| {
            if (app.group_filter > 0 and app.group_filter != group + 1) continue;

            const length = collect(app, &members, group + 1);
            if (length == 0) continue;

            y = section(app, app.saved.groups[group].name.slice(), members[0..length], x, y, card_width, columns, body);
            drawn_any = true;
        }

        if (app.group_filter == 0) {
            const length = collect(app, &members, 0);

            if (length > 0) {
                const title = if (app.saved.group_count > 0) "Other KPIs" else "All KPIs";
                y = section(app, title, members[0..length], x, y, card_width, columns, body);
                drawn_any = true;
            }
        }
    }

    if (!drawn_any) {
        const empty = Rect{ .x = x, .y = body.y + 20, .w = w, .h = 128 };

        r.box(empty, fade(p.card, 0.4), theme.radius_large);
        r.dashedRect(empty, theme.radius_large, 1.2, 5, 5, p.border);
        r.centered(if (app.status_filter != 0) "No KPIs match this filter" else "No KPIs available", empty, p.muted_foreground, .body);

        y = empty.bottom() + 20;
    }

    app.scroll_max = @max(0, y + app.scroll - body.bottom() + 8);
    r.restoreClip(previous);

    app.ui.scrollbar(body, app.scroll, app.scroll_max);
}

/// Indices of KPIs shown in a section. `group` is 0 for ungrouped KPIs,
/// a 1-based group index, or null to ignore grouping (status filter view).
fn collect(app: *const App, output: *[prefs.max_kpis]usize, group: ?usize) usize {
    const data = &app.report.?;
    var length: usize = 0;

    for (data.names, 0..) |name, index| {
        const status = statusOf(app, name);

        if (app.status_filter > 0 and 1 + @backingInt(status) != app.status_filter) continue;

        const member_group = groupOf(app, name);

        if (group) |wanted| {
            if (member_group != wanted) continue;
        } else if (app.group_filter > 0 and member_group != app.group_filter) {
            continue;
        }

        output[length] = index;
        length += 1;
    }

    return length;
}

fn section(app: *App, title: []const u8, indices: []const usize, x: f32, top: f32, card_width: f32, columns: usize, body: Rect) f32 {
    const r = app.renderer;
    const p = app.palette();
    var y = top;

    // Group header: bold uppercase label over a hairline.
    var buffer: [160]u8 = undefined;
    const length = @min(title.len, buffer.len);
    const upper = std.ascii.upperString(buffer[0..length], title[0..length]);

    r.tracked(upper, x, y, p.foreground, .label, 0.9);

    var count_buffer: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d}", .{indices.len}) catch "";
    r.text(count, x + r.trackedWidth(upper, .label, 0.9) + 8, y, p.muted_foreground, .label);

    y += r.textHeight(.label) + 4;
    r.hline(x, x + card_width * f(columns) + grid_gap * f(columns - 1), y, p.border);
    y += 12;

    for (indices, 0..) |index, at| {
        const rect = Rect{
            .x = x + f(at % columns) * (card_width + grid_gap),
            .y = y + f(at / columns) * (card_height + grid_gap),
            .w = card_width,
            .h = card_height,
        };

        if (rect.bottom() >= body.y and rect.y < body.bottom()) card(app, index, rect, .{});
    }

    const rows = (indices.len + columns - 1) / columns;
    return y + f(rows) * (card_height + grid_gap) + 18;
}

fn filterRow(app: *App, x: f32, y: f32, width: f32) f32 {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;
    const data = &app.report.?;

    var counts = [_]usize{ data.names.len, 0, 0, 0 };
    for (data.names) |name| counts[1 + @backingInt(statusOf(app, name))] += 1;

    const labels = [_][]const u8{ "All", "Passing", "Failing", "No threshold" };
    const icons = [_]?gfx.Icon{ null, .circle_check, .circle_x, .circle_help };
    const colors = [_]Color{ p.foreground, p.success, p.destructive, p.muted_foreground };

    const height: f32 = 30;
    var xx = x;

    for (labels, icons, colors, counts, 0..) |label, icon, color, count, index| {
        var buffer: [16]u8 = undefined;
        const number = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch "";

        const icon_width: f32 = if (icon != null) 20 else 0;
        const pill_width = 24 + icon_width + r.textWidth(number, .small_strong) + 6 + r.textWidth(label, .small);
        const pill = Rect{ .x = xx, .y = y, .w = pill_width, .h = height };

        const active = app.status_filter == index;
        const clicked = ui.hit(pill);
        const amount = ui.hoverAmount(pill);

        if (active) {
            r.box(pill, fade(color, if (index == 0) 0.1 else 0.14), height / 2);
            r.outline(pill, fade(color, 0.35), height / 2);
        } else {
            r.box(pill, fade(p.accent, amount), height / 2);
            r.outline(pill, p.border, height / 2);
        }

        var cursor = pill.x + 12;

        if (icon) |which| {
            r.icon(which, .{ .x = cursor, .y = pill.centerY() - 7, .w = 14, .h = 14 }, color);
            cursor += icon_width;
        }

        const number_color = if (index == 0) p.foreground else color;
        r.leading(number, .{ .x = cursor, .y = pill.y, .w = 40, .h = pill.h }, number_color, .small_strong);
        cursor += r.textWidth(number, .small_strong) + 6;

        r.leading(label, .{ .x = cursor, .y = pill.y, .w = 200, .h = pill.h }, if (active) p.foreground else p.muted_foreground, .small);

        if (clicked) {
            app.status_filter = if (active and index != 0) 0 else index;
            app.resetScroll();
        }

        xx = pill.right() + 8;
    }

    // Date range: calendar + segmented control.
    const segmented_width = ui.segmentedWidth(&day_labels);
    const range_width = segmented_width + 28;

    var range_x = x + width - range_width;
    var range_y = y;
    var bottom = y + height;

    if (range_x < xx + 16) {
        range_x = x;
        range_y = y + height + 10;
        bottom = range_y + height + 2;
    }

    r.icon(.calendar, .{ .x = range_x, .y = range_y + height / 2 - 8, .w = 16, .h = 16 }, p.muted_foreground);

    const global_days = app.saved.days("", "");
    var selected: usize = 2;

    for (day_options, 0..) |days, index| {
        if (days == global_days) selected = index;
    }

    const segmented = Rect{ .x = range_x + 26, .y = range_y - 1, .w = segmented_width, .h = height + 2 };

    if (ui.segmented(&day_labels, selected, segmented)) |index| {
        var buffer: [8]u8 = undefined;
        app.saved.global_days.set(std.fmt.bufPrint(&buffer, "{d}", .{day_options[index]}) catch "30");
        persist(app);
    }

    ui.setTooltip(segmented, "Date range for every chart. Area and KPI overrides still apply.");

    return bottom;
}

// ── Chart card ─────────────────────────────────────────────────────────

/// One KPI chart card. `index` is into `report.names`.
pub fn card(app: *App, index: usize, rect: Rect, view: View) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;
    const data = &app.report.?;

    const name = data.names[index];
    const status = statusOf(app, name);
    const series = data.find(app.area, name);
    const latest: ?f64 = if (series) |value| (if (value.points.len > 0) value.points[value.points.len - 1].value else null) else null;

    const clicked = view.clickable and ui.hit(rect);
    const hover = if (view.clickable or view.toolbar) ui.hoverAmount(rect) else 0;
    const hovering = (view.clickable or view.toolbar) and ui.hovered(rect);

    // Frame
    var fill = p.card;
    if (status == .failing) fill = geo.tint(p.card, p.destructive, 0.04);

    if (hover > 0.01 and view.clickable) {
        r.shadow(rect, theme.radius, 12, 0, fade(p.brand, 0.28 * hover));
    }

    r.box(rect, fill, theme.radius);
    r.outline(rect, geo.blend(p.border, geo.tint(p.border, p.primary, 0.4), if (view.clickable) hover else 0), theme.radius);

    // Title row
    var label_buffer: [512]u8 = undefined;
    const label = thresholdLabel(app, &label_buffer, name);

    var upper_buffer: [512]u8 = undefined;
    const upper = std.ascii.upperString(upper_buffer[0..label.len], label);

    var latest_buffer: [64]u8 = undefined;
    const latest_text = if (latest) |value| formatFloat(&latest_buffer, value) else "";
    const badge_width: f32 = if (latest != null) r.textWidth(latest_text, .tiny) + 12 else 0;

    const title_x = rect.x + 12 + 16;
    const title_width = rect.right() - 12 - badge_width - (if (latest != null) @as(f32, 8) else 0) - title_x;

    var lines: [2][]const u8 = undefined;
    var line_buffer: [600]u8 = undefined;
    const line_count = wrapCharacters(r, upper, title_width, &lines, &line_buffer);

    const line_height: f32 = 15;
    const title_height = f(line_count) * line_height;
    const title_top = rect.y + 10;
    const title_middle = title_top + title_height / 2;

    statusDot(app, rect.x + 16, title_middle, status, view.hover);

    const title_color = if (status == .failing) p.destructive else p.foreground;

    for (lines[0..line_count], 0..) |line, at| {
        const line_y = title_top + f(at) * line_height + (line_height - r.textHeight(.label)) / 2;
        r.tracked(line, title_x, line_y, title_color, .label, 0.3);
    }

    if (latest != null) {
        const badge = Rect{ .x = rect.right() - 12 - badge_width, .y = title_middle - 9, .w = badge_width, .h = 18 };
        const failing = status == .failing;

        ui.badge(
            latest_text,
            badge,
            if (failing) p.destructive else p.primary,
            if (failing) fade(p.destructive, 0.15) else fade(p.primary, 0.1),
        );
    }

    // Datasets: the primary series plus overlays.
    var overlay_buffer: [16][]const u8 = undefined;
    const overlay_names = view.overlays orelse savedOverlayNames(app, name, &overlay_buffer);

    const days = view.days orelse app.saved.days(data.areas[app.area].name, name);
    var datasets: [17]Dataset = undefined;
    var dataset_count: usize = 0;

    datasets[0] = .{
        .name = name,
        .points = data.points(app.area, name, days),
        .color = if (status == .passing) theme.passing_line else theme.series[0],
    };
    dataset_count = 1;

    // Overlays take the next palette colors, skipping the primary's color
    // (a passing primary is green, which is also ldd's second color).
    var color_index: usize = 1;

    for (overlay_names) |other| {
        if (dataset_count == datasets.len) break;

        var color = theme.series[color_index % theme.series.len];

        if (std.mem.eql(u8, &color, &datasets[0].color)) {
            color_index += 1;
            color = theme.series[color_index % theme.series.len];
        }

        color_index += 1;

        datasets[dataset_count] = .{
            .name = other,
            .points = data.points(app.area, other, days),
            .color = color,
        };
        dataset_count += 1;
    }

    const canvas = Rect{
        .x = rect.x + 8,
        .y = title_top + title_height + 4,
        .w = rect.w - 16,
        .h = rect.bottom() - 8 - (title_top + title_height + 4),
    };

    plot(app, canvas, rect, datasets[0..dataset_count], threshold(app, name), view.hover, ui.id(rect));

    // Floating toolbar (appears on hover).
    var copy = false;

    if (view.toolbar and hover > 0.01) {
        copy = toolbar(app, rect, name, overlay_names, hover, hovering);
    }

    if (clicked and !copy) openFocus(app, index);

    if (copy) {
        chart_image.copy(app, index, .{ .days = view.days, .overlays = view.overlays }) catch |err| app.failure(err);
    }
}

fn statusDot(app: *App, x: f32, y: f32, status: report.Status, animate: bool) void {
    const r = app.renderer;
    const p = app.palette();
    const color = statusColor(p, status);

    if (status == .failing and animate) {
        // ldd's statusPulse: a ring grows to 4 px and fades every 2 s.
        const time = f(sdl.timer.getMillisecondsSinceInit() % 2000) / 2000;
        const phase = if (time < 0.5) time * 2 else (1 - time) * 2;
        const eased = phase * phase * (3 - 2 * phase);

        r.circle(x, y, 4 + 4 * eased, fade(color, 0.6 * (1 - eased)));
        r.circle(x, y, 4, fade(color, 1 - 0.3 * eased));
        return;
    }

    r.circle(x, y, 4, color);
}

/// Break `value` at character boundaries (CSS `break-all`) into at most
/// two lines; the second line is ellipsised if it still overflows.
fn wrapCharacters(r: *gfx.Renderer, value: []const u8, width: f32, lines: *[2][]const u8, buffer: []u8) usize {
    const tracking: f32 = 0.3;

    if (r.trackedWidth(value, .label, tracking) <= width) {
        lines[0] = value;
        return 1;
    }

    var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();
    var end: usize = 0;
    var used: f32 = 0;

    while (iterator.nextCodepointSlice()) |slice| {
        const advance = r.textWidth(slice, .label) + tracking;
        if (used + advance > width and end > 0) break;

        used += advance;
        end += slice.len;
    }

    lines[0] = value[0..end];
    lines[1] = r.fit(buffer, value[end..], width, .label);
    return 2;
}

fn toolbar(app: *App, rect: Rect, name: []const u8, overlay_names: []const []const u8, amount: f32, hovering: bool) bool {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    const primary = app.saved.find(name) orelse return false;
    const button: f32 = 24;

    // Measure: plus, chips, copy.
    var chip_widths: [16]f32 = undefined;
    var width: f32 = 4 + button + 2 + button + 4;
    var chip_count: usize = 0;

    for (overlay_names, 0..) |other, at| {
        if (at == chip_widths.len) break;

        const chip_width = @min(140, r.textWidth(other, .tiny)) + 22;
        if (width + chip_width + 2 > rect.w - 8) break;

        chip_widths[at] = chip_width;
        width += chip_width + 2;
        chip_count += 1;
    }

    const bar = Rect{ .x = rect.right() - 4 - width, .y = rect.y + 4, .w = width, .h = button + 4 };

    r.shadow(bar, theme.radius, 4, 1, fade(p.shadow, amount));
    r.box(bar, fade(p.card, 0.95 * amount), theme.radius);
    r.outline(bar, fade(p.border, amount), theme.radius);

    if (!hovering) return false;

    var x = bar.x + 2;
    const y = bar.y + 2;

    const plus = Rect{ .x = x, .y = y, .w = button, .h = button };
    if (ui.iconButton(.plus, plus, p.muted_foreground, "Compare with another KPI")) {
        app.openPopup(plus, .overlay, primary);
    }

    x += button + 2;

    for (overlay_names[0..chip_count], chip_widths[0..chip_count]) |other, chip_width| {
        const chip = Rect{ .x = x, .y = y, .w = chip_width, .h = button };
        const clicked = ui.hit(chip);
        const chip_hover = ui.hoverAmount(chip);

        if (chip_hover > 0.01) r.box(chip, fade(p.destructive, 0.1 * chip_hover), theme.radius_small);

        const color = geo.blend(p.muted_foreground, p.destructive, chip_hover);

        var buffer: [160]u8 = undefined;
        const fitted = r.fit(&buffer, other, chip_width - 22, .tiny);

        r.leading(fitted, .{ .x = chip.x + 5, .y = chip.y, .w = chip.w, .h = chip.h }, color, .tiny);
        r.icon(.close, .{ .x = chip.right() - 15, .y = chip.centerY() - 5, .w = 10, .h = 10 }, color);

        ui.setTooltip(chip, "Remove overlay");

        if (clicked) removeOverlay(app, primary, other);

        x += chip_width + 2;
    }

    const copy_rect = Rect{ .x = x, .y = y, .w = button, .h = button };
    return ui.iconButton(.copy, copy_rect, p.muted_foreground, "Copy chart to clipboard");
}

// ── Plot ───────────────────────────────────────────────────────────────

/// Chart.js `niceNum` without rounding.
fn niceNum(range: f64) f64 {
    const rounded = @round(range);
    const value = if (@abs(range - rounded) <= range / 1000) rounded else range;
    const exponent = @floor(std.math.log10(value));
    const magnitude = std.math.pow(f64, 10, exponent);
    const fraction = value / magnitude;

    const nice: f64 = if (fraction <= 1) 1 else if (fraction <= 2) 2 else if (fraction <= 5) 5 else 10;
    return nice * magnitude;
}

const Ticks = struct {
    low: f64,
    high: f64,
    spacing: f64,
    count: usize,

    fn value(self: Ticks, index: usize) f64 {
        const raw = self.low + self.spacing * @as(f64, @floatFromInt(index));
        const decimals = @max(0, -@floor(std.math.log10(self.spacing)) + 1);
        const factor = std.math.pow(f64, 10, @min(decimals, 12));

        return @round(raw * factor) / factor;
    }
};

/// Linear scale ticks the way Chart.js generates them with `bounds: 'ticks'`.
fn niceTicks(low: f64, high: f64, max_ticks: usize) Ticks {
    var min = low;
    var max = high;

    if (min == max) {
        const offset = if (min == 0) 1 else @abs(min * 0.05);
        min -= offset;
        max += offset;
    }

    const spaces: f64 = @floatFromInt(@max(1, max_ticks - 1));
    var spacing = niceNum((max - min) / spaces);
    var nice_min = @floor(min / spacing) * spacing;
    var nice_max = @ceil(max / spacing) * spacing;
    const count = @round((nice_max - nice_min) / spacing);

    if (count > spaces) {
        spacing = niceNum(count * spacing / spaces);
        nice_min = @floor(min / spacing) * spacing;
        nice_max = @ceil(max / spacing) * spacing;
    }

    return .{
        .low = nice_min,
        .high = nice_max,
        .spacing = spacing,
        .count = @intFromFloat(@round((nice_max - nice_min) / spacing) + 1),
    };
}

const tick_font = gfx.FontRole.mono;
const tick_line: f32 = 12;
const tick_length: f32 = 8;
const tick_padding: f32 = 3;

fn plot(app: *App, canvas: Rect, bounds: Rect, datasets: []const Dataset, threshold_value: ?f64, hover: bool, key: u64) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    const muted = p.muted_foreground;
    // Chart.js draws 0.3 px grid lines; a faded hairline reads the same.
    const grid = fade(p.border, if (p.dark) 0.55 else 0.75);

    // Chart.js layout padding: top 4, right 8.
    var area = Rect{ .x = canvas.x, .y = canvas.y + 4, .w = canvas.w - 8, .h = canvas.h - 4 };

    // X range from every dataset.
    var first_day: i32 = std.math.maxInt(i32);
    var last_day: i32 = std.math.minInt(i32);
    var low: f64 = std.math.inf(f64);
    var high: f64 = -std.math.inf(f64);

    for (datasets) |dataset| {
        for (dataset.points) |point| {
            first_day = @min(first_day, point.day);
            last_day = @max(last_day, point.day);
            low = @min(low, point.value);
            high = @max(high, point.value);
        }
    }

    if (first_day > last_day) {
        r.centered("No data in this range", area, muted, .small);
        return;
    }

    if (threshold_value) |value| {
        low = @min(low, value);
        high = @max(high, value);
    }

    // Legend, shown only with overlays.
    if (datasets.len > 1) {
        const legend_height = legend(app, area, datasets, false);
        area.h -= legend_height;
    }

    const total_days: usize = @intCast(last_day - first_day + 1);
    const show_all = total_days <= 31;

    // X ticks: every day up to 31 days, otherwise at most 8.
    var tick_days: [192]i32 = undefined;
    var tick_count: usize = 0;
    const step: i32 = if (show_all) 1 else @intCast((total_days + 7) / 8);
    var day = first_day;

    while (day <= last_day and tick_count < tick_days.len) : (day += step) {
        tick_days[tick_count] = day;
        tick_count += 1;
    }

    var widest_label: f32 = 0;
    var label_buffer: [32]u8 = undefined;

    for (tick_days[0..tick_count]) |tick| {
        widest_label = @max(widest_label, r.textWidth(shortDate(&label_buffer, tick), tick_font));
    }

    // First pass at the y axis to size its labels.
    var ticks = niceTicks(low, high, maxTicks(area.h - 40));
    var y_label_width: f32 = 0;
    var number_buffer: [64]u8 = undefined;

    for (0..ticks.count) |index| {
        y_label_width = @max(y_label_width, r.textWidth(formatFloat(&number_buffer, ticks.value(index)), tick_font));
    }

    const y_axis_width = y_label_width + tick_length + tick_padding;

    // Label rotation: Chart.js picks asin((height + 6) / tickWidth) within
    // the allowed range (60–90° for daily ticks, 0° otherwise).
    const plot_width = area.w - y_axis_width;
    var rotation: f32 = 0;

    if (show_all) {
        const tick_width = plot_width / f(@max(1, tick_count));
        const ratio = (r.fontSize(tick_font) + 6) / @max(1, tick_width);
        const angle = if (ratio >= 1) 90 else std.math.radiansToDegrees(std.math.asin(ratio));
        rotation = std.math.clamp(angle, 60, 90);
    }

    const radians = std.math.degreesToRadians(rotation);
    const x_axis_height = if (rotation > 0)
        widest_label * @sin(radians) + tick_line * @cos(radians) + tick_length + tick_padding
    else
        tick_line + tick_length + tick_padding;

    var plot_area = Rect{
        .x = area.x + y_axis_width,
        .y = area.y,
        .w = plot_width,
        .h = @max(20, area.h - x_axis_height),
    };

    // Keep the last unrotated label inside the canvas.
    if (rotation == 0 and tick_count > 0) {
        const last_label = r.textWidth(shortDate(&label_buffer, tick_days[tick_count - 1]), tick_font);
        const span = f(@max(1, last_day - first_day));
        const last_x = plot_area.w * f(tick_days[tick_count - 1] - first_day) / span;
        const overflow = last_x + last_label / 2 - (plot_area.w + 8);

        if (overflow > 0) plot_area.w -= overflow;
    }

    // Final y ticks for the real plot height.
    ticks = niceTicks(low, high, maxTicks(plot_area.h));

    const span_days = f(@max(1, last_day - first_day));
    const value_span = ticks.high - ticks.low;

    const Mapper = struct {
        area: Rect,
        first: i32,
        days: f32,
        low: f64,
        span: f64,
        single: bool,

        fn x(self: @This(), day_value: i32) f32 {
            if (self.single) return self.area.centerX();
            return self.area.x + self.area.w * f(day_value - self.first) / self.days;
        }

        fn y(self: @This(), value: f64) f32 {
            return self.area.bottom() - self.area.h * @as(f32, @floatCast((value - self.low) / self.span));
        }
    };

    const map = Mapper{
        .area = plot_area,
        .first = first_day,
        .days = span_days,
        .low = ticks.low,
        .span = value_span,
        .single = first_day == last_day,
    };

    // Grid lines and tick marks.
    for (0..ticks.count) |index| {
        const value = ticks.value(index);
        const y = @round(map.y(value));

        r.hline(plot_area.x - tick_length, plot_area.right(), y, grid);

        const text = formatFloat(&number_buffer, value);
        const text_x = plot_area.x - tick_length - tick_padding - r.textWidth(text, tick_font);
        r.text(text, text_x, y - r.textHeight(tick_font) / 2, muted, tick_font);
    }

    for (tick_days[0..tick_count]) |tick| {
        const x = @round(map.x(tick));
        r.vline(x, plot_area.y, plot_area.bottom() + tick_length, grid);

        const text = shortDate(&label_buffer, tick);
        const label_y = plot_area.bottom() + tick_length + tick_padding;

        if (rotation > 0) {
            r.rotatedText(text, x + 2, label_y + 2, muted, tick_font, -@as(f64, rotation));
        } else {
            r.text(text, x - r.textWidth(text, tick_font) / 2, label_y, muted, tick_font);
        }
    }

    // Lines, clipped to the chart area.
    const previous = r.clipWithin(plot_area.expand(2));

    for (datasets) |dataset| drawSpline(r, dataset, map, plot_area);

    // Threshold annotation, drawn after the datasets.
    if (threshold_value) |value| {
        const y = map.y(value);
        r.dashedLine(plot_area.x, y, plot_area.right(), y, 1.5, 4, 4, theme.threshold_line);
    }

    r.restoreClip(previous);

    if (threshold_value) |value| {
        const y = map.y(value);
        const text = formatFloat(&number_buffer, value);
        const label_width = r.textWidth(text, tick_font) + 6;
        const label_rect = Rect{ .x = plot_area.right() - label_width, .y = y - 7, .w = label_width, .h = 14 };

        r.box(label_rect, fade(theme.threshold_line, 0.8), 6);
        r.centered(text, label_rect, .{ 255, 255, 255, 255 }, tick_font);
    }

    if (datasets.len > 1) _ = legend(app, area, datasets, true);

    // Index-mode tooltip.
    const visible = hover and ui.hovered(canvas);
    const opacity = ui.animate(key ^ 0x7001, if (visible) 1 else 0, 20);

    if (opacity > 0.01 or visible) {
        tooltip(app, map, datasets, bounds, key, opacity, visible);
    }
}

fn maxTicks(height: f32) usize {
    const limit: usize = @intFromFloat(@ceil(@max(1, height) / tick_line));
    return std.math.clamp(limit, 2, 11);
}

fn drawSpline(r: *gfx.Renderer, dataset: Dataset, map: anytype, area: Rect) void {
    const points = dataset.points;
    if (points.len == 0) return;

    var anchors: [400]Point = undefined;
    const count = @min(points.len, anchors.len);

    for (points[0..count], 0..) |point, index| {
        anchors[index] = .{ .x = map.x(point.day), .y = map.y(point.value) };
    }

    if (count == 1) {
        r.circle(anchors[0].x, anchors[0].y, 1.5, dataset.color);
        return;
    }

    // Chart.js splineCurve control points (tension 0.3), capped to the
    // chart area like `capBezierPoints`.
    const tension: f32 = 0.3;
    var before: [400]Point = undefined;
    var after: [400]Point = undefined;

    for (0..count) |index| {
        const current = anchors[index];
        const previous = if (index > 0) anchors[index - 1] else current;
        const next = if (index + 1 < count) anchors[index + 1] else current;

        const d01 = distance(current, previous);
        const d12 = distance(next, current);
        const total = d01 + d12;

        const s01 = if (total > 0) d01 / total else 0;
        const s12 = if (total > 0) d12 / total else 0;
        const fa = tension * s01;
        const fb = tension * s12;

        before[index] = cap(.{ .x = current.x - fa * (next.x - previous.x), .y = current.y - fa * (next.y - previous.y) }, area);
        after[index] = cap(.{ .x = current.x + fb * (next.x - previous.x), .y = current.y + fb * (next.y - previous.y) }, area);
    }

    var path: [4096]Point = undefined;
    var length: usize = 0;

    path[0] = anchors[0];
    length = 1;

    for (1..count) |index| {
        const a = anchors[index - 1];
        const b = after[index - 1];
        const c = before[index];
        const d = anchors[index];

        const segments: usize = @intFromFloat(std.math.clamp(distance(a, d) / 3, 2, 12));

        for (1..segments + 1) |step| {
            if (length == path.len) break;

            const t = f(step) / f(segments);
            const u = 1 - t;

            path[length] = .{
                .x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                .y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y,
            };
            length += 1;
        }
    }

    r.polyline(path[0..length], 1.5, dataset.color);
}

fn cap(point: Point, area: Rect) Point {
    return .{
        .x = std.math.clamp(point.x, area.x, area.right()),
        .y = std.math.clamp(point.y, area.y, area.bottom()),
    };
}

fn distance(a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Chart.js bottom legend: 12×2 line samples and labels, centred rows.
/// Returns the height used; draws only when `draw` is set.
fn legend(app: *App, area: Rect, datasets: []const Dataset, draw: bool) f32 {
    const r = app.renderer;
    const p = app.palette();
    const padding: f32 = 8;
    const box_width: f32 = 12;
    const row_height = tick_line + padding;

    var rows: f32 = 1;
    var row_width: f32 = 0;
    var widths: [17]f32 = undefined;

    for (datasets, 0..) |dataset, index| {
        widths[index] = box_width + 5 + @min(area.w - 40, r.textWidth(dataset.name, tick_font));

        if (row_width > 0 and row_width + widths[index] + padding > area.w) {
            rows += 1;
            row_width = 0;
        }

        row_width += widths[index] + padding;
    }

    const height = rows * row_height + 2;
    if (!draw) return height;

    var y = area.bottom() + 6;
    var start: usize = 0;

    while (start < datasets.len) {
        var end = start;
        var width: f32 = 0;

        while (end < datasets.len and (end == start or width + widths[end] + padding <= area.w)) {
            width += widths[end] + padding;
            end += 1;
        }

        var x = area.x + (area.w - width + padding) / 2;

        for (datasets[start..end], widths[start..end]) |dataset, item_width| {
            r.box(.{ .x = x, .y = y + tick_line / 2 - 1, .w = box_width, .h = 2 }, dataset.color, 0);

            var buffer: [160]u8 = undefined;
            const fitted = r.fit(&buffer, dataset.name, item_width - box_width - 5, tick_font);
            r.text(fitted, x + box_width + 5, y + (tick_line - r.textHeight(tick_font)) / 2, p.muted_foreground, tick_font);

            x += item_width + padding;
        }

        y += row_height;
        start = end;
    }

    return height;
}

const TooltipItem = struct { color: Color, label: []const u8, value: f64, y: f32 };

fn tooltip(app: *App, map: anytype, datasets: []const Dataset, bounds: Rect, key: u64, opacity: f32, visible: bool) void {
    const r = app.renderer;
    const ui = &app.ui;

    // Nearest day along x across every dataset (Chart.js index mode).
    const mouse_x = ui.mouse_x;
    var nearest: ?i32 = null;
    var best: f32 = std.math.inf(f32);

    for (datasets) |dataset| {
        for (dataset.points) |point| {
            const gap = @abs(map.x(point.day) - mouse_x);

            if (gap < best) {
                best = gap;
                nearest = point.day;
            }
        }
    }

    const day = nearest orelse return;

    var items: [17]TooltipItem = undefined;
    var count: usize = 0;
    var sum_y: f32 = 0;

    for (datasets) |dataset| {
        for (dataset.points) |point| {
            if (point.day != day) continue;

            items[count] = .{ .color = dataset.color, .label = dataset.name, .value = point.value, .y = map.y(point.value) };
            sum_y += items[count].y;
            count += 1;
            break;
        }
    }

    if (count == 0) return;

    const anchor_x = map.x(day);
    const anchor_y = sum_y / f(count);

    // Hover points (pointHoverRadius 3 with a 1 px border).
    if (visible) {
        for (items[0..count]) |item| {
            r.circle(anchor_x, item.y, 4, fade(item.color, opacity));
        }
    }

    // Measure.
    const padding: f32 = 8;
    const caret: f32 = 5;
    const box_size: f32 = 11;
    const row: f32 = 13;
    const max_width = bounds.w - 24;

    var title_buffer: [32]u8 = undefined;
    const title = longDate(&title_buffer, day);

    var width = r.textWidth(title, .mono_bold);
    // Each row keeps its own text and fitted copy; `fit` may return its
    // input, so the formatted text must outlive the loop.
    var rows: [17][]const u8 = undefined;
    var text_buffers: [17][200]u8 = undefined;
    var fit_buffers: [17][200]u8 = undefined;

    for (items[0..count], 0..) |item, index| {
        var number: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buffers[index], "{s}: {s}", .{ item.label, formatFloat(&number, item.value) }) catch item.label;

        rows[index] = r.fit(&fit_buffers[index], text, max_width - padding * 2 - box_size - 6, .mono_body);
        width = @max(width, box_size + 6 + r.textWidth(rows[index], .mono_body));
    }

    width += padding * 2;
    const height = padding * 2 + row + 6 + f(count) * row + f(count - 1) * 2;

    // Place to the right of the point, flipping left near the edge, and
    // centred vertically on it.
    const right_side = anchor_x + caret + 2 + width <= bounds.right() - 4;
    const target_x = if (right_side) anchor_x + caret + 2 else anchor_x - caret - 2 - width;
    const target_y = std.math.clamp(anchor_y - height / 2, bounds.y + 4, bounds.bottom() - height - 4);

    const x = ui.animate(key ^ 0x7002, target_x, 16);
    const y = ui.animate(key ^ 0x7003, target_y, 16);
    const rect = Rect{ .x = x, .y = y, .w = width, .h = height };
    const background = fade(theme.tooltip_background, opacity);

    r.shadow(rect, 4, 10, 4, fade(.{ 0, 0, 0, 255 }, 0.25 * opacity));
    r.box(rect, background, 4);

    // Caret pointing at the hovered point.
    const caret_y = std.math.clamp(anchor_y, rect.y + 8, rect.bottom() - 8);

    if (x > anchor_x) {
        r.triangle(
            .{ .x = rect.x + 0.5, .y = caret_y - caret },
            .{ .x = rect.x + 0.5, .y = caret_y + caret },
            .{ .x = rect.x - caret, .y = caret_y },
            background,
        );
    } else {
        r.triangle(
            .{ .x = rect.right() - 0.5, .y = caret_y - caret },
            .{ .x = rect.right() - 0.5, .y = caret_y + caret },
            .{ .x = rect.right() + caret, .y = caret_y },
            background,
        );
    }

    const text_offset = (row - r.textHeight(.mono_body)) / 2;
    r.text(title, rect.x + padding, rect.y + padding + (row - r.textHeight(.mono_bold)) / 2, fade(theme.tooltip_title, opacity), .mono_bold);

    var row_y = rect.y + padding + row + 6;

    for (items[0..count], 0..) |item, index| {
        const swatch = Rect{ .x = rect.x + padding, .y = row_y + (row - box_size) / 2, .w = box_size, .h = box_size };

        r.box(swatch, fade(.{ 255, 255, 255, 255 }, opacity), 2);
        r.box(swatch.inset(1), fade(item.color, opacity), 1.5);
        r.text(rows[index], swatch.right() + 6, row_y + text_offset, fade(theme.tooltip_body, opacity), .mono_body);

        row_y += row + 2;
    }
}

// ── Focus view ─────────────────────────────────────────────────────────

pub fn openFocus(app: *App, index: usize) void {
    app.focus_chart = index;
    app.focus_days = 30;
    app.focus_overlay_count = 0;
    app.focus_amount = 0;
    app.popup.open = false;
}

pub fn closeFocus(app: *App) void {
    app.focus_chart = null;
    app.focus_overlay_count = 0;
    app.focus_days = 30;
    app.focus_amount = 0;
    app.popup.open = false;
}

fn focusNames(app: *const App, output: *[16][]const u8) [][]const u8 {
    const data = &app.report.?;

    for (app.focus_overlays[0..app.focus_overlay_count], 0..) |index, at| {
        output[at] = data.names[index];
    }

    return output[0..app.focus_overlay_count];
}

/// ldd's `chart-focus-modal.svelte`: a blurred backdrop and a large chart
/// with its own date range and temporary overlays.
pub fn drawFocus(app: *App) void {
    const index = app.focus_chart orelse return;
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;
    const data = &app.report.?;

    app.focus_amount = geo.approach(app.focus_amount, 1, ui.delta_time, 14);
    const amount = app.focus_amount;
    const eased = 1 - (1 - amount) * (1 - amount);

    r.blurFrame();
    r.box(.{ .w = app.width, .h = app.height }, fade(p.scrim, eased), 0);

    const width = @min(1152, app.width - 64);
    const height = @min(app.height - 64, 760);
    const shrink = (1 - eased) * 14;

    const modal = (Rect{
        .x = (app.width - width) / 2,
        .y = (app.height - height) / 2 + (1 - eased) * 10,
        .w = width,
        .h = height,
    }).inset(shrink);

    r.shadow(modal, theme.radius_large, 32, 16, fade(.{ 0, 0, 0, 255 }, 0.35 * eased));
    r.box(modal, fade(p.card, eased), theme.radius_large);
    r.outline(modal, fade(p.border, eased), theme.radius_large);

    // Header
    const header = Rect{ .x = modal.x, .y = modal.y, .w = modal.w, .h = 52 };
    const name = data.names[index];

    var upper_buffer: [256]u8 = undefined;
    const length = @min(name.len, upper_buffer.len);
    const upper = std.ascii.upperString(upper_buffer[0..length], name[0..length]);

    const button_height: f32 = 28;
    const y = header.centerY() - button_height / 2;
    var right = header.right() - 12;

    const close = Rect{ .x = right - button_height, .y = y, .w = button_height, .h = button_height };
    if (ui.iconButton(.close, close, p.muted_foreground, "Close  ·  Esc")) {
        closeFocus(app);
        return;
    }

    right = close.x - 6;

    const copy_width = ui.smallLabelButtonWidth("Copy");
    const copy_rect = Rect{ .x = right - copy_width, .y = y, .w = copy_width, .h = button_height };
    const copy = ui.smallLabelButton(.copy, "Copy", copy_rect, .ghost);

    right = copy_rect.x - 4;

    const overlay_width = ui.smallLabelButtonWidth("Overlay");
    const overlay_rect = Rect{ .x = right - overlay_width, .y = y, .w = overlay_width, .h = button_height };

    if (ui.smallLabelButton(.plus, "Overlay", overlay_rect, .ghost)) {
        app.openPopup(overlay_rect, .focus_overlay, 0);
    }

    right = overlay_rect.x - 12;

    // Day buttons.
    var day_x = right;
    var day_index: usize = day_options.len;

    while (day_index > 0) {
        day_index -= 1;

        const label = day_labels[day_index];
        const button_width = r.textWidth(label, .tiny) + 12;
        day_x -= button_width + 4;

        const rect = Rect{ .x = day_x, .y = header.centerY() - 11, .w = button_width, .h = 22 };
        const active = app.focus_days == day_options[day_index];
        const clicked = ui.hit(rect);
        const hover = ui.hoverAmount(rect);

        if (active) {
            r.box(rect, p.primary, theme.radius_small);
        } else if (hover > 0.01) {
            r.box(rect, fade(p.accent, hover), theme.radius_small);
        }

        r.centered(label, rect, if (active) p.primary_foreground else geo.blend(p.muted_foreground, p.foreground, hover), .tiny);

        if (clicked) app.focus_days = day_options[day_index];
    }

    r.icon(.calendar, .{ .x = day_x - 22, .y = header.centerY() - 7, .w = 14, .h = 14 }, p.muted_foreground);

    var title_buffer: [256]u8 = undefined;
    const title_room = day_x - 32 - (header.x + 16);
    const title = r.fit(&title_buffer, upper, title_room, .strong);
    r.tracked(title, header.x + 16, header.y + (header.h - r.textHeight(.strong)) / 2, p.foreground, .strong, 0.7);

    r.hline(modal.x, modal.right(), header.bottom(), p.border);

    // Overlay badges
    var chart_top = header.bottom() + 1;
    var names_buffer: [16][]const u8 = undefined;
    const names = focusNames(app, &names_buffer);

    if (names.len > 0) {
        const row = Rect{ .x = modal.x, .y = chart_top, .w = modal.w, .h = 36 };
        var x = row.x + 16;

        r.leading("Overlays:", .{ .x = x, .y = row.y, .w = 100, .h = row.h }, p.muted_foreground, .tiny);
        x += r.textWidth("Overlays:", .tiny) + 8;

        var remove: ?usize = null;

        for (names, 0..) |other, at| {
            const chip_width = @min(220, r.textWidth(other, .tiny)) + 26;
            if (x + chip_width > row.right() - 16) break;

            const chip = Rect{ .x = x, .y = row.centerY() - 11, .w = chip_width, .h = 22 };
            const clicked = ui.hit(chip);
            const hover = ui.hoverAmount(chip);

            r.box(chip, geo.blend(p.accent, geo.tint(p.card, p.destructive, 0.1), hover), theme.radius_small);

            const color = geo.blend(p.accent_foreground, p.destructive, hover);
            var buffer: [160]u8 = undefined;
            r.leading(r.fit(&buffer, other, chip_width - 26, .tiny), .{ .x = chip.x + 7, .y = chip.y, .w = chip.w, .h = chip.h }, color, .tiny);
            r.icon(.close, .{ .x = chip.right() - 16, .y = chip.centerY() - 5, .w = 10, .h = 10 }, color);

            if (clicked) remove = app.focus_overlays[at];

            x += chip_width + 6;
        }

        if (remove) |overlay| toggleFocusOverlay(app, overlay);

        r.hline(modal.x, modal.right(), row.bottom(), fade(p.border, 0.5));
        chart_top = row.bottom() + 1;
    }

    // Large chart: the same card, without toolbar or click-through.
    const chart = Rect{ .x = modal.x + 4, .y = chart_top + 4, .w = modal.w - 8, .h = modal.bottom() - chart_top - 8 };
    const view = View{ .days = app.focus_days, .overlays = names, .toolbar = false, .clickable = false };

    card(app, index, chart, view);

    if (copy) chart_image.copy(app, index, view) catch |err| app.failure(err);

    // Click on the backdrop closes the view.
    const outside = !modal.contains(ui.mouse_x, ui.mouse_y);
    if (ui.released and outside and !app.popup.open and !ui.blocked) closeFocus(app);
}
