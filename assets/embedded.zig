pub const regular = @embedFile("regular.ttf");
pub const medium = @embedFile("medium.ttf");
pub const semibold = @embedFile("semibold.ttf");
pub const mono = @embedFile("mono.ttf");
pub const mono_bold = @embedFile("mono-bold.ttf");
pub const thresholds = @embedFile("default_thresholds.json");

/// 128×128 white RGBA masks, in the same order as `render.Icon`.
/// Regenerate them with `icons/build.sh`.
pub const icons = [_][]const u8{
    @embedFile("icons/house.rgba"),
    @embedFile("icons/panel-left-close.rgba"),
    @embedFile("icons/panel-left-open.rgba"),
    @embedFile("icons/chart-spline.rgba"),
    @embedFile("icons/map.rgba"),
    @embedFile("icons/settings.rgba"),
    @embedFile("icons/plus.rgba"),
    @embedFile("icons/chevron-down.rgba"),
    @embedFile("icons/chevron-right.rgba"),
    @embedFile("icons/arrow-left.rgba"),
    @embedFile("icons/arrow-right.rgba"),
    @embedFile("icons/x.rgba"),
    @embedFile("icons/check.rgba"),
    @embedFile("icons/download.rgba"),
    @embedFile("icons/copy.rgba"),
    @embedFile("icons/expand.rgba"),
    @embedFile("icons/cloud-upload.rgba"),
    @embedFile("icons/folder-open.rgba"),
    @embedFile("icons/generic_minimize.rgba"),
    @embedFile("icons/generic_maximize.rgba"),
    @embedFile("icons/generic_restore.rgba"),
    @embedFile("icons/generic_close.rgba"),
    @embedFile("icons/file-spreadsheet.rgba"),
    @embedFile("icons/map-pin.rgba"),
    @embedFile("icons/calendar.rgba"),
    @embedFile("icons/circle-check.rgba"),
    @embedFile("icons/circle-x.rgba"),
    @embedFile("icons/circle-question-mark.rgba"),
    @embedFile("icons/sun.rgba"),
    @embedFile("icons/moon.rgba"),
    @embedFile("icons/sliders-horizontal.rgba"),
    @embedFile("icons/rotate-ccw.rgba"),
    @embedFile("icons/loader-circle.rgba"),
    @embedFile("icons/image.rgba"),
    @embedFile("icons/search.rgba"),
    @embedFile("icons/layers.rgba"),
    @embedFile("icons/file-down.rgba"),
    @embedFile("icons/triangle-alert.rgba"),
    @embedFile("icons/info.rgba"),
    @embedFile("icons/trash.rgba"),
    @embedFile("icons/pencil.rgba"),
    @embedFile("icons/folder.rgba"),
    @embedFile("icons/activity.rgba"),
};
