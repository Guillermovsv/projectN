import SwiftUI
import WebKit

/// The bundled Pixel Agents interface (`Office/web`, built by scripts/build-office.sh).
enum OfficeBundle {
    static let scheme = "pnoffice"

    static let root: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Office")) }
        // `swift run` / tests: the checkout's copy.
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../Office/web").standardizedFileURL)
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }()

    /// The file a request path names, only inside `root`.
    static func file(for path: String, root: URL) -> URL? {
        let relative = path == "/" || path.isEmpty ? "index.html" : String(path.drop { $0 == "/" })
        let url = root.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }

    static func mimeType(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "ttf": return "font/ttf"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}

/// Serves the bundle: ES modules don't load from `file://`.
private final class OfficeSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = OfficeBundle.root,
              let file = OfficeBundle.file(for: url.path, root: root), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = ["Content-Type": OfficeBundle.mimeType(file.pathExtension),
                       "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Owns the web view and is the interface's host: it answers its messages and pushes the panes' state.
@MainActor
final class OfficeController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// A character (or its card) was clicked.
    var onSelect: ((UUID) -> Void)?
    /// The panes to show, asked when the interface (re)loads.
    var agents: () -> [OfficeAgent] = { [] }

    private var bridge = OfficeBridge()
    private var ready = false
    private var saved: OfficeSaved
    private var assets: (messages: [Any], defaultLayout: Any)?

    private static var savedFile: URL { AppHome.root.appendingPathComponent("office.json") }

    override init() {
        saved = AppHome.load(OfficeSaved.self, from: Self.savedFile) ?? OfficeSaved()
        super.init()
    }

    /// The interface thinks it's inside VS Code, so it talks to its host only through these messages.
    private static let hostScript = """
    window.acquireVsCodeApi = () => ({ postMessage: (m) => window.webkit.messageHandlers.office.postMessage(m) });
    """

    /// Controls that belong to Pixel Agents' own host (launching, closing, its settings).
    private static let styleScript = """
    const style = document.createElement('style');
    style.textContent = 'button[aria-label="New agent"], button[aria-label="Roster"], button[title="Settings"], button[title="Close agent"] { display: none !important; }';
    document.head.appendChild(style);
    """

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(OfficeSchemeHandler(), forURLScheme: OfficeBundle.scheme)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: Self.hostScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.styleScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.add(self, name: "office")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        load(view)
        return view
    }()

    private func load(_ view: WKWebView) {
        ready = false
        if let url = URL(string: "\(OfficeBundle.scheme)://app/index.html") { view.load(URLRequest(url: url)) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load(webView) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The office never navigates away; links (changelog, credits) open in your browser.
        if action.request.url?.scheme == OfficeBundle.scheme { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let url = action.request.url,
           url.scheme == "https" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func push() {
        guard ready else { return }
        send(bridge.update(agents(), saved: saved))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "webviewReady":
            guard let assets = loadAssets() else { return }
            ready = true
            send(assets.messages + bridge.snapshot(agents(), saved: saved, defaultLayout: assets.defaultLayout))
        case "focusAgent":
            if let n = body["id"] as? Int, let id = bridge.paneID(for: n) { onSelect?(id) }
        case "saveLayout":
            guard let layout = body["layout"], JSONSerialization.isValidJSONObject(layout),
                  let data = try? JSONSerialization.data(withJSONObject: layout) else { return }
            saved.layout = String(decoding: data, as: UTF8.self)
            save()
        case "saveAgentSeats":
            guard let seats = body["seats"] as? [String: Any] else { return }
            let merged = saved.seats.merging(bridge.seats(from: seats)) { _, new in new }
            guard merged != saved.seats else { return }
            saved.seats = merged
            save()
        default:
            break
        }
    }

    private func save() { AppHome.save(saved, to: Self.savedFile) }

    private func loadAssets() -> (messages: [Any], defaultLayout: Any)? {
        if let assets { return assets }
        guard let root = OfficeBundle.root,
              let data = try? Data(contentsOf: root.appendingPathComponent("office-assets.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [Any], let layout = json["defaultLayout"] else { return nil }
        assets = (messages, layout)
        return assets
    }

    private func send(_ messages: [Any]) {
        guard !messages.isEmpty, let data = try? JSONSerialization.data(withJSONObject: messages) else { return }
        webView.callAsyncJavaScript(
            "for (const data of JSON.parse(json)) window.dispatchEvent(new MessageEvent('message', { data }));",
            arguments: ["json": String(decoding: data, as: UTF8.self)], in: nil, in: .page, completionHandler: nil)
    }
}

/// Hosts the controller's web view. Hidden while another view is shown, so WebKit stops animating it.
struct OfficeWebView: NSViewRepresentable {
    let controller: OfficeController
    var active: Bool

    func makeNSView(context: Context) -> WKWebView {
        controller.webView.isHidden = !active
        return controller.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.isHidden = !active
    }
}
