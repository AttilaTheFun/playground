#!/bin/bash
# Phase C1 for Android: libcmark-gfm for Android (arm64, or x86_64 with
# ISO_ANDROID_ARCH; a small swift-frontend
# dependency), with the NDK Bazel fetched.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
# The NDK Bazel fetched (a Mac's, else a Linux machine's), unless ISO_NDK.
NDK="${ISO_NDK:-$(grep -l "Pkg.Revision = 30\." ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin/source.properties ~/.cache/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_linux/source.properties 2>/dev/null | head -1 | xargs dirname 2>/dev/null)}"
API="${ISO_ANDROID_API:-28}"
# The Android host's architecture: aarch64 (the default, the phones') or
# x86_64 (emulators on x86_64 machines: GitHub's runners). Each builds into
# folders of its own, aarch64's unsuffixed as before.
ARCH="${ISO_ANDROID_ARCH:-aarch64}"
case "$ARCH" in
    aarch64) ABI=arm64-v8a; SUFFIX="" ;;
    x86_64) ABI=x86_64; SUFFIX="-x86_64" ;;
    *) echo "ISO_ANDROID_ARCH is aarch64 or x86_64, not $ARCH" >&2; exit 1 ;;
esac
mkdir -p build/android$SUFFIX-cmark
cmake -S cmark -B build/android$SUFFIX-cmark -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=$ABI \
    -DANDROID_PLATFORM=android-$API \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMARK_TESTS=OFF
"$NINJA" -C build/android$SUFFIX-cmark libcmark-gfm.a libcmark-gfm-extensions.a || \
    "$NINJA" -C build/android$SUFFIX-cmark
echo "PHASE C1 OK"
find build/android$SUFFIX-cmark -name "*.a" | head -4
