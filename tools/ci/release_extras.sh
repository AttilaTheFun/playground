#!/bin/bash
# A release's assets beyond its signed builds and its proof, from the Build
# workflow's `release` job (when the owner publishes a GitHub release: a
# v0.47.N tag on a main commit). The signed builds (Playground-<version>-ios.ipa,
# -macos.zip and -macos.dmg, -android.apk, and builds.json) come through
# Applications' interface: promote_from_ci.sh and publish_from_ci.sh
# --download, then attach_release.sh (the private AttilaTheFun/applications'
# docs/RELEASE_ASSETS.md). The proof (proof.zip, Reviews' format 2) and the
# site (playground-site.tar.gz, which pages.yml deploys) are attached to the
# draft by the proposal. This attaches the rest: the iPhone app for the
# simulator (an ipa is a zip: unzip it and `xcrun simctl install booted
# Payload/Playground.app`), Playground-<version>-iOS-Simulator.zip, until
# the app is on the App Store.
# isomer's tools/ci/release_assets.sh until Applications' script took that
# name (publish_from_ci.sh and promote_from_ci.sh source it beside them).
#
#   tools/ci/release_extras.sh upload <tag> <dir>…  # each dir's simulator app, named as above, onto the release
#
# With gh (installed when missing: gh_ready.sh) and GH_TOKEN, the job's:
# `contents: write` for the upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:?usage: release_extras.sh upload <tag> <dir>…}"
tag="${2:?<tag>}"
shift 2
repo="${GITHUB_REPOSITORY:-AttilaTheFun/playground}"
version="${tag#v}"

# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

case "$mode" in
upload)
    [ $# -gt 0 ] || { echo "release_extras: upload takes the folders" >&2; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    assets=()
    for dir in "$@"; do
        for file in "$dir"/*; do
            [ -f "$file" ] || continue
            name="$(basename "$file")"
            case "$name" in
                *playground*_sim_application.ipa) asset="Playground-$version-iOS-Simulator.zip" ;;
                *) echo "release_extras: $name isn't one of its assets, left out"; continue ;;
            esac
            cp "$file" "$work/$asset"
            assets+=("$work/$asset")
        done
    done
    [ ${#assets[@]} -gt 0 ] || { echo "::error::no assets"; exit 1; }
    gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
    for asset in "${assets[@]}"; do echo "release_extras: $tag: $(basename "$asset")"; done
    ;;
*)
    echo "usage: release_extras.sh upload <tag> <dir>…" >&2
    exit 1
    ;;
esac
