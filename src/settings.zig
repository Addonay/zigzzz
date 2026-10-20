//! Settings: five tabs of staged preferences. Edits apply to a draft and
//! only take effect after saving; a floating bar appears while there are
//! unsaved changes.

const std = @import("std");
const gfx = @import("render.zig");
const App = @import("app.zig").App;
const contains = @import("app.zig").contains;
const prefs = @import("preferences.zig");
const theme = @import("theme.zig");
const geo = @import("geometry.zig");
const Text = @import("text.zig").Text;

const Rect = geo.Rect;
const f = geo.f;
const fade = geo.fade;

const tabs = [_][]const u8{ "General", "Date ranges", "Thresholds", "Groups", "Overlays" };

const row_height: f32 = 64;
const list_row: f32 = 44;

pub fn topbar(app: *App, area: Rect) void {
    const ui = &app.ui;

    app.topbarTitle(area, "Settings", "Workspace preferences and KPI chart configuration");

    const label = "Restore defaults";
    const width = ui.labelButtonWidth(label);
    const rect = Rect{ .x = area.right() - 8 - width, .y = area.centerY() - 16, .w = width, .h = 32 };

    if (ui.labelButton(.rotate, label, rect, .ghost, false)) {
        app.draft.defaults(app.allocator) catch return;

        if (app.report) |report| {
            for (report.names) |name| _ = app.draft.include(name) catch continue;
        }

        app.ui.focused_text = null;
        app.notify("Defaults staged. Save to apply them.");
    }

    ui.setTooltip(rect, "Stage the default settings for review");
}

pub fn page(app: *App, content: Rect) void {
    const r = app.renderer;
    const ui = &app.ui;

    const width = @min(820, content.w - 48);
    const x = content.x + (content.w - width) / 2;

    // Tabs
    const tabs_width = @min(width, ui.segmentedWidth(&tabs));
    const tabs_rect = Rect{ .x = x, .y = content.y + 20, .w = tabs_width, .h = 36 };

    if (ui.segmented(&tabs, app.settings_tab, tabs_rect)) |index| {
        if (index != app.settings_tab) {
            app.settings_tab = index;
            app.resetScroll();
            app.search.set("");
            app.new_name.set("");
            app.editing_group = null;
            app.group_members = @splat(false);
        }
    }

    const body = Rect{ .x = content.x, .y = tabs_rect.bottom() + 16, .w = content.w, .h = content.bottom() - tabs_rect.bottom() - 16 };
    const previous = r.clipWithin(body);

    var y = body.y + 4 - app.scroll;

    switch (app.settings_tab) {
        0 => general(app, x, width, &y),
        1 => ranges(app, x, width, &y, body),
        2 => thresholds(app, x, width, &y, body),
        3 => groups(app, x, width, &y, body),
        else => overlays(app, x, width, &y, body),
    }

    const dirty = !app.draft.equivalent(&app.saved);

    y += if (dirty) 96 else 32;
    app.scroll_max = @max(0, y + app.scroll - body.bottom());

    r.restoreClip(previous);
    ui.scrollbar(body, app.scroll, app.scroll_max);

    if (dirty) unsavedBar(app, content);
}

// ── Building blocks ────────────────────────────────────────────────────

fn heading(app: *App, x: f32, y: *f32, width: f32, title: []const u8, description: []const u8) void {
    const r = app.renderer;
    const p = app.palette();

    r.text(title, x, y.*, p.foreground, .heading);
    y.* += r.textHeight(.heading) + 2;

    y.* += r.wrappedText(description, x, y.*, width, p.muted_foreground, .small);
    y.* += 14;
}

/// Card background for a block of rows.
fn panel(app: *App, rect: Rect) void {
    const p = app.palette();

    app.renderer.shadow(rect, theme.radius_large, 4, 1, fade(p.shadow, 0.5));
    app.renderer.border(rect, p.card, p.border, theme.radius_large);
}

/// Label and description on the left of a settings row.
fn rowLabel(app: *App, rect: Rect, label: []const u8, description: []const u8, control_width: f32) void {
    const r = app.renderer;
    const p = app.palette();
    const text_width = rect.w - control_width - 48;

    const total = r.textHeight(.strong) + r.textHeight(.small);
    const top = rect.y + (rect.h - total) / 2;

    r.text(label, rect.x + 20, top, p.card_foreground, .strong);

    var buffer: [256]u8 = undefined;
    r.text(r.fit(&buffer, description, text_width, .small), rect.x + 20, top + r.textHeight(.strong), p.muted_foreground, .small);
}

fn divider(app: *App, x: f32, right: f32, y: f32) void {
    app.renderer.hline(x, right, y, fade(app.palette().border, 0.8));
}

fn visible(rect: Rect, body: Rect) bool {
    return rect.bottom() >= body.y and rect.y <= body.bottom();
}

fn emptyNote(app: *App, rect: Rect, message: []const u8) void {
    const p = app.palette();

    app.renderer.box(rect, fade(p.muted, 0.5), theme.radius_large);
    app.renderer.dashedRect(rect, theme.radius_large, 1.2, 5, 5, p.border);
    app.renderer.centered(message, rect, p.muted_foreground, .small);
}

fn unsavedBar(app: *App, content: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    const width = @min(520, content.w - 48);
    const bar = Rect{ .x = content.x + (content.w - width) / 2, .y = content.bottom() - 72, .w = width, .h = 52 };

    ui.sink(bar);
    r.shadow(bar, theme.radius_large, 18, 6, fade(p.shadow, 1.4));
    r.border(bar, p.popover, p.border, theme.radius_large);

    r.circle(bar.x + 22, bar.centerY(), 4, p.brand);
    r.leading("You have unsaved changes", .{ .x = bar.x + 36, .y = bar.y, .w = width, .h = bar.h }, p.popover_foreground, .strong);

    const save_width = ui.buttonWidth("Save changes");
    const save = Rect{ .x = bar.right() - 10 - save_width, .y = bar.y + 9, .w = save_width, .h = 34 };

    const discard_width = ui.buttonWidth("Discard");
    const discard = Rect{ .x = save.x - 8 - discard_width, .y = save.y, .w = discard_width, .h = 34 };

    if (ui.button("Discard", discard, .ghost, false)) {
        app.draft = app.saved;
        app.ui.focused_text = null;
        app.notify("Unsaved changes discarded.");
    }

    if (ui.button("Save changes", save, .primary, false)) {
        app.draft.save(app.allocator, app.io, app.settings_path) catch |err| {
            app.failure(err);
            return;
        };

        app.renderer.setTextSize(app.draft.textSize()) catch |err| {
            app.failure(err);
            return;
        };

        app.saved = app.draft;
        app.ui.focused_text = null;
        app.success("Settings saved.");
    }
}

// ── General ────────────────────────────────────────────────────────────

fn general(app: *App, x: f32, width: f32, y: *f32) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    heading(app, x, y, width, "General", "Make the workspace feel right for you.");

    const card = Rect{ .x = x, .y = y.*, .w = width, .h = row_height * 3 };
    panel(app, card);

    // Appearance
    const appearance = Rect{ .x = x, .y = card.y, .w = width, .h = row_height };
    const modes = [_][]const u8{ "Light", "Dark" };
    const mode_width = ui.segmentedWidth(&modes);

    rowLabel(app, appearance, "Appearance", "Teal Perpetuity in light mode, Graphite in dark mode.", mode_width);

    const mode_rect = Rect{ .x = appearance.right() - 20 - mode_width, .y = appearance.centerY() - 17, .w = mode_width, .h = 34 };
    if (ui.segmented(&modes, if (app.draft.dark) 1 else 0, mode_rect)) |index| app.draft.dark = index == 1;

    divider(app, x + 20, card.right() - 20, appearance.bottom());

    // Text size
    const size = Rect{ .x = x, .y = appearance.bottom(), .w = width, .h = row_height };
    rowLabel(app, size, "Text size", "Interface text size, from 12 to 24 px. Chart labels keep their size.", 110);

    const field_rect = Rect{ .x = size.right() - 20 - 110, .y = size.centerY() - 17, .w = 76, .h = 34 };
    _ = ui.field(&app.draft.font_size, "16", field_rect);
    r.leading("px", .{ .x = field_rect.right() + 10, .y = field_rect.y, .w = 30, .h = field_rect.h }, p.muted_foreground, .small);

    divider(app, x + 20, card.right() - 20, size.bottom());

    // Sidebar on launch
    const sidebar = Rect{ .x = x, .y = size.bottom(), .w = width, .h = row_height };
    rowLabel(app, sidebar, "Open sidebar on launch", "Choose whether the sidebar starts expanded.", 40);

    const switch_rect = Rect{ .x = sidebar.right() - 20 - 36, .y = sidebar.centerY() - 10, .w = 36, .h = 20 };
    if (ui.toggle(app.draft.sidebar_open, switch_rect)) app.draft.sidebar_open = !app.draft.sidebar_open;

    y.* = card.bottom() + 12;

    r.icon(.info, .{ .x = x, .y = y.* + 2, .w = 14, .h = 14 }, p.muted_foreground);
    y.* += r.wrappedText(
        "Appearance and text size apply when you save. The sidebar preference applies on the next launch.",
        x + 22,
        y.*,
        width - 22,
        p.muted_foreground,
        .small,
    );
}

// ── Date ranges ────────────────────────────────────────────────────────

fn ranges(app: *App, x: f32, width: f32, y: *f32, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    heading(app, x, y, width, "Date ranges", "Days shown on each chart. KPI overrides take priority over area overrides.");

    const global = Rect{ .x = x, .y = y.*, .w = width, .h = row_height };
    panel(app, global);
    rowLabel(app, global, "Global range", "Used by every chart without an override (7 to 180 days).", 130);

    const field_rect = Rect{ .x = global.right() - 20 - 130, .y = global.centerY() - 17, .w = 84, .h = 34 };
    _ = ui.field(&app.draft.global_days, "30", field_rect);
    r.leading("days", .{ .x = field_rect.right() + 10, .y = field_rect.y, .w = 40, .h = field_rect.h }, p.muted_foreground, .small);

    y.* = global.bottom() + 28;

    for (0..2) |kind| {
        const is_area = kind == 0;
        const count = if (is_area) &app.draft.area_count else &app.draft.kpi_count;
        const rows = if (is_area) app.draft.area_days[0..] else app.draft.kpi_days[0..];

        r.text(if (is_area) "Area overrides" else "KPI overrides", x, y.*, p.foreground, .strong);

        const add_label = if (is_area) "Add area" else "Add KPI";
        const add_width = ui.labelButtonWidth(add_label) - 8;
        const add_rect = Rect{ .x = x + width - add_width, .y = y.* - 6, .w = add_width, .h = 32 };

        if (count.* < rows.len and ui.labelButton(.plus, add_label, add_rect, .outline, false)) {
            rows[count.*] = .{};
            count.* += 1;
        }

        y.* += 36;

        if (count.* == 0) {
            emptyNote(app, .{ .x = x, .y = y.*, .w = width, .h = 52 }, if (is_area) "No area overrides yet." else "No KPI overrides yet.");
            y.* += 52 + 28;
            continue;
        }

        const card = Rect{ .x = x, .y = y.*, .w = width, .h = f(count.*) * list_row + 8 };
        panel(app, card);

        var index: usize = 0;

        while (index < count.*) : (index += 1) {
            const row = Rect{ .x = x + 12, .y = card.y + 4 + f(index) * list_row, .w = width - 24, .h = list_row };

            if (index > 0) divider(app, row.x, row.right(), row.y);
            if (!visible(row, body)) continue;

            const field_y = row.centerY() - 16;

            _ = ui.field(&rows[index].name, if (is_area) "Area name" else "KPI name", .{ .x = row.x, .y = field_y, .w = row.w - 168, .h = 32 });
            _ = ui.field(&rows[index].days, "30", .{ .x = row.right() - 156, .y = field_y, .w = 72, .h = 32 });
            r.leading("days", .{ .x = row.right() - 76, .y = field_y, .w = 40, .h = 32 }, p.muted_foreground, .small);

            const remove = Rect{ .x = row.right() - 32, .y = field_y, .w = 32, .h = 32 };

            if (ui.iconButton(.trash, remove, p.muted_foreground, "Remove override")) {
                std.mem.copyForwards(prefs.Override, rows[index .. count.* - 1], rows[index + 1 .. count.*]);
                count.* -= 1;
                app.ui.focused_text = null;
                break;
            }
        }

        y.* = card.bottom() + 28;
    }
}

// ── Thresholds ─────────────────────────────────────────────────────────

fn thresholds(app: *App, x: f32, width: f32, y: *f32, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    heading(app, x, y, width, "Thresholds", "A KPI passes when its latest sample meets the comparison. Unchecked KPIs have no threshold.");

    // Search and bulk edit
    const search_width = @max(200, width - 360);
    _ = ui.iconField(.search, &app.search, "Search KPIs…", .{ .x = x, .y = y.*, .w = search_width, .h = 36 });

    var bx = x + search_width + 12;
    app.dropdown(prefs.operators[app.bulk_operator], .{ .x = bx, .y = y.*, .w = 70, .h = 36 }, .operator, prefs.max_kpis);
    bx += 78;

    _ = ui.field(&app.bulk_value, "Value", .{ .x = bx, .y = y.*, .w = 90, .h = 36 });
    bx += 98;

    const apply_rect = Rect{ .x = bx, .y = y.*, .w = x + width - bx, .h = 36 };

    if (ui.button("Apply to shown", apply_rect, .secondary, false)) {
        const value = std.fmt.parseFloat(f64, app.bulk_value.slice()) catch std.math.nan(f64);

        if (!std.math.isFinite(value)) {
            app.notify("Enter a finite numeric threshold.");
        } else {
            for (app.draft.rules[0..app.draft.rule_count]) |*rule| {
                if (!contains(rule.name.slice(), app.search.slice())) continue;

                rule.enabled = true;
                rule.operator = app.bulk_operator;
                rule.value = app.bulk_value;
            }
        }
    }

    ui.setTooltip(apply_rect, "Enable this comparison for every KPI that matches the search");

    y.* += 52;

    // Table
    var shown: usize = 0;
    for (app.draft.rules[0..app.draft.rule_count]) |*rule| {
        if (contains(rule.name.slice(), app.search.slice())) shown += 1;
    }

    const header_height: f32 = 36;
    const card = Rect{ .x = x, .y = y.*, .w = width, .h = header_height + f(shown) * list_row + 4 };
    panel(app, card);

    const operator_x = card.right() - 20 - 108 - 12 - 76;
    const value_x = card.right() - 20 - 108;

    r.text("KPI", x + 20, card.y + (header_height - r.textHeight(.small)) / 2, p.muted_foreground, .small);
    r.text("Comparison", operator_x, card.y + (header_height - r.textHeight(.small)) / 2, p.muted_foreground, .small);
    r.text("Value", value_x, card.y + (header_height - r.textHeight(.small)) / 2, p.muted_foreground, .small);
    divider(app, x, card.right(), card.y + header_height);

    var row_y = card.y + header_height;

    for (app.draft.rules[0..app.draft.rule_count], 0..) |*rule, index| {
        if (!contains(rule.name.slice(), app.search.slice())) continue;

        const row = Rect{ .x = x, .y = row_y, .w = width, .h = list_row };
        row_y += list_row;

        if (!visible(row, body)) continue;

        if (row.y > card.y + header_height) divider(app, x + 20, card.right() - 20, row.y);

        const label_rect = Rect{ .x = x + 20, .y = row.y, .w = operator_x - x - 32, .h = row.h };
        if (ui.checkbox(rule.name.slice(), rule.enabled, label_rect)) rule.enabled = !rule.enabled;

        app.dropdown(prefs.operators[rule.operator], .{ .x = operator_x, .y = row.centerY() - 16, .w = 76, .h = 32 }, .operator, index);
        _ = ui.field(&rule.value, "Value", .{ .x = value_x, .y = row.centerY() - 16, .w = 108, .h = 32 });
    }

    if (shown == 0) {
        r.centered("No KPIs match your search.", .{ .x = x, .y = card.y + header_height, .w = width, .h = 40 }, p.muted_foreground, .small);
    }

    y.* = card.bottom() + 16 + (if (shown == 0) @as(f32, 40) else 0);

    // Add a KPI that is not in the current report.
    _ = ui.field(&app.new_name, "Add a KPI by name", .{ .x = x, .y = y.*, .w = width - 96, .h = 36 });

    if (ui.labelButton(.plus, "Add", .{ .x = x + width - 84, .y = y.*, .w = 84, .h = 36 }, .outline, false) and app.new_name.length > 0) {
        _ = app.draft.include(app.new_name.slice()) catch |err| app.failure(err);
        app.new_name.set("");
    }

    y.* += 36;
}

// ── Groups ─────────────────────────────────────────────────────────────

fn groups(app: *App, x: f32, width: f32, y: *f32, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    heading(app, x, y, width, "Groups", "Organise KPIs into named sections on the dashboard. Each KPI belongs to one group.");

    if (app.draft.group_count == 0) {
        emptyNote(app, .{ .x = x, .y = y.*, .w = width, .h = 56 }, "No groups yet. Create one below.");
        y.* += 56 + 24;
    } else {
        const card = Rect{ .x = x, .y = y.*, .w = width, .h = f(app.draft.group_count) * list_row + 8 };
        panel(app, card);

        var index: usize = 0;

        while (index < app.draft.group_count) : (index += 1) {
            const group = &app.draft.groups[index];
            const row = Rect{ .x = x, .y = card.y + 4 + f(index) * list_row, .w = width, .h = list_row };

            if (index > 0) divider(app, x + 20, card.right() - 20, row.y);

            const editing = app.editing_group == index;
            if (editing) r.box(row.inset(4), fade(p.brand, 0.08), theme.radius);

            r.icon(.folder, .{ .x = x + 20, .y = row.centerY() - 8, .w = 16, .h = 16 }, if (editing) p.brand else p.muted_foreground);
            r.leading(group.name.slice(), .{ .x = x + 46, .y = row.y, .w = width, .h = row.h }, p.card_foreground, .strong);

            var count_buffer: [32]u8 = undefined;
            const member_count = std.mem.count(bool, group.members[0..app.draft.rule_count], &.{true});
            const count = std.fmt.bufPrint(&count_buffer, "{d} KPIs", .{member_count}) catch "";
            const badge_x = x + 46 + r.textWidth(group.name.slice(), .strong) + 10;
            ui.badge(count, .{ .x = badge_x, .y = row.centerY() - 9, .w = ui.badgeWidth(count), .h = 18 }, p.muted_foreground, p.muted);

            const remove = Rect{ .x = row.right() - 16 - 32, .y = row.centerY() - 16, .w = 32, .h = 32 };
            const edit = Rect{ .x = remove.x - 4 - 32, .y = remove.y, .w = 32, .h = 32 };

            if (visible(row, body) and ui.iconButton(.pencil, edit, p.muted_foreground, "Edit group")) {
                app.editing_group = index;
                app.new_name = group.name;
                app.group_members = group.members;
            }

            if (visible(row, body) and ui.iconButton(.trash, remove, p.muted_foreground, "Delete group")) {
                const total = app.draft.group_count;
                std.mem.copyForwards(prefs.Group, app.draft.groups[index .. total - 1], app.draft.groups[index + 1 .. total]);
                app.draft.group_count -= 1;
                app.editing_group = null;
                break;
            }
        }

        y.* = card.bottom() + 28;
    }

    // Editor
    r.text(if (app.editing_group != null) "Edit group" else "New group", x, y.*, p.foreground, .strong);
    y.* += 30;

    const save_label = if (app.editing_group != null) "Update group" else "Create group";
    const save_width = ui.buttonWidth(save_label);
    const cancel_width: f32 = if (app.editing_group != null) ui.buttonWidth("Cancel") + 8 else 0;

    _ = ui.field(&app.new_name, "Group name", .{ .x = x, .y = y.*, .w = width - save_width - cancel_width - 8, .h = 36 });

    if (app.editing_group != null and ui.button("Cancel", .{ .x = x + width - save_width - cancel_width, .y = y.*, .w = cancel_width - 8, .h = 36 }, .ghost, false)) {
        app.editing_group = null;
        app.new_name.set("");
        app.group_members = @splat(false);
    }

    if (ui.button(save_label, .{ .x = x + width - save_width, .y = y.*, .w = save_width, .h = 36 }, .primary, false)) saveGroup(app);

    y.* += 48;
    members(app, x, width, y, body, &app.group_members, null);
}

fn saveGroup(app: *App) void {
    const slot = app.editing_group orelse app.draft.group_count;

    if (app.new_name.length == 0 or std.mem.indexOfScalar(bool, &app.group_members, true) == null) {
        app.notify("Choose a group name and at least one KPI.");
        return;
    }

    if (slot >= app.draft.groups.len) return;

    for (app.draft.groups[0..app.draft.group_count], 0..) |*group, at| {
        if (at == slot) continue;

        if (std.mem.eql(u8, group.name.slice(), app.new_name.slice())) {
            app.notify("Use a unique group name.");
            return;
        }

        for (group.members, app.group_members) |existing, selected| {
            if (existing and selected) {
                app.notify("A KPI can belong to only one group.");
                return;
            }
        }
    }

    app.draft.groups[slot] = .{ .name = app.new_name, .members = app.group_members };
    if (app.editing_group == null) app.draft.group_count += 1;

    app.new_name.set("");
    app.group_members = @splat(false);
    app.editing_group = null;
}

// ── Overlays ───────────────────────────────────────────────────────────

fn overlays(app: *App, x: f32, width: f32, y: *f32, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    heading(app, x, y, width, "Overlays", "Show related KPI series together on a primary chart. You can also add them from a chart's toolbar.");

    if (app.draft.overlay_count == 0) {
        emptyNote(app, .{ .x = x, .y = y.*, .w = width, .h = 56 }, "No overlays yet.");
        y.* += 56 + 24;
    } else {
        const card = Rect{ .x = x, .y = y.*, .w = width, .h = f(app.draft.overlay_count) * list_row + 8 };
        panel(app, card);

        var index: usize = 0;

        while (index < app.draft.overlay_count) : (index += 1) {
            const overlay = &app.draft.overlays[index];
            const row = Rect{ .x = x, .y = card.y + 4 + f(index) * list_row, .w = width, .h = list_row };

            if (index > 0) divider(app, x + 20, card.right() - 20, row.y);

            const primary_name = app.draft.rules[overlay.primary].name.slice();
            const others = std.mem.count(bool, overlay.members[0..app.draft.rule_count], &.{true});

            r.icon(.layers, .{ .x = x + 20, .y = row.centerY() - 8, .w = 16, .h = 16 }, p.muted_foreground);

            var buffer: [256]u8 = undefined;
            const name = r.fit(&buffer, primary_name, width - 220, .strong);
            r.leading(name, .{ .x = x + 46, .y = row.y, .w = width, .h = row.h }, p.card_foreground, .strong);

            var count_buffer: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&count_buffer, "+{d}", .{others}) catch "";
            ui.badge(count, .{ .x = x + 46 + r.textWidth(name, .strong) + 10, .y = row.centerY() - 9, .w = ui.badgeWidth(count), .h = 18 }, p.muted_foreground, p.muted);

            const remove = Rect{ .x = row.right() - 16 - 32, .y = row.centerY() - 16, .w = 32, .h = 32 };
            const edit = Rect{ .x = remove.x - 4 - 32, .y = remove.y, .w = 32, .h = 32 };

            if (visible(row, body) and ui.iconButton(.pencil, edit, p.muted_foreground, "Edit overlay")) {
                app.overlay_primary = overlay.primary;
                app.overlay_members = overlay.members;
            }

            if (visible(row, body) and ui.iconButton(.trash, remove, p.muted_foreground, "Delete overlay")) {
                const total = app.draft.overlay_count;
                std.mem.copyForwards(prefs.Overlay, app.draft.overlays[index .. total - 1], app.draft.overlays[index + 1 .. total]);
                app.draft.overlay_count -= 1;
                break;
            }
        }

        y.* = card.bottom() + 28;
    }

    r.text("Primary chart", x, y.*, p.foreground, .strong);
    y.* += 30;

    app.overlay_primary = @min(app.overlay_primary, app.draft.rule_count -| 1);

    const primary_label = if (app.draft.rule_count > 0) app.draft.rules[app.overlay_primary].name.slice() else "Primary KPI";
    const save_width = ui.buttonWidth("Save overlay");

    app.dropdown(primary_label, .{ .x = x, .y = y.*, .w = width - save_width - 8, .h = 36 }, .primary, 0);

    if (ui.button("Save overlay", .{ .x = x + width - save_width, .y = y.*, .w = save_width, .h = 36 }, .primary, false)) {
        var slot = app.draft.overlay_count;

        for (app.draft.overlays[0..app.draft.overlay_count], 0..) |overlay, at| {
            if (overlay.primary == app.overlay_primary) {
                slot = at;
                break;
            }
        }

        app.overlay_members[app.overlay_primary] = false;

        if (slot < app.draft.overlays.len and std.mem.indexOfScalar(bool, &app.overlay_members, true) != null) {
            app.draft.overlays[slot] = .{ .primary = app.overlay_primary, .members = app.overlay_members };
            if (slot == app.draft.overlay_count) app.draft.overlay_count += 1;
        } else {
            app.notify("Select at least one other KPI.");
        }
    }

    y.* += 48;
    members(app, x, width, y, body, &app.overlay_members, app.overlay_primary);
}

/// Searchable KPI checklist, in two columns when there is room.
fn members(app: *App, x: f32, width: f32, y: *f32, body: Rect, selected: *[prefs.max_kpis]bool, exclude: ?usize) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    _ = ui.iconField(.search, &app.search, "Search KPIs…", .{ .x = x, .y = y.*, .w = width, .h = 36 });
    y.* += 48;

    var count: usize = 0;
    var chosen: usize = 0;

    for (app.draft.rules[0..app.draft.rule_count], 0..) |*rule, index| {
        if (exclude == index or !contains(rule.name.slice(), app.search.slice())) continue;

        count += 1;
        if (selected[index]) chosen += 1;
    }

    const columns: usize = if (width >= 600) 2 else 1;
    const rows = (count + columns - 1) / columns;
    const card = Rect{ .x = x, .y = y.*, .w = width, .h = f(rows) * 36 + 16 };
    panel(app, card);

    const column_width = (width - 32) / f(columns);
    var shown: usize = 0;

    for (app.draft.rules[0..app.draft.rule_count], 0..) |*rule, index| {
        if (exclude == index or !contains(rule.name.slice(), app.search.slice())) continue;

        const rect = Rect{
            .x = x + 16 + f(shown % columns) * column_width,
            .y = card.y + 8 + f(shown / columns) * 36,
            .w = column_width - 8,
            .h = 36,
        };
        shown += 1;

        if (visible(rect, body) and ui.checkbox(rule.name.slice(), selected[index], rect)) {
            selected[index] = !selected[index];
        }
    }

    y.* = card.bottom() + 10;

    var buffer: [64]u8 = undefined;
    r.text(std.fmt.bufPrint(&buffer, "{d} of {d} selected", .{ chosen, count }) catch "", x, y.*, p.muted_foreground, .small);
    y.* += 24;
}
