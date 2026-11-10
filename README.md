# The Playground

Write SwiftUI on your device, build it there, and run it there: one SwiftUI
app on iOS, macOS, Android, the web, Linux and Windows, built on
[Isomer](https://github.com/AttilaTheFun/isomer). A project is a `.swift` file; Run compiles it to
WebAssembly with a Swift compiler the app carries, and shows the result on
Isomer's SwiftUI. An agent page (AgentUI) can write and fix the project for
you. New projects start from the canned examples: Counter, 2048, Hacker
News, Meme Creator, Pokédex, Date Planner, Map Explorer, Floating Menu, and
"This website".

| | Target | Renderer | Projects (compiler) | A run |
| --- | --- | --- | --- | --- |
| iOS | `//apple/playground_ios_application` | SwiftUI; Metal for runs | swift-frontend and lld linked into the app | WasmView (WasmKit), or Safari |
| macOS | `//apple/playground_macos_application` | SwiftUI | swift-frontend and wasm-ld in the app, run as processes | WasmView (WasmKit) |
| Android | `//android/playground_android_application` | Compose, OpenGL | swift-frontend and wasm-ld in the APK | its own window (WasmKit), or Chrome |
| Web | `//web/playground_web_application` | React, WebGPU | the compiler as WebAssembly, in a Worker | in the page |
| Linux | `//linux/playground_linux_application` | OpenGL | swift-frontend and wasm-ld beside the app, run as processes | its own window (WasmKit) |
| Windows | `//windows/playground_windows_application` | Direct3D | swift-frontend and wasm-ld beside the app (the build machine's Swift's), run as processes | its own window (WasmKit) |

The six apps share one shell (`shared/app`) and the canned examples
(`shared/sample_sources`). Isomer's SwiftUI API is shown and proven by the
Storybook (isomer's `examples/`).

Also here, because it exercises the same agent page (AgentUI on Isomer): the
transcript stress apps, `//web/transcript_stress_web_application` and
`//android/transcript_stress_android_application` (source in
`shared/transcript_stress_application`): a long agent conversation, to see
how a large transcript scrolls and streams. The web app is published with a
front page beside it (`//web/splash_web_application`, the whole site is its
`:site`).

## Build

This repository is a Bazel module of its own, `playground`, an application
on Isomer: isomer by version from the project's registry
(AttilaTheFun/bazel_registry, listed before the BCR in `.bazelrc`), and
isomer's Swift, AgentUI and UpdateKit through
`third_party/swift_packages/Package.swift` (isomer by its release's tag, the
others by version). Run Bazel from the repository's root:

```sh
# iOS simulator, compiling with the host toolchain
bazel run //apple/playground_ios_application:run
# iOS, onto a phone (installs, does not launch; the compiler must be staged
# first, see below; the Apple team comes from .bazelrc.user, see below)
DEVICE=<udid> apple/playground_ios_application/install_device.sh
# the web site
bazel build -c opt //web/splash_web_application:site
# Android
bazel build -c opt //android/playground_android_application
bazel test //...
```

An iPhone build is signed with your own Apple team: put
`common --repo_env=ISOMER_TEAM_ID=<your team id>` in `.bazelrc.user`
(untracked; `tools/signing`). Simulator, web and Android builds need nothing.

The compilers are not in git; they are far too large. They are built once by
`tools/playground_toolchain` (iOS, Android) and `tools/browser_toolchain`
(web), then staged into gitignored directories by
`apple/playground_ios_application/build_embedded_toolchain.sh` and
`android/playground_android_application/stage_toolchain.sh`. Without them the
iOS and Android apps build but cannot compile; the READMEs in those tools
directories are the instructions. CI stages the compilers it ships from Shireworks'
 files (`tools/ci/stage_playground_compilers.sh`).

## Where things are

- `docs/playground.md`: the iOS app. `docs/playground_web.md`: the web app,
  the site and publishing.
- `tools/playground`: the web dev compile server, headless Chrome drivers, the
  site's packaging script and the hot-reload publish script.
- `MODULE.bazel` declares what isomer asks of its consumer (the Swift
  toolchains and SDKs, the Android and Apple toolchains), as isomer's
  `examples/MODULE.bazel` does; keep the two in step when isomer's change.
- `.github/workflows/build.yml` and `tools/ci`: CI (a pull request's build
  and tests without a GUI, main's cache, and by hand the proof, the Alphas
  and a release); `tools/proof/proof.py` pictures the apps for the proof.
- `AGENTS.md`: how the module is laid out, built and tested, and its rules.

The web site is https://attilathefun.github.io/playground/ (the Playground
at `playground/`): `tools/playground/package_site.sh` packages it as
`playground-site.tar.gz`, which CI attaches to a draft release, and the
repository's `.github/workflows/pages.yml` deploys it to GitHub Pages when
the release is published, or by hand (`docs/playground_web.md`,
"Publishing").

The Playground was `examples/{apple,web,android}/playground_*` in isomer
until Isomer 0.15, then a repository of its own until it came back to
isomer, as `playground/`, at 0.35 (`examples/playground/` from 0.39), and
this repository since 0.47, its history from isomer brought with it.
