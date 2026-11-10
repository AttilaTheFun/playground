#!/bin/bash
# The Android Playground's compiler for one architecture, built from source
# in a Linux container (an OS Server lease: 12 CPUs, 32 GB and 120 GB of
# disk did for x86_64; `oss machine lease container --image=<agent image>
# --cpus=12 --memory=32 --disk=120 --minutes=480`), its every phase's
# outputs archived so that nothing needs building twice: each archive goes
# into OS Server's storage from the lease and is kept in its files, by
# SHA-256, as a hermetic input of the next build.
#
#   tools/playground_toolchain/build_android_in_container.sh <aarch64|x86_64> <out dir>
#
# Run in the Playground's checkout. The pinned inputs are Bazel's, as the
# app's own builds fetch them (MODULE.bazel, by SHA-256): the NDK (r30),
# swift.org's 6.4.2 toolchain for this machine, the 6.4.2 Android Swift SDK.
# The sources are swift.org's at swift-6.4.2-RELEASE (README.md). <out dir>
# gets, zstd-compressed:
#   host-tools.tar.zst      phase A and A2: the host tablegens and helpers
#   android-<arch>-llvm.tar.zst   phase B: LLVM, clang and lld for Android,
#                           their libraries, headers and CMake files
#   android-<arch>-cmark.tar.zst  phase C1
#   android-<arch>-swift.tar.zst  phase C2: swift-frontend and its libraries
#   native-<arch>.tar.zst   what the APK carries (stage_toolchain.sh
#                           --native-only)
# and SHA256SUMS. Object files go between phases: the disk is the limit.
set -euo pipefail
ARCH="${1:?usage: build_android_in_container.sh <aarch64|x86_64> <out dir>}"
mkdir -p "${2:?<out dir>}"
OUT="$(cd "$2" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RELEASE=swift-6.4.2-RELEASE
case "$ARCH" in aarch64) SUFFIX="" ;; x86_64) SUFFIX="-x86_64" ;; *) echo "aarch64 or x86_64, not $ARCH" >&2; exit 2 ;; esac
log() { echo "[$(date -u +%H:%M:%S)] $*"; df -h "$HERE" | tail -1; }

log "the build tools"
need=()
for tool in cmake ninja clang lld git zstd python3; do command -v "$tool" > /dev/null || need+=("$tool"); done
if [ ${#need[@]} -gt 0 ] || [ ! -e /usr/include/curses.h ] || [ ! -e /usr/include/zlib.h ]; then
    sudo_() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    sudo_ apt-get update -qq
    sudo_ env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        cmake ninja-build clang lld git zstd python3 libncurses-dev zlib1g-dev > /dev/null
fi

log "the pinned inputs, as Bazel fetches them"
cd "$ROOT"
bazel fetch //android/playground_android_application/... > /dev/null
EXTERNAL="$(bazel info output_base)/external"
ISO_NDK="$(dirname "$(grep -l "Pkg.Revision = 30\." "$EXTERNAL"/hermetic_android_toolchains++android+androidndk_linux/source.properties | head -1)")"
host="ubuntu24.04$([ "$(uname -m)" = aarch64 ] && echo -aarch64)"
ISO_BASE_TC="$EXTERNAL/rules_swift++swift+swift_toolchain_$host/usr/bin"
ISO_ANDROID_SWIFT_SDK="$(ls -d "$EXTERNAL"/rules_swift++swift+swift_toolchain_android_sdk_$host/*_android.artifactbundle | head -1)"
export ISO_NDK ISO_BASE_TC ISO_ANDROID_SWIFT_SDK ISO_ANDROID_ARCH="$ARCH" ISO_IOS_TOOLCHAIN="$HERE"
for path in "$ISO_NDK/build/cmake" "$ISO_BASE_TC/swiftc" "$ISO_ANDROID_SWIFT_SDK"; do
    [ -e "$path" ] || { echo "missing $path" >&2; exit 1; }
done

log "the sources at $RELEASE"
cd "$HERE"
# Each folder and its repository: swift.org's cmark is swift-cmark.
for pair in swift llvm-project swift-syntax cmark:swift-cmark swift-experimental-string-processing; do
    folder="${pair%%:*}" repo="${pair#*:}"
    [ -d "$folder" ] || git clone -q --depth 1 --branch "$RELEASE" "https://github.com/swiftlang/$repo.git" "$folder"
done
git -C swift apply --check ../swift-embedded-idempotent-init.patch 2> /dev/null && git -C swift apply ../swift-embedded-idempotent-init.patch
git -C llvm-project apply --check ../llvm-signal-handler-reentry.patch 2> /dev/null && git -C llvm-project apply ../llvm-signal-handler-reentry.patch

# A phase's folders archived, their object files gone first (what a later
# phase links is the libraries, never the objects).
archive() {
    local name="$1"; shift
    find "$@" -name '*.o' -delete 2> /dev/null || true
    tar -C "$HERE" -cf - "$@" | zstd -q -T0 -19 -o "$OUT/$name.tar.zst"
    log "archived $name: $(du -h "$OUT/$name.tar.zst" | cut -f1)"
}

if [ ! -x build/host-tblgen/bin/clang-tblgen ]; then
    log "phase A: the host tablegens"; ./build_phase_a_tablegens.sh
    log "phase A2: the host helpers"; ./build_phase_a2_native_helpers.sh
    archive host-tools build/host-tblgen/bin build/host-tblgen/lib build/host-tblgen/include native-tools
fi
# A phase that finished is not run again when the script is (its objects are
# gone by then: ninja would build it all again): build/.done-<phase><suffix>.
phase() {
    local name="$1" what="$2"; shift 2
    if [ -e "build/.done-$name$SUFFIX" ]; then log "phase $name: built already"; return; fi
    log "phase $name: $what"; "$@"
    touch "build/.done-$name$SUFFIX"
}
phase B "LLVM, clang and lld for Android $ARCH" ./build_phase_b_android_llvm.sh
# Its objects now, before the Swift build needs the room: C2 links the
# libraries alone.
find "build/android$SUFFIX-llvm" -name '*.o' -delete
log "phase B's objects deleted"
phase C1 cmark ./build_phase_c1_android_cmark.sh
phase C2 swift-frontend ./build_phase_c2_android_swift.sh
archive "android-$ARCH-llvm" "build/android$SUFFIX-llvm"
archive "android-$ARCH-cmark" "build/android$SUFFIX-cmark"
archive "android-$ARCH-swift" "build/android$SUFFIX-swift" "android-swift-resources$SUFFIX" android-sysroot

log "the natives the APK carries"
"$ROOT/android/playground_android_application/stage_toolchain.sh" --native-only
tar -C "$ROOT/android/playground_android_application/toolchain" -cf - "native$SUFFIX" | zstd -q -T0 -19 -o "$OUT/native-$ARCH.tar.zst"
(cd "$OUT" && sha256sum *.tar.zst > SHA256SUMS && cat SHA256SUMS)
# Into OS Server's storage from here, when this lease can reach it (`oss`
# with a token or a grant's --url): kept seven days by SHA-256, until
# `oss files add <sha256>` makes each a served file for good. Else they wait
# in <out dir> for `oss machine download`.
if command -v oss > /dev/null; then
    for archive in "$OUT"/*.tar.zst; do
        oss storage put "$archive" --name="playground-$(basename "$archive")" --ttl=7d ${OSS_GRANT_URL:+--url="$OSS_GRANT_URL"} ||
            echo "oss storage put $(basename "$archive") failed: download it instead" >&2
    done
fi
log "done"
