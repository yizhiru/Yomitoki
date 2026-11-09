#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_image="$PWD/Resources/AppIcon.png"
output="${1:-$PWD/.build/AppIcon.icns}"
if [[ ! -f "$source_image" ]]; then
    echo "缺少图标源文件：$source_image" >&2
    exit 1
fi

mkdir -p .build "$(dirname "$output")"
stage="$(mktemp -d "$PWD/.build/icon.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"

# macOS uses both standard and Retina variants, including 1024 px artwork.
for size in 16 32 128 256 512; do
    sips --resampleHeightWidth "$size" "$size" "$source_image" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips --resampleHeightWidth "$pixels" "$pixels" "$source_image" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$output"
