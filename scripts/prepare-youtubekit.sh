#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
pinned_revision="e5b7d0396ce12bf3444f0d209e8436c83373b7af"
current_revision=$(git -C .build/checkouts/youtubekit rev-parse HEAD 2>/dev/null || true)
if [ "$current_revision" != "$pinned_revision" ]; then
    swift package resolve
fi
current_revision=$(git -C .build/checkouts/youtubekit rev-parse HEAD 2>/dev/null || true)
if [ "$current_revision" != "$pinned_revision" ]; then
    printf '%s\n' "YouTubeKit patch requires revision $pinned_revision; found ${current_revision:-missing checkout}" >&2
    exit 1
fi

# Check for an already-applied patch without changing the checkout.
if patch -R -C -f -s -p1 -d .build/checkouts/youtubekit < scripts/youtubekit.patch >/dev/null 2>&1; then
    :
else
    patch -p1 -d .build/checkouts/youtubekit < scripts/youtubekit.patch
fi
