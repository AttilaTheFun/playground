// An engine's timings, taken at the engine's own boundary so that every
// engine is timed alike: from the launch to the first tree, and from each
// event the head sends (a tap, a keystroke, a drag) to the tree that next
// comes back. AppleRun shows them over the run, to compare WasmKit with the
// web view (WebViewEngine).

import Foundation
import IsomerWasmView
import SwiftFFIWasmHost

/// What a run's engine has taken so far.
struct EngineTimings: Equatable {
    var engine: String
    /// From the launch to the first tree, in milliseconds.
    var firstFrame: Double?
    /// From each event to the next tree, in milliseconds, newest last.
    var events: [Double] = []

    var summary: String {
        var parts = [engine]
        if let firstFrame { parts.append(String(format: "first frame %.0f ms", firstFrame)) }
        if let last = events.last {
            let mean = events.reduce(0, +) / Double(events.count)
            parts.append(String(format: "event→frame %.1f ms (mean %.1f of %d)", last, mean, events.count))
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class TimedEngine: WasmRuntime {
    let inner: any WasmRuntime
    private var timings: EngineTimings
    private let report: (EngineTimings) -> Void
    private var launched: CFAbsoluteTime = 0
    private var eventSent: CFAbsoluteTime?

    init(_ inner: any WasmRuntime, engine: String, report: @escaping (EngineTimings) -> Void) {
        self.inner = inner
        self.timings = EngineTimings(engine: engine)
        self.report = report
    }

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        launched = CFAbsoluteTimeGetCurrent()
        var imports = hostImports
        let onRenderTree = hostImports.onRenderTree
        imports.onRenderTree = { [weak self] bytes in
            onRenderTree(bytes)
            MainActor.assumeIsolated { self?.treeArrived() }
        }
        try inner.launch(wasm: wasm, hostImports: imports)
    }

    private func treeArrived() {
        let now = CFAbsoluteTimeGetCurrent()
        if timings.firstFrame == nil {
            timings.firstFrame = (now - launched) * 1000
        } else if let sent = eventSent {
            timings.events.append((now - sent) * 1000)
        } else {
            return
        }
        eventSent = nil
        report(timings)
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        inner.installDependencies(prefix: prefix, dependencies)
    }

    @discardableResult
    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        if name == "iso_hot_event", eventSent == nil { eventSent = CFAbsoluteTimeGetCurrent() }
        return try inner.call(name, args)
    }

    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { inner.readBytes(ptr, len) }
    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) { inner.writeBytes(ptr, bytes) }
    func pumpGuestJobs() { inner.pumpGuestJobs() }
    func renderPending() { inner.renderPending() }

    /// Ends what the engine holds beyond the guest (the web view's page).
    func close() {
        #if os(iOS)
        (inner as? WebViewEngine)?.close()
        #endif
    }
}
