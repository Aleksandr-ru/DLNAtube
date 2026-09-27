#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

vendor_dir="$PWD/Vendor"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dlnatube-vendor.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

ffmpeg_dir="$vendor_dir/FFmpeg"
ffmpeg_archive="$ffmpeg_dir/ffmpeg-8.1.3.tar.xz"
expected_ffmpeg_sha256="7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"

verify_ffmpeg_archive() {
    actual_sha256=$(shasum -a 256 "$1" | sed 's/[[:space:]].*$//')
    if [ "$actual_sha256" != "$expected_ffmpeg_sha256" ]; then
        echo "FFmpeg 8.1.3 archive checksum mismatch" >&2
        exit 1
    fi
}

if [ -f "$ffmpeg_archive" ]; then
    verify_ffmpeg_archive "$ffmpeg_archive"
else
    if [ -e "$ffmpeg_archive" ]; then
        echo "Invalid FFmpeg archive path: $ffmpeg_archive" >&2
        exit 1
    fi
    mkdir -p "$work_dir/downloads" "$ffmpeg_dir"
    curl --fail --location --retry 3 --silent --show-error \
        https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz \
        --output "$work_dir/downloads/ffmpeg-8.1.3.tar.xz"
    verify_ffmpeg_archive "$work_dir/downloads/ffmpeg-8.1.3.tar.xz"
    mv "$work_dir/downloads/ffmpeg-8.1.3.tar.xz" "$ffmpeg_archive"
fi

echo "FFmpeg source is ready in Vendor/FFmpeg."
