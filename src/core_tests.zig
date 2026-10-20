const std = @import("std");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const report = @import("report.zig");
const prefs = @import("preferences.zig");
const workbook = @import("workbook.zig");
const kml = @import("kml.zig");
const Text = @import("text.zig").Text;

test "UTF-8 editing preserves boundaries and capacity" {
    var text = Text.init("café");
    try equal(@as(usize, 3), text.previous(text.length));
    text.remove(3, text.length);
    try equal(@as(usize, 2), text.insert(3, "é"));
    try std.testing.expectEqualStrings("café", text.slice());
    var long: [513]u8 = @splat('x');
    long[511] = 0xc3;
    long[512] = 0xa9;
    text.set(&long);
    try equal(@as(usize, 511), text.length);
    try expect(std.unicode.utf8ValidateSlice(text.slice()));
}

test "threshold operators, disabled rules, and date precedence" {
    const p = try std.testing.allocator.create(prefs.Preferences);
    defer std.testing.allocator.destroy(p);
    try p.defaults(std.testing.allocator);
    try equal(@as(usize, 47), p.rule_count);
    const index = try p.include("Example");
    p.rules[index].value.set("10");
    try equal(@as(?bool, null), p.meets("Example", 20));
    p.rules[index].enabled = true;
    for ([_]bool{ true, true, false, false, true, false }, 0..) |expected, op| {
        p.rules[index].operator = op;
        try equal(@as(?bool, expected), p.meets("Example", 10));
    }
    p.global_days.set("30");
    p.area_days[0] = .{ .name = .init("Nairobi"), .days = .init("60") };
    p.area_count = 1;
    p.kpi_days[0] = .{ .name = .init("Example"), .days = .init("90") };
    p.kpi_count = 1;
    try equal(@as(u32, 90), p.days("Nairobi", "Example"));
    try equal(@as(u32, 60), p.days("Nairobi", "Other"));
    try equal(@as(u32, 30), p.days("Other", "Other"));
    p.font_size.set("25");
    try std.testing.expectError(error.TextSizeMustBe12To24, p.validate());
}

test "Excel and string dates agree across leap boundaries" {
    try equal(report.parseDate("2024-02-29"), report.parseDate("29-02-2024"));
    try equal(report.parseDate("2024-02-29"), report.parseDate("45351"));
    try equal(@as(?i32, null), report.parseDate("not a date"));
    const day = report.parseDate("2024-02-29").?;
    const parts = report.dateParts(day + 1);
    try equal(@as(i32, 2024), parts.year);
    try equal(@as(i32, 3), parts.month);
    try equal(@as(i32, 1), parts.day);
}

test "settings survive an atomic round trip" {
    const allocator = std.testing.allocator;
    const p = try allocator.create(prefs.Preferences);
    defer allocator.destroy(p);
    try p.defaults(allocator);
    p.dark = false;
    p.groups[0] = .{ .name = .init("Radio") };
    p.groups[0].members[0] = true;
    p.group_count = 1;
    p.overlays[0] = .{ .primary = 0 };
    p.overlays[0].members[1] = true;
    p.overlay_count = 1;
    const path = "/tmp/zigzzz-test-settings.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try p.save(allocator, std.testing.io, path);
    const loaded = try allocator.create(prefs.Preferences);
    defer allocator.destroy(loaded);
    try loaded.load(allocator, std.testing.io, path);
    try equal(false, loaded.dark);
    try equal(p.rule_count, loaded.rule_count);
    try equal(@as(usize, 1), loaded.group_count);
    try expect(loaded.groups[0].members[0]);
    try expect(loaded.overlays[0].members[1]);
}

test "reference QoS fixture preserves all areas and samples" {
    const path = std.c.getenv("ZIGZZZ_QOS_FIXTURE") orelse return error.SkipZigTest;
    var book = try workbook.Workbook.load(std.testing.allocator, std.testing.io, std.mem.span(path));
    defer book.deinit();
    var data = try report.Report.parse(std.testing.allocator, &book);
    defer data.deinit();
    try equal(@as(usize, 6), data.areas.len);
    try equal(@as(usize, 22), data.names.len);
    var points: usize = 0;
    for (data.areas) |area| {
        try equal(@as(usize, 22), area.series.len);
        for (area.series) |series| points += series.points.len;
    }
    try equal(@as(usize, 23760), points);
    try std.testing.expectEqualStrings("Kenya", data.areas[0].name);
}

test "reference KML fixture aggregates 868 rows into 129 sites" {
    const path = std.c.getenv("ZIGZZZ_KML_FIXTURE") orelse return error.SkipZigTest;
    var book = try workbook.Workbook.load(std.testing.allocator, std.testing.io, std.mem.span(path));
    defer book.deinit();
    var mapping = kml.Mapping.init(&book);
    mapping.output.set("/tmp/zigzzz-test-output.kml");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mapping.output.slice()) catch {};
    const count = try kml.generate(std.testing.allocator, std.testing.io, &book, &mapping);
    try equal(@as(usize, 129), count);
    const xml = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, mapping.output.slice(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(xml);
    try equal(@as(usize, 258), std.mem.count(u8, xml, "<Placemark>"));
    try equal(@as(usize, 129), std.mem.count(u8, xml, "<Polygon>"));
    try expect(std.mem.endsWith(u8, xml, "</Document></kml>\n"));
}

test "PNG encoder writes a valid zlib stream and dimensions" {
    const allocator = std.testing.allocator;
    const encoded = try @import("png.zig").encode(allocator, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, 2, 1, 8);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", encoded[0..8]);
    try equal(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    const size = std.mem.readInt(u32, encoded[33..37], .big);
    var input = std.Io.Reader.fixed(encoded[41..][0..size]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&input, .zlib, &window);
    const pixels = try decoder.reader.allocRemaining(allocator, .limited(9));
    defer allocator.free(pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 255, 0, 255 }, pixels);
}
