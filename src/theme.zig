//! Design tokens.
//!
//! Light mode follows `perpetuity.css` and dark mode follows `graphite.css`.
//! Colors are written in OKLCH exactly as they appear in those files and are
//! converted to sRGB at compile time, so the palettes can be compared with
//! the CSS line by line.

const std = @import("std");
const Color = @import("geometry.zig").Color;

/// Sizes are logical pixels; the window scales them for the display.
pub const toolbar_height: f32 = 52;

/// Windows 11 rounds windows by 8 px; other desktops get a softer corner.
pub const corner_radius: f32 = if (@import("builtin").os.tag == .windows) 8 else 12;

pub const initial_width: c_int = 1280;
pub const initial_height: c_int = 820;
pub const minimum_width: c_int = 760;
pub const minimum_height: c_int = 540;

pub const radius_small: f32 = 4;
pub const radius: f32 = 6;
pub const radius_large: f32 = 10;

pub const Palette = struct {
    dark: bool,

    background: Color,
    foreground: Color,
    card: Color,
    card_foreground: Color,
    popover: Color,
    popover_foreground: Color,
    primary: Color,
    primary_foreground: Color,
    secondary: Color,
    secondary_foreground: Color,
    muted: Color,
    muted_foreground: Color,
    accent: Color,
    accent_foreground: Color,
    destructive: Color,
    destructive_foreground: Color,
    border: Color,
    input: Color,
    ring: Color,

    sidebar: Color,
    sidebar_foreground: Color,
    sidebar_accent: Color,
    sidebar_accent_foreground: Color,
    sidebar_border: Color,

    /// Teal brand mark. In light mode this is the Perpetuity primary; the
    /// Graphite palette is neutral, so dark mode borrows its teal chart hue.
    brand: Color,
    success: Color,
    shadow: Color,
    scrim: Color,
};

pub const light = Palette{
    .dark = false,

    .background = oklch(0.9491, 0.0085, 197.0126),
    .foreground = oklch(0.3772, 0.0619, 212.6640),
    .card = oklch(0.9724, 0.0053, 197.0692),
    .card_foreground = oklch(0.3772, 0.0619, 212.6640),
    .popover = oklch(0.9724, 0.0053, 197.0692),
    .popover_foreground = oklch(0.3772, 0.0619, 212.6640),
    .primary = oklch(0.5624, 0.0947, 203.2755),
    .primary_foreground = oklch(1.0000, 0, 0),
    .secondary = oklch(0.9244, 0.0181, 196.8450),
    .secondary_foreground = oklch(0.3772, 0.0619, 212.6640),
    .muted = oklch(0.9295, 0.0107, 196.9723),
    .muted_foreground = oklch(0.5428, 0.0594, 201.5662),
    .accent = oklch(0.9021, 0.0297, 201.8915),
    .accent_foreground = oklch(0.3772, 0.0619, 212.6640),
    .destructive = oklch(0.5732, 0.1901, 25.5409),
    .destructive_foreground = oklch(1.0000, 0, 0),
    .border = oklch(0.8931, 0.0205, 204.4136),
    .input = oklch(0.9244, 0.0181, 196.8450),
    .ring = oklch(0.5624, 0.0947, 203.2755),

    .sidebar = oklch(0.9280, 0.0183, 205.3151),
    .sidebar_foreground = oklch(0.3772, 0.0619, 212.6640),
    .sidebar_accent = oklch(0.9021, 0.0297, 201.8915),
    .sidebar_accent_foreground = oklch(0.3772, 0.0619, 212.6640),
    .sidebar_border = oklch(0.8931, 0.0205, 204.4136),

    .brand = oklch(0.5624, 0.0947, 203.2755),
    .success = oklch(0.6270, 0.1940, 149.2140),
    .shadow = alpha(oklch(0.3500, 0.0800, 205.0000), 0.16),
    .scrim = alpha(oklch(0.2500, 0.0300, 215.0000), 0.45),
};

pub const dark = Palette{
    .dark = true,

    .background = oklch(0.2178, 0, 0),
    .foreground = oklch(0.8853, 0, 0),
    .card = oklch(0.2435, 0, 0),
    .card_foreground = oklch(0.8853, 0, 0),
    .popover = oklch(0.2435, 0, 0),
    .popover_foreground = oklch(0.8853, 0, 0),
    .primary = oklch(0.7058, 0, 0),
    .primary_foreground = oklch(0.2178, 0, 0),
    .secondary = oklch(0.3092, 0, 0),
    .secondary_foreground = oklch(0.8853, 0, 0),
    .muted = oklch(0.2850, 0, 0),
    .muted_foreground = oklch(0.5999, 0, 0),
    .accent = oklch(0.3715, 0, 0),
    .accent_foreground = oklch(0.8853, 0, 0),
    .destructive = oklch(0.6591, 0.1530, 22.1703),
    .destructive_foreground = oklch(1.0000, 0, 0),
    .border = oklch(0.3290, 0, 0),
    .input = oklch(0.3092, 0, 0),
    .ring = oklch(0.7058, 0, 0),

    .sidebar = oklch(0.2393, 0, 0),
    .sidebar_foreground = oklch(0.8853, 0, 0),
    .sidebar_accent = oklch(0.3715, 0, 0),
    .sidebar_accent_foreground = oklch(0.8853, 0, 0),
    .sidebar_border = oklch(0.3290, 0, 0),

    .brand = oklch(0.7400, 0.1000, 195.0000),
    .success = oklch(0.7230, 0.2190, 149.5790),
    .shadow = alpha(oklch(0.0500, 0, 0), 0.45),
    .scrim = alpha(oklch(0.1000, 0.0200, 220.0000), 0.70),
};

// ── Chart tokens (from ldd's kpi-chart.svelte) ─────────────────────────

/// Twelve or more clearly distinct colors spread across the hue wheel.
pub const series = [_]Color{
    oklch(0.75, 0.18, 30), // red-orange
    oklch(0.72, 0.16, 145), // green
    oklch(0.70, 0.18, 260), // blue
    oklch(0.78, 0.15, 65), // amber
    oklch(0.68, 0.17, 310), // purple
    oklch(0.74, 0.14, 185), // teal
    oklch(0.73, 0.16, 15), // red
    oklch(0.76, 0.13, 110), // lime
    oklch(0.65, 0.18, 285), // indigo
    oklch(0.80, 0.12, 80), // gold
    oklch(0.70, 0.15, 340), // pink
    oklch(0.72, 0.12, 210), // sky
    oklch(0.68, 0.14, 50), // brown
    oklch(0.75, 0.16, 170), // emerald
    oklch(0.67, 0.19, 240), // royal blue
    oklch(0.78, 0.10, 95), // olive
};

pub const passing_line = oklch(0.72, 0.16, 145);
pub const threshold_line = oklch(0.6, 0.15, 250);
pub const tooltip_background = alpha(oklch(0.2, 0.02, 220), 0.95);
pub const tooltip_title: Color = .{ 255, 255, 255, 255 };
pub const tooltip_body: Color = .{ 204, 204, 204, 255 };

// ── Helpers ────────────────────────────────────────────────────────────

pub fn alpha(color: Color, amount: f32) Color {
    var result = color;
    result[3] = @intFromFloat(@round(std.math.clamp(amount, 0, 1) * 255));
    return result;
}

/// Converts a CSS `oklch(L C H)` color to 8-bit sRGB.
pub fn oklch(lightness: f64, chroma: f64, hue: f64) Color {
    @setEvalBranchQuota(100_000);

    const radians = hue * std.math.pi / 180.0;
    const a = chroma * @cos(radians);
    const b = chroma * @sin(radians);

    const l_ = lightness + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = lightness - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = lightness - 0.0894841775 * a - 1.2914855480 * b;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    const red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return .{ encode(red), encode(green), encode(blue), 255 };
}

fn encode(linear: f64) u8 {
    const clamped = std.math.clamp(linear, 0, 1);
    const gamma = if (clamped <= 0.0031308)
        12.92 * clamped
    else
        1.055 * std.math.pow(f64, clamped, 1.0 / 2.4) - 0.055;

    return @intFromFloat(@round(std.math.clamp(gamma, 0, 1) * 255));
}
