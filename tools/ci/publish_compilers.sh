#!/bin/bash
# The Playground's compilers (the archives tools/ci/stage_playground_compilers.sh
# names by SHA-256) uploaded as the assets of this repository's `compilers`
# release, each named by its SHA-256, where CI stages them from. A
# maintainer's, run by hand with a login that may make the release and its
# tag (an agent's may not); never run by CI.
#
#   tools/ci/publish_compilers.sh <dir>               # the archives in <dir>, each
#                                                     # named by its SHA-256
#   tools/ci/publish_compilers.sh --from-shireworks   # each taken from Shireworks'
#                                                     # files first, where they were
#                                                     # kept until 2026-11-17
#
# --from-shireworks reads them as CI did before (tools/ci/shireworks.sh
# files-url and cache-token: SHIREWORKS_SERVERS with a key or token, as for
# any of its commands), with the read token in a netrc of its own, never on
# a command line. Every archive is checked against its SHA-256 before it is
# uploaded. The release is made when missing: `compilers`, a pre-release at
# main's head (a pre-release is never the repository's latest release, which
# pages.yml deploys, and its tag is no v<line>.N, which versions count). An
# asset already there is kept: its name is its bytes' SHA-256.
#
# With gh, logged in, and curl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="${GITHUB_REPOSITORY:-AttilaTheFun/playground}"
TAG=compilers
fail() { echo "publish_compilers: $*" >&2; exit 1; }
[ $# -eq 1 ] || fail "usage: tools/ci/publish_compilers.sh <dir> | --from-shireworks"
sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# Every archive stage_playground_compilers.sh names.
shas="$(sed -n 's/^[A-Z0-9_]*_TOOLCHAIN=\([0-9a-f]\{64\}\)$/\1/p' "$ROOT/tools/ci/stage_playground_compilers.sh")"
[ -n "$shas" ] || fail "no SHA-256 in tools/ci/stage_playground_compilers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
if [ "$1" = --from-shireworks ]; then
    from="$work/archives"
    mkdir -p "$from"
    for sha in $shas; do
        url="$("$ROOT/tools/ci/shireworks.sh" files-url "$sha")"
        host="${url#*://}"
        host="${host%%[:/]*}"
        if ! grep -qs "^machine $host " "$work/netrc"; then
            token="$("$ROOT/tools/ci/shireworks.sh" cache-token)" || fail "no read token for Shireworks' files"
            (umask 077 && printf 'machine %s login bazel password %s\n' "$host" "$token" >> "$work/netrc")
        fi
        curl -fsSL --retry 3 --netrc-file "$work/netrc" -o "$from/$sha" "$url" || fail "$sha wasn't read from Shireworks' files"
    done
else
    from="$(cd "$1" && pwd)"
fi

if ! gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
    target="$(gh api "repos/$REPO/commits/main" --jq .sha)"
    gh release create "$TAG" --repo "$REPO" --prerelease --target "$target" --title "The Playground's compilers" \
        --notes "The compilers the Playground's apps carry, each asset named by its SHA-256, for CI to stage (tools/ci/stage_playground_compilers.sh). Not a release of the Playground." ||
        fail "the $TAG release wasn't made"
fi
there="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')"
for sha in $shas; do
    if grep -qx "$sha" <<< "$there"; then
        echo "publish_compilers: $sha is there already"
        continue
    fi
    [ -f "$from/$sha" ] || fail "no archive $sha in $from"
    [ "$(sha256 "$from/$sha")" = "$sha" ] || fail "$from/$sha's bytes aren't $sha"
    gh release upload "$TAG" --repo "$REPO" "$from/$sha" || fail "$sha wasn't uploaded"
    echo "publish_compilers: $sha uploaded"
done
