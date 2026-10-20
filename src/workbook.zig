//! XLSX is a ZIP of XML documents. Only the first sheet is needed by the two
//! reference workflows. ZIP inflation is Zig; Expat handles XML/entity decoding.
const std = @import("std");
const xml = @import("native");

pub const Cell = struct {
    row: u32,
    column: u16,
    value: []const u8,
};

pub const Workbook = struct {
    arena: std.heap.ArenaAllocator,
    cells: []const Cell,
    row_count: usize,
    column_count: usize,
    name: []const u8,
    path: []const u8,

    pub fn deinit(self: *Workbook) void {
        self.arena.deinit();
    }

    pub fn cell(self: *const Workbook, row: usize, column: usize) []const u8 {
        var low: usize = 0;
        var high = self.cells.len;
        const key = row * 65536 + column;

        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = self.cells[middle];
            const candidate_key = @as(usize, candidate.row) * 65536 + candidate.column;
            if (candidate_key < key) low = middle + 1 else high = middle;
        }

        if (low < self.cells.len) {
            const candidate = self.cells[low];
            if (candidate.row == row and candidate.column == column) return candidate.value;
        }

        return "";
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Workbook {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(128 * 1024 * 1024));

        if (std.ascii.endsWithIgnoreCase(path, ".csv")) {
            return try readCsv(arena, bytes, path);
        }

        var archive = try Zip.init(bytes);
        const shared_xml = archive.extract(memory, "xl/sharedStrings.xml") catch |err| switch (err) {
            error.EntryNotFound => "",
            else => return err,
        };
        var strings: std.ArrayList([]const u8) = .empty;
        if (shared_xml.len > 0) {
            var parser = Parser.init(memory, .shared, &strings);
            try parser.parse(shared_xml);
        }

        // Resolve the first workbook sheet through its relationship, rather
        // than assuming its archive filename is always sheet1.xml.
        var sheet_path: []const u8 = "xl/worksheets/sheet1.xml";
        const workbook_xml = try archive.extract(memory, "xl/workbook.xml");
        const relation_xml = try archive.extract(memory, "xl/_rels/workbook.xml.rels");
        const relation = firstSheetRelation(workbook_xml) orelse "rId1";
        var relations = TagIterator{ .bytes = relation_xml };

        while (relations.next()) |tag| {
            if (!std.mem.startsWith(u8, tag, "Relationship ")) continue;
            const id = attribute(tag, "Id") orelse continue;
            if (!std.mem.eql(u8, id, relation)) continue;
            const target = attribute(tag, "Target") orelse continue;
            sheet_path = if (std.mem.startsWith(u8, target, "/"))
                target[1..]
            else if (std.mem.startsWith(u8, target, "xl/"))
                target
            else
                try memory.print("xl/{s}", .{target});
            break;
        }

        const sheet_xml = try archive.extract(memory, sheet_path);
        var parser = Parser.init(memory, .sheet, &strings);
        try parser.parse(sheet_xml);

        return .{
            .arena = arena,
            .cells = try parser.cells.toOwnedSlice(memory),
            .row_count = parser.rows,
            .column_count = parser.columns,
            .name = try memory.dupe(u8, firstSheetName(workbook_xml) orelse "Sheet1"),
            .path = try memory.dupe(u8, path),
        };
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    mode: enum { shared, sheet },
    shared: *std.ArrayList([]const u8),
    cells: std.ArrayList(Cell) = .empty,
    text: std.ArrayList(u8) = .empty,
    row: u32 = 0,
    column: u16 = 0,
    rows: usize = 0,
    columns: usize = 0,
    cell_type: []const u8 = "",
    collecting: bool = false,
    failed: bool = false,

    fn init(allocator: std.mem.Allocator, mode: @FieldType(Parser, "mode"), shared: *std.ArrayList([]const u8)) Parser {
        return .{ .allocator = allocator, .mode = mode, .shared = shared };
    }

    fn parse(self: *Parser, bytes: []const u8) !void {
        const handle = xml.XML_ParserCreate(null) orelse return error.OutOfMemory;
        defer xml.XML_ParserFree(handle);
        xml.XML_SetUserData(handle, self);
        xml.XML_SetElementHandler(handle, start, finish);
        xml.XML_SetCharacterDataHandler(handle, characters);

        if (xml.XML_Parse(handle, bytes.ptr, @intCast(bytes.len), 1) == xml.XML_STATUS_ERROR) return error.InvalidXml;
        if (self.failed) return error.OutOfMemory;
    }

    fn start(user_data: ?*anyopaque, raw_name: [*c]const u8, attrs: [*c][*c]const u8) callconv(.c) void {
        const self: *Parser = @ptrCast(@alignCast(user_data.?));
        const name = localName(std.mem.span(raw_name));

        if (self.mode == .shared) {
            if (std.mem.eql(u8, name, "si")) self.text.clearRetainingCapacity();
            if (std.mem.eql(u8, name, "t")) self.collecting = true;
            return;
        }

        if (std.mem.eql(u8, name, "c")) {
            self.text.clearRetainingCapacity();
            self.cell_type = "";
            var index: usize = 0;

            while (attrs[index] != null) : (index += 2) {
                const key = std.mem.span(attrs[index]);
                const value = std.mem.span(attrs[index + 1]);
                if (std.mem.eql(u8, key, "r")) self.coordinates(value);
                if (std.mem.eql(u8, key, "t")) self.cell_type = self.allocator.dupe(u8, value) catch { self.failed = true; return; };
            }
        }

        if (std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "t")) self.collecting = true;
    }

    fn finish(user_data: ?*anyopaque, raw_name: [*c]const u8) callconv(.c) void {
        const self: *Parser = @ptrCast(@alignCast(user_data.?));
        const name = localName(std.mem.span(raw_name));
        if (std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "t")) self.collecting = false;

        if (self.mode == .shared and std.mem.eql(u8, name, "si")) {
            const value = self.allocator.dupe(u8, self.text.items) catch { self.failed = true; return; };
            self.shared.append(self.allocator, value) catch { self.failed = true; };
        }

        if (self.mode == .sheet and std.mem.eql(u8, name, "c")) {
            var value: []const u8 = self.text.items;
            if (std.mem.eql(u8, self.cell_type, "s")) {
                const index = std.fmt.parseInt(usize, value, 10) catch return;
                value = if (index < self.shared.items.len) self.shared.items[index] else "";
            }
            const copy = self.allocator.dupe(u8, std.mem.trim(u8, value, " \r\n\t")) catch { self.failed = true; return; };
            self.cells.append(self.allocator, .{ .row = self.row, .column = self.column, .value = copy }) catch { self.failed = true; };
            self.rows = @max(self.rows, @as(usize, self.row) + 1);
            self.columns = @max(self.columns, @as(usize, self.column) + 1);
        }
    }

    fn characters(user_data: ?*anyopaque, bytes: [*c]const u8, length: c_int) callconv(.c) void {
        const self: *Parser = @ptrCast(@alignCast(user_data.?));
        if (!self.collecting) return;
        self.text.appendSlice(self.allocator, bytes[0..@intCast(length)]) catch { self.failed = true; };
    }

    fn coordinates(self: *Parser, value: []const u8) void {
        var column: u32 = 0;
        var index: usize = 0;
        while (index < value.len and std.ascii.isAlphabetic(value[index])) : (index += 1) {
            column = column * 26 + std.ascii.toUpper(value[index]) - 'A' + 1;
        }
        self.column = @intCast(@min(65535, column -| 1));
        self.row = (std.fmt.parseInt(u32, value[index..], 10) catch 1) -| 1;
    }
};

pub const Zip = struct {
    bytes: []const u8,
    directory: usize,
    count: usize,

    pub fn init(bytes: []const u8) !Zip {
        if (bytes.len < 22) return error.NotAnXlsxWorkbook;
        var position = bytes.len - 22;
        const minimum = bytes.len -| 65557;

        while (true) {
            if (std.mem.eql(u8, bytes[position..][0..4], "PK\x05\x06")) break;
            if (position == minimum) return error.NotAnXlsxWorkbook;
            position -= 1;
        }

        const directory = integer(u32, bytes, position + 16);
        const count = integer(u16, bytes, position + 10);
        if (directory >= bytes.len) return error.InvalidArchive;
        return .{ .bytes = bytes, .directory = directory, .count = count };
    }

    pub fn extract(self: *const Zip, allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
        var position = self.directory;

        for (0..self.count) |_| {
            if (position + 46 > self.bytes.len) return error.InvalidArchive;
            const length = integer(u16, self.bytes, position + 28);
            const extra = integer(u16, self.bytes, position + 30);
            const comment = integer(u16, self.bytes, position + 32);
            if (position + 46 + length > self.bytes.len) return error.InvalidArchive;

            if (std.mem.eql(u8, self.bytes[position + 46 ..][0..length], filename)) {
                const method = integer(u16, self.bytes, position + 10);
                const compressed = integer(u32, self.bytes, position + 20);
                const expanded = integer(u32, self.bytes, position + 24);
                const offset: usize = integer(u32, self.bytes, position + 42);
                if (expanded > 128 * 1024 * 1024 or offset + 30 > self.bytes.len) return error.InvalidArchive;
                const start = @as(usize, offset) + 30 + integer(u16, self.bytes, offset + 26) + integer(u16, self.bytes, offset + 28);
                if (start + compressed > self.bytes.len) return error.InvalidArchive;
                const input_bytes = self.bytes[start..][0..compressed];
                const checksum = integer(u32, self.bytes, position + 16);
                if (method == 0) {
                    if (input_bytes.len != expanded or std.hash.Crc32.hash(input_bytes) != checksum) return error.InvalidArchive;
                    return input_bytes;
                }
                if (method != 8) return error.UnsupportedCompression;

                var input = std.Io.Reader.fixed(input_bytes);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var decompressor = std.compress.flate.Decompress.init(&input, .raw, &window);
                const output = try decompressor.reader.allocRemaining(allocator, .limited(expanded + 1));
                if (output.len != expanded or std.hash.Crc32.hash(output) != checksum) return error.InvalidArchive;
                return output;
            }

            position += 46 + @as(usize, length) + extra + comment;
        }

        return error.EntryNotFound;
    }
};

fn integer(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

const TagIterator = struct {
    bytes: []const u8,
    position: usize = 0,

    fn next(self: *TagIterator) ?[]const u8 {
        const start = std.mem.indexOfScalarPos(u8, self.bytes, self.position, '<') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '>') orelse return null;
        self.position = end + 1;
        return self.bytes[start + 1 .. end];
    }
};

pub fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, tag, position, name)) |index| {
        const after = index + name.len;
        if (index > 0 and !std.ascii.isWhitespace(tag[index - 1])) { position = after; continue; }
        if (after + 2 >= tag.len or tag[after] != '=') { position = after; continue; }
        const quote = tag[after + 1];
        const end = std.mem.indexOfScalarPos(u8, tag, after + 2, quote) orelse return null;
        return tag[after + 2 .. end];
    }
    return null;
}

fn firstSheetRelation(bytes: []const u8) ?[]const u8 {
    var tags = TagIterator{ .bytes = bytes };
    while (tags.next()) |tag| if (std.mem.startsWith(u8, tag, "sheet ")) return attribute(tag, "r:id");
    return null;
}

fn firstSheetName(bytes: []const u8) ?[]const u8 {
    var tags = TagIterator{ .bytes = bytes };
    while (tags.next()) |tag| if (std.mem.startsWith(u8, tag, "sheet ")) return attribute(tag, "name");
    return null;
}

fn localName(name: []const u8) []const u8 {
    return name[(if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| index + 1 else 0)..];
}

fn readCsv(arena_value: std.heap.ArenaAllocator, bytes: []const u8, path: []const u8) !Workbook {
    var arena = arena_value;
    const allocator = arena.allocator();
    var cells: std.ArrayList(Cell) = .empty;
    var value: std.ArrayList(u8) = .empty;
    var row: u32 = 0;
    var column: u16 = 0;
    var columns: usize = 0;
    var quoted = false;
    var index: usize = 0;

    while (index <= bytes.len) : (index += 1) {
        const ch: u8 = if (index == bytes.len) '\n' else bytes[index];
        if (ch == '"') {
            if (quoted and index + 1 < bytes.len and bytes[index + 1] == '"') {
                try value.append(allocator, '"');
                index += 1;
            } else quoted = !quoted;
        } else if (!quoted and (ch == ',' or ch == '\n')) {
            try cells.append(allocator, .{ .row = row, .column = column, .value = try allocator.dupe(u8, std.mem.trim(u8, value.items, "\r")) });
            value.clearRetainingCapacity();
            columns = @max(columns, @as(usize, column) + 1);
            if (ch == '\n') { row += 1; column = 0; } else column += 1;
        } else try value.append(allocator, ch);
    }

    return .{
        .arena = arena,
        .cells = try cells.toOwnedSlice(allocator),
        .row_count = row,
        .column_count = columns,
        .name = "Sheet1",
        .path = try allocator.dupe(u8, path),
    };
}
