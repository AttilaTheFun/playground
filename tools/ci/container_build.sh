#!/bin/bash
# CI's build of every platform in a Linux container, on a self-hosted
# runner's Mac: a container leased from that Mac's OS Server (`oss machine
# run container --inside`), in the image a Visor session runs in, so CI
# builds where an agent works. The Apple targets take Xcode 27.0's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository.
#
#   tools/ci/container_build.sh [<bazel build args>…]   # default: every
#                                     # app, then the tests without a GUI
#                                     # (verify's)
#   tools/ci/container_build.sh all   # every app and test built, nothing
#                                     # run or copied: main's populate (the
#                                     # Bazel cache's one writer: OS Server
#                                     # grants that job the write)
#   tools/ci/container_build.sh pr    # the default's build and tests: a pull
#                                     # request's (the owner, 2026-11-08:
#                                     # headless tests before a merge, builds
#                                     # after one)
#   tools/ci/container_build.sh package <dir> <bazel build args>…
#                                     # the build, then the targets' packages
#                                     # (.ipa, a Mac app's .zip, the signed
#                                     # .apk) copied to <dir>, in this checkout,
#                                     # for CI to publish
#
#   ISOMER_EXECUTION_LOGS  a folder for Bazel's execution logs (compact),
#                    to compare two runs' action keys when the cache misses
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   ISOMER_CI_IMAGE  the image (default: Visor's agent image, tools/ci/agent_image)
#   ISOMER_CI_VOLUME Bazel's tree, kept between builds (default: playground-ci;
#                    `:keep`, so OS Server keeps it when the lease ends)
#
# The Playground's compilers must be staged first
# (tools/ci/stage_playground_compilers.sh): the apps carry them.
#
# The tests without a GUI (the steps' tests, below) are the sites' import
# checks: a page whose site lacks a module it imports is blank, and only the
# browser's console says why. templates_compile_test needs a Mac's host
# toolchain (dev_compile_server.py reads Xcode's), and the GUI tests
# (tests/e2e, the iPhone's XCUITest probe) need a simulator and an
# emulator: neither runs here.
#
# package (the publishing jobs', as AttilaTheFun/reviews' container_build.sh
# has it): Bazel's tree is the container's (a volume), so what CI publishes
# is copied out into the checkout, the one folder of the Mac's the
# container sees, found by cquery with the build's own flags, from the
# execution root. Flags as --name=value (--compilation_mode=opt, not -c
# opt): every argument that doesn't start with "-" is taken for a target.
# An Android app's files are its signed .apk (published as signed by its
# build: Applications Server keeps no Android key), its unsigned one and its
# deploy jar; only the first is copied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${ISOMER_CI_IMAGE:-$(cat "$ROOT/tools/ci/agent_image")}"
VOLUME="${ISOMER_CI_VOLUME:-playground-ci}"
SDK_SHA256="251c252f7f41bcd3e08655e49e182686682d705945f4a2807049b9051c606ebb"

# In CI the job's own container builds (the playground-jit runners: OS Server's
# single-use Linux containers, its cache's read token in ~/.netrc and its
# cache in ~/.bazelrc already), in place. On a Mac (OS Server's own, whose
# folders containers may mount) it leases one, as before.
inside=""
[ "$(uname -s)" = Darwin ] || inside=1

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ] && [ -n "${OSS_SERVERS:-}" ]; then
    # The first of the servers' addresses (a URL, or host:port).
    host="${OSS_SERVERS%%[ ,]*}"
    host="${host#*://}"
    host="${host%%[:/]*}"
fi
if [ -z "$host" ] && [ -z "$inside" ]; then
    tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    host="$("$tailscale" status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi
[ -n "$host" ] || { echo "container_build.sh: no host for OS Server's files: set OSS_FILES_HOST (or OSS_SERVERS)" >&2; exit 1; }

# The placeholders in MODULE.bazel, to this Mac's OS Server.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
rewrite windows-sdks\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

mode=build
out=""
if [ "${1:-}" = package ]; then
    [ $# -ge 3 ] || { echo "usage: tools/ci/container_build.sh package <dir> <bazel build args…>" >&2; exit 1; }
    mkdir -p "$2"
    out="$(cd "$2" && pwd)"
    case "$out/" in
        "$ROOT"/*) ;;
        *) echo "container_build.sh: package's folder must be in this checkout ($ROOT)" >&2; exit 1 ;;
    esac
    rm -f "$out"/*
    chmod 775 "$out"
    mode=package
    shift 2
elif [ $# -eq 0 ] || [ "$*" = all ] || [ "$*" = pr ]; then
    mode=checks
    [ $# -eq 0 ] || mode="$*"
    # The iPhone's for the simulator: a device build needs a provisioning
    # profile, which only the publishing jobs make up (--config=ci_device).
    # Linux's app waits for isomer 0.47, whose Linux wasm cell builds again
    # (isomer 0.46's can't see its host's render flag).
    set -- --ios_multi_cpus=sim_arm64 \
        //apple/playground_ios_application:playground_ios_sim_application \
        //apple/playground_macos_application:playground_macos_application \
        //web/playground_web_application \
        //android/playground_android_application:playground_android_application_apk
fi

# In the container: the build and the tests without a GUI, or (package) the
# build and the packages copied out, Bazel reading the cache (--cache writes
# the container's ~/.bazelrc).
steps='
root=$1 mode=$2 out=$3; shift 3
cd "$root"
# The tests without a GUI (above).
tests=(
    //apple/playground_ios_application:playground_site_imports_test
    //web/splash_web_application:site_imports_test
)
flags=(--config=apple_on_linux "--downloader_config=$root/.ci/downloader.cfg")
# A pull request never writes the cache (OS Server grants populate alone the write).
[ "$mode" != pr ] || flags+=(--noremote_upload_local_results)
# An execution log an invocation, named for what it builds (ISOMER_EXECUTION_LOGS).
logs="${ISOMER_EXECUTION_LOGS:-}"
[ -z "$logs" ] || mkdir -p "$logs"
log_of() { [ -z "$logs" ] || printf -- "--execution_log_compact_file=%s/%s.zst" "$logs" "$1"; }
bazel build --keep_going "${flags[@]}" $(log_of build) "$@"
built=$?
# The tests without a GUI, after the targets: run, or (all: main builds
# alone, to fill the cache) built.
if [ "$mode" = all ]; then
    bazel build --keep_going "${flags[@]}" $(log_of tests) "${tests[@]}"
    tested=$?
elif [ "$mode" = checks ] || [ "$mode" = pr ]; then
    bazel test --keep_going "${flags[@]}" $(log_of tests) --test_output=errors "${tests[@]}"
    tested=$?
else
    tested=0
fi
[ $built -ne 0 ] || built=$tested
if [ "$mode" = package ]; then
    [ $built -eq 0 ] || exit $built
    options=()
    query=""
    # cquery takes one expression: the targets as a union of them.
    for argument in "$@"; do
        case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac
    done
    exec_root="$(bazel info "${flags[@]}" "${options[@]}" execution_root)" || exit
    files="$(bazel cquery "${flags[@]}" "${options[@]}" "$query" --output=files 2> /dev/null)" || exit
    for file in $files; do
        case "$file" in
            *_unsigned.apk) ;;
            *.ipa | *.zip | *.apk) cp "$exec_root/$file" "$out/" || exit ;;
        esac
    done
    ls -l "$out"
fi
exit $built
'

cd "$ROOT"
if [ -n "$inside" ]; then
    exec bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$@"
fi
exec oss machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$@"
