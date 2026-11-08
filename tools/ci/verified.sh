#!/bin/bash
# Whether a commit was verified: a run of the Build workflow by hand on it
# (`run: verify` or `run: release`) whose verify job (the build and the
# tests in the container) passed, and its proof: proof-compare for a public
# repository (its proof pictured on GitHub's runners), the proof job for a
# private one. A job missing from the run fails it. The release job asks it
# before anything is promoted (AttilaTheFun/reviews' docs/CI_POLICY.md). As
# isomer's tools/ci/verified.sh, less the jobs of tests this repository
# doesn't have (isomer's apple and android).
#
#   tools/ci/verified.sh <commit>
#
# GH_TOKEN: the job's token (`actions: read`). Prints the verified run.
set -euo pipefail
sha="${1:?usage: verified.sh <commit>}"
repo="${GITHUB_REPOSITORY:?}"
# Which jobs ran depends on it: a public repository's proof is pictured on
# GitHub's runners and compared in proof-compare, a private one's in proof
# alone. A job missing from a run fails it, so a job renamed here or in the
# workflow can't drop out of the check unseen (as isomer's).
private="$(gh api "repos/$repo" --jq .private)"
case "$private" in true | false) ;; *) echo "verified.sh: $repo's visibility unknown" >&2; exit 1 ;; esac
for run in $(gh api "repos/$repo/actions/runs?head_sha=$sha&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs[] | select(.name == "Build") | .id'); do
    if gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq "$private"' as $private
        | .jobs as $jobs
        | def result(name): ([$jobs[] | select(.name == name) | .conclusion][0] // "missing");
        result("verify") == "success"
        and (if $private then result("proof") == "success" else result("proof-compare") == "success" end)' |
        grep -qx true; then
        echo "$run"
        exit 0
    fi
done
echo "verified.sh: no run of the Build workflow verified $sha (its verify and proof passed)" >&2
exit 1
