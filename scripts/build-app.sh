#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
if [ ! -f Vendor/FFmpeg/ffmpeg-8.1.3.tar.xz ]; then
    scripts/setup-vendor.sh
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if ! lipo -archs Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib 2>/dev/null | grep -qw "$(uname -m)"; then
    scripts/build-media-library.sh
fi
sh scripts/prepare-youtubekit.sh
swift build --disable-sandbox -c release
binary_dir=$(swift build --disable-sandbox -c release --show-bin-path)
app_version_base=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
last_build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
if ! app_version_prefix=$(printf '%s\n' "$app_version_base" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { printf "%s.%s\n", $1, $2; valid = 1 } END { if (!valid) exit 1 }'); then
    echo "Invalid app version in Resources/Info.plist: $app_version_base" >&2
    exit 1
fi
if ! build_number=$(printf '%s\n' "$last_build_number" | awk '/^[0-9]+$/ { printf "%d\n", $1 + 1; valid = 1 } END { if (!valid) exit 1 }'); then
    echo "Invalid build number in Resources/Info.plist: $last_build_number" >&2
    exit 1
fi
build_serial=${build_number##*.}
app_version="$app_version_prefix.$build_serial"
app_dir="$PWD/dist/DLNAtube.app"
existing_app_dir=$(find "$PWD/dist" -mindepth 1 -maxdepth 1 -type d -iname 'dlnatube.app' -print -quit 2>/dev/null || true)
if [ -n "$existing_app_dir" ] && [ "$(basename "$existing_app_dir")" != "DLNAtube.app" ]; then
    temporary_app_dir="$PWD/dist/.DLNAtube-name-fix.app"
    mv "$existing_app_dir" "$temporary_app_dir"
    mv "$temporary_app_dir" "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Frameworks"
existing_executable=$(find "$app_dir/Contents/MacOS" -mindepth 1 -maxdepth 1 -type f -iname 'dlnatube' -print -quit 2>/dev/null || true)
if [ -n "$existing_executable" ] && [ "$(basename "$existing_executable")" != "DLNAtube" ]; then
    temporary_executable="$app_dir/Contents/MacOS/.DLNAtube-name-fix"
    mv "$existing_executable" "$temporary_executable"
    mv "$temporary_executable" "$app_dir/Contents/MacOS/DLNAtube"
fi
cp "$binary_dir/DLNAtube" "$app_dir/Contents/MacOS/DLNAtube"
cp Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib "$app_dir/Contents/Frameworks/"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
cp Resources/DlnaTube.icns "$app_dir/Contents/Resources/DlnaTube.icns"
cp -R Resources/ru.lproj Resources/en.lproj "$app_dir/Contents/Resources/"
cp Resources/ThirdPartyLicenses/YouTubeKit-LICENSE.txt "$app_dir/Contents/Resources/YouTubeKit-LICENSE.txt"
cp Resources/ThirdPartyLicenses/FFmpeg-LICENSE.md "$app_dir/Contents/Resources/FFmpeg-LICENSE.md"
cp Resources/ThirdPartyLicenses/FFmpeg-COPYING.LGPLv2.1 "$app_dir/Contents/Resources/FFmpeg-COPYING.LGPLv2.1"
mkdir -p "$app_dir/Contents/Resources/YouTubeKit_YouTubeKit.bundle"
chmod -R u+w "$app_dir/Contents/Resources/YouTubeKit_YouTubeKit.bundle"
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
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" Resources/Info.plist
echo "$app_dir"
