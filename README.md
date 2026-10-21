# Workspace

A native Zig workspace for QoS KPI analysis and KML generation. SDL is used
through the pinned `7Games/zig-sdl3` bindings, zlay lays out the window shell, and
FreeType renders the embedded fonts.

## Build and run

Requires Zig **0.17.0**. SDL3, SDL_image, FreeType, and Expat are built from the pinned
source packages in `build.zig.zon`, so no system development packages are needed.
The native libraries are built once per target in ReleaseFast and reused by
every application release mode.

```sh
zig build run
```

`zig build` produces `zig-out/bin/zigzzz`. Use `zig build -Doptimize=safe` for an
optimized `zig-out/bin/zigzzz-safe` with runtime safety checks; chart image
exports are much faster in optimized builds.

The build targets the current host unless `-Dtarget` is given. The release names
are `zigzzz` (debug), `zigzzz-small`, `zigzzz-fast`, and `zigzzz-safe`, selected
with `-Doptimize`.

`packaging/package.sh` builds the release-fast binaries for Windows and Fedora
on x86-64 and ARM64, then writes the downloadable archives and `SHA256SUMS` to
`dist/release`:

| Archive | Platform |
| --- | --- |
| `zigzzz-<version>-windows-x86_64.zip` | Windows 10/11, Intel/AMD |
| `zigzzz-<version>-windows-aarch64.zip` | Windows 11 on ARM |
| `zigzzz-<version>-linux-x86_64.tar.gz` | Fedora/glibc 2.31+, Intel/AMD |
| `zigzzz-<version>-linux-aarch64.tar.gz` | Fedora/glibc 2.31+, ARM64 |
| `zigzzz-<version>-src.tar.gz` | Source tree |
| `zigzzz-<version>-src.zip` | Source tree |

The binaries are self-contained apart from the OS C runtime; SDL3, SDL_image,
FreeType, and Expat are statically linked. Pass `--skip-build` to repackage
existing binaries.

`zig build size` reports those release binaries from the fixed
`zig-out/windows/bin` and `zig-out/bin` directories. It does not build missing
variants and ignores any custom install prefix.

`zig-sdl3` v0.2.3 is pinned in `build.zig.zon` and builds SDL 3.4.18 from source.
Application code uses its Zig API: typed windows, renderers, textures, events,
keyboard modifiers, dialogs, and clipboard callbacks. It does not use the `c`
module or declare SDL ABI types. Core tests exercise rendering/readback, UTF-8
keyboard editing, and binary PNG clipboard data with ownership cleanup.
The build applies one targeted v0.2.3 fix to generated inputs: its slice-based
clipboard callback must use the Zig calling convention. The fetched package
is untouched, and the patch checks the pinned signature before applying.
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
  - KPIs start in default groups — Availability, Drops, Mobility,
    Accessibility, Throughput, Utilization, Radio quality, Traffic, and Data
    integrity — matched by name. KPIs first seen in a report join them too.
    Edit or delete groups in Settings; a deleted default group only returns
    if a newly seen KPI matches it.
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
- **KML Generator** accepts XLSX workbooks and exports site points and optional
  sector polygons. Rows are aggregated using the mapped cell name.
  - Every field is listed under **Columns**. Picking a column remembers that
    header for every workbook you open later (marked with a teal dot);
    **Reset to auto-detect** forgets those choices. Unremembered fields are
    detected from aliases in each workbook.
  - The column picker lists every column with a sample value. Its search is a
    case-insensitive regular expression (`lat|lon`, `^sec.?r`, `\bci\b`),
    ranked by how closely each header matches; the matched part is
    highlighted and **Enter** picks the top result.
  - Description columns, the sector switches, and the output folder are
    remembered too. Type a folder or use **Browse**, set the file name, and
    turn on **Use this folder by default** to export there for new workbooks.
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
separate from the executable. `ZIGZZZ_QOS_REAL_FIXTURE` adds a check against
a real multi-area report.

## Releases

GitHub Actions builds and publishes every release. To cut one, bump `.version`
in `build.zig.zon`, commit, and push a matching tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The **Release** workflow checks the tag against `build.zig.zon`, runs the tests,
and attaches these files to the GitHub Release:

| File | Platform |
|---|---|
| `zigzzz-<version>-1.x86_64.rpm`, `-1.aarch64.rpm` | Fedora and other RPM distributions |
| `zigzzz-<version>-x86_64.AppImage`, `-aarch64.AppImage` | Any Linux with glibc 2.31+ |
| `zigzzz-<version>-windows-x86_64.exe`, `-aarch64.exe` | Windows 10/11 (portable) |
| `zigzzz-<version>-src.tar.gz`, `-src.zip` | Source |
| `SHA256SUMS` | Checksums |

Running the workflow by hand from the Actions tab is a dry run: the packages are
attached to the run as an artifact and nothing is released. **CI** builds and
tests every push and pull request to `main`.

`./packaging/package.sh` produces the same files locally in `dist/release/`;
it needs `rpmbuild`, `zip`, and `curl`.

## Assets

Default thresholds come from the local `gzzz` reference. Lucide icons come from
`gpui-kit-assets` 0.7.3 (see `assets/icons/LICENSE-LUCIDE`); window controls are
the Breeze SVGs used by GPUI (see `assets/icons/BREEZE-LICENSE` and
`assets/icons/GPUI-LICENSE`). SVG sources are embedded directly and rasterized
at startup by SDL_image through zig-sdl3. The renderer caches white masks at
128, 64, and 32 px for tinting and smooth scaling; no generated icon assets or
ImageMagick conversion step is needed.

Noto Sans Regular, Medium, and SemiBold are embedded with their license in
`assets/FONT-LICENSE`. Liberation Mono (metric-compatible with Courier New, the
chart font in ldd) is embedded with its license in `assets/MONO-FONT-LICENSE`.
