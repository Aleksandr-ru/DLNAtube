#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
iconset=".build/DlnaTube.iconset"
mkdir -p "$iconset"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
swift -module-cache-path "$PWD/.build/swift-module-cache" scripts/render-app-icon.swift Resources/DlnaTube-1024.png

for entry in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'
do
    set -- $entry
    sips -z "$1" "$1" Resources/DlnaTube-1024.png --out "$iconset/$2" >/dev/null
done

iconutil -c icns "$iconset" -o Resources/DlnaTube.icns
