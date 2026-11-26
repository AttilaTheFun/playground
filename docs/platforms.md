# What stays platform-specific

The Playground is one shell (`shared/app`) compiled against Apple's SwiftUI
on the iPhone and the Mac and against Isomer's elsewhere. What a platform
does differently belongs to its host (`PlaygroundHostService`, the views in
`PlaygroundSurfaces`), so the shell itself has as few `#if`s as possible:
the Mac gets what the iPhone has (the engines, Run on the web, the
highlighted editor, OpenRouter sign-in) because both run the same Apple host
(`apple/host`), and the shell picks the host's views with no `#if`.

This file lists every conditional left in the Playground's own Swift (the
templates in `shared/sample_sources` aside: they are isomer's examples'),
and why it stays. It describes the tree with playground#57 and the pull
requests that unified the Mac with the iPhone merged (the Mac's engines and
Run on the web, its highlighted editor, its sign-in, its polish pass). When
you add one, add it here; when one can go, take it out of both.

## The shell (shared/app)

Genuine differences between Apple's SwiftUI on the iPhone and on the Mac,
or between Apple's SwiftUI and Isomer's:

| Where | What | Why it stays |
| --- | --- | --- |
| `App.swift`, the sidebar's toolbar | the Settings gear `#if !os(macOS)` | the Mac has Settings in its Settings scene (⌘,), the place a Mac app's are; elsewhere the gear at the top leading edge, as Visor and Shireworks have it |
| `App.swift`, `projectList` | `.listStyle(.sidebar)` on the Mac, `.insetGrouped` elsewhere | the Mac has no inset grouped style; each is the platform's sidebar |
| `App.swift`, `inlineTitle()` | `navigationBarTitleDisplayMode(.inline)` except on the Mac | the Mac has no navigation bar title modes. The sheets (the editor, the diagnostics, New Project) call this one helper rather than an `#if` each |
| `App.swift`, `plainTextEntry()` | `textInputAutocapitalization(.never)` except on the Mac | the Mac has no autocapitalization to turn off |
| `App.swift`, `runCover` and `fullScreenCoverOrSheet` | the run as a sheet near the window's size on the Mac, with a Stop button (Esc); a full-screen cover elsewhere | the Mac has no full-screen cover, and a Mac can't be shaken (the cover's way out on a phone) |
| `App.swift`, `windowSheetFrame` | a sheet's least size on the Mac | the Mac sizes a sheet to its content, and a run or a web page has no size of its own; elsewhere a sheet fills its column or the screen |
| `App.swift`, `Barred` | a `NavigationStack` around a page off Apple | Apple's SwiftUI gives the detail column its bar (a nested stack strips it on a collapsed phone and squeezes the Mac's sidebar); Isomer's gives a column a bar only inside a stack |
| `App.swift`, `playgroundLog` | `NSLog` on Apple platforms, `print` elsewhere | the tests read the unified log on Apple platforms, where `print` is not kept. Isomer's Swift SDKs have `NSLog` from isomer-6.4.2.3; the Playground registers isomer-6.4.2.2 (MODULE.bazel), so this becomes `NSLog` everywhere once the pin moves past it |
| `App.swift`, `CodeEditorView` | a `TextEditor` on Linux and Windows when no host editor is installed, the web's and Android's `CodeEditor` host view otherwise | the Apple hosts install their own editor (`PlaygroundSurfaces.codeEditor`); the GPU renderer of Linux and Windows draws no `codeeditor` host view |
| `App.swift`, `RunSurfaceView` and `RunSurface`; `WebCodeEditor.swift` | the web's and Android's host views (`surface`, `codeeditor`) compiled only off Apple | they are `PlatformViewRepresentable`s, Isomer's; on Apple the host installs the run surface and the editor |

## The Apple host (apple/host)

The iPhone and the Mac share every file; what differs is UIKit against
AppKit, kept to the few lines that touch them:

| Where | What | Why it stays |
| --- | --- | --- |
| `CodeEditor.swift` | `UIViewRepresentable` over a `UITextView`, with the coding-keyboard accessory row, on the iPhone; `NSViewRepresentable` over an `NSTextView` in an `NSScrollView` on the Mac | UIKit's and AppKit's text views; the highlighting, the syntax check, its underlines and the indentation on Return are one coordinator. The accessory row is the iPhone's alone: a Mac has its keyboard |
| `WebViewEngine.swift` | where the web view out of sight lives: in the key `UIWindow` (or a window of its own, for the benchmark of each placement) on the iPhone, in the key `NSWindow` on the Mac | UIKit's windows and AppKit's |
| `AppleHost.swift`, OpenRouter's sign-in | the presentation anchor: the key `UIWindow` or `NSWindow` | `ASPresentationAnchor` is one or the other |
| `AppleHost.swift`, imports | UIKit on the iPhone, AppKit on the Mac | the anchor's and the web view's types |
| `PlaygroundApp.swift` | the Mac's window: its default and least sizes; its Settings scene (⌘,); View › Search Projects (⌘F) | an iPhone or iPad window has no size to set, and Settings is a sheet there. Search Projects finds the sidebar's AppKit field (NavigationUI's ListSearchChrome keeps its focus to itself); an iPad's search is the system's `.searchable` |

## The compiler (apple/compiler, shared/compiler)

| Where | What | Why it stays |
| --- | --- | --- |
| `ToolchainCompiler.swift`, `EmbeddedCompiler.swift` | `ISO_PLAYGROUND_EMBEDDED` (the iPhone's in-process compiler, a build setting), `targetEnvironment(simulator)` | the iPhone links swift-frontend and lld in, staged per SDK; the Mac runs the compiler it carries as processes |
| `ToolchainCompiler.swift`, `availability` | the Mac's message when its compiler is missing | the iPhone's other backends (the simulator's host toolchain) have their own messages |
| `BundledCompiler.swift` | `.exe` and `.dll` on Windows, `.dylib` on Apple platforms, `.so` elsewhere | the compiler's file names on each system |

## The desktop host (shared/desktop_host)

| Where | What | Why it stays |
| --- | --- | --- |
| `DesktopHost.swift` | `FoundationNetworking` | corelibs Foundation keeps URLSession there on Linux and Windows |
| `DesktopHost.swift`, `PlaygroundWasmLoader.swift` | the loader's `.exe` and the Windows or Linux WasmKit app | Windows paths, and each system's own host |
