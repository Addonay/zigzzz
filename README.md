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

## Settings

On Windows, settings are stored in `%APPDATA%\zigzzz\settings.json`. The native
roaming folder is resolved through SDL, so redirected profiles and Unicode
usernames work. Linux uses `$XDG_CONFIG_HOME/zigzzz/settings.json`, or
`~/.config/zigzzz/settings.json` when that variable is unset.

Set `ZIGZZZ_SETTINGS_PATH` to a file path to override the location on either OS.

## License

Copyright (c) 2026 Addonay. All rights reserved. See [LICENSE](LICENSE).
Bundled fonts and icons keep their own licenses in `assets/`.
