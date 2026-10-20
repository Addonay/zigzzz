const std = @import("std");

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import the fetched binding module without building zsdl3's older examples.
    // Its example build uses b.args, which was removed in Zig 0.17.
    const packages = @import("root").dependencies.packages;
    const bindings = @field(packages, manifest.dependencies.zsdl.hash);
    const layout_package = @field(packages, manifest.dependencies.zlay.hash);

    // Upstream SDL_RenderReadPixels names pixels.SDL_Surface, although that
    // declaration lives in surface.zig. Correct that one type in generated
    // build inputs; never mutate the fetched package or maintain SDL externs.
    const binding_source = b.pathJoin(&.{ bindings.build_root, "src" });
    const render_source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io, b.pathJoin(&.{ binding_source, "render.zig" }), b.allocator, .unlimited,
    ) catch @panic("Cannot read the fetched SDL bindings");
    const corrected_render = std.mem.replaceOwned(u8, b.allocator, render_source,
        "?*pixels.SDL_Surface", "?*surface.SDL_Surface") catch @panic("OOM");
    const generated = b.addWriteFiles();
    const binding_directory = generated.addCopyDirectory(.{ .cwd_relative = binding_source }, "zsdl3", .{
        .exclude_extensions = &.{"render.zig"},
    });
    _ = generated.add("zsdl3/render.zig", corrected_render);

    const sdl = b.createModule(.{
        .root_source_file = binding_directory.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption(bool, "enable_sdl_image", false);
    options.addOption(bool, "enable_sdl_ttf", false);
    options.addOption(bool, "enable_sdl_mixer", false);
    sdl.addOptions("build_options", options);
    sdl.linkSystemLibrary("SDL3", .{});

    const zlay = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ layout_package.build_root, "src/root.zig" }) },
        .target = target,
        .optimize = optimize,
    });

    const native = b.addTranslateC(.{
        .root_source_file = b.path("src/native.h"),
        .target = target,
        .optimize = optimize,
    });
    native.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    native.linkSystemLibrary("freetype", .{});
    native.linkSystemLibrary("expat", .{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zsdl3", sdl);
    module.addImport("zlay", zlay);
    module.addImport("native", native.createModule());
    module.addImport("assets", b.createModule(.{
        .root_source_file = b.path("assets/embedded.zig"),
    }));

    const name = switch (optimize) {
        .fast => "zigzzz-fast",
        .small => "zigzzz-small",
        .safe => "zigzzz-safe",
        else => "zigzzz",
    };

    const executable = b.addExecutable(.{ .name = name, .root_module = module });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    b.step("run", "Run the workspace").dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/core_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("zsdl3", sdl);
    test_module.addImport("zlay", zlay);
    test_module.addImport("native", native.createModule());
    test_module.addImport("assets", module.import_table.get("assets").?);
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Check spreadsheet parsing, preferences, and KML conversion").dependOn(&run_tests.step);
}
