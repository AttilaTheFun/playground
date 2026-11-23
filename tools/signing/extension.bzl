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

def _infoplist(text):
    """ISOMER_INFOPLIST's keys: a JSON object of strings or string arrays."""
    if not text.strip():
        return {}
    value = json.decode(text)
    if type(value) != "dict":
        fail("ISOMER_INFOPLIST must be a JSON object, not %s" % type(value))
    for key, item in value.items():
        if type(item) == "list":
            if [i for i in item if type(i) != "string"]:
                fail("ISOMER_INFOPLIST's %s must be a string or an array of strings" % key)
        elif type(item) != "string":
            fail("ISOMER_INFOPLIST's %s must be a string or an array of strings" % key)
    return value

def _signing_impl(rctx):
    team = rctx.getenv("ISOMER_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    # What the apps carry in their Info.plist (defs.bzl's
    # `stamped_infoplist`), which a public repository never names: what they
    # tell UpdateKit, the distributor's app group and, on a Mac, its bundle
    # ids (comma-separated); and ISOMER_INFOPLIST, the builder's other keys
    # as a JSON object of strings or arrays of strings (ShakeKit's
    # `ShakeKitScope`, which turns it on, and the shared GitHub sign-in's
    # `GitHubShared*`). CI's distribution builds set them from the
    # repository's secrets; with none, UpdateKit and ShakeKit do nothing.
    group = (rctx.getenv("ISOMER_UPDATE_APP_GROUP", "") or "").strip()
    ids = [i.strip() for i in (rctx.getenv("ISOMER_UPDATE_APPLICATIONS_BUNDLE_IDS", "") or "").split(",") if i.strip()]
    infoplist = _infoplist(rctx.getenv("ISOMER_INFOPLIST", "") or "")
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", "\n".join([
        'TEAM_ID = "%s"' % team,
        "UPDATE_APP_GROUP = %s" % repr(group),
        "UPDATE_APPLICATIONS_BUNDLE_IDS = %s" % repr(ids),
        "INFOPLIST = %s" % repr(infoplist),
        "",
    ]))

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "isomer_signing")

signing = module_extension(implementation = _extension_impl)
