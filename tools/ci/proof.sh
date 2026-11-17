#!/bin/bash
# The Playground's proof, from CI: its app on the tier-1 platforms
# (PLATFORMS below), each with its one renderer (SwiftUI on iOS and the Mac,
# Compose on Android, the DOM renderer on the web), pictured
# (tools/proof/proof.py), and the proof Reviews reads made of them in its
# format 2 (tools/ci/proof_write.swift; the private AttilaTheFun/reviews'
# docs/PROOF_FORMAT.md): every picture an item under an id stable from
# release to release (ios/phone/<screen>, macos/window/<screen>,
# android/phone/<screen>, web/desktop/<screen>). Its screens: the projects,
# a project open, and 2048 and the Pokédex built on the device and running.
# Nothing is compared across versions here: Reviews compares a release's
# proof with the release before it. As isomer's tools/ci/proof.sh, for the
# Playground.
#
# In stages, as CI runs it on GitHub's own machines (free for a public
# repository), with nothing of Shireworks: built where each platform
# builds, pictured where it runs, then written (.github/workflows/build.yml's
# proof jobs):
#
#   --stage build --platform <platform>[,<platform>…] --apps <dir> --review <dir>
#       each platform's app built into <apps>/<platform>/: web and android
#       in CI's x86_64 Linux container (Android's for x86_64, the compiler it
#       carries x86_64's, for the Ubuntu runner's emulator), ios and macos on
#       a Mac with its Xcode (Apple's SDKs aren't served to Linux:
#       tools/ci/container_build.sh); the compilers the apps carry staged
#       first (tools/ci/stage_playground_compilers.sh: the simulator's for
#       ios, Android's for android, the browser's for web)
#   --stage shoot --platform ios|macos|android|web --apps <dir> --review <dir>
#       (GitHub's runner: `xcode-27` for the iPhone and the Mac, Ubuntu for
#       Android, on its KVM, and the web) one platform's app pictured on
#       that machine (proof.py --here), into <review>
#   --stage compare --parts <dir> --proof <dir>
#       (CI's container) the stages' <review> folders, as subfolders of
#       <parts>, written into the proof
#
# Run only by hand (the Build workflow's workflow_dispatch), to propose a
# release or, after the fact, to bisect a regression. full and quick take
# the same screens (the Playground's are few); a quick proof's review
# folders are marked so, and never stand for a release.
#
# The proof, in <dir>: proof.json (format 2) and its pictures,
# screens/<id>.png; the `proof` artifact of the run, and, zipped, the
# proof.zip a proposal's draft carries (alpha, tools/ci/proof_zip.sh). The
# script fails when the app doesn't build or a picture doesn't come back.
#
# The builds are proof.py's (--build-to), with Bazel's settings
# tools/ci/ci_bazel.sh wrote for the job. Linux's and Windows' pictures
# (tier 2) are proof.py's alone, run by hand (on Shireworks' machines).
#
#   PROOF_PYTHON        the python3 that runs proof.py, with Pillow, which crops
#                       the desktops' pictures (default: the PATH's python3)
#   PROOF_VERSION       the version the proof is of (default: the app's
#                       committed MAJOR.MINOR.0)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Tier 1 only, as isomer's. proof.py still pictures Linux and Windows when
# named, by hand.
PLATFORMS="${PROOF_PLATFORMS:-ios macos android web}"

usage() {
    cat >&2 << 'EOF2'
usage: tools/ci/proof.sh --stage build --platform <platform>[,<platform>…] --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage shoot --platform <platform> --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage compare --parts <dir> --proof <dir> [--kind quick|full]
EOF2
    exit 2
}
stage=""
proof=""
kind="quick"
apps=""
review=""
platform=""
parts=""
while [ $# -gt 0 ]; do
    case "$1" in
        --stage) stage="${2:?--stage takes build, shoot or compare}"; shift 2 ;;
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        --apps) apps="${2:?--apps takes a folder}"; shift 2 ;;
        --review) review="${2:?--review takes a folder}"; shift 2 ;;
        --platform) platform="${2:?--platform takes a platform}"; shift 2 ;;
        --parts) parts="${2:?--parts takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done
case "$kind" in quick | full) ;; *) usage ;; esac
absolute() { mkdir -p "$1" && (cd "$1" && pwd); }
case "$stage" in
    build) [ -n "$platform" ] && [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    shoot) [ -n "$platform" ] && [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    compare) [ -n "$parts" ] && [ -n "$proof" ] || usage ;;
    *) usage ;;
esac
[ -z "$proof" ] || proof="$(absolute "$proof")"
[ -z "$apps" ] || apps="$(absolute "$apps")"
[ -z "$review" ] || review="$(absolute "$review")"
[ -z "$parts" ] || parts="$(absolute "$parts")"
# Whether this stage runs a step: `stages build compare && …`.
stages() { case " $* " in *" $stage "*) return 0 ;; esac; return 1; }

cd "$ROOT"
commit="$(git rev-parse HEAD)"
repo="${GITHUB_REPOSITORY:-AttilaTheFun/playground}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/playground-proof.XXXXXX")"
started=$SECONDS
phase() { echo "proof.sh: $1 ($((SECONDS - started)) s in)"; }

# What runs long runs in the background, waited for, so a signal's trap
# runs at once (bash runs it only when a foreground command returns).
children=""
background() {
    "$@" &
    local pid=$!
    children="$children $pid"
    wait "$pid"
}
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2> /dev/null); do kill_tree "$child"; done
    kill "$1" 2> /dev/null || true
}
cleanup() {
    local status=$?
    # The exit's status stands: nothing here may end it otherwise.
    set +e
    for pid in $children; do kill_tree "$pid"; done
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# --- The steps the stages share or have alone (run below as the stage says)

# The review folders under the given roots, each platform's checked for
# pictures, written into the proof (format 2).
compare() {
    local platform
    for platform in $PLATFORMS; do
        if [ -z "$(find "$@" -maxdepth 3 -path "*/review-$platform-playground/*.png" -print -quit 2> /dev/null)" ]; then
            echo "::error::no picture of $platform's Playground"
            status=1
        fi
    done
    "$work/proof_write" "$proof" --app Playground --version "$version" --repository "$repo" --commit "$commit" \
        ${GITHUB_RUN_ID:+--run "$GITHUB_RUN_ID"} "$@" | tee "$work/summary.md"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
    phase "done: $(find "$proof/screens" -name '*.png' 2> /dev/null | wc -l | tr -d ' ') pictures"
}

# --stage build: the platforms' apps built for the stage that pictures
# them, each with the compiler it carries staged first. Only ever in a run
# by hand or a release's (the owner: no proof on a push or a pull request),
# so main's populate never builds them.
build() {
    local here=() wanted compilers=()
    for wanted in ${platform//,/ }; do
        case "$wanted" in
            ios) here+=(ios); compilers+=(ios-simulator) ;;
            macos) here+=(macos) ;;
            web) here+=(web); compilers+=(web) ;;
            android) compilers+=(android android-x86_64) ;;
            *) usage ;;
        esac
    done
    if [ ${#compilers[@]} -gt 0 ]; then
        echo "::group::The Playground's compilers"
        "$ROOT/tools/ci/stage_playground_compilers.sh" "${compilers[@]}"
        echo "::endgroup::"
        phase "compilers staged"
    fi
    local web_toolchain=()
    [[ ",$platform," != *",web,"* ]] || web_toolchain=(--web-toolchain "$ROOT/web/playground_web_application/staged_toolchain")
    echo "::group::The apps, built (tools/proof/proof.py --build-to)"
    if [ ${#here[@]} -gt 0 ]; then
        background "$python" -u "$ROOT/tools/proof/proof.py" "${here[@]}" --build-to "$apps" --review "$review" \
            --commit "$commit" ${web_toolchain[@]+"${web_toolchain[@]}"} || { echo "::error::the apps didn't build"; exit 1; }
    fi
    if [[ ",$platform," == *",android,"* ]]; then
        background "$python" -u "$ROOT/tools/proof/proof.py" android --android-abi x86_64 \
            --build-to "$apps/hosted" --review "$review" --commit "$commit" ||
            { echo "::error::the Android Playground (x86_64) didn't build"; exit 1; }
    fi
    echo "::endgroup::"
    phase "built"
}

# --stage shoot, before anything else: what the platform's machine needs.
# GitHub's runners: Python's own (Pillow in a venv of the run's), Xcode
# 27.2 for the simulator, the Mac's screen made the proof's 1920 by 1200
# (its own is 1024 by 768), an emulator booted on the Ubuntu runner's KVM,
# its Chrome.
shoot_setup() {
    echo "::group::This machine, for $platform's pictures"
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" install -q pillow
    shoot_python="$work/venv/bin/python3"
    case "$platform" in
        ios)
            if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
                export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
            fi
            xcrun simctl list runtimes ;;
        macos)
            brew install displayplacer > /dev/null 2>&1 || true
            local screen
            screen="$(displayplacer list 2> /dev/null | sed -n 's/^Persistent screen id: //p' | head -1 || true)"
            # The screen the proof's Mac pictures have always had (1920 by
            # 1200 at 1x, Shireworks' mac slots'), so the app opens its
            # window at the size it always has; else the nearest the
            # runner's display has.
            if [ -z "$screen" ] || ! { displayplacer "id:$screen res:1920x1200 scaling:off origin:(0,0) degree:0" > /dev/null 2>&1 ||
                displayplacer "id:$screen res:1920x1080 scaling:off origin:(0,0) degree:0" > /dev/null 2>&1; }; then
                echo "::warning::the runner's screen stayed as it was (displayplacer)"
            fi
            osascript -l JavaScript -e 'ObjC.import("AppKit"); const f = $.NSScreen.mainScreen.frame; `screen ${f.size.width}x${f.size.height}`' ;;
        android)
            export PROOF_ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/platform-tools/adb"
            "$ROOT/tools/ci/hosted_android_emulator.sh" "$review/emulator.log" "$work/serial" < /dev/null
            PROOF_ANDROID_SERIAL="$(cat "$work/serial")"
            export PROOF_ANDROID_SERIAL ;;
        web)
            CDP_CHROME="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || true)"
            [ -n "$CDP_CHROME" ] || { echo "::error::no Chrome on this runner"; exit 1; }
            # Ubuntu 24.04's AppArmor keeps Chrome's sandbox from its user
            # namespaces.
            export CDP_CHROME CDP_CHROME_FLAGS="--no-sandbox ${CDP_CHROME_FLAGS:-}" ;;
        *) usage ;;
    esac
    echo "::endgroup::"
}

# --stage shoot: the platform's app pictured on this machine.
shoot() {
    local from="$apps"
    # Android's for x86_64, the runner's.
    [ "$platform" != android ] || from="$apps/hosted"
    echo "::group::$platform's app, pictured here (tools/proof/proof.py --here)"
    background "$python" -u "$ROOT/tools/proof/proof.py" "$platform" --here --from "$from" \
        --review "$review" --commit "$commit" ${quick[@]+"${quick[@]}"} ||
        { echo "::error::$platform: a picture didn't come back"; exit 1; }
    echo "::endgroup::"
    phase "$platform pictured"
}

# What each stage needs on its machine. proof.py's python with Pillow:
# without, its desktops' pictures go uncropped (the clocks, the wallpaper),
# which it only logs.
if stages shoot; then
    shoot_setup
elif [ "$(uname -s)" = Darwin ]; then
    # A Mac building the Apple apps: Pillow in a venv of the run's.
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" install -q pillow
    shoot_python="$work/venv/bin/python3"
else
    # A Linux container: git, Python with Pillow, unzip, zstd (the Android
    # x86_64 compiler's archive).
    echo "::group::The container's tools"
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    packages=(git python3 python3-pil unzip zstd)
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null; }
    echo "::endgroup::"
fi
# The proof's writer, for the stage that writes it (a Linux container's).
if stages compare; then
    swiftc -O -o "$work/proof_write" "$ROOT/tools/ci/proof_write.swift"
fi
python="${PROOF_PYTHON:-${shoot_python:-python3}}"
"$python" -c 'import PIL' 2> /dev/null || { echo "::error::$python has no Pillow (PROOF_PYTHON names one that has)"; exit 1; }

quick=()
if [ "$kind" = quick ]; then quick=(--quick); fi
if stages shoot; then
    shoot
    exit 0
fi

if stages build; then
    build
    exit 0
fi

# What the proof is of: the version (the app's committed line's, or
# PROOF_VERSION, a proposal's own).
version="${PROOF_VERSION:-$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/apple/playground_ios_application/Info.plist")}"

if stages compare; then
    status=0
    compare "$parts" "$parts"/*
    exit "$status"
fi

usage
