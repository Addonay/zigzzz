//! System scaling, so the interface matches the desktop's size settings.
//!
//! The app lays out everything in logical pixels. A display set to 200%
//! (Windows) or a 2× Wayland output should show the same interface twice as
//! large and twice as sharp, and the user's system text size should enlarge
//! text the way native apps do.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");

pub const Scale = struct {
    /// Window coordinates per logical pixel. Windows reports window sizes
    /// and mouse positions in physical pixels, so at 200% this is 2. On
    /// Wayland and macOS the compositor already works in scaled units and
    /// this stays at the content scale (usually 1).
    ui: f32 = 1,

    /// Output pixels per logical pixel, used to rasterise glyphs and icons
    /// sharply for the real pixel density.
    pixels: f32 = 1,

    /// System text size multiplier (Windows Accessibility → Text size).
    text: f32 = 1,

    pub fn read(window: sdl.video.Window) Scale {
        const display = clamp(window.getDisplayScale() catch 1);
        const density = clamp(window.getPixelDensity() catch 1);

        return .{
            .ui = clamp(display / density),
            .pixels = display,
            .text = systemTextScale(),
        };
    }

    pub fn eql(self: Scale, other: Scale) bool {
        return self.ui == other.ui and self.pixels == other.pixels and self.text == other.text;
    }

    fn clamp(value: f32) f32 {
        if (!std.math.isFinite(value) or value <= 0) return 1;
        return std.math.clamp(value, 0.5, 4);
    }
};

/// Windows' accessibility text size (100–225%), which native apps apply to
/// text only. Other platforms fold text scaling into the content scale.
fn systemTextScale() f32 {
    return if (builtin.os.tag == .windows) windowsTextScale() else 1;
}

fn windowsTextScale() f32 {
    var percent: u32 = 100;
    var size: u32 = @sizeOf(u32);

    const status = RegGetValueW(
        hkey_current_user,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Accessibility"),
        std.unicode.utf8ToUtf16LeStringLiteral("TextScaleFactor"),
        rrf_rt_reg_dword,
        null,
        &percent,
        &size,
    );

    if (status != 0) return 1;
    return std.math.clamp(@as(f32, @floatFromInt(percent)) / 100, 1, 2.25);
}

const hkey_current_user: *anyopaque = @ptrFromInt(0x80000001);
const rrf_rt_reg_dword: u32 = 0x00000010;

extern "advapi32" fn RegGetValueW(
    key: *anyopaque,
    sub_key: [*:0]const u16,
    value: [*:0]const u16,
    flags: u32,
    kind: ?*u32,
    data: ?*anyopaque,
    data_size: ?*u32,
) callconv(.winapi) i32;
