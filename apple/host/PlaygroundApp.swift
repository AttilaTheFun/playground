// The Playground on Apple platforms: the shared shell (shared/app) against
// Apple's SwiftUI, with the host (AppleHost) and the platform's views (the
// run's WasmView, the iPhone's highlighted code editor) installed before it
// starts.

import ApplePlatformServices
import PlatformServices
import ShireworksKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PlaygroundApp: App {
    /// What the menu commands ask of the shell, and whether they can.
    @State private var actions = PlaygroundActions.shared

    init() {
        PlaygroundHost.service = AppleHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(AppleRunSurface(onStopped: onStopped)) }
        // A shake is the run cover's way out, so the kit's shake stands down
        // while it is up (on the view presenting it: a cover's preferences
        // don't reach the views behind it).
        PlaygroundSurfaces.whileRunning = { content, running in AnyView(content.shakeToReportPaused(running)) }
        #if os(iOS)
        PlaygroundSurfaces.codeEditor = { text, fileName in AnyView(CodeEditor(text: text, fileName: fileName)) }
        #endif
        // The shell's shake reads the compiled-in service table (device
        // motion), as the example apps do.
        installPlatformDependencies(
            keychain: NativeKeychainService(namespace: "isomer"),
            analytics: NativeAnalyticsService(),
            configuration: NativeConfigurationService(flags: ["promo_banner": true]))
        installPlatformImagePicker(imagePicker: NativeImagePickerService())
        installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
    }

    var body: some Scene {
        WindowGroup("Playground") {
            // Shireworks' kit: the build it is, written for Applications at
            // each launch, its update sheet, crash reports, and a shake to
            // file an issue for someone signed in to the shared GitHub
            // sign-in, where the build carries its keys (CI's:
            // ShireworksRepository and the rest, //tools/signing).
            PlaygroundRoot().shireworks()
                #if os(macOS)
                // The sidebar at its narrowest beside a project's chat and
                // its bar's three buttons.
                .frame(minWidth: 720, minHeight: 480)
                #endif
        }
        #if os(macOS)
            // The sidebar at its default width beside a chat as wide as
            // Visor's.
            .defaultSize(width: 1280, height: 820)
            .windowResizability(.contentMinSize)
        #endif
        .commands {
            // File › New Project (⌘N), in place of New Window: one window
            // holds every project.
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { actions.newProject() }
                    .keyboardShortcut("n")
                    .disabled(!actions.canMakeProjects)
            }
            // Project › Run (⌘R): the project open, as its bar's Run.
            CommandMenu("Project") {
                Button("Run") { actions.run() }
                    .keyboardShortcut("r")
                    .disabled(!actions.projectOpen)
            }
            // View › Show Sidebar (⌃⌘S), and on the Mac below it Search
            // Projects.
            SidebarCommands()
            #if os(macOS)
            // View › Search Projects (⌥⌘F, Mail's and Notes' key for
            // searching the list): the sidebar's field. ⌘F stays Edit ›
            // Find's, the code editor's find bar.
            CommandGroup(after: .sidebar) {
                Button("Search Projects") { focusProjectSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            #endif
            // Help › Report a Bug… (⌥⌘B), the shake's twin on the Mac.
            ShakeKitCommands()
        }
        #if os(macOS)
        // Playground › Settings… (⌘,): the Mac's place for them; the iPhone
        // and iPad have the sidebar's gear.
        Settings {
            PlaygroundSettings()
                .frame(minWidth: 480, minHeight: 360)
        }
        #endif
    }
}

#if os(macOS)
/// The sidebar's search field, given the keyboard: NavigationUI's
/// ListSearchChrome keeps its focus to itself, so it is found in the window
/// by its prompt (an iPad's is the system's .searchable, which this key isn't
/// offered for).
@MainActor
private func focusProjectSearch() {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView else { return }
    func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           (field.placeholderString ?? field.placeholderAttributedString?.string) == "Search projects" {
            return field
        }
        for child in view.subviews {
            if let found = field(in: child) { return found }
        }
        return nil
    }
    if let found = field(in: root) { window.makeFirstResponder(found) }
}
#endif

extension NativeKeychainService: PlatformServices.KeychainService {}
extension NativeAnalyticsService: PlatformServices.AnalyticsService {}
extension NativeConfigurationService: PlatformServices.ConfigurationService {}
extension NativeImagePickerService: PlatformServices.ImagePickerService {}
extension NativeDeviceMotionService: PlatformServices.DeviceMotionService {}
