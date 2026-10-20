const std = @import("std");

pub const Text = struct {
    bytes: [512]u8 = @splat(0),
    length: usize = 0,

    pub fn init(value: []const u8) Text {
        var result = Text{};
        result.set(value);
        return result;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn set(self: *Text, value: []const u8) void {
        var length = @min(value.len, self.bytes.len);
        while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
        @memcpy(self.bytes[0..length], value[0..length]);
        self.length = length;
    }

    pub fn insert(self: *Text, position: usize, value: []const u8) usize {
        const at = @min(position, self.length);
        var length = @min(value.len, self.bytes.len - self.length);
        while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
        std.mem.copyBackwards(u8, self.bytes[at + length .. self.length + length], self.bytes[at..self.length]);
        @memcpy(self.bytes[at..][0..length], value[0..length]);
        self.length += length;
        return length;
    }

    pub fn remove(self: *Text, first: usize, last: usize) void {
        if (first >= last or last > self.length) return;
        std.mem.copyForwards(u8, self.bytes[first .. self.length - (last - first)], self.bytes[last..self.length]);
        self.length -= last - first;
    }

    pub fn previous(self: *const Text, position: usize) usize {
        var at = @min(position, self.length) -| 1;
        while (at > 0 and self.bytes[at] & 0xc0 == 0x80) at -= 1;
        return at;
    }

    pub fn next(self: *const Text, position: usize) usize {
        if (position >= self.length) return self.length;
        var at = position + 1;
        while (at < self.length and self.bytes[at] & 0xc0 == 0x80) at += 1;
        return at;
    }
};
