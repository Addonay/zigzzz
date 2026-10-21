//! Resolve the per-user settings file without falling back to a temporary
//! directory on Windows. SDL resolves the native roaming profile using the
//! Windows API and returns UTF-8, including redirected and Unicode paths.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");

pub fn resolve(allocator: std.mem.Allocator) ![]const u8 {
    if (environment("ZIGZZZ_SETTINGS_PATH")) |path| return allocator.dupe(u8, path);

    if (builtin.os.tag == .windows) {
        const directory = try sdl.filesystem.getPrefPath("", "zigzzz");
        defer sdl.free(directory);
        return appendFilename(allocator, directory);
    }

    if (environment("XDG_CONFIG_HOME")) |directory| {
        return allocator.print("{s}/zigzzz/settings.json", .{directory});
    }

    const home = environment("HOME") orelse "/tmp";
    return allocator.print("{s}/.config/zigzzz/settings.json", .{home});
}

fn environment(comptime name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const text = std.mem.span(value);
    return if (text.len > 0) text else null;
}

fn appendFilename(allocator: std.mem.Allocator, directory: []const u8) ![]const u8 {
    // SDL guarantees the trailing platform separator. Preserve it rather
    // than joining with the build host's separator during cross compilation.
    if (directory.len == 0) return error.MissingPreferencesDirectory;
    return allocator.print("{s}settings.json", .{directory});
}

test "Windows roaming settings preserve Unicode and redirected paths" {
    const allocator = std.testing.allocator;
    const paths = [_][]const u8{
        "C:\\Users\\Addo\\AppData\\Roaming\\zigzzz\\",
        "C:\\Users\\José\\AppData\\Roaming\\zigzzz\\",
        "\\\\server\\profiles\\Addo\\Roaming\\zigzzz\\",
    };
    for (paths) |directory| {
        const path = try appendFilename(allocator, directory);
        defer allocator.free(path);
        try std.testing.expectEqualStrings(directory, path[0..directory.len]);
        try std.testing.expectEqualStrings("settings.json", path[directory.len..]);
    }
    try std.testing.expectError(error.MissingPreferencesDirectory, appendFilename(allocator, ""));
}
