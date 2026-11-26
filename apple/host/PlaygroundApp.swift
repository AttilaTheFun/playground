// The Playground on Apple platforms: the shared shell (shared/app) against
// Apple's SwiftUI, with the host (AppleHost) and the platform's views (the
// run's WasmView, the highlighted code editor) installed before it starts.

import ApplePlatformServices
import PlatformServices
import ShireworksKit
import SwiftUI

@main
struct PlaygroundApp: App {
    init() {
        PlaygroundHost.service = AppleHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(AppleRunSurface(onStopped: onStopped)) }
        // A shake is the run cover's way out, so the kit's shake stands down
        // while it is up (on the view presenting it: a cover's preferences
        // don't reach the views behind it).
        PlaygroundSurfaces.whileRunning = { content, running in AnyView(content.shakeToReportPaused(running)) }
        PlaygroundSurfaces.codeEditor = { text, fileName in AnyView(CodeEditor(text: text, fileName: fileName)) }
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
        }
        #if os(macOS)
            .defaultSize(width: 1280, height: 820)
        #endif
        // Help › Report a Bug… (⌥⌘B), the shake's twin on the Mac.
        .commands { ShakeKitCommands() }
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

extension NativeKeychainService: PlatformServices.KeychainService {}
extension NativeAnalyticsService: PlatformServices.AnalyticsService {}
extension NativeConfigurationService: PlatformServices.ConfigurationService {}
extension NativeImagePickerService: PlatformServices.ImagePickerService {}
extension NativeDeviceMotionService: PlatformServices.DeviceMotionService {}
