#!/usr/bin/env bash
# Build the release binaries and assemble the downloadable packages.
#
#   ./packaging/package.sh              # build every target, then package
#   ./packaging/package.sh --skip-build # repackage the existing binaries
#
# Output lands in dist/release:
#   zigzzz-<version>-windows-x86_64.exe
#   zigzzz-<version>-windows-aarch64.exe
#   zigzzz-<version>-x86_64.AppImage
#   zigzzz-<version>-aarch64.AppImage
#   zigzzz-<version>-1.x86_64.rpm
#   zigzzz-<version>-1.aarch64.rpm
#   zigzzz-<version>-src.tar.gz
#   zigzzz-<version>-src.zip
#   SHA256SUMS
#
# Needs zig, rpmbuild, zip, and curl (appimagetool and the AppImage runtimes
# are downloaded once into $ZIGZZZ_TOOLS, default ~/.cache/zigzzz-pack/tools).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",/\1/p' build.zig.zon | head -n1)"
if [[ -z "$version" ]]; then
    echo "package.sh: no .version in build.zig.zon" >&2
    exit 1
fi

app_id="io.github.addonay.zigzzz"
optimize=fast
build_root="$root/dist/build"
release="$root/dist/release"
staging="$root/dist/package"
tools="${ZIGZZZ_TOOLS:-$HOME/.cache/zigzzz-pack/tools}"
skip_build=false
[[ "${1:-}" == "--skip-build" ]] && skip_build=true

# Zig target triple | package architecture
windows_targets=(
    "x86_64-windows-gnu|x86_64"
    "aarch64-windows-gnu|aarch64"
)

# glibc 2.31 keeps the Linux builds running on Ubuntu 20.04 / Fedora 32+.
linux_targets=(
    "x86_64-linux-gnu.2.31|x86_64"
    "aarch64-linux-gnu.2.31|aarch64"
)

binary() {
    local triple="$1" extension="${2:-}"
    local path="$build_root/$triple/bin/zigzzz-$optimize$extension"

    if [[ ! -f "$path" ]]; then
        echo "package.sh: missing $path (run without --skip-build)" >&2
        exit 1
    fi

    printf '%s' "$path"
}

# ── Build ──────────────────────────────────────────────────────────────

if ! $skip_build; then
    for entry in "${windows_targets[@]}" "${linux_targets[@]}"; do
        IFS='|' read -r triple _ <<<"$entry"
        printf '==> building %s (%s)\n' "$triple" "$optimize"
        zig build -Dtarget="$triple" -Doptimize="$optimize" --prefix "$build_root/$triple"
    done
fi

rm -rf "$staging" "$release"
mkdir -p "$staging" "$release"

# ── Shared Linux files ─────────────────────────────────────────────────

# Desktop entry, icons, and licenses used by both the RPM and AppImage.
linux_stage() {
    local dest="$1" bin="$2"

    mkdir -p "$dest/icons" "$dest/licenses"
    install -m755 "$bin" "$dest/zigzzz"
    install -m644 "packaging/linux/$app_id.desktop" "$dest/"
    cp packaging/icons/zigzzz-*.png "$dest/icons/"
    cp assets/FONT-LICENSE assets/MONO-FONT-LICENSE "$dest/licenses/"
    cp assets/icons/BREEZE-LICENSE assets/icons/GPUI-LICENSE assets/icons/LICENSE-LUCIDE "$dest/licenses/"
}

# ── Windows ────────────────────────────────────────────────────────────

echo "==> packaging Windows executables"
for entry in "${windows_targets[@]}"; do
    IFS='|' read -r triple arch <<<"$entry"
    name="zigzzz-$version-windows-$arch.exe"

    cp "$(binary "$triple" .exe)" "$release/$name"
    printf '    %s\n' "$name"
done

# ── RPM ────────────────────────────────────────────────────────────────

echo "==> packaging RPMs"
for entry in "${linux_targets[@]}"; do
    IFS='|' read -r triple arch <<<"$entry"
    stage="$staging/rpm-$arch"
    top="$staging/rpmbuild-$arch"

    linux_stage "$stage" "$(binary "$triple")"

    rpmbuild -bb packaging/linux/zigzzz.spec \
        --target "$arch" \
        --define "_topdir $top" \
        --define "pkg_version $version" \
        --define "stage $stage" \
        --quiet

    rpm="$(find "$top/RPMS" -name '*.rpm' | head -n1)"
    cp "$rpm" "$release/"
    printf '    %s\n' "$(basename "$rpm")"
done

# ── AppImage ───────────────────────────────────────────────────────────

fetch() {
    local url="$1" path="$2"

    if [[ ! -s "$path" ]]; then
        mkdir -p "$(dirname "$path")"
        curl -fsSL --retry 3 -o "$path.part" "$url"
        mv "$path.part" "$path"
    fi
}

fetch "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
    "$tools/appimagetool-x86_64.AppImage"
chmod +x "$tools/appimagetool-x86_64.AppImage"

echo "==> packaging AppImages"
for entry in "${linux_targets[@]}"; do
    IFS='|' read -r triple arch <<<"$entry"
    runtime="$tools/runtime-$arch"
    fetch "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-$arch" "$runtime"

    files="$staging/appimage-files-$arch"
    appdir="$staging/AppDir-$arch"
    linux_stage "$files" "$(binary "$triple")"

    mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" "$appdir/usr/share/licenses/zigzzz"
    install -m755 "$files/zigzzz" "$appdir/usr/bin/zigzzz"
    install -m644 "$files/$app_id.desktop" "$appdir/$app_id.desktop"
    install -m644 "$files/$app_id.desktop" "$appdir/usr/share/applications/"
    install -m644 "$files/icons/zigzzz-256.png" "$appdir/$app_id.png"
    ln -s "$app_id.png" "$appdir/.DirIcon"
    cp "$files/licenses/"* "$appdir/usr/share/licenses/zigzzz/"

    for size in 16 24 32 48 64 128 256 512; do
        install -Dm644 "$files/icons/zigzzz-$size.png" \
            "$appdir/usr/share/icons/hicolor/${size}x${size}/apps/$app_id.png"
    done

    cat >"$appdir/AppRun" <<'EOF'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/usr/bin/zigzzz" "$@"
EOF
    chmod 755 "$appdir/AppRun"

    name="zigzzz-$version-$arch.AppImage"

    # appimagetool is itself an AppImage; extract-and-run avoids needing FUSE.
    # It is chatty, so keep its output for failures only.
    log="$staging/appimagetool-$arch.log"

    if ! APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$arch" "$tools/appimagetool-x86_64.AppImage" \
        --no-appstream --runtime-file "$runtime" "$appdir" "$release/$name" >"$log" 2>&1; then
        cat "$log" >&2
        echo "package.sh: appimagetool failed for $arch" >&2
        exit 1
    fi

    printf '    %s\n' "$name"
done

# ── Source ─────────────────────────────────────────────────────────────

echo "==> packaging source"
src_dir="zigzzz-$version-src"
stage="$staging/$src_dir"
mkdir -p "$stage"

# Tracked files plus new, non-ignored files; skip anything deleted locally.
while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    mkdir -p "$stage/$(dirname "$file")"
    cp -p "$file" "$stage/$file"
done < <(git ls-files -z --cached --others --exclude-standard)

tar -C "$staging" --owner=0 --group=0 --numeric-owner -czf "$release/$src_dir.tar.gz" "$src_dir"
(cd "$staging" && zip -qr9 "$release/$src_dir.zip" "$src_dir")
printf '    %s\n    %s\n' "$src_dir.tar.gz" "$src_dir.zip"

# ── Checksums ──────────────────────────────────────────────────────────

echo "==> checksums"
(cd "$release" && sha256sum -- * >SHA256SUMS)

echo
echo "Release files in $release:"
ls -lh "$release"
