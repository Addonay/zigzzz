pub const regular = @embedFile("regular.ttf");
pub const medium = @embedFile("medium.ttf");
pub const semibold = @embedFile("semibold.ttf");
pub const mono = @embedFile("mono.ttf");
pub const mono_bold = @embedFile("mono-bold.ttf");
pub const thresholds = @embedFile("default_thresholds.json");

/// SVG sources in the same order as `render.Icon`; SDL_image rasterizes them at startup.
pub const icons = [_][]const u8{
    @embedFile("icons/house.svg"),
    @embedFile("icons/panel-left-close.svg"),
    @embedFile("icons/panel-left-open.svg"),
    @embedFile("icons/chart-spline.svg"),
    @embedFile("icons/map.svg"),
    @embedFile("icons/settings.svg"),
    @embedFile("icons/plus.svg"),
    @embedFile("icons/chevron-down.svg"),
    @embedFile("icons/chevron-right.svg"),
    @embedFile("icons/arrow-left.svg"),
    @embedFile("icons/arrow-right.svg"),
    @embedFile("icons/x.svg"),
    @embedFile("icons/check.svg"),
    @embedFile("icons/download.svg"),
    @embedFile("icons/copy.svg"),
    @embedFile("icons/expand.svg"),
    @embedFile("icons/cloud-upload.svg"),
    @embedFile("icons/folder-open.svg"),
    @embedFile("icons/generic_minimize.svg"),
    @embedFile("icons/generic_maximize.svg"),
    @embedFile("icons/generic_restore.svg"),
    @embedFile("icons/generic_close.svg"),
    @embedFile("icons/file-spreadsheet.svg"),
    @embedFile("icons/map-pin.svg"),
    @embedFile("icons/calendar.svg"),
    @embedFile("icons/circle-check.svg"),
    @embedFile("icons/circle-x.svg"),
    @embedFile("icons/circle-question-mark.svg"),
    @embedFile("icons/sun.svg"),
    @embedFile("icons/moon.svg"),
    @embedFile("icons/sliders-horizontal.svg"),
    @embedFile("icons/rotate-ccw.svg"),
    @embedFile("icons/loader-circle.svg"),
    @embedFile("icons/image.svg"),
    @embedFile("icons/search.svg"),
    @embedFile("icons/layers.svg"),
    @embedFile("icons/file-down.svg"),
    @embedFile("icons/triangle-alert.svg"),
    @embedFile("icons/info.svg"),
    @embedFile("icons/trash.svg"),
    @embedFile("icons/pencil.svg"),
    @embedFile("icons/folder.svg"),
    @embedFile("icons/activity.svg"),
};
