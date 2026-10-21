#!/usr/bin/env bash
# Build the release binaries and assemble the downloadable archives.
#
#   ./packaging/package.sh              # build every target, then package
#   ./packaging/package.sh --skip-build # repackage the existing binaries
#
# Output lands in dist/release:
#   zigzzz-<version>-windows-x86_64.zip
#   zigzzz-<version>-windows-aarch64.zip
#   zigzzz-<version>-linux-x86_64.tar.gz
#   zigzzz-<version>-linux-aarch64.tar.gz
#   zigzzz-<version>-src.tar.gz
#   zigzzz-<version>-src.zip
#   SHA256SUMS

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",/\1/p' build.zig.zon | head -n1)"
if [[ -z "$version" ]]; then
    echo "package.sh: no .version in build.zig.zon" >&2
    exit 1
fi

optimize=fast
build_root="$root/dist/build"
release="$root/dist/release"
staging="$root/dist/package"
skip_build=false
[[ "${1:-}" == "--skip-build" ]] && skip_build=true

# target triple | archive platform | executable name
targets=(
    "x86_64-windows-gnu|windows-x86_64|zigzzz.exe"
    "aarch64-windows-gnu|windows-aarch64|zigzzz.exe"
    "x86_64-linux-gnu.2.31|linux-x86_64|zigzzz"
    "aarch64-linux-gnu.2.31|linux-aarch64|zigzzz"
)

if ! $skip_build; then
    for entry in "${targets[@]}"; do
        IFS='|' read -r triple _ _ <<<"$entry"
        printf '==> building %s (%s)\n' "$triple" "$optimize"
        zig build -Dtarget="$triple" -Doptimize="$optimize" --prefix "$build_root/$triple"
    done
fi

rm -rf "$staging"
mkdir -p "$staging" "$release"

copy_licenses() {
    local dest="$1"
    mkdir -p "$dest/licenses"
    cp assets/FONT-LICENSE "$dest/licenses/"
    cp assets/MONO-FONT-LICENSE "$dest/licenses/"
    cp assets/icons/BREEZE-LICENSE "$dest/licenses/"
}

write_readme() {
    local dest="$1" platform="$2" arch="$3"
    cat >"$dest/README.txt" <<EOF
Workspace $version — $platform $arch

Workspace is a native desktop app for QoS KPI charts and KML generation.

Run it:
$(if [[ "$platform" == windows* ]]; then
    echo '  double-click zigzzz.exe'
else
    echo '  chmod +x zigzzz && ./zigzzz'
fi)

This is a self-contained build: SDL3, SDL_image, FreeType, and Expat are
statically linked. $(if [[ "$platform" == linux* ]]; then
    echo 'It needs glibc 2.31 or newer (Fedora 32+, Ubuntu 20.04+).'
else
    echo 'The Windows x86_64 build runs on Windows 10/11; the ARM64 build runs on Windows 11 ARM.'
fi)

Bundled font and icon licenses are in licenses/.
Source code and build instructions are in the matching -src archive.
EOF
}

archive() {
    local path="$1"
    shift
    rm -f "$release/$path"
    case "$path" in
        *.zip) (cd "$staging" && zip -qr9 "$release/$path" "$@") ;;
        *.tar.gz) tar -C "$staging" --owner=0 --group=0 --numeric-owner -czf "$release/$path" "$@" ;;
        *) echo "package.sh: unknown archive type: $path" >&2; exit 1 ;;
    esac
    printf '    %s\n' "$path"
}

echo "==> packaging binaries"
for entry in "${targets[@]}"; do
    IFS='|' read -r triple platform exe <<<"$entry"
    source_bin="$build_root/$triple/bin/zigzzz-$optimize"
    [[ "$exe" == *.exe ]] && source_bin+=".exe"
    if [[ ! -f "$source_bin" ]]; then
        echo "package.sh: missing $source_bin (run without --skip-build)" >&2
        exit 1
    fi

    dir="zigzzz-$version-$platform"
    stage="$staging/$dir"
    mkdir -p "$stage"
    cp "$source_bin" "$stage/$exe"
    chmod 755 "$stage/$exe"
    cp README.md "$stage/README.md"
    write_readme "$stage" "$platform" "$([[ "$platform" == *x86_64 ]] && echo x86-64 || echo ARM64)"
    copy_licenses "$stage"

    if [[ "$platform" == windows* ]]; then
        archive "$dir.zip" "$dir"
    else
        archive "$dir.tar.gz" "$dir"
    fi
done

echo "==> packaging source"
src_dir="zigzzz-$version-src"
stage="$staging/$src_dir"
mkdir -p "$stage"
# Tracked files plus new, non-ignored files; skip anything deleted locally.
while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    mkdir -p "$stage/$(dirname "$file")"
    cp "$file" "$stage/$file"
done < <(git ls-files -z --cached --others --exclude-standard)
archive "$src_dir.tar.gz" "$src_dir"
archive "$src_dir.zip" "$src_dir"

echo "==> checksums"
(cd "$release" && sha256sum ./*.zip ./*.tar.gz >SHA256SUMS)

echo
echo "Release archives in $release:"
ls -lh "$release"
