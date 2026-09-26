#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
root_dir="$PWD"
archive="$PWD/Vendor/FFmpeg/ffmpeg-8.1.3.tar.xz"
build_dir="$PWD/.build/ffmpeg-media"
source_dir="$build_dir/ffmpeg-8.1.3"
prefix="$build_dir/install"
output="$PWD/Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib"
mkdir -p "$build_dir" "$PWD/Vendor/FFmpeg/lib"
if [ ! -f "$source_dir/configure" ]; then
    tar -xf "$archive" -C "$build_dir"
fi
if [ ! -f "$prefix/lib/libavformat.a" ]; then
    mkdir -p "$build_dir/build"
    cd "$build_dir/build"
    "$source_dir/configure" --prefix="$prefix" --disable-programs --disable-doc \
        --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
        --disable-everything --enable-demuxer=mov --enable-muxer=mpegts \
        --enable-protocol=file,http,https,tcp,tls,crypto,httpproxy \
        --enable-parser=h264,aac --enable-bsf=h264_mp4toannexb,aac_adtstoasc \
        --enable-network --enable-pic --enable-static --disable-shared --disable-debug
    make -j4
    make install
    cd "$root_dir"
fi
clang -O2 -dynamiclib -install_name @rpath/libDlnaTubeMedia.dylib \
    -I"$prefix/include" Sources/MediaBridge/stream.c \
    "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a" \
    -framework Security -framework CoreFoundation -framework CoreMedia \
    -framework VideoToolbox -framework AudioToolbox -framework CoreVideo \
    -framework AVFoundation -framework AppKit -framework CoreImage \
    -lbz2 -lz -liconv -o "$output"
