#!/bin/bash
# CI's build of every platform, on GitHub's own runners, each platform where
# its tools run (ISOMER_PLATFORMS), as isomer's tools/ci/container_build.sh:
# - web, linux and android: together, in one job and one Bazel output base,
#   on GitHub's x86_64 Ubuntu runner, in Swift's own image with the Linux
#   app's libraries added (tools/ci/job_tools.sh): Google's Android SDK and
#   NDK tools, and the hermetic JDK, are x86_64 programs, which GitHub's
#   arm64 runners have nothing to run (no Rosetta);
# - apple: on Nimbus' self-hosted Linux runners (the owner, 2026-11-27: no
#   paid GitHub runners), with rules_applecross (.bazelrc's apple_on_linux)
#   and Xcode 27.2's SDK served by Nimbus (ISOMER_APPLE_ON_LINUX=1, which
#   .github/actions/nimbus_bazel sets): Apple's SDKs may not be
#   redistributed, so no GitHub runner takes the archive. The Mac app's
#   compiler there is the staged one (stage_playground_compilers.sh macos),
#   as a Mac app built on Linux takes; on a Mac, the one Bazel assembles
#   from the building Mac's toolchains (shared/compiler/toolchain.bzl).
# Bazel's settings (its caches in GitHub's cache, BuildBuddy's on main, the
# downloads) are tools/ci/ci_bazel.sh's, written before this runs (the
# workflow's .github/actions/bazel_cache). Nothing of Shireworks.
#
#   tools/ci/container_build.sh [<bazel build args>…]   # default: every
#                                     # app, then the tests without a GUI
#                                     # (verify's)
#   tools/ci/container_build.sh all   # every app and test built, nothing
#                                     # run or copied: main's populate (the
#                                     # one writer of GitHub's cache)
#   tools/ci/container_build.sh pr    # the default's build and tests: a pull
#                                     # request's (the owner, 2026-11-08:
#                                     # headless tests before a merge, builds
#                                     # after one)
#   tools/ci/container_build.sh package <dir> <bazel build args>…
#                                     # the build, then the targets' packages
#                                     # (.ipa, a Mac app's .zip, the .apk)
#                                     # copied to <dir>, in this checkout, for
#                                     # CI to sign and publish
#
#   ISOMER_PLATFORMS  which of apple, android, web and linux (default: a
#                    Mac's apple; a Linux machine's web, linux and android)
#   ISOMER_EXECUTION_LOGS  a folder for Bazel's execution logs (compact),
#                    to compare two runs' action keys when the cache misses
#
# The apps build without the compilers they carry (the staged ones,
# tools/ci/stage_playground_compilers.sh): they then can't compile a
# project, which no test here asks of them. The publishing jobs and the
# proof stage them first.
#
# The tests without a GUI (the steps' tests, below) are the sites' import
# checks, with the web: a page whose site lacks a module it imports is
# blank, and only the browser's console says why. templates_compile_test
# needs a Mac's host toolchain (dev_compile_server.py reads Xcode's), and
# the GUI tests (tests/e2e, the iPhone's XCUITest probe) need a simulator
# and an emulator driven by hand: neither runs here.
#
# package (the publishing jobs'): the targets' files, found by cquery with
# the build's own flags, copied out of the execution root into the checkout.
# Flags as --name=value (--compilation_mode=opt, not -c opt): every argument
# that doesn't start with "-" is taken for a target. An Android app's files
# are its .apk (signed by its build with a debug key, which
# build_tools' `sign android` replaces with the release key), its unsigned one
# and its deploy jar; only the first is copied.
set -euo pipefail
# Bash 3.2 too: GitHub's Macs have no other (no mapfile, no ${!name}).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$(uname -s)" = Darwin ]; then
    default=apple
else
    default="web linux android"
fi
platforms=" ${ISOMER_PLATFORMS:-$default} "
for platform in $platforms; do
    case "$platform" in
        apple | android | web | linux) ;;
        *) echo "container_build.sh: no platform $platform (ISOMER_PLATFORMS: apple, android, web, linux)" >&2; exit 2 ;;
    esac
    if [ "$(uname -s)" = Darwin ] && [ "$platform" != apple ]; then
        echo "container_build.sh: a Mac builds the Apple platforms alone here; $platform is built on Linux" >&2; exit 2
    fi
    if [ "$(uname -s)" != Darwin ] && [ "$platform" = apple ] && [ "${ISOMER_APPLE_ON_LINUX:-}" != 1 ]; then
        echo "container_build.sh: the Apple platforms are built on a Mac, or on Linux with Xcode's SDK served (ISOMER_APPLE_ON_LINUX=1: a Nimbus runner)" >&2; exit 2
    fi
done
has() { [[ $platforms == *" $1 "* ]]; }
echo "container_build.sh: the platforms here:$platforms"

mode=build
out=""
apps=()
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
    # Each platform's app. The iPhone's for the simulator: a device build
    # needs a provisioning profile, which only the publishing jobs make up
    # (--config=ci_device).
    if has apple; then
        apps+=(//apple/playground_ios_application:playground_ios_sim_application
               //apple/playground_macos_application:playground_macos_application)
    fi
    if has web; then
        apps+=(//web/playground_web_application //web/splash_web_application:site)
    fi
    # With Android's, the release jobs' tools (build_tools' sign and what it
    # runs), built where the release jobs build them: a pull request that
    # breaks them fails here, not at a release.
    has android && apps+=(//android/playground_android_application:playground_android_application_apk //tools/ci_tools:all)
    has linux && apps+=(//linux/playground_linux_application)
    set -- --ios_multi_cpus=sim_arm64 ${apps[@]+"${apps[@]}"}
fi

# The build, then (the checks) the tests without a GUI, or (package) the
# packages copied out.
steps='
root=$1 mode=$2 out=$3 platforms=$4; shift 4
has() { [[ $platforms == *" $1 "* ]]; }
cd "$root"
# The tests without a GUI (above): the web-run site the iPhone and Android
# apps serve, and the whole web site.
tests=()
has web && tests+=(//apple/playground_ios_application:playground_site_imports_test
                   //web/splash_web_application:site_imports_test)
# An execution log an invocation, named for what it builds (ISOMER_EXECUTION_LOGS).
logs="${ISOMER_EXECUTION_LOGS:-}"
[ -z "$logs" ] || mkdir -p "$logs"
log_of() { [ -z "$logs" ] || printf -- "--execution_log_compact_file=%s/%s.zst" "$logs" "$1"; }
built=0
targets=0
for argument in "$@"; do case "$argument" in -*) ;; *) targets=1 ;; esac; done
if [ $targets -eq 1 ]; then
    bazel build --keep_going $(log_of build) "$@"
    built=$?
fi
if [ "$mode" = package ]; then
    [ $built -eq 0 ] || exit $built
    options=()
    query=""
    # cquery takes one expression: the targets as a union of them.
    for argument in "$@"; do
        case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac
    done
    exec_root="$(bazel info "${options[@]}" execution_root)" || exit
    files="$(bazel cquery "${options[@]}" "$query" --output=files 2> /dev/null)" || exit
    for file in $files; do
        case "$file" in
            *_unsigned.apk) ;;
            *.ipa | *.zip | *.apk) cp "$exec_root/$file" "$out/" || exit ;;
        esac
    done
    ls -l "$out"
    exit 0
fi
[ "$mode" = checks ] || [ "$mode" = all ] || [ "$mode" = pr ] || exit $built
tested=0
if [ ${#tests[@]} -gt 0 ]; then
    # all: the tests built, not run (main builds alone, to fill the cache).
    if [ "$mode" = all ]; then
        bazel build --keep_going $(log_of tests) "${tests[@]}"
    else
        bazel test --keep_going $(log_of tests) --test_output=errors "${tests[@]}"
    fi
    tested=$?
fi
df -h / /mnt 2> /dev/null || df -h /
[ $built -ne 0 ] || built=$tested
exit $built
'

cd "$ROOT"
exec bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$platforms" "$@"
