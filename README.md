# Workspace

A native Zig workspace for QoS KPI analysis and KML generation. SDL is used
through the pinned `zsdl3` bindings, zlay lays out the window shell, and
FreeType renders the embedded fonts.

## Build and run

Requires Zig **0.17.0**, SDL3, FreeType, and Expat development packages. On Fedora:

```sh
sudo dnf install SDL3-devel freetype-devel expat-devel
zig build run
```

`zig build` produces `zig-out/bin/zigzzz`. Use `zig build -Doptimize=safe` for an
optimized `zig-out/bin/zigzzz-safe` with runtime safety checks; chart image
exports are much faster in optimized builds. Dependencies are fetched from
GitHub using the commits in `build.zig.zon`.

The build corrects one upstream binding typo (`SDL_RenderReadPixels` refers to
`pixels.SDL_Surface` instead of `surface.SDL_Surface`) in generated build inputs.
The fetched dependency is never edited, and the application declares no SDL ABI.
The native FreeType/Expat headers use Zig's built-in `addTranslateC`.

## Design

- Light mode uses the teal **Perpetuity** palette (`perpetuity.css`) and dark
  mode uses **Graphite** (`graphite.css`). `src/theme.zig` lists the OKLCH values
  exactly as they appear in the CSS and converts them to sRGB at compile time.
  Graphite is neutral, so dark mode borrows a teal from its chart colors for the
  brand mark and accents.
- Widgets follow shadcn/ui: outline and ghost buttons, inputs with a focus
  glow, switches, segmented controls, checkboxes, tooltips, and toasts.
- The renderer draws into a 2× target and adds soft shadows, seamless
  antialiased polylines, dashed rounded outlines, and a backdrop blur used
  behind the chart focus view and export progress.

## Use

- **Home** links to both tools. Drop a spreadsheet anywhere to open it in QoS.
- **QoS KPIs** — drop a report on the upload area, click it to browse, or enter
  a path. The first worksheet is read: KPI names in column B, dates from column
  C, and blank rows separating areas. XLSX, XLSM, and CSV are supported; save
  XLS, XLSB, and ODS files as XLSX first.
  - The sidebar lists areas (with failing counts) and KPI groups. The area name
    in the top bar is also a switcher.
  - Filter by status with the pills, and pick the date range with the
    segmented control. Area and KPI overrides from Settings still apply.
  - Charts replicate ldd's Chart.js cards: nice y ticks, daily x ticks up to 31
    days, smooth lines, a dashed threshold annotation, and an index-mode
    tooltip. Hover a card for its toolbar: add overlays, remove them, or copy
    the chart as a PNG. Overlays are saved immediately.
  - Click a card to open the focus view with its own date range and temporary
    overlays. Escape or a click outside closes it.
  - **Export** writes editable Excel charts, or PNG images of failing charts,
    beside the report. Exports cover every area with the current filters.
    Images always use the light palette.
- **KML Generator** accepts XLSX workbooks, detects column mappings, supports
  extra description columns, and exports site points and optional sector
  polygons. Rows are aggregated using the mapped cell name.
- **Settings** has five tabs. Changes are staged; a bar appears with **Save
  changes** and **Discard** while anything differs. **Restore defaults** stages
  the defaults for review. The sidebar footer toggles light and dark mode
  immediately.
- `Ctrl+B` toggles the sidebar. `Tab` and `Shift+Tab` move focus; `Enter`
  activates a focused control or opens an entered path; `Escape` closes a menu,
  the focus view, or the path field. Text fields support UTF-8 editing and
  clipboard shortcuts.

Preferences live in `$XDG_CONFIG_HOME/zigzzz/settings.json`, falling back to
`~/.config/zigzzz/settings.json`. `ZIGZZZ_SETTINGS_PATH` overrides that location.

## Checks

```sh
zig build test
ZIGZZZ_QOS_FIXTURE=/path/to/ldd/static/test-data.xlsx \
ZIGZZZ_KML_FIXTURE=/path/to/KE-lt-99-perc-RNA.xlsx zig build test
```

Fixture checks are optional; ordinary tests cover dates, UTF-8 editing,
threshold comparisons, preference persistence, and PNG encoding. Test code is
separate from the executable.

## Assets

Default thresholds come from the local `gzzz` reference. Lucide icons come from
`gpui-kit-assets` 0.7.3 (see `assets/icons/LICENSE-LUCIDE`); window controls are
the Breeze SVGs used by GPUI (see `assets/icons/BREEZE-LICENSE` and
`assets/icons/GPUI-LICENSE`). Run `assets/icons/build.sh` (ImageMagick) to
rasterize the SVGs into the embedded 128 px RGBA masks.

Noto Sans Regular, Medium, and SemiBold are embedded with their license in
`assets/FONT-LICENSE`. Liberation Mono (metric-compatible with Courier New, the
chart font in ldd) is embedded with its license in `assets/MONO-FONT-LICENSE`.
