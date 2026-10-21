const std = @import("std");
const Io = std.Io;

const Release = struct {
    label: []const u8,
    file: []const u8,
};

const releases = [_]Release{
    .{ .label = "debug", .file = "zigzzz" },
    .{ .label = "small", .file = "zigzzz-small" },
    .{ .label = "fast", .file = "zigzzz-fast" },
    .{ .label = "safe", .file = "zigzzz-safe" },
};

const Platform = struct {
    label: []const u8,
    dir: []const u8,
    extension: []const u8,
};

const platforms = [_]Platform{
    .{ .label = "windows-gnu", .dir = "zig-out/windows/bin", .extension = ".exe" },
    .{ .label = "linux", .dir = "zig-out/bin", .extension = "" },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (platforms, 0..) |platform, platform_index| {
        if (platform_index != 0) try stdout.writeByte('\n');
        try stdout.print("{s}\n", .{platform.label});
        try stdout.print("  {s:<8} {s:>12}  {s}\n", .{ "release", "size", "executable" });

        for (releases) |release| {
            const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ release.file, platform.extension });
            const path = try std.fs.path.join(arena, &.{ platform.dir, file });
            const stat = Io.Dir.cwd().statFile(init.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try stdout.print("  {s:<8} {s:>12}  {s}\n", .{ release.label, "not built", path });
                    continue;
                },
                else => return err,
            };

            var size_buffer: [32]u8 = undefined;
            try stdout.print("  {s:<8} {s:>12}  {s}\n", .{
                release.label,
                formatSize(&size_buffer, stat.size),
                path,
            });
        }
    }

    try stdout.flush();
}

fn formatSize(buffer: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch unreachable;

    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch unreachable;
}

test "formatSize uses binary units" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatSize(&buffer, 512));
    try std.testing.expectEqualStrings("1.0 KiB", formatSize(&buffer, 1024));
    try std.testing.expectEqualStrings("1.5 MiB", formatSize(&buffer, 1024 * 1024 * 3 / 2));
}
