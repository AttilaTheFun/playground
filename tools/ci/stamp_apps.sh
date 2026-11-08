#!/bin/bash
# Stamps a publishing job's checkout with its builds' version, before they
# are built: the Playground's, on every platform (AGENTS.md, "Versions").
# MODULE.bazel and the apps commit MAJOR.MINOR.0; a build is MAJOR.MINOR.N,
# the number releases are tagged with (v0.47.N), the next of the line for
# the job's commit, from Applications Server (tools/ci/next_version.sh,
# which writes it into the iPhone's and the Mac's Info.plists'
# CFBundleShortVersionString). Then the Playground's own stamp
# (tools/playground/stamp.py) writes the same version wherever else the
# apps show it: Android's versionName and versionCode (MAJOR x 1,000,000 +
# MINOR x 1,000 + N), the web page's, the desktop hosts'. Never committed:
# each job checks out afresh.
#
#   tools/ci/stamp_apps.sh
#
# From the job's environment, as next_version.sh's: its `permissions:
# id-token: write`, APPLICATIONS_CI_CODE and APPLICATIONS_AUDIENCE. A server
# without POST /api/next-version leaves the committed MAJOR.MINOR.0, with a
# warning (next_version.sh), and the stamp then writes that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The iPhone app first: next_version.sh takes the line from the first
# Info.plist.
plists=(
    "$ROOT/apple/playground_ios_application/Info.plist"
    "$ROOT/apple/playground_macos_application/Info.plist"
)
"$ROOT/tools/ci/next_version.sh" Playground "${plists[@]}"

# What next_version.sh wrote (or, from an older server, what was committed).
version="$(awk '
    /<key>CFBundleShortVersionString<\/key>/ { found = 1 }
    found && match($0, /<string>[^<]*<\/string>/) { print substr($0, RSTART + 8, RLENGTH - 17); exit }' "${plists[0]}")"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "stamp_apps: ${plists[0]}'s version, \"$version\", is not MAJOR.MINOR.BUILD" >&2; exit 1 ;;
esac

python3 "$ROOT/tools/playground/stamp.py" "$version"
echo "stamp_apps: the Playground is $version"
