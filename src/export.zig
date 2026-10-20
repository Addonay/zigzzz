const std = @import("std");
const App = @import("app.zig").App;
const Document = @import("document.zig").Document;
const Point = @import("report.zig").Point;

const package_namespace = "http://schemas.openxmlformats.org/package/2006/relationships";
const office_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";
const Entry = struct { name: []const u8, size: usize, crc: u32, offset: u32 };

/// Uncompressed ZIP entries keep the package writer small. PNG media is
/// already compressed; spreadsheet cells and chart objects remain editable.
const Archive = struct {
    data: Document,
    entries: std.ArrayList(Entry) = .empty,

    fn integer(self: *Archive, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.data.append(&buffer);
    }

    fn add(self: *Archive, name: []const u8, bytes: []const u8) !void {
        const crc = std.hash.Crc32.hash(bytes);
        const offset: u32 = @intCast(self.data.bytes.items.len);
        try self.integer(u32, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |value| try self.integer(u16, value);
        try self.integer(u32, crc);
        try self.integer(u32, @intCast(bytes.len));
        try self.integer(u32, @intCast(bytes.len));
        try self.integer(u16, @intCast(name.len));
        try self.integer(u16, 0);
        try self.data.append(name);
        try self.data.append(bytes);
        try self.entries.append(self.data.allocator, .{
            .name = name, .size = bytes.len, .crc = crc, .offset = offset,
        });
    }

    fn finish(self: *Archive) !void {
        const start: u32 = @intCast(self.data.bytes.items.len);
        for (self.entries.items) |entry| {
            try self.integer(u32, 0x02014b50);
            for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |value| try self.integer(u16, value);
            try self.integer(u32, entry.crc);
            try self.integer(u32, @intCast(entry.size));
            try self.integer(u32, @intCast(entry.size));
            try self.integer(u16, @intCast(entry.name.len));
            for (0..4) |_| try self.integer(u16, 0);
            try self.integer(u32, 0);
            try self.integer(u32, entry.offset);
            try self.data.append(entry.name);
        }
        const size: u32 = @intCast(self.data.bytes.items.len - start);
        try self.integer(u32, 0x06054b50);
        try self.integer(u16, 0);
        try self.integer(u16, 0);
        try self.integer(u16, @intCast(self.entries.items.len));
        try self.integer(u16, @intCast(self.entries.items.len));
        try self.integer(u32, size);
        try self.integer(u32, start);
        try self.integer(u16, 0);
    }
};

pub fn write(app: *App, images: bool) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const report = &app.report.?;
    const previous_area = app.area;
    defer app.area = previous_area;

    var archive = Archive{ .data = .{ .allocator = memory } };
    var types = Document{ .allocator = memory };
    var sheet = Document{ .allocator = memory };
    var drawing = Document{ .allocator = memory };
    var relationships = Document{ .allocator = memory };

    try types.append(
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        \\  <Default Extension="xml" ContentType="application/xml"/>
        \\  <Default Extension="png" ContentType="image/png"/>
        \\  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        \\  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        \\  <Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
    );
    try archive.add("_rels/.rels", try singleRelationship(memory, "officeDocument", "xl/workbook.xml"));
    try archive.add("xl/workbook.xml",
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\ xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\  <sheets><sheet name="KPIs" sheetId="1" r:id="rId1"/></sheets>
        \\</workbook>
    );
    try archive.add("xl/_rels/workbook.xml.rels", try singleRelationship(memory, "worksheet", "worksheets/sheet1.xml"));
    try archive.add("xl/worksheets/_rels/sheet1.xml.rels", try singleRelationship(memory, "drawing", "../drawings/drawing1.xml"));

    try sheet.append(
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\ xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>
    );
    try drawing.append(
        \\<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
        \\ xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
    );
    try relationships.print("<Relationships xmlns=\"{s}\">", .{package_namespace});

    var row: usize = 1;
    var chart_count: usize = 0;
    for (report.areas, 0..) |area, area_index| {
        if (app.busy) try app.exportProgress(area_index, report.areas.len);
        app.area = area_index;
        for (report.names, 0..) |name, index| {
            const status = report.status(area_index, name, &app.saved);
            if (images and status != .failing) continue;
            if (app.status_filter > 0 and 1 + @intFromEnum(status) != app.status_filter) continue;
            if (app.group_filter > 0) {
                const rule = app.saved.find(name) orelse continue;
                if (!app.saved.groups[app.group_filter - 1].members[rule]) continue;
            }
            const days = app.saved.days(area.name, name);
            const points = report.points(area_index, name, days);
            if (points.len == 0) continue;
            chart_count += 1;
            const title = try memory.print("{s} · {s}", .{ area.name, name });

            if (images) {
                const image = try @import("chart_image.zig").render(app, index, .image, app.allocator);
                defer app.allocator.free(image);
                try archive.add(try memory.print("xl/media/image{d}.png", .{chart_count}), image);
                try relationship(&relationships, chart_count, "image", "media/image", ".png");
            } else {
                var chart = Document{ .allocator = memory };
                try chart.append(chart_open);
                try chart.escaped(title);
                try chart.append(chart_plot);
                try series(&chart, &sheet, &row, name, points, 0, false);
                var series_count: usize = 1;
                if (app.saved.find(name)) |rule_index| {
                    for (app.saved.overlays[0..app.saved.overlay_count]) |*overlay| {
                        if (overlay.primary != rule_index) continue;
                        for (overlay.members[0..app.saved.rule_count], 0..) |selected, member| {
                            if (!selected) continue;
                            const other_name = app.saved.rules[member].name.slice();
                            const other = report.points(area_index, other_name, days);
                            if (other.len == 0) continue;
                            try series(&chart, &sheet, &row, other_name, other, series_count, false);
                            series_count += 1;
                        }
                    }
                    const rule = &app.saved.rules[rule_index];
                    if (rule.enabled) {
                        const value = try std.fmt.parseFloat(f64, rule.value.slice());
                        const threshold = [_]Point{
                            .{ .day = points[0].day, .value = value },
                            .{ .day = points[points.len - 1].day, .value = value },
                        };
                        try series(&chart, &sheet, &row, "Threshold", &threshold, series_count, true);
                    }
                }
                try chart.append(chart_close);
                try archive.add(try memory.print("xl/charts/chart{d}.xml", .{chart_count}), chart.bytes.items);
                try types.print(
                    "<Override PartName=\"/xl/charts/chart{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>",
                    .{chart_count},
                );
                try relationship(&relationships, chart_count, "chart", "charts/chart", ".xml");
            }
            try anchor(&drawing, chart_count, images);
        }
    }
    if (chart_count == 0) return error.NoChartsToExport;
    try sheet.append("</sheetData><drawing r:id=\"rId1\"/></worksheet>");
    try drawing.append("</xdr:wsDr>");
    try relationships.append("</Relationships>");
    try types.append("</Types>");
    try archive.add("[Content_Types].xml", types.bytes.items);
    try archive.add("xl/worksheets/sheet1.xml", sheet.bytes.items);
    try archive.add("xl/drawings/drawing1.xml", drawing.bytes.items);
    try archive.add("xl/drawings/_rels/drawing1.xml.rels", relationships.bytes.items);
    try archive.finish();

    const directory = std.fs.path.dirname(app.qos_path.slice()) orelse ".";
    const filename = if (images) "kpi-chart-images.xlsx" else "kpi-charts.xlsx";
    const output = try memory.print("{s}/{s}", .{ directory, filename });
    try archive.data.save(app.io, output);

    const message = try memory.print("Saved {d} {s} to {s}", .{
        chart_count,
        if (images) "failing chart images" else "editable charts",
        output,
    });

    app.success(message);
}

fn singleRelationship(memory: std.mem.Allocator, kind: []const u8, target: []const u8) ![]const u8 {
    return memory.print(
        "<Relationships xmlns=\"{s}\"><Relationship Id=\"rId1\" Type=\"{s}{s}\" Target=\"{s}\"/></Relationships>",
        .{ package_namespace, office_namespace, kind, target },
    );
}

fn relationship(out: *Document, id: usize, kind: []const u8, target: []const u8, extension: []const u8) !void {
    try out.print(
        "<Relationship Id=\"rId{d}\" Type=\"{s}{s}\" Target=\"../{s}{d}{s}\"/>",
        .{ id, office_namespace, kind, target, id, extension },
    );
}

fn series(chart: *Document, sheet: *Document, row: *usize, name: []const u8, points: []const Point, index: usize, dashed: bool) !void {
    try sheet.print("<row r=\"{d}\"><c r=\"A{d}\" t=\"inlineStr\"><is><t>", .{ row.*, row.* });
    try sheet.escaped(name);
    try sheet.append("</t></is></c></row>");
    row.* += 1;
    const first = row.*;
    for (points) |point| {
        const day = @import("report.zig").dateParts(point.day);
        try sheet.print(
            "<row r=\"{d}\"><c r=\"A{d}\" t=\"inlineStr\"><is><t>{d}-{d:0>2}-{d:0>2}</t></is></c>",
            .{ row.*, row.*, @as(u32, @intCast(day.year)), @as(u32, @intCast(day.month)), @as(u32, @intCast(day.day)) },
        );
        try sheet.print("<c r=\"B{d}\"><v>{d}</v></c></row>", .{ row.*, point.value });
        row.* += 1;
    }
    try chart.print("<c:ser><c:idx val=\"{d}\"/><c:order val=\"{d}\"/><c:tx><c:v>", .{ index, index });
    try chart.escaped(name);
    try chart.append("</c:v></c:tx>");
    if (dashed) try chart.append("<c:spPr><a:ln><a:solidFill><a:srgbClr val=\"5798D0\"/></a:solidFill><a:prstDash val=\"dash\"/></a:ln></c:spPr>");
    try chart.print(
        "<c:cat><c:strRef><c:f>KPIs!$A${d}:$A${d}</c:f></c:strRef></c:cat>",
        .{ first, row.* - 1 },
    );
    try chart.print(
        "<c:val><c:numRef><c:f>KPIs!$B${d}:$B${d}</c:f></c:numRef></c:val><c:smooth val=\"1\"/></c:ser>",
        .{ first, row.* - 1 },
    );
    row.* += 2;
}

fn anchor(out: *Document, index: usize, image: bool) !void {
    const row = (index - 1) * 20;
    try out.print(
        \\<xdr:twoCellAnchor>
        \\  <xdr:from><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>{d}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
        \\  <xdr:to><xdr:col>15</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>{d}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
    , .{ row, row + 19 });
    if (image) {
        try out.print(
            \\<xdr:pic><xdr:nvPicPr>
            \\  <xdr:cNvPr id="{d}" name="Chart {d}"/><xdr:cNvPicPr/>
            \\</xdr:nvPicPr><xdr:blipFill>
            \\  <a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="rId{d}"/>
            \\  <a:stretch><a:fillRect/></a:stretch>
            \\</xdr:blipFill><xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>
        , .{ index, index, index });
    } else {
        try out.print(
            \\<xdr:graphicFrame macro=""><xdr:nvGraphicFramePr>
            \\  <xdr:cNvPr id="{d}" name="Chart {d}"/><xdr:cNvGraphicFramePr/>
            \\</xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>
            \\<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
            \\  <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"
            \\    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId{d}"/>
            \\</a:graphicData></a:graphic></xdr:graphicFrame>
        , .{ index, index, index });
    }
    try out.append("<xdr:clientData/></xdr:twoCellAnchor>");
}

const chart_open =
    \\<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"
    \\ xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
    \\<c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>
;

const chart_plot =
    \\</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:layout/>
    \\<c:lineChart><c:grouping val="standard"/>
;

const chart_close =
    \\<c:axId val="1"/><c:axId val="2"/></c:lineChart>
    \\<c:catAx><c:axId val="1"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:axPos val="b"/><c:crossAx val="2"/></c:catAx>
    \\<c:valAx><c:axId val="2"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:axPos val="l"/><c:crossAx val="1"/></c:valAx>
    \\</c:plotArea><c:plotVisOnly val="1"/></c:chart></c:chartSpace>
;
