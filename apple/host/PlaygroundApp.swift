// The Playground on Apple platforms: the shared shell (shared/app) against
// Apple's SwiftUI, with the host (AppleHost) and the platform's views (the
// run's WasmView, the iPhone's highlighted code editor) installed before it
// starts.

import ApplePlatformServices
import UpdateKit
import PlatformServices
import ShakeKit
import SwiftUI

@main
struct PlaygroundApp: App {
    init() {
        PlaygroundHost.service = AppleHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(AppleRunSurface(onStopped: onStopped)) }
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
        // The build it is, written for Applications at each launch; and its
        // updates, told of while it is in front (UpdateKit).
        AppUpdates.start()
    }

    var body: some Scene {
        WindowGroup("Playground") {
            // A shake files an issue here, with a screenshot and the logs,
            // for someone signed in (ShakeKitScope is in every build's
            // Info.plist).
            PlaygroundRoot().shakeToReport(repository: "AttilaTheFun/playground")
        }
        #if os(macOS)
            .defaultSize(width: 1280, height: 820)
        #endif
        // Help › Report a Bug… (⌥⌘B), the shake's twin on the Mac.
        .commands { ShakeKitCommands() }
    }
}

extension NativeKeychainService: PlatformServices.KeychainService {}
extension NativeAnalyticsService: PlatformServices.AnalyticsService {}
extension NativeConfigurationService: PlatformServices.ConfigurationService {}
extension NativeImagePickerService: PlatformServices.ImagePickerService {}
extension NativeDeviceMotionService: PlatformServices.DeviceMotionService {}
