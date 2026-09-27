#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
pinned_revision="e5b7d0396ce12bf3444f0d209e8436c83373b7af"
current_revision=$(git -C .build/checkouts/youtubekit rev-parse HEAD 2>/dev/null || true)
if [ "$current_revision" != "$pinned_revision" ]; then
    swift package resolve
fi
python3 scripts/patch-youtubekit.py .build/checkouts/youtubekit
