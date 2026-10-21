const std = @import("std");
const App = @import("app.zig").App;
const Text = @import("text.zig").Text;
const Workbook = @import("workbook.zig").Workbook;
const Document = @import("document.zig").Document;
const number = @import("report.zig").number;
const Preferences = @import("preferences.zig").Preferences;
const theme = @import("theme.zig");
const geo = @import("geometry.zig");
const Rect = geo.Rect;
const f = geo.f;
const fade = geo.fade;

/// One KML field. Aliases are listed in order of preference: detection
/// tries every column against the first alias before moving to the next.
///
/// The mapping follows the original WFAppKml (`Form1.cs`) reading the
/// LTE cell export: each row is one cell, keyed by `cellname`, and its
/// sector wedge uses that cell's own azimuth, range, and beamwidth.
const Field = struct { key: []const u8, label: []const u8, aliases: []const []const u8, required: bool = false };
pub const fields = [_]Field{
    .{ .key = "SiteID", .label = "Cell name", .aliases = &.{ "cellname", "cell_name" }, .required = true },
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
    .{ .key = "Configuration", .label = "Configuration", .aliases = &.{ "mimo_config", "configuration" } },
    .{ .key = "FOE", .label = "Field engineer", .aliases = &.{ "foe", "rfengineer" } },
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

/// Index of the field with `key`, checked at compile time.
fn fieldIndex(comptime key: []const u8) usize {
    inline for (fields, 0..) |field, index| {
        if (comptime std.mem.eql(u8, field.key, key)) return index;
    }

    @compileError("unknown KML field " ++ key);
}

const cell_name = fieldIndex("SiteID");
const cell_id = fieldIndex("CellID");
const unique_id = fieldIndex("CI");
const latitude_field = fieldIndex("LAT");
const longitude_field = fieldIndex("LONG");
const spectrum_field = fieldIndex("Spectrum");
const bandwidth_field = fieldIndex("Bandwidth");
const azimuth_field = fieldIndex("Sector_AZ");
const range_field = fieldIndex("Sector_Range");
const beamwidth_field = fieldIndex("Sector_HBW");
const speed_field = fieldIndex("Speed");
const volume_field = fieldIndex("Volume");
const configuration_field = fieldIndex("Configuration");

/// Fields joined with "/" when several rows share a cell name, as the
/// original tool does for cell IDs, unique IDs, bandwidths, and
/// configurations.
const joined_fields = [_]usize{ cell_id, unique_id, bandwidth_field, configuration_field };

pub const max_extras = 16;

pub const Mapping = struct {
    columns: [fields.len + max_extras]?usize = @splat(null),
    labels: [max_extras]Text = @splat(.{}),
    extra_count: usize = 0,
    /// Fields whose column came from the remembered defaults.
    remembered: [fields.len]bool = @splat(false),

    sectors: bool = true,
    limit_range: bool = false,

    folder: Text = .{},
    filename: Text = .{},
    /// Whether `folder` is the remembered default output folder.
    default_folder: bool = false,

    /// Auto-detected mapping, writing `<workbook>.kml` beside the workbook.
    pub fn init(book: *const Workbook) Mapping {
        var result = Mapping{};

        for (0..fields.len) |index| result.columns[index] = detect(book, index);

        result.folder.set(std.fs.path.dirname(book.path) orelse ".");

        var buffer: [512]u8 = undefined;
        const stem = std.fs.path.stem(book.path);
        result.filename.set(std.fmt.bufPrint(&buffer, "{s}.kml", .{if (stem.len > 0) stem else "output"}) catch "output.kml");

        return result;
    }

    /// Auto-detected mapping with the remembered defaults applied on top.
    /// Remembered headers missing from this workbook fall back to detection.
    pub fn initWith(book: *const Workbook, defaults: *const Preferences) Mapping {
        var result = init(book);

        for (fields, 0..) |field, index| {
            const header = defaults.kmlColumn(field.key) orelse continue;

            if (header.len == 0) {
                result.columns[index] = null;
                result.remembered[index] = true;
            } else if (findHeader(book, header)) |column| {
                result.columns[index] = column;
                result.remembered[index] = true;
            }
        }

        for (defaults.kml_extras[0..@min(defaults.kml_extra_count, max_extras)], 0..) |*extra, index| {
            result.labels[index] = extra.label;
            result.columns[fields.len + index] = findHeader(book, extra.header.slice());
            result.extra_count = index + 1;
        }

        result.sectors = defaults.kml_sectors;
        result.limit_range = defaults.kml_limit_range;

        if (defaults.kml_folder.length > 0) {
            result.folder = defaults.kml_folder;
            result.default_folder = true;
        }

        return result;
    }

    /// `folder/filename`, adding `.kml` when the name has no extension.
    pub fn outputPath(self: *const Mapping, buffer: []u8) []const u8 {
        const folder = std.mem.trimEnd(u8, std.mem.trim(u8, self.folder.slice(), " \t"), "/");
        const name = std.mem.trim(u8, self.filename.slice(), " \t");
        const extension = if (std.fs.path.extension(name).len == 0) ".kml" else "";

        if (folder.len == 0) return std.fmt.bufPrint(buffer, "{s}{s}", .{ name, extension }) catch name;
        return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ folder, name, extension }) catch name;
    }

    fn value(self: *const Mapping, book: *const Workbook, row: usize, field: usize) []const u8 {
        const column = self.columns[field] orelse return "";
        return std.mem.trim(u8, book.cell(row, column), " \t\r\n");
    }

    fn numeric(self: *const Mapping, book: *const Workbook, row: usize, field: usize, fallback: f64) f64 {
        const value_text = self.value(book, row, field);
        if (field == spectrum_field or field == bandwidth_field) {
            var end: usize = 0;
            while (end < value_text.len and (std.ascii.isDigit(value_text[end]) or value_text[end] == '.' or value_text[end] == '+' or value_text[end] == '-')) end += 1;
            return number(value_text[0..end]) orelse fallback;
        }
        return number(value_text) orelse fallback;
    }
};

/// Best column for a field: an exact alias match, otherwise the shortest
/// header that contains a distinctive alias (four or more characters).
fn detect(book: *const Workbook, index: usize) ?usize {
    const field = fields[index];

    // Aliases are in preference order, so `cellname` beats a `siteid`
    // column that appears earlier in the sheet.
    for (field.aliases) |alias| {
        for (0..book.column_count) |column| {
            const header = std.mem.trim(u8, book.cell(0, column), " \t\r\n");
            if (normalizedEqual(header, alias)) return column;
        }
    }

    var best: ?usize = null;
    var best_extra: usize = std.math.maxInt(usize);

    for (0..book.column_count) |column| {
        var header_buffer: [256]u8 = undefined;
        const header = normalize(&header_buffer, book.cell(0, column));

        for (field.aliases) |alias| {
            var alias_buffer: [64]u8 = undefined;
            const wanted = normalize(&alias_buffer, alias);

            if (wanted.len < 4 or std.mem.indexOf(u8, header, wanted) == null) continue;

            const extra = header.len - wanted.len;

            if (extra < best_extra) {
                best = column;
                best_extra = extra;
            }
        }
    }

    return best;
}

/// Column whose header equals `name`, exactly or ignoring case and
/// punctuation.
pub fn findHeader(book: *const Workbook, name: []const u8) ?usize {
    const wanted = std.mem.trim(u8, name, " \t\r\n");
    if (wanted.len == 0) return null;

    for (0..book.column_count) |column| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, book.cell(0, column), " \t\r\n"), wanted)) return column;
    }

    for (0..book.column_count) |column| {
        if (normalizedEqual(book.cell(0, column), wanted)) return column;
    }

    return null;
}

/// Lowercase letters and digits only.
fn normalize(buffer: []u8, value: []const u8) []const u8 {
    var length: usize = 0;

    for (value) |character| {
        if (!std.ascii.isAlphanumeric(character) or length == buffer.len) continue;

        buffer[length] = std.ascii.toLower(character);
        length += 1;
    }

    return buffer[0..length];
}

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
    const summary = generate(app.allocator, app.io, &app.book.?, &app.mapping) catch |err| {
        app.failure(err);
        return;
    };

    var path_buffer: [1024]u8 = undefined;
    var buffer: [1400]u8 = undefined;
    const output = app.mapping.outputPath(&path_buffer);

    if (summary.repaired > 0) {
        app.success(std.fmt.bufPrint(&buffer, "Exported {d} cells to {s}. {d} impossible sector values were replaced with defaults ({d} m range, {d}° beamwidth).", .{
            summary.sites,
            output,
            summary.repaired,
            default_sector_range,
            default_beamwidth,
        }) catch "KML exported.");
    } else {
        app.success(std.fmt.bufPrint(&buffer, "Exported {d} cells to {s}", .{ summary.sites, output }) catch "KML exported.");
    }
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

// ── Remembered defaults ────────────────────────────────────────────────

/// Remember the column picked for field `index` so every workbook opened
/// later starts with the same choice.
pub fn remember(app: *App, index: usize) void {
    if (index >= fields.len) return;

    const header = if (app.mapping.columns[index]) |column| app.book.?.cell(0, column) else "";

    app.saved.setKmlColumn(fields[index].key, header);
    app.mapping.remembered[index] = true;
    app.queueSave();
}

/// Forget remembered column choices and detect them again.
fn resetColumns(app: *App) void {
    const book = &app.book.?;

    app.saved.kml_column_count = 0;

    for (0..fields.len) |index| {
        app.mapping.columns[index] = detect(book, index);
        app.mapping.remembered[index] = false;
    }

    app.queueSave();
    app.notify("Column choices reset. Mappings are detected from each workbook again.");
}

fn rememberedCount(app: *const App) usize {
    return std.mem.count(bool, &app.mapping.remembered, &.{true});
}

/// Mirror description columns, switches, and the default folder into the
/// saved settings whenever they change on the page.
fn sync(app: *App) void {
    const mapping = &app.mapping;
    const saved = &app.saved;
    const book = &app.book.?;
    var changed = false;

    if (saved.kml_sectors != mapping.sectors or saved.kml_limit_range != mapping.limit_range) {
        saved.kml_sectors = mapping.sectors;
        saved.kml_limit_range = mapping.limit_range;
        changed = true;
    }

    if (mapping.default_folder and !std.mem.eql(u8, saved.kml_folder.slice(), mapping.folder.slice())) {
        saved.kml_folder = mapping.folder;
        changed = true;
    }

    var extras_differ = saved.kml_extra_count != mapping.extra_count;

    for (0..@min(mapping.extra_count, saved.kml_extra_count)) |index| {
        const header = if (mapping.columns[fields.len + index]) |column| book.cell(0, column) else "";
        const extra = &saved.kml_extras[index];

        if (!std.mem.eql(u8, extra.label.slice(), mapping.labels[index].slice())) extras_differ = true;
        if (!std.mem.eql(u8, extra.header.slice(), header)) extras_differ = true;
    }

    if (extras_differ) {
        for (0..mapping.extra_count) |index| {
            const header = if (mapping.columns[fields.len + index]) |column| book.cell(0, column) else "";
            saved.kml_extras[index] = .{ .label = mapping.labels[index], .header = .init(header) };
        }

        saved.kml_extra_count = mapping.extra_count;
        changed = true;
    }

    if (changed) app.queueSave();
}

// ── Page ───────────────────────────────────────────────────────────────

/// Label on the left, column dropdown on the right.
fn mappingRow(app: *App, rect: Rect, index: usize, body: Rect) void {
    const r = app.renderer;
    const p = app.palette();
    const field = fields[index];

    if (rect.bottom() < body.y or rect.y > body.bottom()) return;

    const dropdown_width = @min(250, rect.w * 0.52);
    const label_width = rect.w - dropdown_width - 44;

    var buffer: [128]u8 = undefined;
    const label = r.fit(&buffer, field.label, label_width - (if (field.required) @as(f32, 14) else 0), .body);
    r.leading(label, .{ .x = rect.x + 16, .y = rect.y, .w = label_width, .h = rect.h }, p.card_foreground, .body);

    if (field.required) {
        r.text("*", rect.x + 16 + r.textWidth(label, .body) + 4, rect.y + (rect.h - r.textHeight(.body)) / 2, p.destructive, .body);
    }

    const dropdown = Rect{ .x = rect.right() - 12 - dropdown_width, .y = rect.centerY() - 16, .w = dropdown_width, .h = 32 };

    if (app.mapping.remembered[index]) {
        const marker = Rect{ .x = dropdown.x - 18, .y = rect.centerY() - 6, .w = 12, .h = 12 };

        app.renderer.circle(marker.centerX(), marker.centerY(), 3, p.brand);
        app.ui.setTooltip(marker, "Your choice — used for every workbook");
    }

    app.dropdown(columnLabel(app, index), dropdown, .column, index);

    if (field.required and app.mapping.columns[index] == null) r.outline(dropdown, fade(p.destructive, 0.7), theme.radius);
}

/// Label and description on the left of a settings-style row.
fn rowLabel(app: *App, rect: Rect, label: []const u8, detail: []const u8) void {
    const r = app.renderer;
    const p = app.palette();

    if (detail.len == 0) {
        r.leading(label, .{ .x = rect.x + 20, .y = rect.y, .w = rect.w, .h = rect.h }, p.card_foreground, .strong);
        return;
    }

    const total = r.textHeight(.strong) + r.textHeight(.small);
    const top = rect.y + (rect.h - total) / 2;

    r.text(label, rect.x + 20, top, p.card_foreground, .strong);
    r.text(detail, rect.x + 20, top + r.textHeight(.strong), p.muted_foreground, .small);
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

    // Columns
    if (rememberedCount(app) > 0) {
        const label = "Reset to auto-detect";
        const reset_width = ui.smallLabelButtonWidth(label);
        const reset = Rect{ .x = x + width - reset_width, .y = y + 4, .w = reset_width, .h = 30 };

        if (ui.smallLabelButton(.rotate, label, reset, .ghost)) resetColumns(app);
        ui.setTooltip(reset, "Forget your column choices for future workbooks");
    }

    panelTitle(app, x, &y, "Columns", "Pick a column for each field. Your choices are remembered for every workbook you open.");

    const columns: usize = if (width >= 720) 2 else 1;
    const column_width = width / f(columns);
    const rows = (fields.len + columns - 1) / columns;
    const card = Rect{ .x = x, .y = y, .w = width, .h = f(rows) * row_height + 8 };
    panel(app, card);

    for (0..fields.len) |index| {
        const row = index / columns;
        const rect = Rect{
            .x = x + f(index % columns) * column_width,
            .y = card.y + 4 + f(row) * row_height,
            .w = column_width,
            .h = row_height,
        };

        if (index % columns == 0 and row > 0) {
            r.hline(x + 16, card.right() - 16, rect.y, fade(p.border, 0.6));
        }

        mappingRow(app, rect, index, body);
    }

    if (columns == 2) r.vline(x + column_width, card.y + 12, card.bottom() - 12, fade(p.border, 0.6));

    y = card.bottom() + 32;

    // Description columns
    const add_label = "Add column";
    const add_width = ui.labelButtonWidth(add_label) - 8;

    if (app.mapping.extra_count < max_extras) {
        const add_rect = Rect{ .x = x + width - add_width, .y = y, .w = add_width, .h = 32 };
        if (ui.labelButton(.plus, add_label, add_rect, .outline, false)) app.mapping.extra_count += 1;
    }

    panelTitle(app, x, &y, "Description columns", "Extra columns appended to each placemark description. Also remembered.");

    if (app.mapping.extra_count == 0) {
        const empty = Rect{ .x = x, .y = y, .w = width, .h = 56 };

        r.box(empty, fade(p.muted, 0.5), theme.radius_large);
        r.dashedRect(empty, theme.radius_large, 1.2, 5, 5, p.border);
        r.centered("No extra columns. Use “Add column” to include more data.", empty, p.muted_foreground, .small);

        y = empty.bottom() + 32;
    } else {
        const extras = Rect{ .x = x, .y = y, .w = width, .h = f(app.mapping.extra_count) * row_height + 8 };
        panel(app, extras);

        for (0..app.mapping.extra_count) |index| {
            const row = Rect{ .x = x + 12, .y = extras.y + 4 + f(index) * row_height, .w = width - 24, .h = row_height };
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

        y = extras.bottom() + 32;
    }

    // Output
    panelTitle(app, x, &y, "Output", "Where the KML file is written, and what it contains.");

    const field_row: f32 = 60;
    const switch_row: f32 = 64;
    const output = Rect{ .x = x, .y = y, .w = width, .h = field_row * 2 + switch_row * 3 };
    panel(app, output);

    const control_x = x + 170;
    const control_right = output.right() - 20;

    // Folder: type a path or browse for one.
    const folder_row = Rect{ .x = x, .y = output.y, .w = width, .h = field_row };
    rowLabel(app, folder_row, "Folder", "");

    const browse_width = ui.labelButtonWidth("Browse") - 8;
    const browse = Rect{ .x = control_right - browse_width, .y = folder_row.centerY() - 17, .w = browse_width, .h = 34 };

    _ = ui.iconField(.folder, &app.mapping.folder, "/path/to/folder", .{
        .x = control_x,
        .y = browse.y,
        .w = browse.x - 8 - control_x,
        .h = 34,
    });

    if (ui.labelButton(.folder_open, "Browse", browse, .outline, false)) app.browseFolder(app.mapping.folder.slice());
    ui.setTooltip(browse, "Choose the output folder");

    // File name
    const name_row = Rect{ .x = x, .y = folder_row.bottom(), .w = width, .h = field_row };
    r.hline(x + 16, output.right() - 16, name_row.y, fade(p.border, 0.6));
    rowLabel(app, name_row, "File name", "");

    _ = ui.iconField(.file_down, &app.mapping.filename, "sites.kml", .{
        .x = control_x,
        .y = name_row.centerY() - 17,
        .w = control_right - control_x,
        .h = 34,
    });

    // Switches
    const switches = [_]struct { label: []const u8, description: []const u8, value: *bool }{
        .{
            .label = "Use this folder by default",
            .description = "New workbooks export here instead of beside the workbook.",
            .value = &app.mapping.default_folder,
        },
        .{
            .label = "Generate sectors",
            .description = "Draw a wedge for each sector from azimuth, range, and beamwidth.",
            .value = &app.mapping.sectors,
        },
        .{
            .label = "Limit sector range by band",
            .description = "Shorten wedges for higher frequency bands.",
            .value = &app.mapping.limit_range,
        },
    };

    for (switches, 0..) |item, index| {
        const row = Rect{ .x = x, .y = name_row.bottom() + f(index) * switch_row, .w = width, .h = switch_row };

        r.hline(x + 16, output.right() - 16, row.y, fade(p.border, 0.6));
        rowLabel(app, row, item.label, item.description);

        const switch_rect = Rect{ .x = row.right() - 20 - 36, .y = row.centerY() - 10, .w = 36, .h = 20 };

        if (ui.toggle(item.value.*, switch_rect)) {
            item.value.* = !item.value.*;

            // Turning the default folder off forgets it.
            if (index == 0 and !app.mapping.default_folder) {
                app.saved.kml_folder.set("");
                app.queueSave();
            }
        }
    }

    // Destination preview
    y = output.bottom() + 12;

    var path_buffer: [1024]u8 = undefined;
    var preview_buffer: [1100]u8 = undefined;
    const target_path = app.mapping.outputPath(&path_buffer);
    const preview = std.fmt.bufPrint(&preview_buffer, "Saves to {s}. An existing file there is replaced.", .{target_path}) catch "";

    var fit_buffer: [1100]u8 = undefined;
    r.icon(.info, .{ .x = x, .y = y + 2, .w = 14, .h = 14 }, p.muted_foreground);
    r.text(r.fit(&fit_buffer, preview, width - 22, .small), x + 22, y, p.muted_foreground, .small);
    y += 48;

    app.scroll_max = @max(0, y + app.scroll - body.bottom());
    r.restoreClip(previous);
    ui.scrollbar(body, app.scroll, app.scroll_max);

    sync(app);
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

/// Longest believable sector reach (LTE timing advance tops out near 100 km).
const max_sector_range: f64 = 100_000;
const default_sector_range: f64 = 500;
const default_beamwidth: f64 = 65;

pub const Summary = struct {
    sites: usize,
    /// Sector ranges or beamwidths replaced by defaults because the
    /// spreadsheet value was missing or impossible.
    repaired: usize,
};

pub fn generate(allocator: std.mem.Allocator, io: std.Io, book: *const Workbook, mapping: *const Mapping) !Summary {
    var repaired: usize = 0;

    for (fields, 0..) |field, index| {
        if (field.required and mapping.columns[index] == null) return error.MapAllRequiredColumns;
    }
    var path_buffer: [1024]u8 = undefined;
    const output = mapping.outputPath(&path_buffer);
    if (std.mem.trim(u8, mapping.filename.slice(), " \t").len == 0) return error.ChooseAnOutputFileName;
    if (std.mem.eql(u8, output, book.path)) return error.OutputWouldReplaceSourceWorkbook;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var sites: std.ArrayList(Site) = .empty;
    var indices: std.StringHashMapUnmanaged(usize) = .empty;

    for (1..book.row_count) |row| {
        var values: [fields.len + 16][]const u8 = @splat("");
        for (0..fields.len + mapping.extra_count) |field| values[field] = mapping.value(book, row, field);
        if (values[cell_name].len == 0 and values[unique_id].len == 0) continue;
        if (values[cell_name].len == 0) values[cell_name] = values[unique_id];
        const latitude = mapping.numeric(book, row, latitude_field, std.math.nan(f64));
        const longitude = mapping.numeric(book, row, longitude_field, std.math.nan(f64));
        if (!std.math.isFinite(latitude) or !std.math.isFinite(longitude) or @abs(latitude) > 90 or @abs(longitude) > 180) return error.InvalidSiteCoordinates;
        const speed = mapping.numeric(book, row, speed_field, 0) / 1000;
        const volume = mapping.numeric(book, row, volume_field, 0);
        const bandwidth = mapping.numeric(book, row, bandwidth_field, 0);
        const traffic = if (bandwidth > 0) volume / bandwidth else 0;
        const entry = try indices.getOrPut(memory, values[cell_name]);
        if (entry.found_existing) {
            const site = &sites.items[entry.value_ptr.*];
            for (joined_fields) |field| {
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
                .values = values,
                .latitude = latitude,
                .longitude = longitude,
                .speed = speed,
                .speed_sum = speed,
                .volume = volume,
                .traffic = traffic,
                .spectrum = mapping.numeric(book, row, spectrum_field, 700),
                .azimuth = mapping.numeric(book, row, azimuth_field, 32.5),
                .range = mapping.numeric(book, row, range_field, default_sector_range),
                .beamwidth = mapping.numeric(book, row, beamwidth_field, default_beamwidth),
            });
        }
    }
    if (sites.items.len == 0) return error.NoSiteRows;
    std.mem.sort(Site, sites.items, {}, struct {
        fn less(_: void, a: Site, b: Site) bool {
            return std.mem.lessThan(u8, a.values[cell_name], b.values[cell_name]);
        }
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
        try out.escaped(site.values[cell_name]);
        try out.print("</name><styleUrl>#{s}</styleUrl><description>", .{if (site.speed < 3) "lowplacemarkStyle" else "placemarkStyle"});
        try description(&out, &site, mapping);
        try out.print("</description><Point><coordinates>{d},{d},0</coordinates></Point></Placemark>\n", .{ site.longitude, site.latitude });
        if (!mapping.sectors) continue;
        var band: f64 = 0;
        for (bands[0..6]) |candidate| {
            if (site.spectrum == candidate) band = candidate;
        }
        if (site.speed < 3) band = -1;
        // Spreadsheet errors (e.g. a range of 2e17 m) would draw a wedge
        // around the planet. Fall back to the defaults for that cell instead
        // of failing the whole export, and report how many were repaired.
        var radius = if (mapping.limit_range) limitedRange(site.spectrum) else site.range;
        var beamwidth = site.beamwidth;

        if (!std.math.isFinite(radius) or radius <= 0 or radius > max_sector_range) {
            radius = default_sector_range;
            repaired += 1;
        }

        if (!std.math.isFinite(beamwidth) or beamwidth <= 0 or beamwidth > 360) {
            beamwidth = default_beamwidth;
            repaired += 1;
        }
        try out.append("<Placemark><name>sec-");
        try out.escaped(site.values[cell_name]);
        try out.print("</name><styleUrl>#sector{d}</styleUrl><description>", .{band});
        try description(&out, &site, mapping);
        try out.append("</description><Polygon><extrude>1</extrude><altitudeMode>relativeToGround</altitudeMode><outerBoundaryIs><LinearRing><coordinates>");
        try out.print("{d},{d},0\n", .{ site.longitude, site.latitude });
        for (0..33) |step| {
            const bearing = site.azimuth - beamwidth / 2 + beamwidth * @as(f64, @floatFromInt(step)) / 32;
            const point = destination(site.latitude, site.longitude, radius, bearing);
            try out.print("{d},{d},0\n", .{ point.longitude, point.latitude });
        }
        try out.print("{d},{d},0\n</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n", .{ site.longitude, site.latitude });
    }
    try out.append("</Document></kml>\n");
    try out.save(io, output);
    return .{ .sites = sites.items.len, .repaired = repaired };
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

test "reference KML fixture maps like the original tool, one wedge per cell" {
    const path = std.c.getenv("ZIGZZZ_KML_FIXTURE") orelse return error.SkipZigTest;
    var book = try Workbook.load(std.testing.allocator, std.testing.io, std.mem.span(path));
    defer book.deinit();
    var mapping = Mapping.init(&book);

    // Detected headers match WFAppKml's Form1.cs for KE-lt-99-perc-RNA.xlsx.
    const expected = [_][2][]const u8{
        .{ "SiteID", "cellname" },
        .{ "CellID", "cellid" },
        .{ "CI", "UNIQUE_ID" },
        .{ "WCell", "period_start_time" },
        .{ "SITE_NAME", "Physical_Site_Id" },
        .{ "LAT", "LATITUDE" },
        .{ "LONG", "LONGITUDE" },
        .{ "Spectrum", "Spectrum" },
        .{ "Bandwidth", "Bandwidth" },
        .{ "Sector_AZ", "Sec-Azmuth" },
        .{ "Sector_Range", "Sec-Range" },
        .{ "Sector_HBW", "BW" },
        .{ "Sector_ABH", "ABH" },
        .{ "Sector_MTilt", "M Tilt" },
        .{ "Sector_ETilt", "E Tilt" },
        .{ "Sector_dlRsBoost", "dlRsBoost" },
        .{ "Sector_PMax", "PMax(W)" },
        .{ "Speed", "DL_User_throughput" },
        .{ "Volume", "Total_Data_Volume" },
        .{ "Availability", "rna_4g" },
        .{ "Drop", "PS_Drop_Call_Rate" },
        .{ "xTxR", "MIMO_CONFIG" },
        .{ "Configuration", "MIMO_CONFIG" },
        .{ "FOE", "FOE" },
        .{ "TAC", "County" },
        .{ "Clutter", "Town" },
        .{ "ENodeBId", "siteid" },
        .{ "Site_Prefence", "Site_Prefence" },
        .{ "REGION", "ZONE" },
        .{ "Carrier_Count", "Carriers" },
        .{ "Macro_IBS", "Macro_IBS" },
        .{ "ONAIR_DATE", "IOE_STATUS" },
        .{ "SITE_STATUS", "SITE_STATUS" },
        .{ "VENDOR", "VENDOR" },
    };

    for (expected) |pair| {
        const index = for (fields, 0..) |field, at| {
            if (std.mem.eql(u8, field.key, pair[0])) break at;
        } else unreachable;

        const column = mapping.columns[index] orelse return error.FieldNotDetected;
        try std.testing.expectEqualStrings(pair[1], book.cell(0, column));
    }

    // The traffic-distribution columns are not in this export.
    try std.testing.expect(mapping.columns[fieldIndex("Sector_R1")] == null);

    mapping.folder.set("/tmp/");
    mapping.filename.set("zigzzz-test-output");

    var path_buffer: [1024]u8 = undefined;
    const output = mapping.outputPath(&path_buffer);
    try std.testing.expectEqualStrings("/tmp/zigzzz-test-output.kml", output);

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    const summary = try generate(std.testing.allocator, std.testing.io, &book, &mapping);

    // Every row is a distinct cell: a point and a sector wedge each.
    try std.testing.expectEqual(@as(usize, 868), summary.sites);

    // KEEKOROK_LODGE_L8_C has a sector range of 2.1e17 m in the export.
    try std.testing.expectEqual(@as(usize, 1), summary.repaired);

    const xml = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(xml);

    try std.testing.expectEqual(@as(usize, 1736), std.mem.count(u8, xml, "<Placemark>"));
    try std.testing.expectEqual(@as(usize, 868), std.mem.count(u8, xml, "<Polygon>"));
    try std.testing.expect(std.mem.indexOf(u8, xml, "<name>ABOKE_UWAI_1</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "SITE_NAME:  SYA0057") != null);
    try std.testing.expect(std.mem.endsWith(u8, xml, "</Document></kml>\n"));
}
