#!/bin/bash
# Stages the Android Playground's toolchain, gitignored under toolchain/ and
# packaged by the app when present:
#
#   toolchain/native/   swift-frontend and wasm-ld built for Android arm64
#                       (toolchain/native-x86_64/ for x86_64, ISO_ANDROID_ARCH) by
#                       the ~/Developer/ios-toolchain campaign's Android phases
#                       (tools/playground_toolchain/build_phase_{b,c1,c2}_android_*.sh),
#                       with the compiler's own Swift libraries, the Swift
#                       runtime it needs and the macro plugins with their server — named lib*.so so the APK's native
#                       library directory holds them, where the app may execute them
#   toolchain/toolchain.zip   the SDK the browser Playground ships
#                       (tools/browser_toolchain/stage_bundle.sh: resource dir,
#                       sysroot, the Isomer modules and archives, manifest.json)
#
#   stage_toolchain.sh [--slice <wasip1 slice>] [--native-only]
#
# --native-only: toolchain/native* alone (a machine with the Android phases'
# outputs and nothing of the browser toolchain's: a container's build).
#
# The slice defaults to one made of the iOS Playground's bundled SDK data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TC="${ISO_IOS_TOOLCHAIN:-$HOME/Developer/ios-toolchain}"
NDK="${ISO_NDK:-$(grep -l "Pkg.Revision = 30\." ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin/source.properties ~/.cache/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_linux/source.properties 2>/dev/null | head -1 | xargs dirname 2>/dev/null)}"
PREBUILT="$NDK/toolchains/llvm/prebuilt/$([ "$(uname -s)" = Darwin ] && echo darwin || echo linux)-x86_64"
STRIP="$PREBUILT/bin/llvm-strip"
# The phones' arm64, or x86_64 for emulators on x86_64 machines (its phases
# built with the same ISO_ANDROID_ARCH): each staged into a folder of its own.
ARCH="${ISO_ANDROID_ARCH:-aarch64}"
case "$ARCH" in
    aarch64) SUFFIX="" ;;
    x86_64) SUFFIX="-x86_64" ;;
    *) echo "ISO_ANDROID_ARCH is aarch64 or x86_64, not $ARCH" >&2; exit 1 ;;
esac
SLICE=""
NATIVE_ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slice) SLICE="$2"; shift 2;;
        --native-only) NATIVE_ONLY=1; shift;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[ -x "$TC/build/android$SUFFIX-swift/bin/swift-frontend" ] || { echo "run the Android toolchain phases first ($TC/build/android$SUFFIX-swift/bin/swift-frontend missing)" >&2; exit 1; }
if [ -z "$SLICE" ] && [ -z "$NATIVE_ONLY" ]; then
    DATA="$ROOT/apple/playground_ios_application/embedded_toolchain/data"
    SLICE="$(mktemp -d)/slice"
    mkdir -p "$SLICE/swift.xctoolchain/usr/lib"
    ln -s "$DATA/WASI.sdk" "$SLICE/WASI.sdk"
    ln -s "$DATA/swift_static" "$SLICE/swift.xctoolchain/usr/lib/swift_static"
fi
OUT="$HERE/toolchain"
NATIVE="$OUT/native$SUFFIX"
# This architecture's natives afresh; the other's stay.
rm -rf "$NATIVE" "$OUT/tree" "$OUT/toolchain.zip"; mkdir -p "$NATIVE" "$OUT/tree"

# The compiler and linker, stripped, plus every shared library they load.
"$STRIP" -o "$NATIVE/libswift-frontend.so" "$TC/build/android$SUFFIX-swift/bin/swift-frontend"
"$STRIP" -o "$NATIVE/libwasm-ld.so" "$TC/build/android$SUFFIX-llvm/bin/lld"
for lib in "$TC"/build/android$SUFFIX-swift/lib/swift/host/compiler/*.so; do
    "$STRIP" -o "$NATIVE/$(basename "$lib")" "$lib"
done
# Macros: the in-process plugin server, the swift-syntax libraries it and the
# plugins load (lib/swift/host/*.so, apart from the compiler's own _Compiler
# copies above), and the prebuilt plugins (ObservationMacros, SwiftMacros).
# The frontend is told where they are (PlaygroundServices.kt's macroArguments).
for lib in "$TC"/build/android$SUFFIX-swift/lib/swift/host/*.so "$TC"/build/android$SUFFIX-swift/lib/swift/host/plugins/*.so; do
    "$STRIP" -o "$NATIVE/$(basename "$lib")" "$lib"
done
for lib in libswiftCore libswift_Concurrency libswift_Builtin_float libswift_math libswift_StringProcessing libswift_RegexParser libdispatch libswiftAndroid libBlocksRuntime; do
    cp "$TC/android-swift-resources$SUFFIX/android/$lib.so" "$NATIVE/"
done
cp "$PREBUILT/sysroot/usr/lib/$ARCH-linux-android/libc++_shared.so" "$NATIVE/"
if [ -n "$NATIVE_ONLY" ]; then du -sh "$NATIVE"; echo "staged $NATIVE"; exit 0; fi

# The SDK, the browser bundle's way (without the bundle blob itself).
cd "$ROOT"   # the workspace, whose bazel-out the output paths are under
bazel build -c opt //apple/playground_ios_application:playground_sdk
SDK="$PWD/$(bazel cquery -c opt --output=files //apple/playground_ios_application:playground_sdk 2>/dev/null | head -1)"
STAGE="$(mktemp -d)/stage"
"$ROOT/tools/browser_toolchain/stage_bundle.sh" --frontend "$TC/build/browser-work/opt/swift-frontend.opt.wasm" --linker "$TC/build/browser-work/opt/lld.opt.wasm" --slice "$SLICE" --sdk "$SDK" --out "$STAGE"
cp -R "$STAGE/resource-dir" "$STAGE/sysroot" "$STAGE/sdk" "$STAGE/manifest.json" "$OUT/tree/"
(cd "$OUT/tree" && zip -q -r -X ../toolchain.zip .)
rm -rf "$OUT/tree"
du -sh "$NATIVE" "$OUT/toolchain.zip"
echo "staged"
