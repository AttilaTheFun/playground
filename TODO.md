# TODO

The Playground's own open items (they left isomer's TODO.md with it at 0.15;
isomer's docs/open_items.md is the framework's list).

## Toolchain

- **Package the in-app Swift compiler as a reusable Swift package /
  framework.** Everything that makes `swift-frontend` + `lld` run inside
  an iOS app (tools/playground_toolchain: the cross-compile campaign, the
  idempotent-init and signal-handler re-entry patches, the swift-syntax +
  in-process macro plugin server, the short-named embedded frameworks,
  the `iso_swiftc_main` / `iso_wasm_ld_main` entry shims, WASI sysroot +
  static stdlib data) currently lives in
  apple/playground_ios_application. Extract it into an
  `EmbeddedSwiftCompiler` package (xcframework of the static compiler libs
  + the framework set + a resource bundle for the sysroot, with a Swift
  API: compile(sources:) → wasm / diagnostics, parse-only check) so other
  apps can compile Swift to wasm on device without repeating the campaign.
  See docs/playground.md ("Device packaging") for the constraints the
  package has to preserve.

- **A standalone bundle-building kit for hot reloaders.** Publishing a
  version for a Playground hot reloader (`tools/playground/publish_hot_reload.sh`)
  needs a wasm bundle, and building one today means the Playground's own
  in-app toolchain or the Bazel tree. Neither the wasi-threads fork nor the
  isomer sources are required: the inputs are the swift.org toolchain
  (Xcode's Swift has no wasm backend), the public swiftwasm SDK
  (sysroot + static stdlib), and Isomer compiled for wasm as prebuilt
  swiftmodules/archives plus the link recipe (reactor entry, exports,
  16 MiB stack, whole-archive) — the same three pieces the Playground embeds.
  Package them as a downloadable kit with a `build_bundle.sh` that runs the
  Playground's two compile/link invocations, so a remote Claude Code / Codex
  session goes from `App.swift` to a published version with only that
  download. Prerequisite once public: codify the tree wire format
  (tree.fbs Patches) and the `iso_hot` export ABI with versioning, since a
  bundle must match the framework revision of the Playground it targets
  (today: the Playground's SDK stamp); the kit should carry that revision.

## Playground unification

Done in 0.38: one shell, `shared/app`, on all six platforms (the agent
session, transcript, composer, editor, run cover, settings and project
store shared; the host's `PlaygroundHostService` does the platform's part).
What the iPhone app had before and the shared agent doesn't yet:

- Anthropic keys used directly (it speaks OpenRouter only now).
- Streamed replies (the host's `chat` answers whole).
- Images in a message, and multi-file projects.
- The agent's screenshot, crash-log and web-search tools.
- The model catalog sheet.

## Playground agent

- More injected services beyond those in isomer's `shared/platform_services`
  (keychain, OAuth, timers, analytics, configuration, the image picker,
  device motion; the network and files are Foundation's since 0.31):
  location, camera/photos, notifications — each a swift_ffi interface
  implemented by every host and described to the agent in the system prompt.
- swift_ffi: async interface methods on Swift-OWNED instances are callable
  from wasm/TS consumers only (they complete through `async_complete`);
  Kotlin/Swift-host callers and C++/Rust consumers still get a runtime
  error for them.

## CI and the proof

(Moved from isomer's TODO.md and docs/open_items.md when the Playground left
it, at 0.47.)

- **The templates in CI.** `//tests/templates:templates_compile_test`
  compiles and links every template against the Playground SDK with the
  host's wasm toolchain. It is `local` and finds a Mac's toolchain
  (`tools/playground/dev_compile_server.py`'s `find_toolchain` reads
  rules_swift's `_xcode` repositories), so no CI job runs it, and isomer
  0.44's first proof showed the Playground's projects failing to link
  (swift_ffi in the SDK twice) before any test did. It should run in CI's
  container (the toolchain's Linux repository names) beside the sites'
  import checks (`tools/ci/container_build.sh`'s tests).
- **x86_64 Android.** The compiler the Android Playground carries is
  arm64's alone, so its proof is pictured on an emulator leased from OS
  Server, in the proof's build job, while GitHub's Ubuntu runners (KVM,
  free for a public repository) run only x86_64 emulators. An x86_64 build
  of the on-device compiler (tools/playground_toolchain), staged beside the
  arm64 one, lets the Android proof run there (proof.sh --stage shoot
  --platform android and tools/ci/hosted_android_emulator.sh are ready for
  it). Planned with isomer 0.48.
- **The Pokédex reads PokéAPI live.** Its pictures have held still so far.
- **Android's 2048, 1 px higher at 0.41 (Swift 6.4.2).** In both of isomer's
  proofs of a6ceeb16 (quick and full), its content sits 1 px above
  v0.40.1's; the web's and the iPhone's 2048 (the same project, compiled for
  wasm too) are pixel-identical. Android runs the Playground's wasm under
  WasmKit built by the Android Swift 6.4.2 toolchain, and its host measures
  with Compose: find which number moved (a float conversion in the engine,
  or a host measurement) before it hides a real change.

## Open items

- **Playground projects**: an unedited project made from a template by any
  earlier build is brought to the current template at launch
  (`TemplateHistory`, rebuilt from git history by
  `tools/playground/template_history.py`); an edited one keeps its source
  and needs a manual update where Isomer 0.31 removed API it used
  (`ObservableObject`, since back in 0.42; `DispatchQueue`, the injected
  services).
- **The macro toolchain is built outside Bazel**: `tools/browser_toolchain`'s
  scripts build the WASI compiler and `MacroPlugins.wasm`
  (ObservationMacros, SwiftMacros), and Android's prebuilt plugins are
  staged by `android/playground_android_application/stage_toolchain.sh`; a
  toolchain bump means running them again by hand (and, for CI, `oss files
  add` of the new archives and their SHA-256s in
  `tools/ci/stage_playground_compilers.sh`).
