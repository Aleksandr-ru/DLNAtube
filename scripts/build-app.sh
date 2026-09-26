#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if ! lipo -archs Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib 2>/dev/null | grep -qw "$(uname -m)"; then
    scripts/build-media-library.sh
fi
swift build --disable-sandbox -c release
binary_dir=$(swift build --disable-sandbox -c release --show-bin-path)
last_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if ! app_version=$(printf '%s\n' "$last_version" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { printf "%d.%d.%d\n", $1, $2, $3 + 1; valid = 1 } END { if (!valid) exit 1 }'); then
    echo "Invalid app version in Resources/Info.plist: $last_version" >&2
    exit 1
fi
app_dir="$PWD/dist/DlnaTube.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Frameworks"
cp "$binary_dir/DlnaTube" "$app_dir/Contents/MacOS/DlnaTube"
cp Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib "$app_dir/Contents/Frameworks/"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" "$app_dir/Contents/Info.plist"
cp Resources/DlnaTube.icns "$app_dir/Contents/Resources/DlnaTube.icns"
cp Vendor/YouTubeKit-0.4.9/LICENSE "$app_dir/Contents/Resources/YouTubeKit-LICENSE.txt"
cp Vendor/FFmpeg/LICENSE.md "$app_dir/Contents/Resources/FFmpeg-LICENSE.md"
cp Vendor/FFmpeg/COPYING.LGPLv2.1 "$app_dir/Contents/Resources/FFmpeg-COPYING.LGPLv2.1"
mkdir -p "$app_dir/Contents/Resources/YouTubeKit_YouTubeKit.bundle"
cp -R "$binary_dir/YouTubeKit_YouTubeKit.bundle/." "$app_dir/Contents/Resources/YouTubeKit_YouTubeKit.bundle/"
current_year=$(date +%Y)
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Copyright © $current_year Aleksandr.ru." "$app_dir/Contents/Info.plist"
if [ -d "$app_dir/YouTubeKit_YouTubeKit.bundle" ]; then
    rm -r "$app_dir/YouTubeKit_YouTubeKit.bundle"
fi
codesign_identity=${DLNATUBE_CODESIGN_IDENTITY:--}
codesign --force --sign "$codesign_identity" "$app_dir/Contents/Frameworks/libDlnaTubeMedia.dylib"
codesign --force --sign "$codesign_identity" --identifier ru.aleksandr.dlnatube "$app_dir"
touch "$app_dir/Contents" "$app_dir"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" Resources/Info.plist
echo "$app_dir"
