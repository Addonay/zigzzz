const std = @import("std");
const Workbook = @import("workbook.zig").Workbook;
const Preferences = @import("preferences.zig").Preferences;

pub const Point = struct { day: i32, value: f64 };
pub const Series = struct { name: []const u8, points: []Point };
pub const Area = struct { name: []const u8, series: []Series };
pub const Status = enum { passing, failing, no_threshold };

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    areas: []Area,
    names: []const []const u8,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn parse(allocator: std.mem.Allocator, book: *const Workbook) !Report {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        var first_date: usize = 2;
        while (first_date < book.column_count and parseDate(book.cell(0, first_date)) == null) first_date += 1;
        if (first_date == book.column_count) return error.NoDatesInFirstRow;

        var areas: std.ArrayList(Area) = .empty;
        var series: std.ArrayList(Series) = .empty;
        var name = try memory.dupe(u8, book.name);
        var expecting_area = false;

        for (1..@min(403, book.row_count)) |row| {
            var empty = true;
            for (0..book.column_count) |column| {
                if (book.cell(row, column).len > 0) {
                    empty = false;
                    break;
                }
            }

            if (empty) {
                if (series.items.len > 0) {
                    try areas.append(memory, .{ .name = name, .series = try series.toOwnedSlice(memory) });
                    series = .empty;
                }
                expecting_area = true;
                continue;
            }

            if (expecting_area) {
                for (0..book.column_count) |column| {
                    const candidate = std.mem.trim(u8, book.cell(row, column), " \t\r\n");
                    if (candidate.len > 0 and number(candidate) == null) {
                        name = try memory.dupe(u8, candidate);
                        break;
                    }
                }
                expecting_area = false;
            }

            // Reports pad some names ("2G Utilization "); trim them so
            // thresholds and groups match.
            const kpi = std.mem.trim(u8, book.cell(row, 1), " \t\r\n");
            if (kpi.len == 0) continue;
            var samples: std.ArrayList(Point) = .empty;

            for (first_date..book.column_count) |column| {
                const day = parseDate(book.cell(0, column)) orelse continue;
                const value = number(book.cell(row, column)) orelse continue;
                try samples.append(memory, .{ .day = day, .value = value });
            }

            if (samples.items.len == 0) continue;
            for (series.items) |item| if (std.mem.eql(u8, item.name, kpi)) return error.DuplicateKpiInArea;
            std.mem.sort(Point, samples.items, {}, struct {
                fn less(_: void, a: Point, b: Point) bool {
                    return a.day < b.day;
                }
            }.less);
            try series.append(memory, .{ .name = try memory.dupe(u8, kpi), .points = try samples.toOwnedSlice(memory) });
        }

        if (series.items.len > 0) try areas.append(memory, .{ .name = name, .series = try series.toOwnedSlice(memory) });
        if (areas.items.len == 0) return error.NoNumericKpiValues;
        for (areas.items, 0..) |area, index| {
            for (areas.items[0..index]) |previous| if (std.mem.eql(u8, previous.name, area.name)) return error.DuplicateAreaName;
        }

        // Every KPI from every area, in first-seen order. Areas need not
        // share one list: later blocks often add rows such as "2G Sites".
        var names: std.ArrayList([]const u8) = .empty;

        for (areas.items) |area| {
            next: for (area.series) |item| {
                for (names.items) |existing| {
                    if (std.mem.eql(u8, existing, item.name)) continue :next;
                }

                try names.append(memory, item.name);
            }
        }

        return .{
            .arena = arena,
            .source = try memory.dupe(u8, std.fs.path.basename(book.path)),
            .areas = try areas.toOwnedSlice(memory),
            .names = try names.toOwnedSlice(memory),
        };
    }

    pub fn find(self: *const Report, area: usize, name: []const u8) ?*const Series {
        if (area >= self.areas.len) return null;
        for (self.areas[area].series) |*series| if (std.mem.eql(u8, series.name, name)) return series;
        return null;
    }

    /// Whether `area` reports `name` at all.
    pub fn has(self: *const Report, area: usize, name: []const u8) bool {
        return self.find(area, name) != null;
    }

    pub fn status(self: *const Report, area: usize, name: []const u8, preferences: *const Preferences) Status {
        const series = self.find(area, name) orelse return .no_threshold;
        if (series.points.len == 0) return .no_threshold;
        const passing = preferences.meets(name, series.points[series.points.len - 1].value) orelse return .no_threshold;
        return if (passing) .passing else .failing;
    }

    pub fn points(self: *const Report, area: usize, name: []const u8, days: u32) []const Point {
        const series = self.find(area, name) orelse return &.{};
        if (series.points.len == 0) return &.{};
        const cutoff = series.points[series.points.len - 1].day - @as(i32, @intCast(days)) + 1;
        for (series.points, 0..) |point, index| if (point.day >= cutoff) return series.points[index..];
        return &.{};
    }
};

pub fn number(value: []const u8) ?f64 {
    if (value.len == 0) return null;
    var buffer: [128]u8 = undefined;
    var length: usize = 0;
    for (value) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == ',' or ch == '%') continue;
        if (length == buffer.len) return null;
        buffer[length] = ch;
        length += 1;
    }
    const result = std.fmt.parseFloat(f64, buffer[0..length]) catch return null;
    return if (std.math.isFinite(result)) result else null;
}

pub fn parseDate(value: []const u8) ?i32 {
    if (value.len >= 8 and (std.mem.indexOfScalar(u8, value, '-') != null or std.mem.indexOfScalar(u8, value, '/') != null)) {
        var parts = std.mem.tokenizeAny(u8, value, "-/ T");
        const first = parts.next() orelse return null;
        const second = parts.next() orelse return null;
        const third = parts.next() orelse return null;
        const a = std.fmt.parseInt(i32, first, 10) catch return null;
        const b = std.fmt.parseInt(i32, second, 10) catch return null;
        const c = std.fmt.parseInt(i32, third, 10) catch return null;
        const year = if (first.len == 4) a else c;
        const month = b;
        const day = if (first.len == 4) c else a;
        if (year < 1900 or year > 9999 or month < 1 or month > 12 or day < 1) return null;
        const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
        const limit = month_days[@intCast(month - 1)] + @as(i32, if (month == 2 and leap) 1 else 0);
        if (day > limit) return null;
        return civilToDays(year, month, day);
    }
    const serial = number(value) orelse return null;
    if (serial < 1 or serial >= 2958466) return null;
    return @as(i32, @intFromFloat(@floor(serial))) - 25569;
}

pub fn civilToDays(year_value: i32, month: i32, day: i32) i32 {
    const year = year_value - @as(i32, if (month <= 2) 1 else 0);
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const adjusted_month = month + @as(i32, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn dateParts(day: i32) struct { year: i32, month: i32, day: i32 } {
    const z = day + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + @as(i32, if (mp < 10) 3 else -9);
    year += @as(i32, if (month <= 2) 1 else 0);
    return .{ .year = year, .month = month, .day = d };
}

test "Excel and string dates agree across leap boundaries" {
    try std.testing.expectEqual(parseDate("2024-02-29"), parseDate("29-02-2024"));
    try std.testing.expectEqual(parseDate("2024-02-29"), parseDate("45351"));
    try std.testing.expectEqual(@as(?i32, null), parseDate("not a date"));
    const day = parseDate("2024-02-29").?;
    const parts = dateParts(day + 1);
    try std.testing.expectEqual(@as(i32, 2024), parts.year);
    try std.testing.expectEqual(@as(i32, 3), parts.month);
    try std.testing.expectEqual(@as(i32, 1), parts.day);
}

test "reference QoS fixture preserves all areas and samples" {
    const path = std.c.getenv("ZIGZZZ_QOS_FIXTURE") orelse return error.SkipZigTest;
    var book = try Workbook.load(std.testing.allocator, std.testing.io, std.mem.span(path));
    defer book.deinit();
    var data = try Report.parse(std.testing.allocator, &book);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 6), data.areas.len);
    try std.testing.expectEqual(@as(usize, 22), data.names.len);
    var points: usize = 0;
    for (data.areas) |area| {
        try std.testing.expectEqual(@as(usize, 22), area.series.len);
        for (area.series) |series| points += series.points.len;
    }
    try std.testing.expectEqual(@as(usize, 23760), points);
    try std.testing.expectEqualStrings("Kenya", data.areas[0].name);
}

test "real report lists every area's KPIs with trimmed names" {
    const path = std.c.getenv("ZIGZZZ_QOS_REAL_FIXTURE") orelse return error.SkipZigTest;
    var book = try Workbook.load(std.testing.allocator, std.testing.io, std.mem.span(path));
    defer book.deinit();
    var data = try Report.parse(std.testing.allocator, &book);
    defer data.deinit();

    // Every KPI of every area is in the shared list, so no area loses
    // KPIs that the first area doesn't report.
    for (data.areas, 0..) |area, index| {
        for (area.series) |series| {
            var listed = false;
            for (data.names) |name| listed = listed or std.mem.eql(u8, name, series.name);

            try std.testing.expect(listed);
            try std.testing.expect(data.has(index, series.name));
        }
    }

    for (data.names) |name| {
        try std.testing.expectEqualStrings(std.mem.trim(u8, name, " \t\r\n"), name);
    }

    var has_sites = false;
    for (data.names) |name| has_sites = has_sites or std.mem.eql(u8, name, "2G Sites");
    try std.testing.expect(has_sites);
}
