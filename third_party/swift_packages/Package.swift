// swift-tools-version: 5.9
// The SwiftPM manifest rules_swift_package_manager consumes: isomer's Swift
// (its Foundation and frameworks off Apple, SwiftUI) by the release's tag,
// AgentUI (the agent page), by version, and Shireworks' kit (the iPhone and
// Mac apps tell Applications the build they are, show its update sheet,
// report crashes and file bug reports), by revision until its 0.1.0; build_tools, CI's.
import PackageDescription

let package = Package(
    name: "playground_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.61.1"),
        // AgentUI 0.39.0, whose Markdown is a product of its own
        // (MarkdownViews), shared with the other apps that render Markdown.
        .package(url: "https://github.com/AttilaTheFun/agent_ui.git", exact: "0.39.1"),
        // ShireworksKit: the build it is for Shireworks' Applications, its
        // update sheet, crash reports, and shake to report for someone signed
        // in to the shared GitHub sign-in, where the build carries its keys
        // (CI's, //tools/signing). It replaced UpdateKit and ShakeKit.
        .package(url: "https://github.com/AttilaTheFun/shireworks_kit.git", revision: "6e61e129ca8ee4bcff16ff17ba1056deaa761928"),
        // build_tools: CI's shared tools, built here and run by the release
        // jobs: `sign` (an APK, a Mac app, an iPhone app, with the release
        // environment's keys) and `proof-diff`. CI's alone: no app depends
        // on it.
        .package(url: "https://github.com/AttilaTheFun/build_tools.git", exact: "0.4.2"),
    ]
)
