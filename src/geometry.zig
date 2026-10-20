const sdl = @import("zsdl3");

pub const Color = [4]u8;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn native(self: Rect) sdl.pixels.SDL_FRect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }

    pub fn inset(self: Rect, padding: f32) Rect {
        return .{
            .x = self.x + padding,
            .y = self.y + padding,
            .w = @max(0, self.w - padding * 2),
            .h = @max(0, self.h - padding * 2),
        };
    }

    pub fn expand(self: Rect, amount: f32) Rect {
        return self.inset(-amount);
    }

    pub fn offset(self: Rect, x: f32, y: f32) Rect {
        return .{ .x = self.x + x, .y = self.y + y, .w = self.w, .h = self.h };
    }

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    pub fn centerX(self: Rect) f32 {
        return self.x + self.w / 2;
    }

    pub fn centerY(self: Rect) f32 {
        return self.y + self.h / 2;
    }

    /// A square of `size` centred inside this rectangle.
    pub fn centered(self: Rect, size: f32) Rect {
        return .{
            .x = self.x + (self.w - size) / 2,
            .y = self.y + (self.h - size) / 2,
            .w = size,
            .h = size,
        };
    }

    pub fn intersect(self: Rect, other: Rect) Rect {
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);

        return .{
            .x = left,
            .y = top,
            .w = @max(0, @min(self.right(), other.right()) - left),
            .h = @max(0, @min(self.bottom(), other.bottom()) - top),
        };
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }
};

pub fn f(value: anytype) f32 {
    return @floatFromInt(value);
}

pub fn blend(a: Color, b: Color, amount: f32) Color {
    var result: Color = undefined;

    for (0..4) |index| {
        result[index] = @intFromFloat(f(a[index]) + (f(b[index]) - f(a[index])) * amount);
    }

    return result;
}

/// Mix `tint` over `base` the way CSS `color/opacity` over a solid surface
/// would look, keeping the result opaque.
pub fn tint(base: Color, color: Color, amount: f32) Color {
    var result = blend(base, color, amount);
    result[3] = base[3];
    return result;
}

/// Scale the alpha channel, e.g. `fade(primary, 0.1)` for `primary/10`.
pub fn fade(color: Color, amount: f32) Color {
    var result = color;
    result[3] = @intFromFloat(@min(255, f(color[3]) * @max(0, amount)));
    return result;
}

/// Exponential smoothing that behaves the same at any frame rate.
pub fn approach(current: f32, target: f32, delta_time: f32, speed: f32) f32 {
    const amount = 1 - @exp(-speed * @max(delta_time, 1.0 / 240.0));
    return current + (target - current) * amount;
}
