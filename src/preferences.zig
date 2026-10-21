const std = @import("std");
const assets = @import("assets");
const regex = @import("regex.zig");
pub const Text = @import("text.zig").Text;

pub const operators = [_][]const u8{ ">=", "<=", ">", "<", "==", "!=" };
pub const max_kpis = 512;
pub const max_kml_columns = 64;
pub const max_kml_extras = 16;

/// Built-in KPI groups. A KPI joins the first group whose pattern matches
/// its name (case-insensitive); groups are created only once they have a KPI.
pub const default_groups = [_]struct { name: []const u8, pattern: []const u8 }{
    .{ .name = "Availability", .pattern = "rna|availab" },
    .{ .name = "Drops", .pattern = "drop|dcr" },
    .{ .name = "Mobility", .pattern = "^ho\\b|handover|srvcc|csfb" },
    .{ .name = "Accessibility", .pattern = "cssr|setup|attach|\\brrc\\b|paging|\\bpsr\\b|success|addition" },
    .{ .name = "Throughput", .pattern = "throughput" },
    .{ .name = "Utilization", .pattern = "utili|blocking" },
    .{ .name = "Radio quality", .pattern = "cqi|qual|latency|packet loss" },
    .{ .name = "Traffic", .pattern = "traffic|volume" },
    .{ .name = "Data integrity", .pattern = "integrity" },
    .{ .name = "Sites & cells", .pattern = "\\bsites?$|\\bcells$" },
};

/// A remembered KML column choice: the field key and the header it maps
/// to. An empty header means the field was deliberately left unmapped.
pub const KmlColumn = struct {
    key: Text = .{},
    header: Text = .{},
};

pub const KmlExtra = struct {
    label: Text = .{},
    header: Text = .{},
};

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
    groups_seeded: bool = false,
    overlays: std.json.Value = .null,
    kml: std.json.Value = .null,
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
    groups_seeded: bool = false,

    // KML generation defaults, remembered from the KML page.
    kml_columns: [max_kml_columns]KmlColumn = undefined,
    kml_column_count: usize = 0,
    kml_extras: [max_kml_extras]KmlExtra = undefined,
    kml_extra_count: usize = 0,
    kml_folder: Text = .{},
    kml_sectors: bool = true,
    kml_limit_range: bool = false,

    pub fn defaults(result: *Preferences, allocator: std.mem.Allocator) !void {
        result.* = .{};
        const parsed = try std.json.parseFromSlice([]RawRule, allocator, assets.thresholds, .{});
        defer parsed.deinit();

        for (parsed.value) |rule| try result.includeRule(rule.name, rule.operator, rule.value);
        result.seedGroups();
    }

    // ── Default groups ─────────────────────────────────────────────────

    /// Put every ungrouped KPI into its default group, once per settings
    /// file. Groups the user deletes afterwards stay deleted.
    pub fn seedGroups(self: *Preferences) void {
        for (0..self.rule_count) |index| self.groupByDefault(index);
        self.groups_seeded = true;
    }

    /// Add one ungrouped KPI to the first default group whose pattern
    /// matches its name, creating that group if needed.
    pub fn groupByDefault(self: *Preferences, index: usize) void {
        if (index >= self.rule_count) return;

        for (self.groups[0..self.group_count]) |*group| {
            if (group.members[index]) return;
        }

        const name = self.rules[index].name.slice();

        for (default_groups) |candidate| {
            const pattern = regex.Regex.compile(candidate.pattern) catch continue;
            if (!pattern.matches(name)) continue;

            for (self.groups[0..self.group_count]) |*group| {
                if (std.mem.eql(u8, group.name.slice(), candidate.name)) {
                    group.members[index] = true;
                    return;
                }
            }

            if (self.group_count == self.groups.len) return;

            self.groups[self.group_count] = .{ .name = .init(candidate.name) };
            self.groups[self.group_count].members[index] = true;
            self.group_count += 1;
            return;
        }
    }

    // ── KML defaults ───────────────────────────────────────────────────

    /// The remembered header for a KML field: null when nothing is
    /// remembered, "" when the field was deliberately left unmapped.
    pub fn kmlColumn(self: *const Preferences, key: []const u8) ?[]const u8 {
        for (self.kml_columns[0..self.kml_column_count]) |*column| {
            if (std.mem.eql(u8, column.key.slice(), key)) return column.header.slice();
        }

        return null;
    }

    pub fn setKmlColumn(self: *Preferences, key: []const u8, header: []const u8) void {
        for (self.kml_columns[0..self.kml_column_count]) |*column| {
            if (std.mem.eql(u8, column.key.slice(), key)) {
                column.header.set(header);
                return;
            }
        }

        if (self.kml_column_count == self.kml_columns.len) return;

        self.kml_columns[self.kml_column_count] = .{ .key = .init(key), .header = .init(header) };
        self.kml_column_count += 1;
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

        if (self.groups_seeded != other.groups_seeded) return false;
        if (self.kml_sectors != other.kml_sectors or self.kml_limit_range != other.kml_limit_range) return false;
        if (!same(&self.kml_folder, &other.kml_folder)) return false;
        if (self.kml_column_count != other.kml_column_count or self.kml_extra_count != other.kml_extra_count) return false;

        for (self.kml_columns[0..self.kml_column_count], other.kml_columns[0..other.kml_column_count]) |*a, *b| {
            if (!same(&a.key, &b.key) or !same(&a.header, &b.header)) return false;
        }

        for (self.kml_extras[0..self.kml_extra_count], other.kml_extras[0..other.kml_extra_count]) |*a, *b| {
            if (!same(&a.label, &b.label) or !same(&a.header, &b.header)) return false;
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

        if (parsed.value.kml == .object) try result.loadKml(parsed.value.kml.object);

        // Settings written before default groups existed get them once.
        if (parsed.value.groups_seeded) result.groups_seeded = true else result.seedGroups();

        try result.validate();
    }

    fn loadKml(self: *Preferences, object: std.json.ObjectMap) !void {
        if (object.get("columns")) |columns| {
            if (columns != .object) return error.InvalidSettings;

            var iterator = columns.object.iterator();

            while (iterator.next()) |item| {
                const header = switch (item.value_ptr.*) {
                    .string => |value| value,
                    .null => "",
                    else => return error.InvalidSettings,
                };

                self.setKmlColumn(item.key_ptr.*, header);
            }
        }

        if (object.get("extras")) |extras| {
            if (extras != .array) return error.InvalidSettings;

            for (extras.array.items) |item| {
                if (item != .object or self.kml_extra_count == self.kml_extras.len) return error.InvalidSettings;

                const label = item.object.get("label") orelse return error.InvalidSettings;
                const header = item.object.get("header") orelse return error.InvalidSettings;
                if (label != .string or header != .string) return error.InvalidSettings;

                self.kml_extras[self.kml_extra_count] = .{ .label = .init(label.string), .header = .init(header.string) };
                self.kml_extra_count += 1;
            }
        }

        if (object.get("folder")) |folder| {
            if (folder != .string) return error.InvalidSettings;
            self.kml_folder.set(folder.string);
        }

        if (object.get("sectors")) |value| {
            if (value != .bool) return error.InvalidSettings;
            self.kml_sectors = value.bool;
        }

        if (object.get("limit_range")) |value| {
            if (value != .bool) return error.InvalidSettings;
            self.kml_limit_range = value.bool;
        }
    }

    fn kmlJson(self: *const Preferences, memory: std.mem.Allocator) !std.json.Value {
        var columns: std.json.ObjectMap = .empty;

        for (self.kml_columns[0..self.kml_column_count]) |*column| {
            const header = column.header.slice();
            try columns.put(memory, column.key.slice(), if (header.len == 0) .null else .{ .string = header });
        }

        var extras = std.json.Array.init(memory);

        for (self.kml_extras[0..self.kml_extra_count]) |*extra| {
            var item: std.json.ObjectMap = .empty;
            try item.put(memory, "label", .{ .string = extra.label.slice() });
            try item.put(memory, "header", .{ .string = extra.header.slice() });
            try extras.append(.{ .object = item });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(memory, "columns", .{ .object = columns });
        try result.put(memory, "extras", .{ .array = extras });
        try result.put(memory, "folder", .{ .string = self.kml_folder.slice() });
        try result.put(memory, "sectors", .{ .bool = self.kml_sectors });
        try result.put(memory, "limit_range", .{ .bool = self.kml_limit_range });

        return .{ .object = result };
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
            .groups_seeded = self.groups_seeded,
            .area_days = .{ .object = area_map },
            .kpi_days = .{ .object = kpi_map },
            .overlays = .{ .object = overlay_map },
            .kml = try self.kmlJson(memory),
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

test "default groups use short names and stay seeded" {
    const allocator = std.testing.allocator;
    const p = try allocator.create(Preferences);
    defer allocator.destroy(p);
    try p.defaults(allocator);

    const expectations = [_][2][]const u8{
        .{ "2G RNA", "Availability" },
        .{ "5G Session Drop Rate", "Drops" },
        .{ "SRVCC Success Rate (3G & 2G)", "Mobility" },
        .{ "3G CSSR", "Accessibility" },
        .{ "4G Throughput(DL_User_throughput) (Mbps)", "Throughput" },
        .{ "2G_TCH_Blocking", "Utilization" },
        .{ "4G CQI", "Radio quality" },
        .{ "4G Data integrity(%)", "Data integrity" },
    };

    for (expectations) |expectation| {
        const index = p.find(expectation[0]).?;
        var found = false;

        for (p.groups[0..p.group_count]) |*group| {
            if (group.members[index]) {
                try std.testing.expectEqualStrings(expectation[1], group.name.slice());
                found = true;
            }
        }

        try std.testing.expect(found);
    }

    // A KPI seen later in a report joins its group, creating it if needed.
    const traffic = try p.include("Data Traffic (TB)");
    p.groupByDefault(traffic);
    try std.testing.expectEqualStrings("Traffic", p.groups[p.group_count - 1].name.slice());

    // Network inventory rows from real reports.
    for ([_][]const u8{ "2G Sites", "Total Physical Sites", "4G Cells" }) |name| {
        const index = try p.include(name);
        p.groupByDefault(index);
        try std.testing.expectEqualStrings("Sites & cells", p.groups[p.group_count - 1].name.slice());
        try std.testing.expect(p.groups[p.group_count - 1].members[index]);
    }

    // "No. of cells having 4G user throughput <3Mbps" is a throughput KPI.
    const slow_cells = try p.include("No. of cells having 4G user throughput <3Mbps");
    p.groupByDefault(slow_cells);
    try std.testing.expect(!p.groups[p.group_count - 1].members[slow_cells]);

    try p.validate();
}

test "KML defaults survive a round trip" {
    const allocator = std.testing.allocator;
    const p = try allocator.create(Preferences);
    defer allocator.destroy(p);
    try p.defaults(allocator);

    p.setKmlColumn("LAT", "Lat_Deg");
    p.setKmlColumn("Speed", "");
    p.kml_extras[0] = .{ .label = .init("Owner"), .header = .init("owner_name") };
    p.kml_extra_count = 1;
    p.kml_folder.set("/srv/maps");
    p.kml_limit_range = true;

    const path = "/tmp/zigzzz-test-kml-settings.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try p.save(allocator, std.testing.io, path);

    const loaded = try allocator.create(Preferences);
    defer allocator.destroy(loaded);
    try loaded.load(allocator, std.testing.io, path);

    try std.testing.expectEqualStrings("Lat_Deg", loaded.kmlColumn("LAT").?);
    try std.testing.expectEqualStrings("", loaded.kmlColumn("Speed").?);
    try std.testing.expect(loaded.kmlColumn("LONG") == null);
    try std.testing.expectEqualStrings("owner_name", loaded.kml_extras[0].header.slice());
    try std.testing.expectEqualStrings("/srv/maps", loaded.kml_folder.slice());
    try std.testing.expect(loaded.kml_limit_range);
    try std.testing.expect(loaded.equivalent(p));
}
