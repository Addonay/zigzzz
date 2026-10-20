#!/usr/bin/env bash
# Rasterize every SVG in this directory into a 128×128 white RGBA mask.
# The renderer tints the masks at draw time and builds its own mip levels.
#
# Requires ImageMagick 7 with an SVG delegate.
set -euo pipefail
cd "$(dirname "$0")"

for source in *.svg; do
    name="${source%.svg}"
    temporary="$(mktemp --suffix=.svg)"

    # Lucide uses currentColor; Breeze controls use a fixed grey.
    sed -e 's/currentColor/#ffffff/g' -e 's/#DCE0E5/#ffffff/g' "$source" > "$temporary"

    magick -background none -density 768 "$temporary" \
        -resize 128x128 -depth 8 "rgba:$name.rgba"

    rm -f "$temporary"
done
