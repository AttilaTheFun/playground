// The proof in Reviews' format 2 (the private AttilaTheFun/reviews'
// docs/PROOF_FORMAT.md), as isomer's tools/ci/proof_write.swift: every
// picture an item under an id stable from release to release, proof.json
// beside them, nothing compared (Reviews compares a release's proof with
// the one before it). Made from the review folders tools/proof/proof.py
// writes (review-<platform>-playground/, each with its manifest.json and
// pictures). tools/ci/proof.sh builds this file with swiftc on the runner.
//
//   swiftc -O -o proof_write tools/ci/proof_write.swift
//   proof_write <out> --app <App> --version <version> --repository <owner/name>
//               --commit <sha> [--run <id>] <folder>…
//
// Each folder is searched for review-*/manifest.json. The ids, each
// <platform>/<device>/<screen>, the screen its capture's file name
// (projects.png is projects):
//   review-ios-playground      ios/phone/<screen>
//   review-macos-playground    macos/window/<screen>
//   review-android-playground  android/phone/<screen>
//   review-web-playground      web/desktop/<screen>
//   review-linux-playground    linux/window/<screen>
//   review-windows-playground  windows/window/<screen>
// An id is lowercase letters, digits, - . and / alone: a capture named
// otherwise fails the proof rather than change its id from one release to
// the next. <out> gets proof.json and screens/<id>.png.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("proof_write: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    fail("usage: proof_write <out> --app <App> --version <v> --repository <r> --commit <sha> [--run <id>] <folder>…")
}
let out = URL(fileURLWithPath: arguments.removeFirst())
var options: [String: String] = [:]
var folders: [URL] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") {
        guard !arguments.isEmpty else { fail("\(argument) takes a value") }
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else {
        folders.append(URL(fileURLWithPath: argument))
    }
}
for key in ["app", "version", "repository", "commit"] where options[key] == nil { fail("--\(key) is required") }

let files = FileManager.default

/// A PNG's width and height, from its IHDR (bytes 16 to 23).
func pngSize(_ url: URL) -> (Int, Int)? {
    guard let data = try? Data(contentsOf: url), data.count > 24, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
    func number(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    return (number(16), number(20))
}

/// A file's SHA-256, by the system's own tool (sha256sum on Linux, shasum
/// on a Mac).
func sha256(_ url: URL) -> String {
    let process = Process()
    let pipe = Pipe()
    if files.isExecutableFile(atPath: "/usr/bin/sha256sum") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [url.path]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
    }
    process.standardOutput = pipe
    do { try process.run() } catch { fail("no SHA-256 for \(url.path): \(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard let digest = output.split(separator: " ").first, digest.count == 64 else { fail("no SHA-256 for \(url.path)") }
    return String(digest)
}

/// Where a review folder's pictures go: its platform and device.
let devices: [String: String] = [
    "ios-playground": "ios/phone",
    "macos-playground": "macos/window",
    "android-playground": "android/phone",
    "web-playground": "web/desktop",
    "linux-playground": "linux/window",
    "windows-playground": "windows/window",
]

func valid(_ id: String) -> Bool {
    !id.isEmpty && id.allSatisfy { ($0.isLowercase && $0.isASCII) || ($0.isNumber && $0.isASCII) || "-./".contains($0) }
}

// Each item with the order it was read in: a platform's screens stay in
// its manifest's order (proof.py's: the projects, a project open, 2048,
// the Pokédex).
var screens: [String: (index: Int, item: [String: Any])] = [:]

/// One picture, an item.
func add(id: String, title: String?, picture: URL) {
    guard valid(id) else { fail("\(id) is no proof id (lowercase letters, digits, - . /): rename its capture in tools/proof/proof.py") }
    guard screens[id] == nil else { fail("\(id) twice") }
    let file = "screens/\(id).png"
    let target = out.appendingPathComponent(file)
    try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.removeItem(at: target)
    do { try files.copyItem(at: picture, to: target) } catch { fail("\(picture.path): \(error)") }
    guard let (width, height) = pngSize(target) else { fail("\(picture.path) is no PNG") }
    var item: [String: Any] = ["id": id, "kind": "screen", "file": file, "sha256": sha256(target),
                               "width": width, "height": height]
    if let title { item["title"] = title }
    screens[id] = (screens.count, item)
}

// Each file once, however the folders given overlap (a folder and those in
// it: proof.sh gives the parts' folder and each part).
var seen: Set<String> = []
for folder in folders {
    guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
    for case let url as URL in walker {
        guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
        guard url.lastPathComponent == "manifest.json", url.deletingLastPathComponent().lastPathComponent.hasPrefix("review-") else { continue }
        let cellFolder = url.deletingLastPathComponent()
        let cell = String(cellFolder.lastPathComponent.dropFirst("review-".count))
        guard let device = devices[cell] else {
            FileHandle.standardError.write(Data("proof_write: \(cell): no device for it, left out\n".utf8))
            continue
        }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = manifest["items"] as? [[String: Any]] else { fail("\(url.path) is no manifest") }
        for entry in items {
            // The item's name is the screen's title ("2048, built here and
            // running"); its capture is named by the screen's slug
            // (game2048.png), which is the proof's id.
            guard let capture = entry["capture"] as? String else { fail("\(url.path): an item without a capture") }
            let picture = cellFolder.appendingPathComponent(capture)
            guard files.fileExists(atPath: picture.path) else { fail("\(picture.path): its manifest names it, and it isn't there") }
            let screen = URL(fileURLWithPath: capture).deletingPathExtension().lastPathComponent
            add(id: "\(device)/\(screen)", title: entry["name"] as? String, picture: picture)
        }
    }
}

// In the order Reviews shows them: the platforms, each in its manifest's order.
let order = ["ios/", "macos/", "android/", "web/", "linux/", "windows/"]
func rank(_ id: String) -> Int { order.firstIndex { id.hasPrefix($0) } ?? order.count }
let items = screens.values.sorted {
    let (a, b) = ($0.item["id"] as! String, $1.item["id"] as! String)
    return rank(a) != rank(b) ? rank(a) < rank(b) : $0.index < $1.index
}.map(\.item)

var proof: [String: Any] = [
    "format": 2,
    "app": options["app"]!,
    "version": options["version"]!,
    "repository": options["repository"]!,
    "commit": options["commit"]!,
    "made": ISO8601DateFormatter().string(from: Date()),
    "items": items,
]
if let run = options["run"].flatMap(Int.init) { proof["run"] = run }
try? files.createDirectory(at: out, withIntermediateDirectories: true)
let json = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: out.appendingPathComponent("proof.json"))
print("proof_write: \(screens.count) screens in \(out.path)/proof.json")
