// swift-tools-version: 5.9
// The SwiftPM manifest rules_swift_package_manager consumes: isomer's Swift
// (its Foundation and frameworks off Apple, SwiftUI) by the release's tag,
// AgentUI (the agent page) and UpdateKit (the iPhone and Mac apps tell
// Applications the build they are), each by version.
import PackageDescription

let package = Package(
    name: "playground_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.48.1"),
        // AgentUI 0.39.0, whose Markdown is a product of its own
        // (MarkdownViews), shared with the other apps that render Markdown.
        .package(url: "https://github.com/AttilaTheFun/agent_ui.git", exact: "0.39.1"),
        .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.11.0"),
    ]
)
