# zigzzz

Workspace.

## Download

Get the latest build from [Releases](https://github.com/Addonay/zigzzz/releases):

| File | Platform |
|---|---|
| `zigzzz-<version>-1.x86_64.rpm`, `-1.aarch64.rpm` | Fedora |
| `zigzzz-<version>-x86_64.AppImage`, `-aarch64.AppImage` | Linux (glibc 2.31+) |
| `zigzzz-<version>-windows-x86_64.exe`, `-aarch64.exe` | Windows 10/11 |
| `zigzzz-<version>-src.tar.gz`, `-src.zip` | Source |

## Build

Requires Zig 0.17.0. Every native dependency is built from source.

```sh
zig build run
zig build test
```

## Release

Bump `.version` in `build.zig.zon`, commit, then push a matching tag:

```sh
git tag v0.1.1
git push origin v0.1.1
```

GitHub Actions builds every package and publishes the release.

CI and releases cache the installed compiler, Zig build artifacts, and fetched packages. Release builds
also cache AppImage packaging tools. Cache keys include the runner platform,
Zig version, dependency manifest, and commit; compatible older caches seed new
builds, while Zig checks which outputs need rebuilding. A manual Release workflow
run on `main` warms the full multi-target cache for later tags without publishing
a release. The first run after a cache reset still needs a cold build.

## Settings

On Windows, settings are stored in `%APPDATA%\zigzzz\settings.json`. The native
roaming folder is resolved through SDL, so redirected profiles and Unicode
usernames work. Linux uses `$XDG_CONFIG_HOME/zigzzz/settings.json`, or
`~/.config/zigzzz/settings.json` when that variable is unset.

Set `ZIGZZZ_SETTINGS_PATH` to a file path to override the location on either OS.

## License

Copyright (c) 2026 Addonay. All rights reserved. See [LICENSE](LICENSE).
Bundled fonts and icons keep their own licenses in `assets/`.
