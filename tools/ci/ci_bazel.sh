#!/bin/bash
# CI's Bazel settings, on GitHub's runners alone (nothing of the project's
# own servers): written before a job's first Bazel command, as the
# Playground's .bazelrc.user (which .bazelrc try-imports), so every Bazel
# the job runs reads them, its scripts', tools/proof/proof.py's and
# tools/playground/package_site.sh's alike. Copied from isomer's
# tools/ci/ci_bazel.sh, for the Playground's one module.
#
#   tools/ci/ci_bazel.sh setup [<cache>]   # the settings (<cache>: ISOMER_BAZEL_CACHE)
#   tools/ci/ci_bazel.sh trim <cache> <GB> # the disk cache cut to <GB>, before it is saved
#
# setup writes:
# - Bazel's disk cache and repository cache in <cache>/disk and
#   <cache>/repository, which the workflow keeps in GitHub's cache
#   (actions/cache, by job and MODULE.bazel), when a cache is named;
# - GitHub's downloads tried at GitHub, then at Bazel's mirror (GitHub's
#   release downloads have failed with 504s for hours), and Maven Central's
#   at Central, then at Google's mirror of it (Central has answered 404 for
#   artifacts it has), each retried: tools/ci/downloader.cfg;
# - Bazel's tree (--output_user_root) in ISOMER_BAZEL_ROOT when it is set
#   and can be made: the x86_64 runner's second disk (/mnt), its first
#   being too small for an Android build's;
# - Windows on Linux (--config=windows_on_linux's toolchains), when
#   ISOMER_WINDOWS_SDKS says where the Windows Swift SDK and Microsoft's
#   sysroot are: a folder holding them (Bazel's --distdir), or a URL serving
#   each file by its SHA-256 (<url>/<sha256>, as MODULE.bazel's
#   windows-sdks.invalid placeholders name them). Microsoft's may not be
#   redistributed, so nothing public serves it, and CI names none: the
#   Playground's CI builds no Windows app (tier 2; built by hand on Windows).
# - BuildBuddy's remote cache (.bazelrc's --config=buildbuddy), when
#   BUILDBUDDY_API_KEY is set: the config and the key's headers in a file of
#   the job's own outside the checkout (mode 600), which .bazelrc.user
#   imports by its path, the key never on a command line nor in the log.
#   The workflow hands the key to every job on GitHub's runners, before a
#   merge and after it (the owner, 2026-11-23): each reads and writes. A
#   fork's pull request gets no secrets from GitHub, so it builds on
#   GitHub's cache alone. main's builds (a push to main: populate, bazel8)
#   and the release jobs (alpha and alpha-apple on main, a published
#   release's) download every output, so the disk cache GitHub's cache
#   keeps (above) stays whole for the runs with no key; the others download
#   only the top-level outputs (Bazel's default, the files the jobs copy and
#   run).
#   The cache the signed builds read is reviewed code's alone: runs on main
#   and a published release's (the Alphas and the release jobs sign what
#   they build) use one instance, and every other run (a pull request's, a
#   branch's) another, `-unreviewed`, so a pull request's scripts can't put
#   a result where a signed build would take it (Visor's catch, 2026-11-23).
#   A pull request reads and writes its own instance, warm from the pull
#   requests before it on the same dependency graph.
# BuildBuddy's cache is partitioned by the dependency graph
# (--remote_instance_name, a hash of MODULE.bazel and the SwiftPM graph): a
# Swift SDK's modules aren't a compile's inputs, so one isomer's outputs
# would otherwise be served to the next's actions of the same key.
# Never the Apple targets on Linux (.bazelrc's apple_on_linux, which takes
# Xcode's SDK archive): Apple's SDKs may not be redistributed, so CI builds
# the Apple targets on GitHub's Macs with their own Xcode (the owner,
# 2026-11-15). A builder with the archive turns apple_on_linux on in a
# .bazelrc.user of its own, as tools/linux/build.sh does.
# It refuses to replace a .bazelrc.user it didn't write (a builder's own).
#
# trim: Bazel collects its disk cache's garbage only when its server is
# idle, which a CI job's seldom is, so the oldest entries (Bazel touches an
# entry each time it is read) are removed until the cache is under <GB>:
# the caches a workflow keeps share GitHub's 10 GB a repository.
set -euo pipefail
# A folder as Bazel names it: on Windows (Git's bash, CI's windows-11-arm
# job) D:/a/…, not /d/a/….
here() { case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) pwd -W ;; *) pwd ;; esac; }
ROOT="$(cd "$(dirname "$0")/../.." && here)"
MARK="# tools/ci/ci_bazel.sh's: CI's Bazel settings"
fail() { echo "ci_bazel: $*" >&2; exit 1; }

case "${1:-}" in
setup)
    cache="${2:-${ISOMER_BAZEL_CACHE:-}}"
    mkdir -p "$ROOT/.ci"
    cp "$ROOT/tools/ci/downloader.cfg" "$ROOT/.ci/downloader.cfg"
    # No bazel-* convenience symlinks in the checkout: rules_swift_package_manager
    # copies a local package with `cp -RL`, which follows them into
    # Bazel's output tree and its dangling links, and fails the fetch.
    lines=("$MARK" "common --downloader_config=$ROOT/.ci/downloader.cfg"
           "common --experimental_repository_downloader_retries=5"
           "common --experimental_convenience_symlinks=ignore")
    if [ -n "${ISOMER_BAZEL_ROOT:-}" ]; then
        if mkdir -p "$ISOMER_BAZEL_ROOT" 2> /dev/null && [ -w "$ISOMER_BAZEL_ROOT" ]; then
            lines+=("startup --output_user_root=$ISOMER_BAZEL_ROOT")
        else
            echo "::warning::ci_bazel: $ISOMER_BAZEL_ROOT can't be made: Bazel's tree stays in its default place"
        fi
    fi
    # BuildBuddy, with the key: never traced, never echoed.
    if [ -n "${BUILDBUDDY_API_KEY:-}" ]; then
        set +x
        # Whether this run downloads every output, and whether it is
        # reviewed code's, which alone shares the signed builds' instance
        # (above).
        whole=0
        reviewed=0
        case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
            push:refs/heads/main | release:*) whole=1 reviewed=1 ;;
            workflow_dispatch:refs/heads/main | schedule:refs/heads/main)
                reviewed=1
                case "${GITHUB_JOB:-}" in alpha | alpha-apple) whole=1 ;; esac ;;
        esac
        instance="playground"
        if [ $reviewed -eq 0 ]; then instance="playground-unreviewed"; fi
        secret_dir="$HOME/.config/playground-ci"
        (umask 077 && mkdir -p "$secret_dir")
        chmod 700 "$secret_dir"
        secret_rc="$secret_dir/buildbuddy.bazelrc"
        (umask 077 && : > "$secret_rc")
        chmod 600 "$secret_rc"
        # BuildBuddy's cache partitioned by the dependency graph (MODULE.bazel
        # and the SwiftPM graph): the Swift SDKs' modules aren't among a
        # compile's inputs, so after an isomer bump an action's key can be
        # what it was before it, and its old output (compiled against the old
        # Foundation) was served stale (a dry run of isomer 0.55.1 to 0.56.1:
        # the Android app's link failed). The disk cache GitHub keeps is
        # restored by the same graph alone (.github/actions/bazel_cache).
        graph="$(cat "$ROOT/MODULE.bazel" "$ROOT"/third_party/swift_packages/Package.resolved 2> /dev/null |
            { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; } | cut -c1-16)"
        {
            echo "common --config=buildbuddy"
            echo "common --remote_instance_name=$instance-$graph"
            printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            printf 'common --bes_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            if [ $whole -eq 1 ]; then echo "common --remote_download_all"; fi
        } >> "$secret_rc"
        unset BUILDBUDDY_API_KEY
        secret_rc="$(cd "$secret_dir" && here)/buildbuddy.bazelrc"
        lines+=("try-import $secret_rc")
        echo "ci_bazel: BuildBuddy's remote cache ($instance), read and written$([ $whole -eq 1 ] && echo ", every output downloaded") (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
    else
        # A fork's pull request (GitHub gives it no secrets), or a builder's own.
        echo "ci_bazel: no BUILDBUDDY_API_KEY: no remote cache, GitHub's cache alone"
    fi
    if [ -n "$cache" ]; then
        mkdir -p "$cache/disk" "$cache/repository"
        cache="$(cd "$cache" && here)"
        lines+=("common --disk_cache=$cache/disk" "common --repository_cache=$cache/repository")
    fi
    # sdks <ISOMER_*_SDKS's value> <placeholder host> <rewrite of it>: a
    # folder as a distdir, a URL as the placeholder's rewrite.
    sdks() {
        case "$1" in
            http://* | https://*)
                printf '%s\n' "$3" | sed "s|@URL@|${1%/}|" >> "$ROOT/.ci/downloader.cfg" ;;
            *)
                [ -d "$1" ] || fail "$2: no folder $1"
                lines+=("common --distdir=$(cd "$1" && here)") ;;
        esac
    }
    if [ -n "${ISOMER_WINDOWS_SDKS:-}" ]; then
        sdks "$ISOMER_WINDOWS_SDKS" ISOMER_WINDOWS_SDKS "rewrite windows-sdks\\.invalid/sha256/(.*) @URL@/\$1"
    fi
    rc="$ROOT/.bazelrc.user"
    if [ -e "$rc" ] && ! head -1 "$rc" | grep -qxF "$MARK"; then
        fail "$rc is a builder's own: not replaced"
    fi
    printf '%s\n' "${lines[@]}" > "$rc"
    echo "ci_bazel: Bazel's settings written ($ROOT/.bazelrc.user):"
    sed 's/^/  /' "$ROOT/.bazelrc.user"
    ;;
trim)
    cache="${2:?usage: ci_bazel.sh trim <cache> <GB>}"
    gb="${3:?usage: ci_bazel.sh trim <cache> <GB>}"
    [[ "$gb" =~ ^[0-9]+$ ]] || fail "<GB> is a whole number of gigabytes"
    [ -d "$cache/disk" ] || { echo "ci_bazel: no disk cache in $cache"; exit 0; }
    limit=$((gb * 1024 * 1024))
    # Every entry's time and size (KB), the newest first; what is past the
    # limit, counted from the newest, goes. python3: find's -printf is
    # GNU's alone, and a Mac's runner trims too. Windows' Python may be
    # `python` alone (its `python3` the Store's stub).
    python=""
    for candidate in python3 python; do
        if command -v "$candidate" > /dev/null && "$candidate" -c "" 2> /dev/null; then python="$candidate"; break; fi
    done
    [ -n "$python" ] || fail "no Python here"
    "$python" -I - "$cache/disk" "$limit" << 'PY'
import os, sys
root, limit = sys.argv[1], int(sys.argv[2]) * 1024
entries = []
for folder, _, names in os.walk(root):
    for name in names:
        path = os.path.join(folder, name)
        try:
            stat = os.lstat(path)
        except OSError:
            continue
        entries.append((stat.st_mtime, stat.st_size, path))
entries.sort(reverse=True)
kept = removed = 0
for _, size, path in entries:
    if kept + size <= limit:
        kept += size
    else:
        os.remove(path)
        removed += size
print(f"ci_bazel: the disk cache is {kept / 2**30:.2f} GB ({removed / 2**30:.2f} GB of its oldest entries removed)")
PY
    ;;
*)
    echo "usage: tools/ci/ci_bazel.sh setup [<cache>] | trim <cache> <GB>" >&2
    exit 2
    ;;
esac
