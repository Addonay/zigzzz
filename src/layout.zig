//! Workspace shell layout, computed by zlay every frame.
//!
//!   ┌──────────┬─────────────────────────────────┐
//!   │ brand    │ topbar                          │
//!   │ nav × 3  ├─────────────────────────────────┤
//!   │ context  │ content                         │
//!   │ footer   │                                 │
//!   └──────────┴─────────────────────────────────┘
//!
//! Pages lay out their own content inside the `content` rectangle.

const std = @import("std");
const zlay = @import("zlay");
const theme = @import("theme.zig");
const Rect = @import("geometry.zig").Rect;

pub const nav_count = 3;

pub const Layout = struct {
    memory: []u8,
    context: *zlay.Context,

    pub fn init(allocator: std.mem.Allocator) !Layout {
        const options = zlay.Options{
            .max_element_count = 256,
            .layout_dimensions = .init(theme.initial_width, theme.initial_height),
        };

        const memory = try allocator.alloc(u8, zlay.minMemorySize(options));
        errdefer allocator.free(memory);

        return .{ .memory = memory, .context = try zlay.Context.init(memory, options) };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }

    pub fn update(self: *Layout, width: f32, height: f32, sidebar_open: bool, sidebar_width: f32) void {
        const ui = self.context;

        ui.setLayoutDimensions(.init(width, height));
        ui.beginLayout();

        ui.element(.named("workspace"), .{ .layout = .{ .sizing = .grow } }).children({
            if (sidebar_open) sidebar(ui, sidebar_width);

            ui.element(.named("main"), .{ .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
            } }).children({
                ui.element(.named("topbar"), .{ .layout = .{
                    .sizing = .{ .width = .grow(.{}), .height = .fixed(theme.toolbar_height) },
                } }).end();

                ui.element(.named("content"), .{ .layout = .{ .sizing = .grow } }).end();
            });
        });

        _ = ui.endLayout(1.0 / 60.0);
    }

    fn sidebar(ui: *zlay.Context, width: f32) void {
        ui.element(.named("sidebar"), .{ .layout = .{
            .sizing = .{ .width = .fixed(width), .height = .grow(.{}) },
            .direction = .top_to_bottom,
        } }).children({
            ui.element(.named("brand"), .{ .layout = .{
                .sizing = .{ .width = .grow(.{}), .height = .fixed(theme.toolbar_height) },
            } }).end();

            ui.element(.named("nav"), .{ .layout = .{
                .sizing = .{ .width = .grow(.{}), .height = .fit(.{}) },
                .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 },
                .child_gap = 2,
                .direction = .top_to_bottom,
            } }).children({
                for (0..nav_count) |index| {
                    ui.element(.indexed("nav-item", @intCast(index)), .{ .layout = .{
                        .sizing = .{ .width = .grow(.{}), .height = .fixed(34) },
                    } }).end();
                }
            });

            ui.element(.named("sidebar-context"), .{ .layout = .{
                .sizing = .grow,
                .padding = .axes(10, 4),
            } }).end();

            ui.element(.named("sidebar-footer"), .{ .layout = .{
                .sizing = .{ .width = .grow(.{}), .height = .fixed(54) },
                .padding = .axes(10, 10),
                .child_gap = 4,
            } }).children({
                ui.element(.named("settings-nav"), .{ .layout = .{ .sizing = .grow } }).end();
                ui.element(.named("theme-toggle"), .{ .layout = .{
                    .sizing = .{ .width = .fixed(34), .height = .grow(.{}) },
                } }).end();
            });
        });
    }

    pub fn rect(self: *Layout, comptime name: []const u8) Rect {
        return self.bounds(.named(name));
    }

    pub fn indexed(self: *Layout, comptime name: []const u8, index: usize) Rect {
        return self.bounds(.indexed(name, @intCast(index)));
    }

    fn bounds(self: *Layout, id: zlay.ElementId) Rect {
        const element = self.context.elementData(id) orelse return .{};
        const value = element.bounding_box;

        return .{ .x = value.x, .y = value.y, .w = value.width, .h = value.height };
    }
};
