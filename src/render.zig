//! SDL rendering is exclusively through zsdl3. FreeType supplies coverage
//! bitmaps; the app owns the atlases and presents a supersampled frame.
//!
//! Everything here draws in logical (window) coordinates. The frame is
//! rendered into a target twice the output size and filtered down when it
//! is presented, which keeps curves, text, and rounded corners smooth.

const std = @import("std");
const sdl = @import("zsdl3");
const ft = @import("native");
const assets = @import("assets");
const geo = @import("geometry.zig");

const api = sdl.render;
const Rect = geo.Rect;
const Color = geo.Color;
const f = geo.f;

pub const Point = struct { x: f32, y: f32 };

pub const Icon = enum(usize) {
    home,
    panel_close,
    panel_open,
    chart,
    map,
    settings,
    plus,
    chevron_down,
    chevron_right,
    back,
    forward,
    close,
    check,
    download,
    copy,
    expand,
    cloud_upload,
    folder_open,
    minimize,
    maximize,
    restore,
    window_close,
    file,
    map_pin,
    calendar,
    circle_check,
    circle_x,
    circle_help,
    sun,
    moon,
    sliders,
    rotate,
    loader,
    image,
    search,
    layers,
    file_down,
    alert,
    info,
    trash,
    pencil,
    folder,
    activity,
};

pub const FontRole = enum(usize) {
    /// 14 px — default interface text.
    body,
    /// 12 px — descriptions and secondary text.
    small,
    /// 11 px — badges and dense metadata.
    tiny,
    /// 14 px medium — buttons, navigation, and emphasised labels.
    strong,
    /// 12 px medium — pills, chips, and compact controls.
    small_strong,
    /// 16 px semibold — card and section titles.
    heading,
    /// 22 px semibold — page titles.
    title,
    /// 12 px semibold — uppercase chart and group labels.
    label,
    /// 10 px monospace — chart ticks and legends (fixed size).
    mono,
    /// 11 px monospace — chart tooltip rows (fixed size).
    mono_body,
    /// 11 px monospace bold — chart tooltip titles (fixed size).
    mono_bold,
};

const Face = enum { regular, medium, semibold, mono, mono_bold };

const FontSpec = struct { face: Face, size: f32, scales: bool };

const font_specs = [_]FontSpec{
    .{ .face = .regular, .size = 14, .scales = true },
    .{ .face = .regular, .size = 12, .scales = true },
    .{ .face = .regular, .size = 11, .scales = true },
    .{ .face = .medium, .size = 14, .scales = true },
    .{ .face = .medium, .size = 12, .scales = true },
    .{ .face = .semibold, .size = 16, .scales = true },
    .{ .face = .semibold, .size = 22, .scales = true },
    .{ .face = .semibold, .size = 12, .scales = true },
    .{ .face = .mono, .size = 10, .scales = false },
    .{ .face = .mono, .size = 11, .scales = false },
    .{ .face = .mono_bold, .size = 11, .scales = false },
};

const role_count = font_specs.len;

/// Glyphs are rasterised at three times their logical size.
const oversample: f32 = 3;

const Glyph = struct {
    source: Rect = .{},
    left: f32 = 0,
    top: f32 = 0,
    advance: f32 = 0,
};

const Font = struct {
    texture: *api.SDL_Texture,
    glyphs: [256]Glyph,
    size: f32,
    baseline: f32,
};

const ShadowKey = struct { radius: u8, blur: u8 };

const ShadowEntry = struct {
    key: ShadowKey,
    texture: *api.SDL_Texture,
    edge: f32,
};

const icon_levels = [_]usize{ 128, 64, 32 };

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *sdl.video.SDL_Window,
    handle: *api.SDL_Renderer,
    library: ft.FT_Library,

    fonts: [role_count]Font = undefined,
    icons: [assets.icons.len][icon_levels.len]*api.SDL_Texture = undefined,

    rounded: [33]?*api.SDL_Texture = @splat(null),
    rings: [33]?*api.SDL_Texture = @splat(null),
    shadows: [32]?ShadowEntry = @splat(null),

    target: ?*api.SDL_Texture = null,
    target_width: c_int = 0,
    target_height: c_int = 0,
    blur_levels: [5]?*api.SDL_Texture = @splat(null),

    logical_width: f32 = 1,
    logical_height: f32 = 1,
    clip_rect: ?Rect = null,
    vsync: bool = false,

    vertices: std.ArrayList(api.SDL_Vertex) = .empty,
    indices: std.ArrayList(c_int) = .empty,

    pub fn init(allocator: std.mem.Allocator, window: *sdl.video.SDL_Window) !Renderer {
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FontLibrary;
        errdefer _ = ft.FT_Done_FreeType(library);

        const handle = api.createRenderer(window, null) orelse return error.Renderer;
        errdefer api.destroyRenderer(handle);

        var self = Renderer{
            .allocator = allocator,
            .window = window,
            .handle = handle,
            .library = library,
        };

        self.vsync = api.setRenderVSync(handle, 1);
        _ = api.setRenderDrawBlendMode(handle, sdl.pixels.SDL_BLENDMODE_BLEND);

        self.fonts = try self.bakeAll(16);

        for (assets.icons, 0..) |pixels, index| {
            self.icons[index] = try self.iconMips(pixels);
        }

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        for (self.fonts) |font| api.destroyTexture(font.texture);

        for (self.icons) |levels| {
            for (levels) |texture_handle| api.destroyTexture(texture_handle);
        }

        for (self.rounded) |optional| {
            if (optional) |texture_handle| api.destroyTexture(texture_handle);
        }

        for (self.rings) |optional| {
            if (optional) |texture_handle| api.destroyTexture(texture_handle);
        }

        for (self.shadows) |optional| {
            if (optional) |entry| api.destroyTexture(entry.texture);
        }

        for (self.blur_levels) |optional| {
            if (optional) |texture_handle| api.destroyTexture(texture_handle);
        }

        if (self.target) |texture_handle| api.destroyTexture(texture_handle);

        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);

        api.destroyRenderer(self.handle);
        _ = ft.FT_Done_FreeType(self.library);
    }

    // ── Resources ──────────────────────────────────────────────────────

    /// Re-bake the interface fonts for a text size between 12 and 24 px.
    /// Chart fonts keep their fixed size so plots stay comparable.
    pub fn setTextSize(self: *Renderer, size: u32) !void {
        const fonts = try self.bakeAll(size);

        for (self.fonts) |font| api.destroyTexture(font.texture);
        self.fonts = fonts;
    }

    fn bakeAll(self: *Renderer, size: u32) ![role_count]Font {
        var fonts: [role_count]Font = undefined;
        var ready: usize = 0;
        errdefer for (fonts[0..ready]) |font| api.destroyTexture(font.texture);

        const scale = f(size) / 16;

        for (font_specs, 0..) |spec, index| {
            const font_size = if (spec.scales) @round(spec.size * scale * 2) / 2 else spec.size;
            fonts[index] = try self.bake(spec.face, font_size);
            ready += 1;
        }

        return fonts;
    }

    fn texture(self: *Renderer, pixels: []const u8, width: usize, height: usize) !*api.SDL_Texture {
        const result = api.createTexture(
            self.handle,
            sdl.pixels.SDL_PIXELFORMAT_RGBA32,
            api.SDL_TEXTUREACCESS_STATIC,
            @intCast(width),
            @intCast(height),
        ) orelse return error.Texture;
        errdefer api.destroyTexture(result);

        if (!api.updateTexture(result, null, pixels.ptr, @intCast(width * 4))) return error.Texture;

        _ = api.setTextureBlendMode(result, sdl.pixels.SDL_BLENDMODE_BLEND);
        _ = api.setTextureScaleMode(result, .SDL_SCALEMODE_LINEAR);
        return result;
    }

    /// Box-filter the 128 px mask down to 64 and 32 px so small icons are
    /// minified from a nearby level instead of aliasing.
    fn iconMips(self: *Renderer, pixels: []const u8) ![icon_levels.len]*api.SDL_Texture {
        var levels: [icon_levels.len]*api.SDL_Texture = undefined;
        var ready: usize = 0;
        errdefer for (levels[0..ready]) |level| api.destroyTexture(level);

        var current = try self.allocator.dupe(u8, pixels);
        defer self.allocator.free(current);

        for (icon_levels, 0..) |side, index| {
            if (index > 0) {
                const smaller = try self.allocator.alloc(u8, side * side * 4);
                const previous = side * 2;

                for (0..side) |y| {
                    for (0..side) |x| {
                        var total: u32 = 0;

                        for ([_]usize{ 0, 1 }) |dy| {
                            for ([_]usize{ 0, 1 }) |dx| {
                                total += current[((y * 2 + dy) * previous + x * 2 + dx) * 4 + 3];
                            }
                        }

                        const at = (y * side + x) * 4;
                        smaller[at] = 255;
                        smaller[at + 1] = 255;
                        smaller[at + 2] = 255;
                        smaller[at + 3] = @intCast(total / 4);
                    }
                }

                self.allocator.free(current);
                current = smaller;
            }

            levels[index] = try self.texture(current, side, side);
            ready += 1;
        }

        return levels;
    }

    fn faceData(face: Face) []const u8 {
        return switch (face) {
            .regular => assets.regular,
            .medium => assets.medium,
            .semibold => assets.semibold,
            .mono => assets.mono,
            .mono_bold => assets.mono_bold,
        };
    }

    fn bake(self: *Renderer, face_kind: Face, size: f32) !Font {
        const data = faceData(face_kind);

        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(self.library, data.ptr, @intCast(data.len), 0, &face) != 0) return error.Font;
        defer _ = ft.FT_Done_Face(face);

        _ = ft.FT_Set_Pixel_Sizes(face, 0, @intFromFloat(@round(size * oversample)));

        const atlas_side: usize = if (size > 18) 2048 else 1024;
        const pixels = try self.allocator.alloc(u8, atlas_side * atlas_side * 4);
        defer self.allocator.free(pixels);
        @memset(pixels, 0);

        var result: Font = undefined;
        result.size = size;

        const ascent = f(face.*.size.*.metrics.ascender) / 64 / oversample;
        const descent = -f(face.*.size.*.metrics.descender) / 64 / oversample;
        result.baseline = (size * 1.5 - ascent - descent) / 2 + ascent;

        var x: usize = 2;
        var y: usize = 2;
        var row_height: usize = 0;

        for (0..256) |index| {
            const codepoint = glyphCodepoint(index);

            if (ft.FT_Load_Char(face, codepoint, ft.FT_LOAD_RENDER) != 0) {
                result.glyphs[index] = .{};
                continue;
            }

            const glyph = face.*.glyph;
            const bitmap = glyph.*.bitmap;
            const width: usize = bitmap.width;
            const height: usize = bitmap.rows;

            if (x + width + 2 > atlas_side) {
                x = 2;
                y += row_height + 2;
                row_height = 0;
            }

            if (y + height >= atlas_side) return error.FontAtlasFull;

            for (0..height) |py| {
                for (0..width) |px| {
                    const at = ((y + py) * atlas_side + x + px) * 4;
                    const pitch: usize = @intCast(bitmap.pitch);

                    pixels[at] = 255;
                    pixels[at + 1] = 255;
                    pixels[at + 2] = 255;
                    pixels[at + 3] = bitmap.buffer[py * pitch + px];
                }
            }

            result.glyphs[index] = .{
                .source = .{ .x = f(x), .y = f(y), .w = f(width), .h = f(height) },
                .left = f(glyph.*.bitmap_left) / oversample,
                .top = -f(glyph.*.bitmap_top) / oversample,
                .advance = f(glyph.*.advance.x) / 64 / oversample,
            };

            x += width + 2;
            row_height = @max(row_height, height);
        }

        result.texture = try self.texture(pixels, atlas_side, atlas_side);
        return result;
    }

    // ── Frame ──────────────────────────────────────────────────────────

    pub fn begin(self: *Renderer, width: f32, height: f32, background: Color) !void {
        var output_width: c_int = 0;
        var output_height: c_int = 0;
        _ = api.getRenderOutputSize(self.handle, &output_width, &output_height);

        const target_width = output_width * 2;
        const target_height = output_height * 2;

        if (self.target == null or self.target_width != target_width or self.target_height != target_height) {
            if (self.target) |old| api.destroyTexture(old);

            self.target = try self.targetTexture(target_width, target_height);
            self.target_width = target_width;
            self.target_height = target_height;

            for (&self.blur_levels) |*level| {
                if (level.*) |old| api.destroyTexture(old);
                level.* = null;
            }
        }

        self.logical_width = width;
        self.logical_height = height;

        _ = api.setRenderTarget(self.handle, self.target);
        _ = api.setRenderScale(self.handle, f(target_width) / width, f(target_height) / height);

        self.unclip();
        self.color(background);
        _ = api.renderClear(self.handle);
    }

    pub fn finish(self: *Renderer) void {
        self.unclip();

        _ = api.setRenderTarget(self.handle, null);
        _ = api.setRenderScale(self.handle, 1, 1);
        _ = api.renderTexture(self.handle, self.target.?, null, null);
        _ = api.renderPresent(self.handle);
    }

    fn targetTexture(self: *Renderer, width: c_int, height: c_int) !*api.SDL_Texture {
        const result = api.createTexture(
            self.handle,
            sdl.pixels.SDL_PIXELFORMAT_RGBA32,
            api.SDL_TEXTUREACCESS_TARGET,
            @max(1, width),
            @max(1, height),
        ) orelse return error.RenderTarget;

        _ = api.setTextureScaleMode(result, .SDL_SCALEMODE_LINEAR);
        _ = api.setTextureBlendMode(result, sdl.pixels.SDL_BLENDMODE_NONE);
        return result;
    }

    /// Blur everything drawn so far, like CSS `backdrop-filter: blur()`.
    /// The frame is halved five times and scaled back up again, filtering
    /// on every step, which approximates a wide Gaussian cheaply.
    pub fn blurFrame(self: *Renderer) void {
        const target = self.target orelse return;
        const previous_clip = self.clip_rect;

        var sizes: [5][2]f32 = undefined;
        var width = self.target_width;
        var height = self.target_height;

        for (&self.blur_levels, 0..) |*level, index| {
            width = @max(1, @divTrunc(width, 2));
            height = @max(1, @divTrunc(height, 2));
            sizes[index] = .{ f(width), f(height) };

            if (level.* == null) {
                level.* = self.targetTexture(width, height) catch return;
            }
        }

        // Down: each level averages 2×2 blocks of the one above.
        var source = target;

        for (self.blur_levels, sizes) |level, size| {
            _ = api.setRenderTarget(self.handle, level.?);
            _ = api.setRenderScale(self.handle, 1, 1);
            _ = api.setRenderClipRect(self.handle, null);

            self.filterInto(source, size[0], size[1], 0.25);
            source = level.?;
        }

        // Up: each level is smoothed into the one below it.
        var index: usize = self.blur_levels.len - 1;

        while (index > 0) : (index -= 1) {
            _ = api.setRenderTarget(self.handle, self.blur_levels[index - 1].?);
            self.filterInto(self.blur_levels[index].?, sizes[index - 1][0], sizes[index - 1][1], 1);
        }

        _ = api.setRenderTarget(self.handle, target);
        _ = api.setRenderScale(self.handle, 1, 1);
        _ = api.setRenderClipRect(self.handle, null);

        self.filterInto(self.blur_levels[0].?, f(self.target_width), f(self.target_height), 1);

        _ = api.setRenderScale(
            self.handle,
            f(self.target_width) / self.logical_width,
            f(self.target_height) / self.logical_height,
        );

        if (previous_clip) |rect| self.clip(rect) else self.unclip();
    }

    /// Draw `source` over the whole current target as the average of four
    /// copies offset by ±`spread` pixels. With a spread of half a source
    /// texel this is a 2×2 box (going down) or tent (going up) filter,
    /// even on renderers that sample render targets with nearest-neighbour
    /// filtering.
    fn filterInto(self: *Renderer, source: *api.SDL_Texture, width: f32, height: f32, spread: f32) void {
        const offsets = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };

        // Start from black so edge pixels missed by an offset copy never
        // keep stale content.
        self.color(.{ 0, 0, 0, 255 });
        _ = api.renderClear(self.handle);

        _ = api.setTextureColorMod(source, 64, 64, 64);
        _ = api.setTextureAlphaMod(source, 255);
        _ = api.setTextureBlendMode(source, sdl.pixels.SDL_BLENDMODE_ADD);

        for (offsets) |offset| {
            const destination = (Rect{ .x = offset[0] * spread, .y = offset[1] * spread, .w = width, .h = height }).native();
            _ = api.renderTexture(self.handle, source, null, &destination);
        }

        _ = api.setTextureColorMod(source, 255, 255, 255);
        _ = api.setTextureBlendMode(source, sdl.pixels.SDL_BLENDMODE_NONE);
    }

    // ── Shapes ─────────────────────────────────────────────────────────

    pub fn color(self: *Renderer, value: Color) void {
        _ = api.setRenderDrawColor(self.handle, value[0], value[1], value[2], value[3]);
    }

    /// Filled rectangle with optionally rounded corners (radius ≤ 32).
    pub fn box(self: *Renderer, rect: Rect, value: Color, radius: f32) void {
        if (rect.w <= 0 or rect.h <= 0 or value[3] == 0) return;
        const destination = rect.native();

        if (radius <= 0.5) {
            self.color(value);
            _ = api.renderFillRect(self.handle, &destination);
            return;
        }

        const size = roundedSize(radius, rect);
        const texture_handle = self.cornerTexture(&self.rounded, size, false) orelse return;
        const edge = f(size);

        self.tint(texture_handle, value);
        _ = api.renderTexture9Grid(self.handle, texture_handle, null, edge * 4, edge * 4, edge * 4, edge * 4, 0.25, &destination);
    }

    /// A one pixel rounded outline with a transparent centre.
    pub fn outline(self: *Renderer, rect: Rect, value: Color, radius: f32) void {
        if (rect.w <= 0 or rect.h <= 0 or value[3] == 0) return;

        const size = @max(1, roundedSize(radius, rect));
        const texture_handle = self.cornerTexture(&self.rings, size, true) orelse return;
        const edge = f(size);
        const destination = rect.native();

        self.tint(texture_handle, value);
        _ = api.renderTexture9Grid(self.handle, texture_handle, null, edge * 4, edge * 4, edge * 4, edge * 4, 0.25, &destination);
    }

    /// Filled rectangle with a one pixel stroke drawn inside its bounds.
    pub fn border(self: *Renderer, rect: Rect, fill: Color, stroke: Color, radius: f32) void {
        self.box(rect, fill, radius);
        self.outline(rect, stroke, radius);
    }

    pub fn circle(self: *Renderer, x: f32, y: f32, radius: f32, value: Color) void {
        self.box(.{ .x = x - radius, .y = y - radius, .w = radius * 2, .h = radius * 2 }, value, radius);
    }

    fn roundedSize(radius: f32, rect: Rect) usize {
        const limited = @min(radius, @min(rect.w, rect.h) / 2);
        return @intFromFloat(@max(1, @min(32, @round(limited))));
    }

    /// Rounded-rectangle masks rendered at four times their logical size.
    /// The 9-grid scale of 0.25 maps them back to logical units.
    fn cornerTexture(self: *Renderer, cache: *[33]?*api.SDL_Texture, size: usize, ring: bool) ?*api.SDL_Texture {
        if (cache[size]) |existing| return existing;

        const side = (size * 2 + 4) * 4;
        const pixels = self.allocator.alloc(u8, side * side * 4) catch return null;
        defer self.allocator.free(pixels);

        const half = f(side) / 2;
        const corner = f(size * 4);

        for (0..side) |py| {
            for (0..side) |px| {
                const dx = @abs(f(px) + 0.5 - half) - (half - corner);
                const dy = @abs(f(py) + 0.5 - half) - (half - corner);
                const outside = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0));
                const signed = outside + @min(@max(dx, dy), 0) - corner;

                var coverage = std.math.clamp(0.5 - signed, 0, 1);

                if (ring) {
                    // Keep a band four texels (one logical pixel) wide.
                    const inner = std.math.clamp(0.5 - (signed + 4), 0, 1);
                    coverage = @max(0, coverage - inner);
                }

                const at = (py * side + px) * 4;
                pixels[at] = 255;
                pixels[at + 1] = 255;
                pixels[at + 2] = 255;
                pixels[at + 3] = @intFromFloat(coverage * 255);
            }
        }

        cache[size] = self.texture(pixels, side, side) catch return null;
        return cache[size];
    }

    /// Soft drop shadow, similar to CSS `box-shadow: 0 y blur color`.
    pub fn shadow(self: *Renderer, rect: Rect, radius: f32, blur: f32, offset_y: f32, value: Color) void {
        if (rect.w <= 0 or rect.h <= 0 or value[3] == 0) return;

        // The 9-grid corners span 2 × blur + radius; keep them from
        // overlapping on small elements.
        const corner = @min(radius, @min(rect.w, rect.h) / 2);
        const largest_blur = @max(1, (@min(rect.w, rect.h) - 2 * corner) / 2);

        const key = ShadowKey{
            .radius = @intFromFloat(std.math.clamp(@round(corner), 0, 32)),
            .blur = @intFromFloat(std.math.clamp(@round(@min(blur, largest_blur)), 1, 48)),
        };

        const entry = self.shadowTexture(key) orelse return;
        const margin = f(key.blur);
        const destination = (Rect{
            .x = rect.x - margin,
            .y = rect.y - margin + offset_y,
            .w = rect.w + margin * 2,
            .h = rect.h + margin * 2,
        }).native();

        self.tint(entry.texture, value);
        _ = api.renderTexture9Grid(self.handle, entry.texture, null, entry.edge * 2, entry.edge * 2, entry.edge * 2, entry.edge * 2, 0.5, &destination);
    }

    fn shadowTexture(self: *Renderer, key: ShadowKey) ?ShadowEntry {
        var free_slot: ?usize = null;

        for (self.shadows, 0..) |optional, index| {
            if (optional) |entry| {
                if (entry.key.radius == key.radius and entry.key.blur == key.blur) return entry;
            } else if (free_slot == null) {
                free_slot = index;
            }
        }

        const slot = free_slot orelse return null;

        // Two texels per logical pixel. The rectangle inside the texture is
        // inset by `blur`, and its edge fades out over `blur` on each side.
        const blur = f(key.blur);
        const corner = f(key.radius);
        const edge = blur * 2 + corner;
        const side_logical = edge * 2 + 2;
        const side: usize = @intFromFloat(side_logical * 2);

        const pixels = self.allocator.alloc(u8, side * side * 4) catch return null;
        defer self.allocator.free(pixels);

        const half = side_logical / 2;
        const inner_half = half - blur;

        for (0..side) |py| {
            for (0..side) |px| {
                const x = (f(px) + 0.5) / 2;
                const y = (f(py) + 0.5) / 2;
                const dx = @abs(x - half) - (inner_half - corner);
                const dy = @abs(y - half) - (inner_half - corner);
                const outside = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0));
                const signed = outside + @min(@max(dx, dy), 0) - corner;

                const t = std.math.clamp((blur - signed) / (blur * 2), 0, 1);
                const coverage = t * t * (3 - 2 * t);

                const at = (py * side + px) * 4;
                pixels[at] = 255;
                pixels[at + 1] = 255;
                pixels[at + 2] = 255;
                pixels[at + 3] = @intFromFloat(coverage * 255);
            }
        }

        const created = self.texture(pixels, side, side) catch return null;
        const entry = ShadowEntry{ .key = key, .texture = created, .edge = edge };
        self.shadows[slot] = entry;
        return entry;
    }

    /// Crisp horizontal hairline.
    pub fn hline(self: *Renderer, x: f32, right: f32, y: f32, value: Color) void {
        self.box(.{ .x = x, .y = y, .w = right - x, .h = 1 }, value, 0);
    }

    /// Crisp vertical hairline.
    pub fn vline(self: *Renderer, x: f32, y: f32, bottom: f32, value: Color) void {
        self.box(.{ .x = x, .y = y, .w = 1, .h = bottom - y }, value, 0);
    }

    pub fn line(self: *Renderer, x: f32, y: f32, right: f32, bottom: f32, value: Color) void {
        self.polyline(&.{ .{ .x = x, .y = y }, .{ .x = right, .y = bottom } }, 1.2, value);
    }

    /// Antialiased stroke through `points` drawn as one triangle strip, so
    /// joints have no seams or overlapping alpha.
    pub fn polyline(self: *Renderer, points: []const Point, width: f32, value: Color) void {
        if (points.len < 2 or value[3] == 0) return;

        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();

        const core = @max(0, width / 2 - 0.45);
        const outer = width / 2 + 0.45;
        const offsets = [_]f32{ -outer, -core, core, outer };

        const rgba = api.SDL_FColor{
            .r = f(value[0]) / 255,
            .g = f(value[1]) / 255,
            .b = f(value[2]) / 255,
            .a = f(value[3]) / 255,
        };

        var clear = rgba;
        clear.a = 0;

        for (points, 0..) |point, index| {
            const normal = joinNormal(points, index);

            for (offsets, 0..) |offset, column| {
                self.vertices.append(self.allocator, .{
                    .position = .{ .x = point.x + normal.x * offset, .y = point.y + normal.y * offset },
                    .color = if (column == 0 or column == 3) clear else rgba,
                    .tex_coord = .{ .x = 0, .y = 0 },
                }) catch return;
            }

            if (index == 0) continue;

            const a: c_int = @intCast((index - 1) * 4);
            const b: c_int = @intCast(index * 4);

            for (0..3) |band| {
                const k: c_int = @intCast(band);

                self.indices.appendSlice(self.allocator, &.{
                    a + k, b + k, a + k + 1,
                    b + k, b + k + 1, a + k + 1,
                }) catch return;
            }
        }

        _ = api.renderGeometry(
            self.handle,
            null,
            self.vertices.items.ptr,
            @intCast(self.vertices.items.len),
            self.indices.items.ptr,
            @intCast(self.indices.items.len),
        );
    }

    /// Unit normal at a polyline vertex, mitred between the neighbouring
    /// segments and limited so sharp turns don't spike.
    fn joinNormal(points: []const Point, index: usize) Point {
        const previous = if (index > 0) points[index - 1] else points[index];
        const next = if (index + 1 < points.len) points[index + 1] else points[index];

        const before = segmentNormal(previous, points[index]);
        const after = segmentNormal(points[index], next);

        if (index == 0) return after;
        if (index + 1 == points.len) return before;

        var x = before.x + after.x;
        var y = before.y + after.y;
        const length = @sqrt(x * x + y * y);

        if (length < 0.0001) return after;

        x /= length;
        y /= length;

        const dot = @max(0.5, x * after.x + y * after.y);
        return .{ .x = x / dot, .y = y / dot };
    }

    fn segmentNormal(a: Point, b: Point) Point {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = @sqrt(dx * dx + dy * dy);

        if (length < 0.0001) return .{ .x = 0, .y = -1 };
        return .{ .x = -dy / length, .y = dx / length };
    }

    pub fn dashedLine(self: *Renderer, x: f32, y: f32, right: f32, bottom: f32, width: f32, dash: f32, gap: f32, value: Color) void {
        const dx = right - x;
        const dy = bottom - y;
        const length = @sqrt(dx * dx + dy * dy);

        if (length < 0.001) return;

        var travelled: f32 = 0;

        while (travelled < length) : (travelled += dash + gap) {
            const end = @min(length, travelled + dash);

            self.polyline(&.{
                .{ .x = x + dx * travelled / length, .y = y + dy * travelled / length },
                .{ .x = x + dx * end / length, .y = y + dy * end / length },
            }, width, value);
        }
    }

    /// Dashed outline that follows rounded corners, like CSS
    /// `border: 2px dashed` on an element with `border-radius`.
    pub fn dashedRect(self: *Renderer, rect: Rect, radius: f32, width: f32, dash: f32, gap: f32, value: Color) void {
        const r = @min(radius, @min(rect.w, rect.h) / 2);
        const inset = width / 2;
        const left = rect.x + inset;
        const top = rect.y + inset;
        const right = rect.right() - inset;
        const bottom = rect.bottom() - inset;

        // Walk the perimeter clockwise, sampling each corner arc.
        var path: [4 * 10 + 1]Point = undefined;
        var count: usize = 0;

        const corners = [_]struct { cx: f32, cy: f32, start: f32 }{
            .{ .cx = right - r, .cy = top + r, .start = -90 },
            .{ .cx = right - r, .cy = bottom - r, .start = 0 },
            .{ .cx = left + r, .cy = bottom - r, .start = 90 },
            .{ .cx = left + r, .cy = top + r, .start = 180 },
        };

        for (corners) |corner| {
            for (0..10) |step| {
                const angle = (corner.start + 90 * f(step) / 9) * std.math.pi / 180;
                path[count] = .{ .x = corner.cx + r * @cos(angle), .y = corner.cy + r * @sin(angle) };
                count += 1;
            }
        }

        path[count] = .{ .x = left + r, .y = top };
        count += 1;

        // Prepend the start of the top edge so the path is closed.
        var closed: [path.len + 1]Point = undefined;
        closed[0] = .{ .x = left + r, .y = top };
        @memcpy(closed[1 .. count + 1], path[0..count]);

        const points = closed[0 .. count + 1];

        var total: f32 = 0;
        for (1..points.len) |index| total += distance(points[index - 1], points[index]);

        // Fit a whole number of dash periods around the perimeter.
        const period_count = @max(1, @round(total / (dash + gap)));
        const period = total / period_count;
        const dash_length = period * dash / (dash + gap);

        var segment: [64]Point = undefined;
        var start: f32 = 0;

        while (start < total - 0.01) : (start += period) {
            const end = start + dash_length;
            var length: usize = 0;
            var walked: f32 = 0;

            for (1..points.len) |index| {
                const a = points[index - 1];
                const b = points[index];
                const piece = distance(a, b);
                const piece_start = walked;
                const piece_end = walked + piece;
                walked = piece_end;

                if (piece_end < start or piece_start > end or piece < 0.0001) continue;

                const from = std.math.clamp((start - piece_start) / piece, 0, 1);
                const to = std.math.clamp((end - piece_start) / piece, 0, 1);

                if (length == 0) {
                    segment[length] = lerp(a, b, from);
                    length += 1;
                }

                if (length < segment.len) {
                    segment[length] = lerp(a, b, to);
                    length += 1;
                }
            }

            self.polyline(segment[0..length], width, value);
        }
    }

    pub fn triangle(self: *Renderer, a: Point, b: Point, c: Point, value: Color) void {
        const rgba = api.SDL_FColor{
            .r = f(value[0]) / 255,
            .g = f(value[1]) / 255,
            .b = f(value[2]) / 255,
            .a = f(value[3]) / 255,
        };

        var vertices: [3]api.SDL_Vertex = undefined;

        for ([_]Point{ a, b, c }, 0..) |point, index| {
            vertices[index] = .{
                .position = .{ .x = point.x, .y = point.y },
                .color = rgba,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
        }

        _ = api.renderGeometry(self.handle, null, &vertices, 3, null, 0);
    }

    // ── Text ───────────────────────────────────────────────────────────

    fn fontFor(self: *const Renderer, role: FontRole) *const Font {
        return &self.fonts[@intFromEnum(role)];
    }

    pub fn fontSize(self: *const Renderer, role: FontRole) f32 {
        return self.fontFor(role).size;
    }

    pub fn textWidth(self: *const Renderer, value: []const u8, role: FontRole) f32 {
        return self.trackedWidth(value, role, 0);
    }

    pub fn trackedWidth(self: *const Renderer, value: []const u8, role: FontRole, tracking: f32) f32 {
        const selected = self.fontFor(role);
        var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();
        var width: f32 = 0;
        var count: f32 = 0;

        while (iterator.nextCodepoint()) |codepoint| {
            width += selected.glyphs[glyphIndex(codepoint)].advance;
            count += 1;
        }

        return width + @max(0, count - 1) * tracking;
    }

    /// Height of one line box (1.5 × the font size).
    pub fn textHeight(self: *const Renderer, role: FontRole) f32 {
        return self.fontFor(role).size * 1.5;
    }

    pub fn text(self: *Renderer, value: []const u8, x: f32, y: f32, tint_color: Color, role: FontRole) void {
        self.tracked(value, x, y, tint_color, role, 0);
    }

    /// Text with extra letter spacing, like CSS `tracking-wide`.
    pub fn tracked(self: *Renderer, value: []const u8, x: f32, y: f32, tint_color: Color, role: FontRole, tracking: f32) void {
        const selected = self.fontFor(role);
        self.tint(selected.texture, tint_color);

        var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();
        var position = x;

        while (iterator.nextCodepoint()) |codepoint| {
            const glyph = selected.glyphs[glyphIndex(codepoint)];

            if (glyph.source.w > 0) {
                const source = glyph.source.native();
                const destination = (Rect{
                    .x = position + glyph.left,
                    .y = y + selected.baseline + glyph.top,
                    .w = glyph.source.w / oversample,
                    .h = glyph.source.h / oversample,
                }).native();

                _ = api.renderTexture(self.handle, selected.texture, &source, &destination);
            }

            position += glyph.advance + tracking;
        }
    }

    /// Text centred inside `rect`.
    pub fn centered(self: *Renderer, value: []const u8, rect: Rect, tint_color: Color, role: FontRole) void {
        self.text(
            value,
            rect.x + (rect.w - self.textWidth(value, role)) / 2,
            rect.y + (rect.h - self.textHeight(role)) / 2,
            tint_color,
            role,
        );
    }

    /// Text vertically centred in `rect`, starting at its left edge.
    pub fn leading(self: *Renderer, value: []const u8, rect: Rect, tint_color: Color, role: FontRole) void {
        self.text(value, rect.x, rect.y + (rect.h - self.textHeight(role)) / 2, tint_color, role);
    }

    /// Returns `value`, or a prefix with an ellipsis that fits `width`.
    pub fn fit(self: *const Renderer, buffer: []u8, value: []const u8, width: f32, role: FontRole) []const u8 {
        if (self.textWidth(value, role) <= width) return value;

        const ellipsis = "…";
        const available = width - self.textWidth(ellipsis, role);
        var end: usize = 0;
        var used: f32 = 0;
        var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();

        while (iterator.nextCodepointSlice()) |slice| {
            const advance = self.textWidth(slice, role);
            if (used + advance > available) break;

            used += advance;
            end += slice.len;
        }

        if (end + ellipsis.len > buffer.len) return value[0..@min(end, buffer.len)];

        @memcpy(buffer[0..end], value[0..end]);
        @memcpy(buffer[end..][0..ellipsis.len], ellipsis);
        return buffer[0 .. end + ellipsis.len];
    }

    /// Word-wrapped text. Returns the height used.
    pub fn wrappedText(self: *Renderer, value: []const u8, x: f32, y: f32, width: f32, tint_color: Color, role: FontRole) f32 {
        return self.wrap(value, x, y, width, tint_color, role, true);
    }

    pub fn wrappedHeight(self: *Renderer, value: []const u8, width: f32, role: FontRole) f32 {
        return self.wrap(value, 0, 0, width, .{ 0, 0, 0, 0 }, role, false);
    }

    fn wrap(self: *Renderer, value: []const u8, x: f32, y: f32, width: f32, tint_color: Color, role: FontRole, draw: bool) f32 {
        const space = self.textWidth(" ", role);
        var words = std.mem.tokenizeScalar(u8, value, ' ');
        var line_start: usize = 0;
        var line_end: usize = 0;
        var line_width: f32 = 0;
        var yy = y;

        while (words.next()) |word| {
            const start = @intFromPtr(word.ptr) - @intFromPtr(value.ptr);
            const word_width = self.textWidth(word, role);

            if (line_end > line_start and line_width + space + word_width > width) {
                if (draw) self.text(value[line_start..line_end], x, yy, tint_color, role);

                yy += self.textHeight(role);
                line_start = start;
                line_width = 0;
            } else if (line_end == line_start) {
                line_start = start;
            }

            line_width += (if (line_end > line_start) space else 0) + word_width;
            line_end = start + word.len;
        }

        if (draw and line_end > line_start) self.text(value[line_start..line_end], x, yy, tint_color, role);
        return yy - y + self.textHeight(role);
    }

    /// Text rotated about its end point, which sits at (`x`, `y`). Used for
    /// slanted axis labels that end at their tick.
    pub fn rotatedText(self: *Renderer, value: []const u8, x: f32, y: f32, tint_color: Color, role: FontRole, degrees: f64) void {
        const selected = self.fontFor(role);
        self.tint(selected.texture, tint_color);

        const radians: f32 = @floatCast(degrees * std.math.pi / 180);
        const center = api.SDL_FPoint{ .x = 0, .y = 0 };
        var position = -self.textWidth(value, role);
        var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();

        // Centre the line box vertically on the anchor.
        const middle = self.textHeight(role) / 2;

        while (iterator.nextCodepoint()) |codepoint| {
            const glyph = selected.glyphs[glyphIndex(codepoint)];
            const dx = position + glyph.left;
            const dy = selected.baseline + glyph.top - middle;

            const source = glyph.source.native();
            const destination = (Rect{
                .x = x + dx * @cos(radians) - dy * @sin(radians),
                .y = y + dx * @sin(radians) + dy * @cos(radians),
                .w = glyph.source.w / oversample,
                .h = glyph.source.h / oversample,
            }).native();

            _ = api.renderTextureRotated(self.handle, selected.texture, &source, &destination, degrees, &center, .SDL_FLIP_NONE);
            position += glyph.advance;
        }
    }

    // ── Icons ──────────────────────────────────────────────────────────

    fn iconTexture(self: *Renderer, which: Icon, size: f32) *api.SDL_Texture {
        var scale_x: f32 = 1;
        var scale_y: f32 = 1;
        _ = api.getRenderScale(self.handle, &scale_x, &scale_y);

        const pixels = size * @max(scale_x, scale_y);
        const levels = self.icons[@intFromEnum(which)];

        if (pixels <= 40) return levels[2];
        if (pixels <= 80) return levels[1];
        return levels[0];
    }

    pub fn icon(self: *Renderer, which: Icon, rect: Rect, tint_color: Color) void {
        const handle = self.iconTexture(which, rect.w);
        const destination = rect.native();

        self.tint(handle, tint_color);
        _ = api.renderTexture(self.handle, handle, null, &destination);
    }

    pub fn rotatedIcon(self: *Renderer, which: Icon, rect: Rect, tint_color: Color, degrees: f64) void {
        const handle = self.iconTexture(which, rect.w);
        const destination = rect.native();

        self.tint(handle, tint_color);
        _ = api.renderTextureRotated(self.handle, handle, null, &destination, degrees, null, .SDL_FLIP_NONE);
    }

    fn tint(_: *Renderer, texture_handle: *api.SDL_Texture, value: Color) void {
        _ = api.setTextureColorMod(texture_handle, value[0], value[1], value[2]);
        _ = api.setTextureAlphaMod(texture_handle, value[3]);
    }

    // ── Clipping ───────────────────────────────────────────────────────

    pub fn clip(self: *Renderer, rect: Rect) void {
        self.clip_rect = rect;

        const native_rect = sdl.pixels.SDL_Rect{
            .x = @intFromFloat(@floor(rect.x)),
            .y = @intFromFloat(@floor(rect.y)),
            .w = @intFromFloat(@ceil(@max(0, rect.w))),
            .h = @intFromFloat(@ceil(@max(0, rect.h))),
        };

        _ = api.setRenderClipRect(self.handle, &native_rect);
    }

    /// Clip to the intersection of `rect` and the current clip.
    pub fn clipWithin(self: *Renderer, rect: Rect) ?Rect {
        const previous = self.clip_rect;
        self.clip(if (previous) |current| current.intersect(rect) else rect);
        return previous;
    }

    pub fn restoreClip(self: *Renderer, previous: ?Rect) void {
        if (previous) |rect| self.clip(rect) else self.unclip();
    }

    pub fn unclip(self: *Renderer) void {
        self.clip_rect = null;
        _ = api.setRenderClipRect(self.handle, null);
    }
};

fn distance(a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

fn lerp(a: Point, b: Point, amount: f32) Point {
    return .{ .x = a.x + (b.x - a.x) * amount, .y = a.y + (b.y - a.y) * amount };
}

const extra_glyphs = [_]u21{ '…', '·', '←', '→', '×', '≥', '≤', '−', '—', '✓', '°', '•', '–', '≠', '↑', '↓', '“', '”', '‘', '’' };

fn glyphCodepoint(index: usize) u32 {
    if (index < 224) return @intCast(index + 32);
    if (index - 224 < extra_glyphs.len) return extra_glyphs[index - 224];
    return '?';
}

fn glyphIndex(codepoint: u21) usize {
    if (codepoint >= 32 and codepoint < 256) return codepoint - 32;

    for (extra_glyphs, 0..) |extra, index| {
        if (extra == codepoint) return index + 224;
    }

    return '?' - 32;
}
