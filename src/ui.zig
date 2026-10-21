//! Immediate-mode widgets styled after shadcn/ui.
//!
//! Every widget registers its rectangle for hit testing and keyboard focus,
//! then draws itself. Hover and toggle transitions are eased with a small
//! table of per-widget animation values.

const std = @import("std");
const sdl = @import("sdl3");
const gfx = @import("render.zig");
const geo = @import("geometry.zig");
const theme = @import("theme.zig");
const Text = @import("text.zig").Text;

const Rect = geo.Rect;
const Color = geo.Color;
const fade = geo.fade;

const Widget = struct { id: u64, rect: Rect, text: ?*Text = null };
const Animation = struct { id: u64 = 0, amount: f32 = 0, seen: bool = false };

pub const Style = enum { primary, secondary, outline, ghost, destructive };

pub const Ui = struct {
    renderer: *gfx.Renderer,
    palette: theme.Palette = theme.dark,

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    activate: bool = false,
    submitted: bool = false,
    consumed: bool = false,
    blocked: bool = false,

    hand: bool = false,
    text_cursor: bool = false,
    layer: u32 = 0,

    active: u64 = 0,
    focus: u64 = 0,
    focused_text: ?*Text = null,
    caret: usize = 0,
    select_all: bool = false,

    widgets: [1536]Widget = undefined,
    widget_count: usize = 0,
    animations: [2048]Animation = @splat(.{}),
    delta_time: f32 = 1.0 / 60.0,

    tooltip: []const u8 = "",
    tooltip_anchor: Rect = .{},
    tooltip_amount: f32 = 0,
    hot: u64 = 0,
    previous_hot: u64 = 0,
    hover_since: u64 = 0,

    pub fn begin(self: *Ui, palette: theme.Palette, blocked: bool) void {
        self.palette = palette;
        self.blocked = blocked;
        self.layer = 0;
        self.consumed = false;
        self.hand = false;
        self.text_cursor = false;
        self.widget_count = 0;
        self.tooltip = "";
        self.hot = 0;
    }

    pub fn resetEvents(self: *Ui) void {
        self.pressed = false;
        self.released = false;
        self.activate = false;
        self.submitted = false;
    }

    pub fn press(self: *Ui, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.down = true;
        self.pressed = true;
        self.active = 0;
        self.focused_text = null;
        self.focus = 0;

        var index = self.widget_count;

        while (index > 0) {
            index -= 1;
            const widget = self.widgets[index];

            if (widget.rect.contains(x, y)) {
                self.active = widget.id;
                break;
            }
        }
    }

    pub fn release(self: *Ui, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.down = false;
        self.released = true;
    }

    // ── Hit testing ────────────────────────────────────────────────────

    pub fn id(self: *const Ui, rect: Rect) u64 {
        const values = [_]i32{
            @intFromFloat(rect.x * 4),
            @intFromFloat(rect.y * 4),
            @intFromFloat(rect.w * 4),
            @intFromFloat(rect.h * 4),
            @intCast(self.layer),
        };

        return std.hash.Wyhash.hash(0, std.mem.asBytes(&values));
    }

    pub fn hovered(self: *const Ui, rect: Rect) bool {
        if (self.blocked or !rect.contains(self.mouse_x, self.mouse_y)) return false;

        if (self.renderer.clip_rect) |clip| {
            if (!clip.contains(self.mouse_x, self.mouse_y)) return false;
        }

        return true;
    }

    pub fn isPressed(self: *const Ui, rect: Rect) bool {
        return self.down and self.active == self.id(rect) and self.hovered(rect);
    }

    /// Register `rect` as interactive and report whether it was clicked
    /// (or activated with Enter while focused).
    pub fn hit(self: *Ui, rect: Rect) bool {
        const key = self.id(rect);
        var bounds = rect;

        if (self.renderer.clip_rect) |clip| bounds = rect.intersect(clip);

        if (!self.blocked and bounds.w > 0 and bounds.h > 0 and self.widget_count < self.widgets.len) {
            self.widgets[self.widget_count] = .{ .id = key, .rect = bounds };
            self.widget_count += 1;
        }

        if (self.hovered(rect)) {
            self.hand = true;
            self.hot = key;
            if (self.pressed and self.down and self.active == 0) self.active = key;
        }

        if (!self.blocked and self.focus == key) self.focusRing(rect, theme.radius);

        const mouse_click = self.released and self.active == key and self.hovered(rect);
        const key_click = self.activate and self.focus == key;
        const clicked = !self.blocked and !self.consumed and (mouse_click or key_click);

        if (clicked) self.consumed = true;
        return clicked;
    }

    /// Register a non-interactive surface (a floating bar or panel) so
    /// clicks on it don't fall through to widgets underneath.
    pub fn sink(self: *Ui, rect: Rect) void {
        if (self.blocked or self.widget_count == self.widgets.len) return;

        self.widgets[self.widget_count] = .{ .id = self.id(rect) ^ 0x51c, .rect = rect };
        self.widget_count += 1;
    }

    pub fn focusRing(self: *Ui, rect: Rect, radius: f32) void {
        self.renderer.box(rect.expand(3), fade(self.palette.ring, 0.35), radius + 3);
    }

    /// Eased value that moves toward `target` for the widget `key`.
    pub fn animate(self: *Ui, key: u64, target: f32, speed: f32) f32 {
        var slot: usize = @intCast(key % self.animations.len);

        for (0..8) |probe| {
            const index = (slot + probe) % self.animations.len;
            const candidate = self.animations[index];

            if (candidate.id == 0 or candidate.id == key) {
                slot = index;
                break;
            }
        }

        const animation = &self.animations[slot];

        if (animation.id != key) animation.* = .{ .id = key, .amount = target };

        animation.amount = geo.approach(animation.amount, target, self.delta_time, speed);
        if (@abs(animation.amount - target) < 0.002) animation.amount = target;

        return animation.amount;
    }

    pub fn hoverAmount(self: *Ui, rect: Rect) f32 {
        return self.animate(self.id(rect) ^ 0x9e37, if (self.hovered(rect)) 1 else 0, 18);
    }

    pub fn setTooltip(self: *Ui, rect: Rect, value: []const u8) void {
        if (value.len == 0 or !self.hovered(rect)) return;

        self.tooltip = value;
        self.tooltip_anchor = rect;
    }

    // ── Buttons ────────────────────────────────────────────────────────

    const ButtonColors = struct { fill: Color, text: Color, stroke: ?Color };

    fn buttonColors(self: *Ui, rect: Rect, style: Style, selected: bool) ButtonColors {
        const p = self.palette;
        const amount = self.hoverAmount(rect);
        const pressed = self.isPressed(rect);

        return switch (style) {
            .primary => .{
                .fill = geo.blend(p.primary, fade(p.primary, 0.82), if (pressed) 1 else amount * 0.6),
                .text = p.primary_foreground,
                .stroke = null,
            },
            .secondary => .{
                .fill = geo.blend(p.secondary, p.accent, if (pressed) 1 else amount * 0.8),
                .text = p.secondary_foreground,
                .stroke = null,
            },
            .destructive => .{
                .fill = geo.blend(p.destructive, fade(p.destructive, 0.85), amount),
                .text = p.destructive_foreground,
                .stroke = null,
            },
            .outline => .{
                .fill = if (selected) p.accent else geo.blend(fade(p.accent, 0), p.accent, if (pressed) 1 else amount),
                .text = if (selected) p.accent_foreground else p.foreground,
                .stroke = p.border,
            },
            .ghost => .{
                .fill = if (selected) p.accent else geo.blend(fade(p.accent, 0), p.accent, if (pressed) 1 else amount),
                .text = if (selected or amount > 0.5) p.accent_foreground else p.foreground,
                .stroke = null,
            },
        };
    }

    fn drawButtonFrame(self: *Ui, rect: Rect, colors: ButtonColors, style: Style) void {
        const r = self.renderer;

        if (style == .outline) {
            r.box(rect, if (self.palette.dark) fade(self.palette.input, 0.3) else self.palette.background, theme.radius);
            r.shadow(rect, theme.radius, 2, 1, fade(self.palette.shadow, 0.35));
        }

        if (style == .primary) {
            r.shadow(rect, theme.radius, 3, 1, fade(self.palette.shadow, 0.6));
        }

        r.box(rect, colors.fill, theme.radius);
        if (colors.stroke) |stroke| r.outline(rect, stroke, theme.radius);
    }

    pub fn button(self: *Ui, label: []const u8, rect: Rect, style: Style, selected: bool) bool {
        const clicked = self.hit(rect);
        const colors = self.buttonColors(rect, style, selected);

        self.drawButtonFrame(rect, colors, style);
        self.renderer.centered(label, rect, colors.text, .strong);

        return clicked;
    }

    /// Button with a leading icon. Width is decided by the caller; use
    /// `labelButtonWidth` to size it to its content.
    pub fn labelButton(self: *Ui, icon: gfx.Icon, label: []const u8, rect: Rect, style: Style, selected: bool) bool {
        const r = self.renderer;
        const clicked = self.hit(rect);
        const colors = self.buttonColors(rect, style, selected);

        self.drawButtonFrame(rect, colors, style);

        const content = 16 + 8 + r.textWidth(label, .strong);
        const x = rect.x + (rect.w - content) / 2;

        r.icon(icon, .{ .x = x, .y = rect.centerY() - 8, .w = 16, .h = 16 }, colors.text);
        r.text(label, x + 24, rect.y + (rect.h - r.textHeight(.strong)) / 2, colors.text, .strong);

        return clicked;
    }

    /// Compact variant (12 px text, 14 px icon) for dense toolbars.
    pub fn smallLabelButton(self: *Ui, icon: gfx.Icon, label: []const u8, rect: Rect, style: Style) bool {
        const r = self.renderer;
        const clicked = self.hit(rect);
        const colors = self.buttonColors(rect, style, false);

        self.drawButtonFrame(rect, colors, style);

        const content = 14 + 6 + r.textWidth(label, .small_strong);
        const x = rect.x + (rect.w - content) / 2;

        r.icon(icon, .{ .x = x, .y = rect.centerY() - 7, .w = 14, .h = 14 }, colors.text);
        r.text(label, x + 20, rect.y + (rect.h - r.textHeight(.small_strong)) / 2, colors.text, .small_strong);

        return clicked;
    }

    pub fn smallLabelButtonWidth(self: *const Ui, label: []const u8) f32 {
        return self.renderer.textWidth(label, .small_strong) + 14 + 6 + 20;
    }

    pub fn labelButtonWidth(self: *const Ui, label: []const u8) f32 {
        return self.renderer.textWidth(label, .strong) + 16 + 8 + 28;
    }

    pub fn buttonWidth(self: *const Ui, label: []const u8) f32 {
        return self.renderer.textWidth(label, .strong) + 32;
    }

    /// Square ghost button holding one icon.
    pub fn iconButton(self: *Ui, icon: gfx.Icon, rect: Rect, color: Color, tooltip: []const u8) bool {
        const clicked = self.hit(rect);
        const amount = self.hoverAmount(rect);
        const pressed = self.isPressed(rect);

        if (amount > 0.01 or pressed) {
            self.renderer.box(rect, fade(self.palette.accent, if (pressed) 1 else amount), theme.radius);
        }

        const size: f32 = if (rect.w >= 30) 16 else 14;
        const tint = if (amount > 0.5) geo.blend(color, self.palette.accent_foreground, 0.5) else color;

        self.renderer.icon(icon, rect.centered(size), tint);
        self.setTooltip(rect, tooltip);

        return clicked;
    }

    // ── Inputs ─────────────────────────────────────────────────────────

    pub fn field(self: *Ui, value: *Text, placeholder: []const u8, rect: Rect) bool {
        return self.iconField(null, value, placeholder, rect);
    }

    /// Text input; an optional leading icon such as a search glass.
    pub fn iconField(self: *Ui, icon: ?gfx.Icon, value: *Text, placeholder: []const u8, rect: Rect) bool {
        const r = self.renderer;
        const p = self.palette;
        const previous_count = self.widget_count;
        const active = self.focused_text == value;

        if (active) r.box(rect.expand(3), fade(p.ring, 0.25), theme.radius + 3);

        r.box(rect, if (p.dark) fade(p.input, 0.3) else p.card, theme.radius);
        r.outline(rect, if (active) p.ring else p.border, theme.radius);

        const clicked = self.hit(rect);
        if (self.widget_count > previous_count) self.widgets[self.widget_count - 1].text = value;

        if (clicked) {
            self.focused_text = value;
            self.caret = value.length;
            self.select_all = false;
        }

        if (self.hovered(rect)) {
            self.text_cursor = true;
            self.hand = false;
        }

        var left = rect.x + 12;

        if (icon) |which| {
            r.icon(which, .{ .x = rect.x + 10, .y = rect.centerY() - 8, .w = 16, .h = 16 }, p.muted_foreground);
            left = rect.x + 34;
        }

        const caret = @min(self.caret, value.length);
        const caret_width = r.textWidth(value.slice()[0..caret], .body);
        const visible = rect.right() - left - 12;
        const scroll = if (active) @max(0, caret_width - visible) else 0;

        const previous_clip = r.clipWithin(.{ .x = left - 2, .y = rect.y + 2, .w = rect.right() - left - 6, .h = rect.h - 4 });
        defer r.restoreClip(previous_clip);

        const text_y = rect.y + (rect.h - r.textHeight(.body)) / 2;

        if (active and self.select_all and value.length > 0) {
            r.box(.{
                .x = left - scroll,
                .y = rect.y + 6,
                .w = r.textWidth(value.slice(), .body),
                .h = rect.h - 12,
            }, fade(p.ring, 0.3), 2);
        }

        if (value.length == 0 and !active) {
            r.text(placeholder, left, text_y, p.muted_foreground, .body);
        } else {
            r.text(value.slice(), left - scroll, text_y, p.foreground, .body);
        }

        if (active and !self.select_all and sdl.timer.getMillisecondsSinceInit() % 1000 < 550) {
            r.box(.{
                .x = left - scroll + caret_width,
                .y = rect.y + 8,
                .w = 1,
                .h = rect.h - 16,
            }, p.foreground, 0);
        }

        return clicked;
    }

    pub fn checkbox(self: *Ui, label: []const u8, checked: bool, rect: Rect) bool {
        const r = self.renderer;
        const p = self.palette;
        const clicked = self.hit(rect);
        const amount = self.animate(self.id(rect) ^ 0xc4ec, if (checked) 1 else 0, 22);
        const box_rect = Rect{ .x = rect.x, .y = rect.centerY() - 8, .w = 16, .h = 16 };

        if (self.hovered(rect) and !checked) r.box(box_rect.expand(3), fade(p.ring, 0.15), 7);

        r.box(box_rect, geo.blend(if (p.dark) fade(p.input, 0.3) else p.card, p.primary, amount), theme.radius_small);
        r.outline(box_rect, geo.blend(p.border, p.primary, amount), theme.radius_small);

        if (amount > 0.05) {
            r.icon(.check, box_rect.centered(12), fade(p.primary_foreground, amount));
        }

        if (label.len > 0) {
            const previous = r.clipWithin(.{ .x = rect.x + 26, .y = rect.y, .w = rect.w - 26, .h = rect.h });
            r.leading(label, .{ .x = rect.x + 26, .y = rect.y, .w = rect.w - 26, .h = rect.h }, p.foreground, .body);
            r.restoreClip(previous);
        }

        return clicked;
    }

    /// Switch with an animated thumb. Expects a 36×20 rectangle.
    pub fn toggle(self: *Ui, checked: bool, rect: Rect) bool {
        const r = self.renderer;
        const p = self.palette;
        const clicked = self.hit(rect);
        const amount = self.animate(self.id(rect) ^ 0x5717, if (checked) 1 else 0, 20);

        const track = geo.blend(if (p.dark) p.input else p.border, p.primary, amount);
        r.box(rect, track, rect.h / 2);

        const thumb_size = rect.h - 4;
        const travel = rect.w - thumb_size - 4;
        const thumb = Rect{ .x = rect.x + 2 + travel * amount, .y = rect.y + 2, .w = thumb_size, .h = thumb_size };

        r.shadow(thumb, thumb_size / 2, 2, 1, fade(p.shadow, 0.8));
        r.box(thumb, if (p.dark) geo.blend(p.foreground, p.primary_foreground, amount) else p.card, thumb_size / 2);

        return clicked;
    }

    /// Segmented control (shadcn tabs list). Returns the clicked index.
    pub fn segmented(self: *Ui, labels: []const []const u8, selected: usize, rect: Rect) ?usize {
        const r = self.renderer;
        const p = self.palette;
        const key = self.id(rect) ^ 0x5e9;

        r.box(rect, p.muted, theme.radius + 2);

        const inner = rect.inset(3);
        const width = inner.w / geo.f(labels.len);
        const position = self.animate(key, geo.f(selected), 16);
        const indicator = Rect{ .x = inner.x + width * position, .y = inner.y, .w = width, .h = inner.h };

        r.shadow(indicator, theme.radius, 3, 1, fade(p.shadow, if (p.dark) 0.6 else 0.5));
        r.box(indicator, if (p.dark) p.accent else p.card, theme.radius);

        var result: ?usize = null;

        for (labels, 0..) |label, index| {
            const segment = Rect{ .x = inner.x + width * geo.f(index), .y = inner.y, .w = width, .h = inner.h };

            if (self.hit(segment)) result = index;

            const is_selected = index == selected;
            const color = if (is_selected) p.foreground else if (self.hovered(segment)) p.foreground else p.muted_foreground;

            r.centered(label, segment, color, .small_strong);
        }

        return result;
    }

    /// Width a segmented control needs to fit its labels comfortably.
    pub fn segmentedWidth(self: *const Ui, labels: []const []const u8) f32 {
        var widest: f32 = 0;

        for (labels) |label| widest = @max(widest, self.renderer.textWidth(label, .small_strong));

        return (widest + 20) * geo.f(labels.len) + 6;
    }

    /// Small rounded label. Draw only — no interaction.
    pub fn badge(self: *Ui, label: []const u8, rect: Rect, foreground: Color, background: Color) void {
        self.renderer.box(rect, background, theme.radius_small);
        self.renderer.centered(label, rect, foreground, .tiny);
    }

    pub fn badgeWidth(self: *const Ui, label: []const u8) f32 {
        return self.renderer.textWidth(label, .tiny) + 12;
    }

    /// Thin rounded scrollbar thumb for a scrolled region.
    pub fn scrollbar(self: *Ui, area: Rect, scroll: f32, scroll_max: f32) void {
        if (scroll_max <= 0) return;

        const track = Rect{ .x = area.right() - 8, .y = area.y + 4, .w = 6, .h = area.h - 8 };
        const amount = self.animate(self.id(track) ^ 0x5c, if (self.hovered(area)) 1 else 0, 10);
        const thumb_height = @max(32, track.h * track.h / (track.h + scroll_max));
        const thumb = Rect{
            .x = track.x + 1,
            .y = track.y + (track.h - thumb_height) * scroll / scroll_max,
            .w = 4,
            .h = thumb_height,
        };

        self.renderer.box(thumb, fade(self.palette.muted_foreground, 0.25 + amount * 0.25), 2);
    }

    // ── Text editing ───────────────────────────────────────────────────

    pub fn insert(self: *Ui, value: []const u8) void {
        const text = self.focused_text orelse return;

        if (self.select_all) {
            text.set("");
            self.caret = 0;
            self.select_all = false;
        }

        self.caret += text.insert(self.caret, value);
    }

    pub fn keyboard(self: *Ui, event: sdl.events.Keyboard) bool {
        const ctrl = event.mod.left_control or event.mod.right_control;

        if (self.focused_text) |value| {
            self.caret = @min(self.caret, value.length);

            if (ctrl and event.key == .a) {
                self.select_all = true;
                self.caret = value.length;
                return true;
            }

            if (ctrl and event.key == .v) {
                if (sdl.clipboard.getText()) |clipboard| {
                    defer sdl.free(clipboard);
                    self.insert(clipboard);
                } else |_| {}

                return true;
            }

            if (ctrl and event.key == .c) {
                if (self.select_all) {
                    var buffer: [513:0]u8 = @splat(0);
                    @memcpy(buffer[0..value.length], value.slice());
                    sdl.clipboard.setText(buffer[0..value.length :0]) catch {};
                }

                return true;
            }

            switch (event.key orelse return false) {
                .backspace, .delete => {
                    if (self.select_all) {
                        value.set("");
                        self.caret = 0;
                        self.select_all = false;
                    } else if (event.key == .backspace and self.caret > 0) {
                        const before = value.previous(self.caret);
                        value.remove(before, self.caret);
                        self.caret = before;
                    } else if (event.key == .delete) {
                        value.remove(self.caret, value.next(self.caret));
                    }

                    return true;
                },

                .left => {
                    self.caret = value.previous(self.caret);
                    self.select_all = false;
                    return true;
                },

                .right => {
                    self.caret = value.next(self.caret);
                    self.select_all = false;
                    return true;
                },

                .home => {
                    self.caret = 0;
                    self.select_all = false;
                    return true;
                },

                .end => {
                    self.caret = value.length;
                    self.select_all = false;
                    return true;
                },

                .return_key => {
                    self.submitted = true;
                    return true;
                },

                .escape => {
                    self.focused_text = null;
                    return true;
                },

                else => {},
            }
        }

        if (event.repeat) return false;

        if (event.key == .tab and self.widget_count > 0) {
            var current = self.widget_count - 1;

            for (self.widgets[0..self.widget_count], 0..) |widget, index| {
                if (widget.id == self.focus) {
                    current = index;
                    break;
                }
            }

            const backwards = event.mod.left_shift or event.mod.right_shift;
            const index = if (backwards)
                (current + self.widget_count - 1) % self.widget_count
            else
                (current + 1) % self.widget_count;

            self.focus = self.widgets[index].id;
            self.focused_text = self.widgets[index].text;
            if (self.focused_text) |value| self.caret = value.length;

            return true;
        }

        if (event.key == .return_key) {
            self.activate = true;
            return true;
        }

        return false;
    }

    // ── Tooltip ────────────────────────────────────────────────────────

    /// shadcn-style tooltip under the hovered control, after a short delay.
    pub fn drawTooltip(self: *Ui, width: f32, height: f32) void {
        const r = self.renderer;
        const p = self.palette;
        const now = sdl.timer.getMillisecondsSinceInit();

        if (self.hot != self.previous_hot) {
            self.previous_hot = self.hot;
            self.hover_since = now;
            self.tooltip_amount = 0;
        }

        if (self.tooltip.len == 0 or now - self.hover_since < 500 or self.down) {
            self.tooltip_amount = 0;
            return;
        }

        self.tooltip_amount = geo.approach(self.tooltip_amount, 1, self.delta_time, 16);

        const amount = self.tooltip_amount;
        const w = r.textWidth(self.tooltip, .small) + 20;
        const h: f32 = 28;
        const anchor = self.tooltip_anchor;

        var below = true;
        var y = anchor.bottom() + 8;

        if (y + h > height - 8) {
            y = anchor.y - h - 8;
            below = false;
        }

        const rect = Rect{
            .x = std.math.clamp(anchor.centerX() - w / 2, 8, width - w - 8),
            .y = y + (1 - amount) * (if (below) @as(f32, -4) else 4),
            .w = w,
            .h = h,
        };

        const background = fade(p.foreground, amount);
        const arrow_x = std.math.clamp(anchor.centerX(), rect.x + 10, rect.right() - 10);

        r.shadow(rect, theme.radius, 8, 2, fade(p.shadow, amount));
        r.box(rect, background, theme.radius);

        if (below) {
            r.triangle(
                .{ .x = arrow_x - 5, .y = rect.y + 0.5 },
                .{ .x = arrow_x + 5, .y = rect.y + 0.5 },
                .{ .x = arrow_x, .y = rect.y - 4.5 },
                background,
            );
        } else {
            r.triangle(
                .{ .x = arrow_x - 5, .y = rect.bottom() - 0.5 },
                .{ .x = arrow_x + 5, .y = rect.bottom() - 0.5 },
                .{ .x = arrow_x, .y = rect.bottom() + 4.5 },
                background,
            );
        }

        r.centered(self.tooltip, rect, fade(p.background, amount), .small);
    }
};

test "typed keyboard events preserve UTF-8 editing and control shortcuts" {
    var text = Text.init("café");
    var ui = Ui{ .renderer = undefined, .focused_text = &text, .caret = text.length };
    var key = sdl.events.Keyboard{
        .common = .{ .timestamp = 0 },
        .id = null,
        .scancode = null,
        .key = .left,
        .mod = .{},
        .raw = 0,
        .down = true,
        .repeat = false,
    };
    try std.testing.expect(ui.keyboard(key));
    try std.testing.expectEqual(@as(usize, 3), ui.caret);
    key.key = .delete;
    try std.testing.expect(ui.keyboard(key));
    try std.testing.expectEqualStrings("caf", text.slice());
    key.key = .a;
    key.mod.right_control = true;
    try std.testing.expect(ui.keyboard(key));
    try std.testing.expect(ui.select_all);
    key.key = .backspace;
    key.mod = .{};
    try std.testing.expect(ui.keyboard(key));
    try std.testing.expectEqual(@as(usize, 0), text.length);
    try std.testing.expectEqual(@as(usize, 0), ui.caret);
}
