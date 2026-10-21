const std = @import("std");

const manifest = @import("build.zig.zon");

const dependency_optimize: std.builtin.Optimize = .fast;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const packages = @import("root").dependencies.packages;
    const layout_package = @field(packages, manifest.dependencies.zlay.hash);

    const assets = b.createModule(.{ .root_source_file = b.path("assets/embedded.zig") });

    const sdl_dep = b.dependency("sdl3", .{ .target = target, .optimize = dependency_optimize, .ext_image = true });
    const sdl = sdl_dep.module("sdl3");

    // v0.2.3 incorrectly gives its slice-based clipboard callback a C ABI.
    // Patch build inputs only; the fetched package stays untouched.
    const clipboard_source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.pathJoin(&.{ @field(packages, manifest.dependencies.sdl3.hash).build_root, "src/clipboard.zig" }),
        b.allocator,
        .unlimited,
    ) catch @panic("Cannot read zig-sdl3 clipboard bindings");
    const callback_signature = "mime_type: ?[:0]const u8) callconv(.c) ?[]u8";
    if (std.mem.count(u8, clipboard_source, callback_signature) != 1)
        @panic("Review zig-sdl3 clipboard callback patch after updating the dependency");
    const clipboard_fixed = std.mem.replaceOwned(u8, b.allocator, clipboard_source, callback_signature, "mime_type: ?[:0]const u8) ?[]u8") catch @panic("OOM");
    const patched = b.addWriteFiles();
    const patched_source = patched.addCopyDirectory(sdl_dep.path("src"), "sdl3", .{ .exclude_extensions = &.{"clipboard.zig"} });
    _ = patched.add("sdl3/clipboard.zig", clipboard_fixed);
    sdl.root_source_file = patched_source.path(b, "sdl3.zig");

    const ft_dep = b.dependency("freetype", .{ .target = target, .optimize = dependency_optimize });
    const ft_lib = ft_dep.artifact("freetype");
    const expat_dep = b.dependency("expat", .{ .target = target, .optimize = dependency_optimize });
    const expat_lib = expat_dep.artifact("expat");

    const zlay = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ layout_package.build_root, "src/root.zig" }) },
        .target = target,
        .optimize = dependency_optimize,
    });

    const native = b.addTranslateC(.{
        .root_source_file = b.path("src/native.h"),
        .target = target,
        .optimize = dependency_optimize,
    });
    native.addIncludePath(ft_lib.getEmittedIncludeTree());
    native.addIncludePath(expat_lib.getEmittedIncludeTree());

    const native_module = native.createModule();
    const name = switch (optimize) {
        .debug => "zigzzz",
        .small => "zigzzz-small",
        .fast => "zigzzz-fast",
        .safe => "zigzzz-safe",
    };

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
    });
    module.addImport("sdl3", sdl);
    module.addImport("zlay", zlay);
    module.addImport("native", native_module);
    module.addImport("assets", assets);
    module.linkLibrary(ft_lib);
    module.linkLibrary(expat_lib);

    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "version", manifest.version);
    module.addOptions("build_options", build_options);

    const windows = target.result.os.tag == .windows;

    // Icon and version details for Explorer and the taskbar.
    // The version comes from build.zig.zon: "0.1.2" is passed as the string
    // ZIGZZZ_VERSION and as ZIGZZZ_VERSION_NUMBERS 0,1,2,0.
    if (windows) module.addWin32ResourceFile(.{
        .file = b.path("packaging/windows/zigzzz.rc"),
        .flags = &.{
            b.fmt("/dZIGZZZ_VERSION=\"{s}\"", .{manifest.version}),
            b.fmt("/dZIGZZZ_VERSION_NUMBERS={s}", .{versionNumbers(b, manifest.version)}),
        },
    });

    const exe = b.addExecutable(.{ .name = name, .root_module = module });

    // A GUI app: no console window behind it on Windows.
    if (windows) exe.subsystem = .windows;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the workspace").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run application tests").dependOn(&run_tests.step);

    // Report installed binary sizes. This only reads zig-out; it never builds
    // missing variants and ignores any custom install prefix.
    const size_tool = b.addExecutable(.{
        .name = "zigzzz-size",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/size.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const size_run = b.addRunArtifact(size_tool);
    size_run.setCwd(b.path("."));
    size_run.stdio = .inherit;
    b.step("size", "Display the size of each built release").dependOn(&size_run.step);
}


/// "0.1.2" as "0,1,2,0", the four numbers Windows version resources expect.
fn versionNumbers(b: *std.Build, version: []const u8) []const u8 {
    var numbers: [4][]const u8 = .{ "0", "0", "0", "0" };
    var parts = std.mem.tokenizeAny(u8, version, ".-+");

    for (&numbers) |*number| {
        const part = parts.next() orelse break;
        _ = std.fmt.parseInt(u16, part, 10) catch break;
        number.* = part;
    }

    return b.fmt("{s},{s},{s},{s}", .{ numbers[0], numbers[1], numbers[2], numbers[3] });
}
