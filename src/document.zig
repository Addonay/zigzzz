const std = @import("std");

/// A small owned builder used by the XML exporters. Appending is fallible;
/// callers never publish a partially generated document.
pub const Document = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn append(self: *Document, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }

    pub fn print(self: *Document, comptime format: []const u8, args: anytype) !void {
        const value = try self.allocator.print(format, args);
        defer self.allocator.free(value);
        try self.append(value);
    }

    pub fn escaped(self: *Document, value: []const u8) !void {
        for (value) |byte| {
            try self.append(switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&apos;",
                else => &.{byte},
            });
        }
    }

    pub fn save(self: *const Document, io: std.Io, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, self.bytes.items);
        try file.file.sync(io);
        try file.replace(io);
    }
};
