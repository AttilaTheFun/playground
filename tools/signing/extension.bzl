"""The builder's own signing values, from the environment, not the repo.

`@isomer_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign the
Playground's device builds with, from ISOMER_TEAM_ID, or a placeholder. Set
it for your builds in a `.bazelrc.user` beside this module's MODULE.bazel
(it is not checked in):

    common --repo_env=ISOMER_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile (Xcode's, found by `local_provisioning_profile`; the
Playground's a wildcard one, which tools/playground_toolchain/mint_profile
makes).
"""

def _signing_impl(rctx):
    team = rctx.getenv("ISOMER_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    # What the apps tell UpdateKit (defs.bzl's `update_infoplist`), which a
    # public repository never names: the distributor's app group and, on a
    # Mac, its bundle ids (comma-separated). CI's distribution builds set
    # both from the repository's secrets; with none, UpdateKit does nothing.
    group = (rctx.getenv("ISOMER_UPDATE_APP_GROUP", "") or "").strip()
    ids = [i.strip() for i in (rctx.getenv("ISOMER_UPDATE_APPLICATIONS_BUNDLE_IDS", "") or "").split(",") if i.strip()]
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", "\n".join([
        'TEAM_ID = "%s"' % team,
        "UPDATE_APP_GROUP = %s" % repr(group),
        "UPDATE_APPLICATIONS_BUNDLE_IDS = %s" % repr(ids),
        "",
    ]))

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "isomer_signing")

signing = module_extension(implementation = _extension_impl)
