// swift-tools-version: 5.9
// The SwiftPM manifest rules_swift_package_manager consumes: isomer's Swift
// (its Foundation and frameworks off Apple, SwiftUI) by the release's tag,
// AgentUI (the agent page), UpdateKit (the iPhone and Mac apps tell
// Applications the build they are) and ShakeKit (they file bug reports), each
// by version; build_tools, CI's.
import PackageDescription

let package = Package(
    name: "playground_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.60.1"),
        // AgentUI 0.39.0, whose Markdown is a product of its own
        // (MarkdownViews), shared with the other apps that render Markdown.
        .package(url: "https://github.com/AttilaTheFun/agent_ui.git", exact: "0.39.1"),
        .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.18.0"),
        // ShakeKit: shake the iPhone (or Help › Report a Bug… on the Mac) to
        // file an issue with a screenshot and the logs, where the build's
        // Info.plist opts in (ShakeKitScope: CI's Alphas, //tools/signing).
        .package(url: "https://github.com/AttilaTheFun/shake_kit.git", exact: "0.2.0"),
        // build_tools: CI's shared tools, built here and run by the release
        // jobs: `sign` (an APK, a Mac app, an iPhone app, with the release
        // environment's keys) and `proof-diff`. CI's alone: no app depends
        // on it.
        .package(url: "https://github.com/AttilaTheFun/build_tools.git", exact: "0.4.2"),
    ]
)
