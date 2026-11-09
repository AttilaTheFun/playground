// The Playground's second engine on the iPhone: a build run headless in a
// web view kept out of sight, by WebKit's JavaScript engine (its JIT), and
// drawn by the app as a WasmKit run is. To WasmView it is any engine
// (`WasmRuntime`): the run's driver (WasmFeatureRuntime) and its head are
// the same as WasmKit's, so the two compare engine for engine. The page
// (web/native_head.html, native_head.js, served with the build by
// WebRunServer) posts each tree here and runs the calls it is sent.
//
// WasmRuntime is synchronous and a web view is not: a call goes to the page
// and answers nil (or, for a count, 0), and the bytes the driver stages in
// guest memory (iso_hot_alloc, writeBytes) are kept here under a handle and
// sent with the call that names it, where the page copies them into the
// guest. The guest's platform services are the page's (page_dependencies.js)
// and its networking the page's fetch, not the app's.

#if os(iOS)
import Foundation
import IsomerWasmView
import SwiftFFIWasmHost
import UIKit
import WebKit

@MainActor
final class WebViewEngine: NSObject, WasmRuntime {
    /// Said once the page has the build instantiated, and of each tree:
    /// the timings AppleRun shows.
    var onReady: ((Double) -> Void)?

    private var webView: WKWebView?
    private var hostImports: WasmHostImports?
    private var ready = false
    /// Calls made before the page was ready, in order.
    private var queued: [String] = []
    /// Bytes the driver staged, by the handle `iso_hot_alloc` answered.
    private var staged: [Int32: [UInt8]] = [:]
    private var nextHandle: Int32 = 0x4000_0000

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        self.hostImports = hostImports
        guard let index = WebRunServer.shared.publish(wasm: Data(wasm)) else {
            throw EngineError("the in-app web server did not start")
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(MessageRelay(self), name: "isomerHead")
        // In a window, but not seen and never touched: WebKit holds back the
        // timers of a web view in none.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        scenes.compactMap(\.keyWindow).first?.addSubview(view)
        view.load(URLRequest(url: index.deletingLastPathComponent().appendingPathComponent("native_head.html")))
        webView = view
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        // The page gives the build its own (page_dependencies.js).
    }

    @discardableResult
    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        switch name {
        case "iso_hot_alloc":
            nextHandle += 1
            staged[nextHandle] = []
            return .i32(nextHandle)
        case "iso_hot_free":
            if case .i32(let handle)? = args.first { staged[handle] = nil }
            return nil
        default:
            // A staged handle goes as its bytes; the page allocates them.
            let values: [Any] = args.map { arg -> Any in
                switch arg {
                case .i32(let value):
                    if let bytes = staged[value] { return ["bytes": Data(bytes).base64EncodedString()] }
                    return Int(value)
                case .i64(let value): return Int(value)
                case .f32(let value): return Double(value)
                case .f64(let value): return value
                }
            }
            guard let json = try? JSONSerialization.data(withJSONObject: [name, values]),
                  let text = String(data: json, encoding: .utf8) else { return nil }
            run("isoHead.call(...\(text))")
            return name == "iso_hot_pending_tasks" ? .i32(0) : nil
        }
    }

    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { [] }

    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        let handle = Int32(bitPattern: ptr)
        if staged[handle] != nil { staged[handle] = bytes }
    }

    /// The page runs its own frames (setTimeout) when the guest asks.
    func renderPending() {
        run("isoHead.call('iso_hot_render', [])")
    }

    private func run(_ script: String) {
        if ready {
            webView?.evaluateJavaScript(script)
        } else {
            queued.append(script)
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["kind"] as? String else { return }
        switch kind {
        case "tree":
            if let text = message["bytes"] as? String, let bytes = Data(base64Encoded: text) {
                hostImports?.onRenderTree([UInt8](bytes))
            }
        case "log":
            if let line = message["line"] as? String { hostImports?.onLog(line) }
        case "platform":
            hostImports?.onPlatformCommand(message["key"] as? String ?? "", message["value"] as? String ?? "")
        case "ready":
            ready = true
            onReady?(message["instantiateMs"] as? Double ?? 0)
            for script in queued { webView?.evaluateJavaScript(script) }
            queued = []
        case "error":
            hostImports?.onLog("[web view] \(message["message"] as? String ?? "?")")
        default:
            break
        }
    }

    /// Ends the page with the run.
    func close() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "isomerHead")
        webView?.removeFromSuperview()
        webView = nil
    }

    struct EngineError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// WebKit keeps its message handler strongly: this holds the engine weakly.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var engine: WebViewEngine?
    init(_ engine: WebViewEngine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { engine?.received(body) }
    }
}
#endif
