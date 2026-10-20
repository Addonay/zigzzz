const std = @import("std");
const App = @import("app.zig").App;
const Text = @import("text.zig").Text;
const Workbook = @import("workbook.zig").Workbook;
const Document = @import("document.zig").Document;
const number = @import("report.zig").number;
const theme = @import("theme.zig");
const geo = @import("geometry.zig");
const Rect = geo.Rect;
const f = geo.f;
const fade = geo.fade;

const Field = struct { key: []const u8, label: []const u8, aliases: []const []const u8, required: bool = false };
pub const fields = [_]Field{
    .{ .key = "SiteID", .label = "Cell name", .aliases = &.{ "cellname", "cell_name", "site_id" }, .required = true },
    .{ .key = "CellID", .label = "Cell ID", .aliases = &.{ "cellid", "cell_id" } },
    .{ .key = "CI", .label = "Unique ID", .aliases = &.{ "unique_id", "ci" }, .required = true },
    .{ .key = "WCell", .label = "Period", .aliases = &.{ "period_start_time", "wcell" } },
    .{ .key = "SITE_NAME", .label = "Physical site", .aliases = &.{ "physical_site_id", "site_name" } },
    .{ .key = "LAT", .label = "Latitude", .aliases = &.{ "latitude", "lat" }, .required = true },
    .{ .key = "LONG", .label = "Longitude", .aliases = &.{ "longitude", "lon", "lng" }, .required = true },
    .{ .key = "Spectrum", .label = "Spectrum (MHz)", .aliases = &.{"spectrum"} },
    .{ .key = "Bandwidth", .label = "Bandwidth", .aliases = &.{"bandwidth"} },
    .{ .key = "Sector_AZ", .label = "Azimuth (°)", .aliases = &.{ "sec_azmuth", "azimuth", "sector_azimuth" } },
    .{ .key = "Sector_Range", .label = "Sector range (m)", .aliases = &.{ "sec_range", "sector_range" } },
    .{ .key = "Sector_HBW", .label = "Horizontal beamwidth (°)", .aliases = &.{ "bw", "sector_hbw" } },
    .{ .key = "Sector_ABH", .label = "Antenna height", .aliases = &.{ "abh", "sector_abh" } },
    .{ .key = "Sector_MTilt", .label = "Mechanical tilt", .aliases = &.{ "m_tilt", "mtilt", "sector_mtilt" } },
    .{ .key = "Sector_ETilt", .label = "Electrical tilt", .aliases = &.{ "e_tilt", "etilt", "sector_etilt" } },
    .{ .key = "Sector_dlRsBoost", .label = "DL RS boost", .aliases = &.{ "dlrsboost", "dl_boost" } },
    .{ .key = "Sector_PMax", .label = "Maximum power (W)", .aliases = &.{ "pmax_w", "pmax" } },
    .{ .key = "Sector_R1", .label = "0–1.64 km (%)", .aliases = &.{ "sector_r1", "r1" } },
    .{ .key = "Sector_R2", .label = "1.64–3.36 km (%)", .aliases = &.{ "sector_r2", "r2" } },
    .{ .key = "Sector_R3", .label = "Beyond 3.36 km (%)", .aliases = &.{ "sector_r3", "r3" } },
    .{ .key = "Speed", .label = "Downlink throughput (kbps)", .aliases = &.{ "dl_user_throughput", "speed" } },
    .{ .key = "Volume", .label = "Data volume (MB)", .aliases = &.{ "total_data_volume", "volume" } },
    .{ .key = "Availability", .label = "Availability (%)", .aliases = &.{ "rna_4g", "availability" } },
    .{ .key = "Drop", .label = "PS drop rate", .aliases = &.{ "ps_drop_call_rate", "drop_rate" } },
    .{ .key = "xTxR", .label = "MIMO", .aliases = &.{ "mimo_config", "mimo" } },
    .{ .key = "ConfigurationGuard", .label = "Downlink data volume", .aliases = &.{"total_data_volume_dl"} },
    .{ .key = "FOE", .label = "Field engineer", .aliases = &.{"foe"} },
    .{ .key = "TAC", .label = "County", .aliases = &.{ "county", "tac" } },
    .{ .key = "Clutter", .label = "Town", .aliases = &.{ "town", "clutter" } },
    .{ .key = "ENodeBId", .label = "eNodeB ID", .aliases = &.{ "siteid", "enodeb_id" } },
    .{ .key = "Site_Prefence", .label = "Site preference", .aliases = &.{ "site_prefence", "site_preference" } },
    .{ .key = "REGION", .label = "Zone", .aliases = &.{ "zone", "region" } },
    .{ .key = "Carrier_Count", .label = "Carrier count", .aliases = &.{ "carriers", "carrier_count" } },
    .{ .key = "Macro_IBS", .label = "Macro / IBS", .aliases = &.{"macro_ibs"} },
    .{ .key = "ONAIR_DATE", .label = "On-air date / IOE status", .aliases = &.{ "onair_date", "ioe_status" } },
    .{ .key = "SITE_STATUS", .label = "Site status", .aliases = &.{"site_status"} },
    .{ .key = "VENDOR", .label = "Vendor", .aliases = &.{"vendor"} },
};

pub const Mapping = struct {
    columns: [fields.len + 16]?usize = @splat(null),
    labels: [16]Text = @splat(.{}),
    extra_count: usize = 0,
    sectors: bool = true,
    limit_range: bool = false,
    output: Text = .{},

    pub fn init(book: *const Workbook) Mapping {
        var result = Mapping{};
        for (fields, 0..) |field, index| {
            for (0..book.column_count) |column| {
                const header = std.mem.trim(u8, book.cell(0, column), " \t\r\n");
                var matches = false;
                for (field.aliases) |alias| matches = matches or normalizedEqual(header, alias);
                if (matches) { result.columns[index] = column; break; }
            }
        }
        var buffer: [512]u8 = undefined;
        const directory = std.fs.path.dirname(book.path) orelse ".";
        result.output.set(std.fmt.bufPrint(&buffer, "{s}/output.kml", .{directory}) catch "output.kml");
        return result;
    }

    fn value(self: *const Mapping, book: *const Workbook, row: usize, field: usize) []const u8 {
        const column = self.columns[field] orelse return "";
        return std.mem.trim(u8, book.cell(row, column), " \t\r\n");
    }

    fn numeric(self: *const Mapping, book: *const Workbook, row: usize, field: usize, fallback: f64) f64 {
        const value_text = self.value(book, row, field);
        if (field == 7 or field == 8) {
            var end: usize = 0;
            while (end < value_text.len and (std.ascii.isDigit(value_text[end]) or value_text[end] == '.' or value_text[end] == '+' or value_text[end] == '-')) end += 1;
            return number(value_text[0..end]) orelse fallback;
        }
        return number(value_text) orelse fallback;
    }
};

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var left: usize = 0;
    var right: usize = 0;
    while (true) {
        while (left < a.len and !std.ascii.isAlphanumeric(a[left])) left += 1;
        while (right < b.len and !std.ascii.isAlphanumeric(b[right])) right += 1;
        if (left == a.len or right == b.len) return left == a.len and right == b.len;
        if (std.ascii.toLower(a[left]) != std.ascii.toLower(b[right])) return false;
        left += 1;
        right += 1;
    }
}

// ── Interface ──────────────────────────────────────────────────────────

const row_height: f32 = 48;

fn columnLabel(app: *App, index: usize) []const u8 {
    const column = app.mapping.columns[index] orelse return "(none)";
    return app.book.?.cell(0, column);
}

fn missingRequired(app: *const App) usize {
    var missing: usize = 0;

    for (fields, 0..) |field, index| {
        if (field.required and app.mapping.columns[index] == null) missing += 1;
    }

    return missing;
}

fn exportKml(app: *App) void {
    const count = generate(app.allocator, app.io, &app.book.?, &app.mapping) catch |err| {
        app.failure(err);
        return;
    };

    var buffer: [512]u8 = undefined;
    app.success(std.fmt.bufPrint(&buffer, "Exported {d} sites to {s}", .{ count, app.mapping.output.slice() }) catch "KML exported.");
}

pub fn topbar(app: *App, area: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    const back = Rect{ .x = area.x - 4, .y = area.centerY() - 16, .w = 32, .h = 32 };

    if (ui.iconButton(.back, back, p.muted_foreground, "Choose another workbook")) {
        app.closeBook();
        return;
    }

    const title_x = back.right() + 8;
    r.text("KML Generator", title_x, area.y + (area.h - r.textHeight(.heading)) / 2, p.foreground, .heading);

    const label = "Export KML";
    const width = ui.labelButtonWidth(label);
    const export_rect = Rect{ .x = area.right() - 8 - width, .y = area.centerY() - 16, .w = width, .h = 32 };

    if (ui.labelButton(.download, label, export_rect, .primary, false)) exportKml(app);

    const missing = missingRequired(app);
    var buffer: [64]u8 = undefined;

    if (missing > 0) {
        const note = std.fmt.bufPrint(&buffer, "{d} required column{s} unmapped", .{ missing, if (missing == 1) "" else "s" }) catch "";
        const note_width = r.textWidth(note, .small) + 22;
        const note_x = export_rect.x - 16 - note_width;

        if (note_x > title_x + r.textWidth("KML Generator", .heading) + 16) {
            r.icon(.alert, .{ .x = note_x, .y = area.centerY() - 7, .w = 14, .h = 14 }, p.destructive);
            r.text(note, note_x + 20, area.y + (area.h - r.textHeight(.small)) / 2, p.destructive, .small);
        }
    }
}

/// Workbook summary and required mappings in the sidebar.
pub fn sidebar(app: *App, context: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const book = &app.book.?;

    const previous = r.clipWithin(context);
    defer r.restoreClip(previous);

    r.hline(context.x, context.right(), context.y, p.sidebar_border);

    var y = context.y + 14;
    app.sectionLabel("Workbook", context.x + 10, y);
    y += 26;

    r.icon(.file, .{ .x = context.x + 10, .y = y + 2, .w = 16, .h = 16 }, p.brand);

    var buffer: [256]u8 = undefined;
    const name = r.fit(&buffer, std.fs.path.basename(book.path), context.w - 46, .strong);
    r.text(name, context.x + 36, y, p.sidebar_foreground, .strong);
    y += 22;

    var stats: [64]u8 = undefined;
    r.text(std.fmt.bufPrint(&stats, "{d} rows  ·  {d} columns", .{ book.row_count -| 1, book.column_count }) catch "", context.x + 36, y, p.muted_foreground, .small);
    y += 36;

    app.sectionLabel("Required columns", context.x + 10, y);
    y += 26;

    for (fields, 0..) |field, index| {
        if (!field.required) continue;

        const mapped = app.mapping.columns[index] != null;

        r.icon(if (mapped) .circle_check else .circle_x, .{ .x = context.x + 10, .y = y + 3, .w = 14, .h = 14 }, if (mapped) p.success else p.destructive);
        r.text(field.label, context.x + 32, y, if (mapped) p.sidebar_foreground else p.destructive, .body);
        y += 26;
    }

    const another = Rect{ .x = context.x, .y = @max(y + 12, context.bottom() - 38), .w = context.w, .h = 32 };
    if (app.navItem(another, .rotate, "Open another workbook", false, null)) app.closeBook();
}

fn panel(app: *App, rect: Rect) void {
    const p = app.palette();

    app.renderer.shadow(rect, theme.radius_large, 4, 1, fade(p.shadow, 0.5));
    app.renderer.border(rect, p.card, p.border, theme.radius_large);
}

fn panelTitle(app: *App, x: f32, y: *f32, title: []const u8, subtitle: []const u8) void {
    const r = app.renderer;
    const p = app.palette();

    r.text(title, x, y.*, p.foreground, .heading);
    y.* += r.textHeight(.heading) + 2;
    r.text(subtitle, x, y.*, p.muted_foreground, .small);
    y.* += r.textHeight(.small) + 12;
}

/// Label on the left, column dropdown on the right.
fn mappingRow(app: *App, rect: Rect, index: usize, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const field = fields[index];

    if (rect.bottom() < body.y or rect.y > body.bottom()) return;

    const dropdown_width = @min(260, rect.w * 0.55);
    const label_width = rect.w - dropdown_width - 28;

    var buffer: [128]u8 = undefined;
    const label = r.fit(&buffer, field.label, label_width - (if (field.required) @as(f32, 14) else 0), .body);
    r.leading(label, .{ .x = rect.x + 16, .y = rect.y, .w = label_width, .h = rect.h }, p.card_foreground, .body);

    const missing = field.required and app.mapping.columns[index] == null;

    if (field.required) {
        r.text("*", rect.x + 16 + r.textWidth(label, .body) + 4, rect.y + (rect.h - r.textHeight(.body)) / 2, p.destructive, .body);
    }

    const dropdown = Rect{ .x = rect.right() - 12 - dropdown_width, .y = rect.centerY() - 16, .w = dropdown_width, .h = 32 };
    app.dropdown(columnLabel(app, index), dropdown, .column, index);

    if (missing) r.outline(dropdown, fade(p.destructive, 0.7), theme.radius);
}

pub fn page(app: *App, content: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const ui = &app.ui;

    const width = @min(880, content.w - 48);
    const x = content.x + (content.w - width) / 2;
    const body = content;

    const previous = r.clipWithin(body);
    var y = body.y + 24 - app.scroll;

    // Required columns
    panelTitle(app, x, &y, "Required columns", "Every site needs a name, a unique ID, and coordinates.");

    var required: [8]usize = undefined;
    var required_count: usize = 0;

    for (fields, 0..) |field, index| {
        if (!field.required) continue;
        required[required_count] = index;
        required_count += 1;
    }

    const two_columns = width >= 720;
    const columns: usize = if (two_columns) 2 else 1;
    const column_width = width / f(columns);

    const required_rows = (required_count + columns - 1) / columns;
    const required_card = Rect{ .x = x, .y = y, .w = width, .h = f(required_rows) * row_height + 8 };
    panel(app, required_card);

    for (required[0..required_count], 0..) |index, at| {
        const rect = Rect{
            .x = x + f(at % columns) * column_width,
            .y = required_card.y + 4 + f(at / columns) * row_height,
            .w = column_width,
            .h = row_height,
        };

        mappingRow(app, rect, index, body);
    }

    y = required_card.bottom() + 32;

    // Optional columns
    panelTitle(app, x, &y, "Optional columns", "Detected automatically from the header row. Unmapped fields are left out of descriptions.");

    const optional_count = fields.len - required_count;
    const optional_rows = (optional_count + columns - 1) / columns;
    const optional_card = Rect{ .x = x, .y = y, .w = width, .h = f(optional_rows) * row_height + 8 };
    panel(app, optional_card);

    var shown: usize = 0;

    for (fields, 0..) |field, index| {
        if (field.required) continue;

        const row = shown / columns;
        const rect = Rect{
            .x = x + f(shown % columns) * column_width,
            .y = optional_card.y + 4 + f(row) * row_height,
            .w = column_width,
            .h = row_height,
        };

        if (shown % columns == 0 and row > 0) {
            r.hline(x + 16, optional_card.right() - 16, rect.y, fade(p.border, 0.6));
        }

        mappingRow(app, rect, index, body);
        shown += 1;
    }

    if (two_columns) r.vline(x + column_width, optional_card.y + 12, optional_card.bottom() - 12, fade(p.border, 0.6));

    y = optional_card.bottom() + 32;

    // Extra description columns
    const add_label = "Add column";
    const add_width = ui.labelButtonWidth(add_label) - 8;

    if (app.mapping.extra_count < 16) {
        const add_rect = Rect{ .x = x + width - add_width, .y = y, .w = add_width, .h = 32 };
        if (ui.labelButton(.plus, add_label, add_rect, .outline, false)) app.mapping.extra_count += 1;
    }

    panelTitle(app, x, &y, "Description columns", "Extra columns appended to each placemark description.");

    if (app.mapping.extra_count == 0) {
        const empty = Rect{ .x = x, .y = y, .w = width, .h = 56 };

        r.box(empty, fade(p.muted, 0.5), theme.radius_large);
        r.dashedRect(empty, theme.radius_large, 1.2, 5, 5, p.border);
        r.centered("No extra columns. Use “Add column” to include more data.", empty, p.muted_foreground, .small);

        y = empty.bottom() + 32;
    } else {
        const card = Rect{ .x = x, .y = y, .w = width, .h = f(app.mapping.extra_count) * row_height + 8 };
        panel(app, card);

        for (0..app.mapping.extra_count) |index| {
            const row = Rect{ .x = x + 12, .y = card.y + 4 + f(index) * row_height, .w = width - 24, .h = row_height };
            const control_y = row.centerY() - 16;

            if (index > 0) r.hline(row.x, row.right(), row.y, fade(p.border, 0.6));

            _ = ui.field(&app.mapping.labels[index], "Label", .{ .x = row.x, .y = control_y, .w = row.w - 320, .h = 32 });

            const column_index = fields.len + index;
            app.dropdown(columnLabel(app, column_index), .{ .x = row.right() - 300, .y = control_y, .w = 260, .h = 32 }, .column, column_index);

            const remove = Rect{ .x = row.right() - 32, .y = control_y, .w = 32, .h = 32 };

            if (ui.iconButton(.trash, remove, p.muted_foreground, "Remove column")) {
                for (index..app.mapping.extra_count - 1) |at| {
                    app.mapping.labels[at] = app.mapping.labels[at + 1];
                    app.mapping.columns[fields.len + at] = app.mapping.columns[fields.len + at + 1];
                }

                app.mapping.extra_count -= 1;
                ui.focused_text = null;
                break;
            }
        }

        y = card.bottom() + 32;
    }

    // Output
    panelTitle(app, x, &y, "Output", "Placemarks for every site, with optional sector polygons.");

    const output_card = Rect{ .x = x, .y = y, .w = width, .h = 64 * 2 + 84 };
    panel(app, output_card);

    const switches = [_]struct { label: []const u8, description: []const u8, value: *bool }{
        .{ .label = "Generate sectors", .description = "Draw a wedge for each sector from azimuth, range, and beamwidth.", .value = &app.mapping.sectors },
        .{ .label = "Limit sector range by band", .description = "Shorten wedges for higher frequency bands.", .value = &app.mapping.limit_range },
    };

    for (switches, 0..) |item, index| {
        const row = Rect{ .x = x, .y = output_card.y + f(index) * 64, .w = width, .h = 64 };

        if (index > 0) r.hline(x + 16, output_card.right() - 16, row.y, fade(p.border, 0.6));

        const total = r.textHeight(.strong) + r.textHeight(.small);
        const top = row.y + (row.h - total) / 2;

        r.text(item.label, x + 20, top, p.card_foreground, .strong);
        r.text(item.description, x + 20, top + r.textHeight(.strong), p.muted_foreground, .small);

        const switch_rect = Rect{ .x = row.right() - 20 - 36, .y = row.centerY() - 10, .w = 36, .h = 20 };
        if (ui.toggle(item.value.*, switch_rect)) item.value.* = !item.value.*;
    }

    const path_y = output_card.y + 128;
    r.hline(x + 16, output_card.right() - 16, path_y, fade(p.border, 0.6));
    r.text("Output file", x + 20, path_y + 12, p.card_foreground, .strong);
    _ = ui.iconField(.file_down, &app.mapping.output, "output.kml", .{ .x = x + 20, .y = path_y + 38, .w = width - 40, .h = 34 });

    y = output_card.bottom() + 12;
    r.icon(.info, .{ .x = x, .y = y + 2, .w = 14, .h = 14 }, p.muted_foreground);
    r.text("An existing file at this path is replaced when you export.", x + 22, y, p.muted_foreground, .small);
    y += 48;

    app.scroll_max = @max(0, y + app.scroll - body.bottom());
    r.restoreClip(previous);
    ui.scrollbar(body, app.scroll, app.scroll_max);
}

const Site = struct {
    values: [fields.len + 16][]const u8,
    latitude: f64,
    longitude: f64,
    spectrum: f64,
    speed: f64,
    speed_sum: f64,
    volume: f64,
    traffic: f64,
    count: usize = 1,
    azimuth: f64,
    range: f64,
    beamwidth: f64,
};

pub fn generate(allocator: std.mem.Allocator, io: std.Io, book: *const Workbook, mapping: *const Mapping) !usize {
    for (fields, 0..) |field, index| {
        if (field.required and mapping.columns[index] == null) return error.MapAllRequiredColumns;
    }
    if (std.mem.eql(u8, mapping.output.slice(), book.path)) return error.OutputWouldReplaceSourceWorkbook;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var sites: std.ArrayList(Site) = .empty;
    var indices: std.StringHashMapUnmanaged(usize) = .empty;

    for (1..book.row_count) |row| {
        var values: [fields.len + 16][]const u8 = @splat("");
        for (0..fields.len + mapping.extra_count) |field| values[field] = mapping.value(book, row, field);
        if (values[0].len == 0 and values[2].len == 0) continue;
        if (values[0].len == 0) values[0] = values[2];
        const latitude = mapping.numeric(book, row, 5, std.math.nan(f64));
        const longitude = mapping.numeric(book, row, 6, std.math.nan(f64));
        if (!std.math.isFinite(latitude) or !std.math.isFinite(longitude) or @abs(latitude) > 90 or @abs(longitude) > 180) return error.InvalidSiteCoordinates;
        const speed = mapping.numeric(book, row, 20, 0) / 1000;
        const volume = mapping.numeric(book, row, 21, 0);
        const bandwidth = mapping.numeric(book, row, 8, 0);
        const traffic = if (bandwidth > 0) volume / bandwidth else 0;
        const entry = try indices.getOrPut(memory, values[0]);
        if (entry.found_existing) {
            const site = &sites.items[entry.value_ptr.*];
            for ([_]usize{ 1, 2, 8, 24 }) |field| {
                if (values[field].len > 0) site.values[field] = try memory.print("{s}{s}{s}", .{ site.values[field], if (site.values[field].len > 0) "/" else "", values[field] });
            }
            for (fields.len..fields.len + mapping.extra_count) |field| {
                if (values[field].len > 0) site.values[field] = try memory.print("{s}{s}{s}", .{ site.values[field], if (site.values[field].len > 0) "/" else "", values[field] });
            }
            site.speed_sum += speed;
            site.volume += volume;
            site.traffic += traffic;
            site.count += 1;
        } else {
            entry.value_ptr.* = sites.items.len;
            try sites.append(memory, .{
                .values = values, .latitude = latitude, .longitude = longitude,
                .speed = speed, .speed_sum = speed, .volume = volume, .traffic = traffic,
                .spectrum = mapping.numeric(book, row, 7, 700),
                .azimuth = mapping.numeric(book, row, 9, 32.5),
                .range = mapping.numeric(book, row, 10, 500),
                .beamwidth = mapping.numeric(book, row, 11, 65),
            });
        }
    }
    if (sites.items.len == 0) return error.NoSiteRows;
    std.mem.sort(Site, sites.items, {}, struct {
        fn less(_: void, a: Site, b: Site) bool { return std.mem.lessThan(u8, a.values[0], b.values[0]); }
    }.less);

    var out = Document{ .allocator = memory };
    try out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n");
    try out.append("<Style id=\"placemarkStyle\"><IconStyle><color>ff0000e6</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle></Style>\n<Style id=\"lowplacemarkStyle\"><IconStyle><color>ffff0000</color><scale>1.3</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle></Style>\n");
    const bands = [_]f64{ 800, 900, 1800, 2100, 2300, 2600, 0, -1 };
    const band_colors = [_][]const u8{ "7f00ff00", "ff0000e6", "ffff3300", "ffff9900", "ffffff00", "ff00ffff", "ff000099", "ffff0000" };
    for (bands, band_colors) |band, color| {
        try out.print("<Style id=\"sector{d}\"><LineStyle><color>{s}</color><width>2</width></LineStyle><PolyStyle><color>{s}</color><fill>1</fill></PolyStyle></Style>\n", .{ band, color, color });
    }
    for (sites.items) |site| {
        try out.append("<Placemark><name>");
        try out.escaped(site.values[0]);
        try out.print("</name><styleUrl>#{s}</styleUrl><description>", .{if (site.speed < 3) "lowplacemarkStyle" else "placemarkStyle"});
        try description(&out, &site, mapping);
        try out.print("</description><Point><coordinates>{d},{d},0</coordinates></Point></Placemark>\n", .{ site.longitude, site.latitude });
        if (!mapping.sectors) continue;
        var band: f64 = 0;
        for (bands[0..6]) |candidate| { if (site.spectrum == candidate) band = candidate; }
        if (site.speed < 3) band = -1;
        const radius = if (mapping.limit_range) limitedRange(site.spectrum) else site.range;
        if (!std.math.isFinite(radius) or radius < 0 or radius > 1_000_000 or site.beamwidth < 0 or site.beamwidth > 360) return error.InvalidSectorGeometry;
        try out.append("<Placemark><name>sec-");
        try out.escaped(site.values[0]);
        try out.print("</name><styleUrl>#sector{d}</styleUrl><description>", .{band});
        try description(&out, &site, mapping);
        try out.append("</description><Polygon><extrude>1</extrude><altitudeMode>relativeToGround</altitudeMode><outerBoundaryIs><LinearRing><coordinates>");
        try out.print("{d},{d},0\n", .{ site.longitude, site.latitude });
        for (0..33) |step| {
            const bearing = site.azimuth - site.beamwidth / 2 + site.beamwidth * @as(f64, @floatFromInt(step)) / 32;
            const point = destination(site.latitude, site.longitude, radius, bearing);
            try out.print("{d},{d},0\n", .{ point.longitude, point.latitude });
        }
        try out.print("{d},{d},0\n</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n", .{ site.longitude, site.latitude });
    }
    try out.append("</Document></kml>\n");
    try out.save(io, mapping.output.slice());
    return sites.items.len;
}

fn description(out: *Document, site: *const Site, mapping: *const Mapping) !void {
    for (fields, 0..) |field, index| {
        if (site.values[index].len == 0) continue;
        try out.escaped(field.key);
        try out.escaped(":  ");
        try out.escaped(site.values[index]);
        try out.escaped("<br/>");
    }
    try out.print("Speed-avg (Mbps): {d}&lt;br/&gt;Data Volume (MB): {d}&lt;br/&gt;Trafficpermhz: {d}&lt;br/&gt;", .{ site.speed_sum / @as(f64, @floatFromInt(site.count)), site.volume, site.traffic });
    for (0..mapping.extra_count) |index| {
        try out.escaped(mapping.labels[index].slice());
        try out.escaped(":  ");
        try out.escaped(site.values[fields.len + index]);
        try out.escaped("<br/>");
    }
}

fn limitedRange(band: f64) f64 {
    const bands = [_]f64{ 700, 800, 1800, 2100, 2600, 3500 };
    for (bands, 0..) |candidate, index| {
        if (candidate == band) return 290 - @as(f64, @floatFromInt(index)) * 10;
    }
    return 200;
}

fn destination(latitude: f64, longitude: f64, distance: f64, bearing: f64) struct { latitude: f64, longitude: f64 } {
    const radians = std.math.pi / 180.0;
    const lat = latitude * radians;
    const lon = longitude * radians;
    const angle = bearing * radians;
    const arc = distance / 6_371_000;
    const new_lat = std.math.asin(@sin(lat) * @cos(arc) + @cos(lat) * @sin(arc) * @cos(angle));
    const new_lon = lon + std.math.atan2(@sin(angle) * @sin(arc) * @cos(lat), @cos(arc) - @sin(lat) * @sin(new_lat));
    return .{ .latitude = new_lat / radians, .longitude = new_lon / radians };
}
