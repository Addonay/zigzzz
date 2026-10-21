//! Lossless RGBA PNG encoding for chart clipboard and workbook exports.
const std = @import("std");
const Document = @import("document.zig").Document;

pub fn encode(allocator: std.mem.Allocator, pixels: []const u8, width: usize, height: usize, pitch: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var raw = Document{ .allocator = memory };
    for (0..height) |row| {
        try raw.append(&.{0});
        try raw.append(pixels[row * pitch ..][0 .. width * 4]);
    }
    var zlib = try std.Io.Writer.Allocating.initCapacity(memory, 65536);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&zlib.writer, &history, .zlib, .fastest);
    try compressor.writer.writeAll(raw.bytes.items);
    try compressor.finish();
    var result = Document{ .allocator = memory };
    try result.append("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    try chunk(&result, "IHDR", &ihdr);
    try chunk(&result, "IDAT", zlib.written());
    try chunk(&result, "IEND", "");
    return allocator.dupe(u8, result.bytes.items);
}

fn chunk(out: *Document, name: *const [4]u8, value: []const u8) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, @intCast(value.len), .big);
    try out.append(&buffer);
    try out.append(name);
    try out.append(value);
    var crc = std.hash.Crc32.init();
    crc.update(name);
    crc.update(value);
    std.mem.writeInt(u32, &buffer, crc.final(), .big);
    try out.append(&buffer);
}

test "PNG encoder writes a valid zlib stream and dimensions" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, 2, 1, 8);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", encoded[0..8]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    const size = std.mem.readInt(u32, encoded[33..37], .big);
    var input = std.Io.Reader.fixed(encoded[41..][0..size]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&input, .zlib, &window);
    const pixels = try decoder.reader.allocRemaining(allocator, .limited(9));
    defer allocator.free(pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 255, 0, 255 }, pixels);
}
