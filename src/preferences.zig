const std = @import("std");
const assets = @import("assets");
pub const Text = @import("text.zig").Text;

pub const operators = [_][]const u8{ ">=", "<=", ">", "<", "==", "!=" };
pub const max_kpis = 512;

pub const Rule = struct {
    name: Text = .{},
    value: Text = .{},
    operator: usize = 0,
    enabled: bool = false,
};

pub const Group = struct {
    name: Text = .{},
    members: [max_kpis]bool = @splat(false),
};

pub const Override = struct {
    name: Text = .{},
    days: Text = .init("30"),
};

pub const Overlay = struct {
    primary: usize = 0,
    members: [max_kpis]bool = @splat(false),
};

const RawRule = struct { name: []const u8, operator: []const u8, value: f64 };
const RawGroup = struct { name: []const u8, kpis: []const []const u8 };
const Raw = struct {
    dark: bool = true,
    font_size: u32 = 16,
    sidebar_open: bool = true,
    global_days: u32 = 30,
    area_days: std.json.Value = .null,
    kpi_days: std.json.Value = .null,
    thresholds: []const RawRule = &.{},
    kpi_names: []const []const u8 = &.{},
    groups: []const RawGroup = &.{},
    overlays: std.json.Value = .null,
};

pub const Preferences = struct {
    dark: bool = true,
    font_size: Text = .init("16"),
    sidebar_open: bool = true,
    global_days: Text = .init("30"),
    rules: [max_kpis]Rule = undefined,
    rule_count: usize = 0,
    groups: [32]Group = undefined,
    group_count: usize = 0,
    area_days: [32]Override = undefined,
    area_count: usize = 0,
    kpi_days: [64]Override = undefined,
    kpi_count: usize = 0,
    overlays: [32]Overlay = undefined,
    overlay_count: usize = 0,

    pub fn defaults(result: *Preferences, allocator: std.mem.Allocator) !void {
        result.* = .{};
        const parsed = try std.json.parseFromSlice([]RawRule, allocator, assets.thresholds, .{});
        defer parsed.deinit();

        for (parsed.value) |rule| try result.includeRule(rule.name, rule.operator, rule.value);
    }

    pub fn find(self: *const Preferences, name: []const u8) ?usize {
        for (self.rules[0..self.rule_count], 0..) |*rule, index| {
            if (std.mem.eql(u8, rule.name.slice(), name)) return index;
        }
        return null;
    }

    pub fn include(self: *Preferences, name: []const u8) !usize {
        if (self.find(name)) |index| return index;
        if (self.rule_count == max_kpis) return error.TooManyKpis;
        const index = self.rule_count;
        self.rules[index] = .{ .name = .init(name), .value = .init("0") };
        self.rule_count += 1;
        return index;
    }

    fn includeRule(self: *Preferences, name: []const u8, operator: []const u8, value: f64) !void {
        const index = try self.include(name);
        self.rules[index].enabled = true;
        self.rules[index].operator = for (operators, 0..) |candidate, at| {
            if (std.mem.eql(u8, candidate, operator)) break at;
        } else return error.InvalidOperator;
        var buffer: [64]u8 = undefined;
        self.rules[index].value.set(try std.fmt.bufPrint(&buffer, "{d}", .{value}));
    }

    /// True when both preferences would save to the same settings.
    pub fn equivalent(self: *const Preferences, other: *const Preferences) bool {
        if (self.dark != other.dark or self.sidebar_open != other.sidebar_open) return false;
        if (!same(&self.font_size, &other.font_size) or !same(&self.global_days, &other.global_days)) return false;

        if (self.rule_count != other.rule_count) return false;
        if (self.group_count != other.group_count) return false;
        if (self.area_count != other.area_count or self.kpi_count != other.kpi_count) return false;
        if (self.overlay_count != other.overlay_count) return false;

        for (self.rules[0..self.rule_count], other.rules[0..other.rule_count]) |*a, *b| {
            if (a.enabled != b.enabled or a.operator != b.operator) return false;
            if (!same(&a.name, &b.name) or !same(&a.value, &b.value)) return false;
        }

        for (self.groups[0..self.group_count], other.groups[0..other.group_count]) |*a, *b| {
            if (!same(&a.name, &b.name)) return false;
            if (!std.mem.eql(bool, a.members[0..self.rule_count], b.members[0..self.rule_count])) return false;
        }

        for (self.area_days[0..self.area_count], other.area_days[0..other.area_count]) |*a, *b| {
            if (!same(&a.name, &b.name) or !same(&a.days, &b.days)) return false;
        }

        for (self.kpi_days[0..self.kpi_count], other.kpi_days[0..other.kpi_count]) |*a, *b| {
            if (!same(&a.name, &b.name) or !same(&a.days, &b.days)) return false;
        }

        for (self.overlays[0..self.overlay_count], other.overlays[0..other.overlay_count]) |*a, *b| {
            if (a.primary != b.primary) return false;
            if (!std.mem.eql(bool, a.members[0..self.rule_count], b.members[0..self.rule_count])) return false;
        }

        return true;
    }

    fn same(a: *const Text, b: *const Text) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }

    pub fn textSize(self: *const Preferences) u32 {
        return std.fmt.parseInt(u32, self.font_size.slice(), 10) catch 16;
    }

    pub fn days(self: *const Preferences, area: []const u8, kpi: []const u8) u32 {
        for (self.kpi_days[0..self.kpi_count]) |*row| {
            if (std.mem.eql(u8, row.name.slice(), kpi)) return std.fmt.parseInt(u32, row.days.slice(), 10) catch 30;
        }
        for (self.area_days[0..self.area_count]) |*row| {
            if (std.mem.eql(u8, row.name.slice(), area)) return std.fmt.parseInt(u32, row.days.slice(), 10) catch 30;
        }
        return std.fmt.parseInt(u32, self.global_days.slice(), 10) catch 30;
    }

    pub fn meets(self: *const Preferences, name: []const u8, value: f64) ?bool {
        const index = self.find(name) orelse return null;
        const rule = &self.rules[index];
        if (!rule.enabled or !std.math.isFinite(value)) return null;
        const threshold = std.fmt.parseFloat(f64, rule.value.slice()) catch return null;
        return switch (rule.operator) {
            0 => value >= threshold,
            1 => value <= threshold,
            2 => value > threshold,
            3 => value < threshold,
            4 => @abs(value - threshold) < 1e-9,
            5 => @abs(value - threshold) >= 1e-9,
            else => null,
        };
    }

    pub fn validate(self: *const Preferences) !void {
        const font_size = std.fmt.parseInt(u32, self.font_size.slice(), 10) catch return error.TextSizeMustBe12To24;
        if (font_size < 12 or font_size > 24) return error.TextSizeMustBe12To24;
        try validateDays(self.global_days.slice());
        for (self.area_days[0..self.area_count]) |*row| {
            if (std.mem.trim(u8, row.name.slice(), " \t").len == 0) return error.OverrideNeedsAName;
            try validateDays(row.days.slice());
        }
        for (self.kpi_days[0..self.kpi_count]) |*row| {
            if (std.mem.trim(u8, row.name.slice(), " \t").len == 0) return error.OverrideNeedsAName;
            try validateDays(row.days.slice());
        }

        for (self.rules[0..self.rule_count]) |*rule| {
            if (rule.operator >= operators.len) return error.InvalidOperator;
            if (!rule.enabled) continue;
            const value = std.fmt.parseFloat(f64, rule.value.slice()) catch return error.InvalidThreshold;
            if (!std.math.isFinite(value)) return error.InvalidThreshold;
        }
        var grouped: [max_kpis]bool = @splat(false);
        for (self.groups[0..self.group_count], 0..) |*group, index| {
            if (std.mem.trim(u8, group.name.slice(), " \t").len == 0) return error.GroupNeedsAName;
            if (std.mem.indexOfScalar(bool, &group.members, true) == null) return error.GroupNeedsAtLeastOneKpi;
            for (self.groups[0..index]) |*other| {
                if (std.mem.eql(u8, group.name.slice(), other.name.slice())) return error.GroupNamesMustBeUnique;
            }
            for (group.members, 0..) |selected, at| {
                if (selected and grouped[at]) return error.KpiCanBelongToOnlyOneGroup;
                grouped[at] = grouped[at] or selected;
            }
        }
        for (self.overlays[0..self.overlay_count]) |*overlay| {
            if (overlay.primary >= self.rule_count or overlay.members[overlay.primary]) return error.InvalidOverlay;
        }
    }

    pub fn load(result: *Preferences, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return result.defaults(allocator),
            else => return err,
        };
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Raw, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        result.* = .{};
        result.dark = parsed.value.dark;
        result.sidebar_open = parsed.value.sidebar_open;
        var buffer: [64]u8 = undefined;
        result.font_size.set(try std.fmt.bufPrint(&buffer, "{d}", .{parsed.value.font_size}));
        result.global_days.set(try std.fmt.bufPrint(&buffer, "{d}", .{parsed.value.global_days}));
        for (parsed.value.thresholds) |rule| try result.includeRule(rule.name, rule.operator, rule.value);
        for (parsed.value.kpi_names) |name| _ = try result.include(name);

        for (parsed.value.groups) |group| {
            if (result.group_count == result.groups.len) return error.TooManyGroups;
            var output = Group{ .name = .init(group.name) };
            for (group.kpis) |name| output.members[try result.include(name)] = true;
            result.groups[result.group_count] = output;
            result.group_count += 1;
        }

        if (parsed.value.area_days == .object) {
            var iterator = parsed.value.area_days.object.iterator();
            while (iterator.next()) |item| {
                if (item.value_ptr.* != .integer) return error.InvalidSettings;
                if (result.area_count == result.area_days.len) return error.TooManyOverrides;
                result.area_days[result.area_count] = .{ .name = .init(item.key_ptr.*), .days = .init(try std.fmt.bufPrint(&buffer, "{d}", .{item.value_ptr.integer})) };
                result.area_count += 1;
            }
        }

        if (parsed.value.kpi_days == .object) {
            var iterator = parsed.value.kpi_days.object.iterator();
            while (iterator.next()) |item| {
                if (item.value_ptr.* != .integer) return error.InvalidSettings;
                if (result.kpi_count == result.kpi_days.len) return error.TooManyOverrides;
                result.kpi_days[result.kpi_count] = .{ .name = .init(item.key_ptr.*), .days = .init(try std.fmt.bufPrint(&buffer, "{d}", .{item.value_ptr.integer})) };
                result.kpi_count += 1;
            }
        }

        if (parsed.value.overlays == .object) {
            var iterator = parsed.value.overlays.object.iterator();
            while (iterator.next()) |item| {
                if (item.value_ptr.* != .array) return error.InvalidSettings;
                if (result.overlay_count == result.overlays.len) return error.TooManyOverlays;
                var output = Overlay{ .primary = try result.include(item.key_ptr.*) };
                for (item.value_ptr.array.items) |name| {
                    if (name != .string) return error.InvalidSettings;
                    output.members[try result.include(name.string)] = true;
                }
                result.overlays[result.overlay_count] = output;
                result.overlay_count += 1;
            }
        }

        try result.validate();
    }

    pub fn save(self: *const Preferences, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        try self.validate();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var rules: std.ArrayList(RawRule) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var groups: std.ArrayList(RawGroup) = .empty;

        for (self.rules[0..self.rule_count]) |*rule| {
            try names.append(memory, rule.name.slice());
            if (rule.enabled) try rules.append(memory, .{
                .name = rule.name.slice(),
                .operator = operators[rule.operator],
                .value = try std.fmt.parseFloat(f64, rule.value.slice()),
            });
        }

        for (self.groups[0..self.group_count]) |*group| {
            var members: std.ArrayList([]const u8) = .empty;
            for (group.members, 0..) |selected, index| {
                if (selected and index < self.rule_count) try members.append(memory, self.rules[index].name.slice());
            }
            try groups.append(memory, .{ .name = group.name.slice(), .kpis = members.items });
        }

        var area_map: std.json.ObjectMap = .empty;
        for (self.area_days[0..self.area_count]) |*row| try area_map.put(memory, row.name.slice(), .{ .integer = try std.fmt.parseInt(i64, row.days.slice(), 10) });
        var kpi_map: std.json.ObjectMap = .empty;
        for (self.kpi_days[0..self.kpi_count]) |*row| try kpi_map.put(memory, row.name.slice(), .{ .integer = try std.fmt.parseInt(i64, row.days.slice(), 10) });
        var overlay_map: std.json.ObjectMap = .empty;
        for (self.overlays[0..self.overlay_count]) |*overlay| {
            var members = std.json.Array.init(memory);
            for (overlay.members, 0..) |selected, index| {
                if (selected and index < self.rule_count) try members.append(.{ .string = self.rules[index].name.slice() });
            }
            try overlay_map.put(memory, self.rules[overlay.primary].name.slice(), .{ .array = members });
        }

        const bytes = try std.json.Stringify.valueAlloc(memory, Raw{
            .dark = self.dark,
            .font_size = self.textSize(),
            .sidebar_open = self.sidebar_open,
            .global_days = try std.fmt.parseInt(u32, self.global_days.slice(), 10),
            .thresholds = rules.items,
            .kpi_names = names.items,
            .groups = groups.items,
            .area_days = .{ .object = area_map },
            .kpi_days = .{ .object = kpi_map },
            .overlays = .{ .object = overlay_map },
        }, .{ .whitespace = .indent_2 });

        if (std.fs.path.dirname(path)) |directory| try std.Io.Dir.cwd().createDirPath(io, directory);
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, bytes);
        try file.file.sync(io);
        try file.replace(io);
    }
};

fn validateDays(value: []const u8) !void {
    const days = std.fmt.parseInt(u32, value, 10) catch return error.DaysMustBe7To180;
    if (days < 7 or days > 180) return error.DaysMustBe7To180;
}

test "threshold operators, disabled rules, and date precedence" {
    const p = try std.testing.allocator.create(Preferences);
    defer std.testing.allocator.destroy(p);
    try p.defaults(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 47), p.rule_count);
    const index = try p.include("Example");
    p.rules[index].value.set("10");
    try std.testing.expectEqual(@as(?bool, null), p.meets("Example", 20));
    p.rules[index].enabled = true;
    for ([_]bool{ true, true, false, false, true, false }, 0..) |expected, op| {
        p.rules[index].operator = op;
        try std.testing.expectEqual(@as(?bool, expected), p.meets("Example", 10));
    }
    p.global_days.set("30");
    p.area_days[0] = .{ .name = .init("Nairobi"), .days = .init("60") };
    p.area_count = 1;
    p.kpi_days[0] = .{ .name = .init("Example"), .days = .init("90") };
    p.kpi_count = 1;
    try std.testing.expectEqual(@as(u32, 90), p.days("Nairobi", "Example"));
    try std.testing.expectEqual(@as(u32, 60), p.days("Nairobi", "Other"));
    try std.testing.expectEqual(@as(u32, 30), p.days("Other", "Other"));
    p.font_size.set("25");
    try std.testing.expectError(error.TextSizeMustBe12To24, p.validate());
}

test "settings survive an atomic round trip" {
    const allocator = std.testing.allocator;
    const p = try allocator.create(Preferences);
    defer allocator.destroy(p);
    try p.defaults(allocator);
    p.dark = false;
    p.groups[0] = .{ .name = .init("Radio") };
    p.groups[0].members[0] = true;
    p.group_count = 1;
    p.overlays[0] = .{ .primary = 0 };
    p.overlays[0].members[1] = true;
    p.overlay_count = 1;
    const path = "/tmp/zigzzz-test-settings.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try p.save(allocator, std.testing.io, path);
    const loaded = try allocator.create(Preferences);
    defer allocator.destroy(loaded);
    try loaded.load(allocator, std.testing.io, path);
    try std.testing.expectEqual(false, loaded.dark);
    try std.testing.expectEqual(p.rule_count, loaded.rule_count);
    try std.testing.expectEqual(@as(usize, 1), loaded.group_count);
    try std.testing.expect(loaded.groups[0].members[0]);
    try std.testing.expect(loaded.overlays[0].members[1]);
}
