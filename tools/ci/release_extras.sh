#!/bin/bash
# A release's assets beyond its signed builds, from the Build workflow's
# `release` job (when the owner publishes a GitHub release: a v0.47.N tag on
# a main commit). The signed builds (Playground-<version>-ios.ipa, -macos.zip
# and -macos.dmg, -android.apk, and builds.json) come through Applications'
# interface: promote_from_ci.sh and publish_from_ci.sh --download, then
# attach_release.sh (the private AttilaTheFun/applications'
# docs/RELEASE_ASSETS.md). Beside them, and the source GitHub archives itself
# and the site (playground-site.tar.gz, attached to the draft, which
# pages.yml deploys), this attaches:
#   - proof.tar.gz: its commit's proof (screens/, before/, diffs/,
#     proof.json: the `proof` artifact of the newest run of this workflow on
#     that commit), so that the next release's proof compares with it after
#     the artifact's 90 days (tools/ci/proof.sh);
#   - the iPhone app for the simulator (an ipa is a zip: unzip it and
#     `xcrun simctl install booted Payload/Playground.app`):
#     Playground-<version>-iOS-Simulator.zip. Until the app is on the App
#     Store.
# isomer's tools/ci/release_assets.sh until Applications' script took that
# name (publish_from_ci.sh and promote_from_ci.sh source it beside them).
#
#   tools/ci/release_extras.sh proof <tag> <dir>   # <dir>/proof.tar.gz, or fails: no release without its proof
#   tools/ci/release_extras.sh upload <tag> <dir>…  # each dir's proof and simulator app, named as above, onto the release
#
# With gh (installed when missing: gh_ready.sh) and GH_TOKEN, the job's:
# `contents: write` for the upload, `actions: read` for the proof.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:?usage: release_extras.sh proof <tag> <dir> | upload <tag> <dir>…}"
tag="${2:?<tag>}"
shift 2
repo="${GITHUB_REPOSITORY:-AttilaTheFun/playground}"
version="${tag#v}"

# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

case "$mode" in
proof)
    out="$(mkdir -p "${1:?<dir>}" && cd "$1" && pwd)"
    commit="$(git -C "$ROOT" rev-list -n 1 "$tag")"
    # The newest run of this workflow on the commit with a proof.
    run="$(gh api --paginate "repos/$repo/actions/artifacts?name=proof&per_page=100" \
        --jq ".artifacts[] | select(.expired | not) | select(.workflow_run.head_sha == \"$commit\") | .workflow_run.id" |
        sort -nr | head -1)"
    [ -n "$run" ] || { echo "::error::no proof of $tag's commit $commit (run the Build workflow on it by hand first)"; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    gh run download "$run" --repo "$repo" --name proof --dir "$work/proof"
    [ -f "$work/proof/proof.json" ] || { echo "::error::run $run's proof has no proof.json"; exit 1; }
    tar -czf "$out/proof.tar.gz" -C "$work/proof" .
    echo "release_extras: $tag's proof from run $run, $(ls "$work/proof/screens" | wc -l | tr -d ' ') pictures"
    ;;
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
                proof.tar.gz) asset="$name" ;;
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
    echo "usage: release_extras.sh proof <tag> <dir> | upload <tag> <dir>…" >&2
    exit 1
    ;;
esac
