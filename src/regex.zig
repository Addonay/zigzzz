//! A small case-insensitive regular expression engine for search boxes.
//!
//! Supported syntax: literals, `.`, classes `[a-z_]` and `[^…]`, escapes
//! `\d \w \s \D \W \S \b \B` and `\.`-style literals, anchors `^ $`, groups
//! `( … )` and `(?: … )`, alternation `|`, and the quantifiers
//! `* + ? {m} {m,} {m,n}` with lazy `?` variants.
//!
//! Patterns compile to a tiny instruction program that a backtracking
//! matcher runs against short strings such as column headers. A step budget
//! keeps pathological patterns from stalling the interface.

const std = @import("std");

pub const Span = struct { start: usize, end: usize };

const Op = enum(u8) { char, any, class, start, end, boundary, not_boundary, split, jump, match };

const Instruction = struct {
    op: Op,
    /// Character, class index, or first branch target.
    a: u16 = 0,
    /// Second branch target for `split`.
    b: u16 = 0,
};

const Class = std.StaticBitSet(256);

const max_instructions = 512;
const max_classes = 32;
const max_nodes = 256;
const max_children = 512;
const step_budget = 200_000;

// ── Syntax tree ────────────────────────────────────────────────────────

const Node = union(enum) {
    char: u8,
    any,
    class: u16,
    start,
    end,
    boundary,
    not_boundary,
    /// Children `[first, first + count)` in `children`, matched in order.
    sequence: struct { first: u16, count: u16 },
    /// Alternatives `[first, first + count)` in `children`.
    alternation: struct { first: u16, count: u16 },
    repeat: struct { child: u16, min: u16, max: ?u16, lazy: bool },
};

pub const Regex = struct {
    program: [max_instructions]Instruction = undefined,
    length: u16 = 0,
    classes: [max_classes]Class = undefined,
    class_count: u16 = 0,

    pub fn compile(pattern: []const u8) !Regex {
        var parser = Parser{ .pattern = pattern };
        var regex = Regex{};

        const root = try parser.alternation();
        if (parser.at < pattern.len) return error.UnbalancedParenthesis;

        @memcpy(regex.classes[0..parser.class_count], parser.classes[0..parser.class_count]);
        regex.class_count = parser.class_count;

        try regex.emit(&parser, root);
        try regex.push(.{ .op = .match });

        return regex;
    }

    /// Leftmost match in `input`, or null.
    pub fn find(self: *const Regex, input: []const u8) ?Span {
        var steps: usize = 0;

        for (0..input.len + 1) |start| {
            if (self.run(input, 0, start, &steps)) |end| return .{ .start = start, .end = end };
            if (steps > step_budget) return null;
        }

        return null;
    }

    pub fn matches(self: *const Regex, input: []const u8) bool {
        return self.find(input) != null;
    }

    fn run(self: *const Regex, input: []const u8, start_pc: u16, start_at: usize, steps: *usize) ?usize {
        var pc = start_pc;
        var at = start_at;

        while (true) {
            steps.* += 1;
            if (steps.* > step_budget) return null;

            const instruction = self.program[pc];

            switch (instruction.op) {
                .char => {
                    if (at >= input.len or std.ascii.toLower(input[at]) != instruction.a) return null;
                    at += 1;
                    pc += 1;
                },

                .any => {
                    if (at >= input.len) return null;
                    at += 1;
                    pc += 1;
                },

                .class => {
                    if (at >= input.len or !self.classes[instruction.a].isSet(input[at])) return null;
                    at += 1;
                    pc += 1;
                },

                .start => {
                    if (at != 0) return null;
                    pc += 1;
                },

                .end => {
                    if (at != input.len) return null;
                    pc += 1;
                },

                .boundary, .not_boundary => {
                    const before = at > 0 and isWord(input[at - 1]);
                    const after = at < input.len and isWord(input[at]);
                    const on_boundary = before != after;

                    if (on_boundary != (instruction.op == .boundary)) return null;
                    pc += 1;
                },

                .split => {
                    if (self.run(input, instruction.a, at, steps)) |end| return end;
                    pc = instruction.b;
                },

                .jump => pc = instruction.a,

                .match => return at,
            }
        }
    }

    fn push(self: *Regex, instruction: Instruction) !void {
        if (self.length == max_instructions) return error.PatternTooLong;

        self.program[self.length] = instruction;
        self.length += 1;
    }

    fn emit(self: *Regex, parser: *const Parser, index: u16) !void {
        switch (parser.nodes[index]) {
            .char => |value| try self.push(.{ .op = .char, .a = value }),
            .any => try self.push(.{ .op = .any }),
            .class => |value| try self.push(.{ .op = .class, .a = value }),
            .start => try self.push(.{ .op = .start }),
            .end => try self.push(.{ .op = .end }),
            .boundary => try self.push(.{ .op = .boundary }),
            .not_boundary => try self.push(.{ .op = .not_boundary }),

            .sequence => |list| {
                for (parser.children[list.first..][0..list.count]) |child| try self.emit(parser, child);
            },

            .alternation => |list| {
                // split L1, next; L1: a; jump end; next: split L2, … ; last
                var jumps: [64]u16 = undefined;
                var jump_count: usize = 0;

                for (parser.children[list.first..][0..list.count], 0..) |child, at| {
                    const last = at + 1 == list.count;

                    if (last) {
                        try self.emit(parser, child);
                        break;
                    }

                    const split = self.length;
                    try self.push(.{ .op = .split, .a = split + 1 });
                    try self.emit(parser, child);

                    if (jump_count == jumps.len) return error.PatternTooLong;
                    jumps[jump_count] = self.length;
                    jump_count += 1;
                    try self.push(.{ .op = .jump });

                    self.program[split].b = self.length;
                }

                for (jumps[0..jump_count]) |jump| self.program[jump].a = self.length;
            },

            .repeat => |value| {
                for (0..value.min) |_| try self.emit(parser, value.child);

                if (value.max) |max| {
                    // Optional copies: each one may be skipped to the end.
                    var exits: [64]u16 = undefined;
                    var exit_count: usize = 0;

                    for (value.min..max) |_| {
                        if (exit_count == exits.len) return error.PatternTooLong;

                        exits[exit_count] = self.length;
                        exit_count += 1;
                        try self.push(.{ .op = .split });
                        try self.emit(parser, value.child);
                    }

                    for (exits[0..exit_count]) |split| self.setSplit(split, split + 1, self.length, value.lazy);
                } else {
                    // loop: split body, out; body; jump loop; out:
                    const loop = self.length;
                    try self.push(.{ .op = .split });
                    try self.emit(parser, value.child);
                    try self.push(.{ .op = .jump, .a = loop });

                    self.setSplit(loop, loop + 1, self.length, value.lazy);
                }
            },
        }
    }

    /// Greedy splits try the body first; lazy splits try leaving first.
    fn setSplit(self: *Regex, at: u16, body: u16, out: u16, lazy: bool) void {
        self.program[at].a = if (lazy) out else body;
        self.program[at].b = if (lazy) body else out;
    }
};

fn isWord(value: u8) bool {
    return std.ascii.isAlphanumeric(value) or value == '_';
}

// ── Parser ─────────────────────────────────────────────────────────────

const Parser = struct {
    pattern: []const u8,
    at: usize = 0,
    nodes: [max_nodes]Node = undefined,
    node_count: u16 = 0,
    children: [max_children]u16 = undefined,
    child_count: u16 = 0,
    classes: [max_classes]Class = undefined,
    class_count: u16 = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.at < self.pattern.len) self.pattern[self.at] else null;
    }

    fn node(self: *Parser, value: Node) !u16 {
        if (self.node_count == max_nodes) return error.PatternTooLong;

        self.nodes[self.node_count] = value;
        self.node_count += 1;
        return self.node_count - 1;
    }

    fn list(self: *Parser, items: []const u16) !u16 {
        if (self.child_count + items.len > max_children) return error.PatternTooLong;

        const first = self.child_count;
        @memcpy(self.children[first..][0..items.len], items);
        self.child_count += @intCast(items.len);
        return first;
    }

    fn alternation(self: *Parser) anyerror!u16 {
        var options: [32]u16 = undefined;
        var count: usize = 0;

        options[0] = try self.sequence();
        count = 1;

        while (self.peek() == '|') {
            self.at += 1;
            if (count == options.len) return error.PatternTooLong;

            options[count] = try self.sequence();
            count += 1;
        }

        if (count == 1) return options[0];

        const first = try self.list(options[0..count]);
        return self.node(.{ .alternation = .{ .first = first, .count = @intCast(count) } });
    }

    fn sequence(self: *Parser) !u16 {
        var items: [128]u16 = undefined;
        var count: usize = 0;

        while (self.peek()) |next| {
            if (next == '|' or next == ')') break;
            if (count == items.len) return error.PatternTooLong;

            items[count] = try self.repeat();
            count += 1;
        }

        const first = try self.list(items[0..count]);
        return self.node(.{ .sequence = .{ .first = first, .count = @intCast(count) } });
    }

    fn repeat(self: *Parser) !u16 {
        var result = try self.atom();

        while (self.peek()) |next| {
            var min: u16 = 0;
            var max: ?u16 = null;

            switch (next) {
                '*' => self.at += 1,

                '+' => {
                    self.at += 1;
                    min = 1;
                },

                '?' => {
                    self.at += 1;
                    max = 1;
                },

                '{' => {
                    const bounds = self.braces() orelse break;
                    min = bounds.min;
                    max = bounds.max;
                },

                else => break,
            }

            if (max) |limit| {
                if (limit < min or limit > 32) return error.InvalidRepeat;
            } else if (min > 32) {
                return error.InvalidRepeat;
            }

            const lazy = self.peek() == '?';
            if (lazy) self.at += 1;

            result = try self.node(.{ .repeat = .{ .child = result, .min = min, .max = max, .lazy = lazy } });
        }

        return result;
    }

    /// `{m}`, `{m,}`, or `{m,n}`; a lone `{` is treated as a literal.
    fn braces(self: *Parser) ?struct { min: u16, max: ?u16 } {
        const close = std.mem.indexOfScalarPos(u8, self.pattern, self.at, '}') orelse return null;
        const body = self.pattern[self.at + 1 .. close];

        if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
            const min = std.fmt.parseInt(u16, body[0..comma], 10) catch return null;
            const rest = body[comma + 1 ..];
            const max: ?u16 = if (rest.len == 0) null else std.fmt.parseInt(u16, rest, 10) catch return null;

            self.at = close + 1;
            return .{ .min = min, .max = max };
        }

        const exact = std.fmt.parseInt(u16, body, 10) catch return null;
        self.at = close + 1;
        return .{ .min = exact, .max = exact };
    }

    fn atom(self: *Parser) !u16 {
        const next = self.peek() orelse return error.UnexpectedEnd;
        self.at += 1;

        switch (next) {
            '(' => {
                if (std.mem.startsWith(u8, self.pattern[self.at..], "?:")) self.at += 2;

                const inner = try self.alternation();
                if (self.peek() != ')') return error.UnbalancedParenthesis;

                self.at += 1;
                return inner;
            },

            '[' => return self.bracket(),
            '.' => return self.node(.any),
            '^' => return self.node(.start),
            '$' => return self.node(.end),
            '*', '+', '?' => return error.NothingToRepeat,
            '\\' => return self.escape(),
            else => return self.node(.{ .char = std.ascii.toLower(next) }),
        }
    }

    fn escape(self: *Parser) !u16 {
        const next = self.peek() orelse return error.UnexpectedEnd;
        self.at += 1;

        switch (next) {
            'b' => return self.node(.boundary),
            'B' => return self.node(.not_boundary),

            'd', 'w', 's', 'D', 'W', 'S' => {
                var class = Class.empty;
                addShorthand(&class, std.ascii.toLower(next));

                if (std.ascii.isUpper(next)) class.toggleAll();
                return self.newClass(class);
            },

            't' => return self.node(.{ .char = '\t' }),
            'n' => return self.node(.{ .char = '\n' }),
            else => return self.node(.{ .char = std.ascii.toLower(next) }),
        }
    }

    fn bracket(self: *Parser) !u16 {
        var class = Class.empty;
        var negate = false;

        if (self.peek() == '^') {
            negate = true;
            self.at += 1;
        }

        var first = true;

        while (self.peek()) |next| {
            if (next == ']' and !first) break;

            first = false;
            self.at += 1;

            var low = next;

            if (next == '\\') {
                const escaped = self.peek() orelse return error.UnexpectedEnd;
                self.at += 1;

                if (std.mem.indexOfScalar(u8, "dwsDWS", escaped) != null) {
                    var shorthand = Class.empty;
                    addShorthand(&shorthand, std.ascii.toLower(escaped));
                    if (std.ascii.isUpper(escaped)) shorthand.toggleAll();

                    class.setUnion(shorthand);
                    continue;
                }

                low = escaped;
            }

            var high = low;
            const is_range = self.at + 1 < self.pattern.len and self.pattern[self.at] == '-' and self.pattern[self.at + 1] != ']';

            if (is_range) {
                high = self.pattern[self.at + 1];
                self.at += 2;
                if (high < low) return error.InvalidRange;
            }

            var value: usize = low;
            while (value <= high) : (value += 1) addCaseless(&class, @intCast(value));
        }

        if (self.peek() != ']') return error.UnbalancedBracket;
        self.at += 1;

        if (negate) class.toggleAll();
        return self.newClass(class);
    }

    fn newClass(self: *Parser, class: Class) !u16 {
        if (self.class_count == max_classes) return error.PatternTooLong;

        self.classes[self.class_count] = class;
        self.class_count += 1;
        return self.node(.{ .class = self.class_count - 1 });
    }
};

fn addCaseless(class: *Class, value: u8) void {
    class.set(value);
    class.set(std.ascii.toLower(value));
    class.set(std.ascii.toUpper(value));
}

fn addShorthand(class: *Class, kind: u8) void {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const included = switch (kind) {
            'd' => std.ascii.isDigit(byte),
            'w' => isWord(byte),
            's' => std.ascii.isWhitespace(byte),
            else => false,
        };

        if (included) class.set(byte);
    }
}

// ── Search ranking ─────────────────────────────────────────────────────

/// A compiled search box query. Invalid patterns fall back to a plain
/// case-insensitive substring search, so typing `(` never breaks search.
pub const Query = struct {
    text: []const u8,
    regex: ?Regex,

    pub fn init(text: []const u8) Query {
        const trimmed = std.mem.trim(u8, text, " \t");
        return .{ .text = trimmed, .regex = if (trimmed.len == 0) null else Regex.compile(trimmed) catch null };
    }

    pub fn find(self: *const Query, label: []const u8) ?Span {
        if (self.text.len == 0) return .{ .start = 0, .end = 0 };
        if (self.regex) |*regex| return regex.find(label);

        const start = std.ascii.findIgnoreCase(label, self.text) orelse return null;
        return .{ .start = start, .end = start + self.text.len };
    }

    /// Lower is closer: an exact match scores 0, then matches covering more
    /// of the label, then matches nearer its start.
    pub fn score(self: *const Query, label: []const u8) ?f32 {
        const span = self.find(label) orelse return null;
        if (self.text.len == 0) return 0;

        const trimmed = std.mem.trim(u8, label, " \t");
        const covered: f32 = @floatFromInt(span.end - span.start);
        const total: f32 = @floatFromInt(@max(1, trimmed.len));

        if (span.end - span.start >= trimmed.len) return 0;

        const uncovered = (total - covered) / total;
        const position: f32 = @floatFromInt(span.start);
        const word_start: f32 = if (span.start == 0 or !isWord(label[span.start - 1])) 0 else 0.5;

        return 1 + uncovered * 4 + @min(position, 40) * 0.02 + word_start;
    }
};

test "regex basics" {
    const cases = [_]struct { pattern: []const u8, input: []const u8, start: ?usize, end: usize = 0 }{
        .{ .pattern = "lat", .input = "LATITUDE", .start = 0, .end = 3 },
        .{ .pattern = "^lon(g|gitude)?$", .input = "Longitude", .start = 0, .end = 9 },
        .{ .pattern = "^lon(g|gitude)?$", .input = "Long", .start = 0, .end = 4 },
        .{ .pattern = "^lon(g|gitude)?$", .input = "Longer", .start = null },
        .{ .pattern = "sec.?az", .input = "Sec-Azmuth", .start = 0, .end = 6 },
        .{ .pattern = "\\bci\\b", .input = "unique ci col", .start = 7, .end = 9 },
        .{ .pattern = "\\bci\\b", .input = "cities", .start = null },
        .{ .pattern = "r[0-9]+", .input = "Sector_R12", .start = 7, .end = 10 },
        .{ .pattern = "[^a-z_]+", .input = "abc_123", .start = 4, .end = 7 },
        .{ .pattern = "a{2,3}", .input = "baaaa", .start = 1, .end = 4 },
        .{ .pattern = "a+?", .input = "aaa", .start = 0, .end = 1 },
        .{ .pattern = "drop|dcr", .input = "3G DCR", .start = 3, .end = 6 },
        .{ .pattern = "\\d+g", .input = "VoLTE 4G", .start = 6, .end = 8 },
    };

    for (cases) |case| {
        const regex = try Regex.compile(case.pattern);
        const span = regex.find(case.input);

        if (case.start) |start| {
            try std.testing.expectEqual(start, span.?.start);
            try std.testing.expectEqual(case.end, span.?.end);
        } else {
            try std.testing.expect(span == null);
        }
    }

    try std.testing.expectError(error.UnbalancedParenthesis, Regex.compile("(ab"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile("+a"));
}

test "query ranking prefers the closest match" {
    const query = Query.init("lat");

    const exact = query.score("LAT").?;
    const prefix = query.score("Latitude").?;
    const inside = query.score("relation_lat_x").?;

    try std.testing.expect(exact < prefix);
    try std.testing.expect(prefix < inside);
    try std.testing.expect(query.score("longitude") == null);

    // Invalid patterns fall back to substring search.
    const literal = Query.init("(4G");
    try std.testing.expect(literal.score("Throughput (4G)") != null);
}
