import AppKit
import SwiftUI
import WebKit

/// A small browser for previewing local dev servers. Keeps one WKWebView alive across tab switches.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    enum Device: String, CaseIterable, Identifiable {
        case fit, mobile, tablet, desktop
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fit: return "Fit"
            case .mobile: return "Mobile"
            case .tablet: return "Tablet"
            case .desktop: return "Desktop"
            }
        }
        var symbol: String {
            switch self {
            case .fit: return "arrow.left.and.right"
            case .mobile: return "iphone"
            case .tablet: return "ipad"
            case .desktop: return "desktopcomputer"
            }
        }
        /// CSS viewport width emulated; nil = use the panel's width.
        var viewportWidth: CGFloat? {
            switch self {
            case .fit: return nil
            case .mobile: return 390
            case .tablet: return 820
            case .desktop: return 1440
            }
        }
    }

    let webView: WKWebView
    @Published var address: String
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorText: String?
    @Published var device: Device { didSet { UserDefaults.standard.set(device.rawValue, forKey: "browserDevice") } }

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        address = UserDefaults.standard.string(forKey: "browserURL") ?? "http://localhost:3000"
        device = Device(rawValue: UserDefaults.standard.string(forKey: "browserDevice") ?? "") ?? .fit
        super.init()
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in MainActor.assumeIsolated { self?.progress = wv.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.title = wv.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = wv.url else { return }
                    self.address = u.isFileURL ? u.path : u.absoluteString
                    UserDefaults.standard.set(u.absoluteString, forKey: "browserURL")
                }
            },
        ]
    }

    // MARK: Suspend while hidden (RAM)

    private var hiddenTimer: Timer?
    private var suspendedURL: URL?

    /// The Browser tab left the screen: after `browserSuspendMinutes` the page is unloaded (about:blank)
    /// so its JS, media and web process memory are released; it reloads when the tab is shown again.
    func didHide() {
        hiddenTimer?.invalidate()
        let minutes = UserDefaults.standard.object(forKey: "browserSuspendMinutes") as? Int ?? 10
        guard minutes > 0, suspendedURL == nil, let url = webView.url, url.absoluteString != "about:blank" else { return }
        let t = Timer(timeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        RunLoop.main.add(t, forMode: .common)
        hiddenTimer = t
    }

    private func suspend() {
        hiddenTimer = nil
        guard let url = webView.url else { return }
        suspendedURL = url
        webView.pauseAllMediaPlayback()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// The Browser tab is on screen again.
    func didShow() {
        hiddenTimer?.invalidate()
        hiddenTimer = nil
        if let url = suspendedURL {
            suspendedURL = nil
            load(url)
        }
    }

    private var didInitialLoad = false
    func loadInitialIfNeeded() {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        go(address)
    }

    /// Accepts "localhost:5173", "example.com", a file path, or search words.
    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        load(Self.resolve(t))
    }

    func load(_ url: URL) {
        didInitialLoad = true
        errorText = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    static func resolve(_ t: String) -> URL {
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        if t.contains("://"), let u = URL(string: t) { return u }
        let hostish = t.split(separator: "/").first.map(String.init) ?? t
        let looksLocal = hostish.hasPrefix("localhost") || hostish.hasPrefix("127.") || hostish.hasPrefix("0.0.0.0") || hostish.hasPrefix("[::1]")
        if !t.contains(" "), looksLocal || hostish.contains(".") || Int(hostish.split(separator: ":").last ?? "") != nil {
            let scheme = looksLocal ? "http" : "https"
            let fixed = hostish.allSatisfy({ $0.isNumber }) ? "localhost:\(t)" : t   // "3000" → localhost:3000
            if let u = URL(string: "\(scheme)://\(fixed)") { return u }
        }
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url!
    }

    func reload() {
        errorText = nil
        if webView.url == nil { go(address) } else { webView.reload() }
    }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }

    func openExternally() {
        if let u = webView.url ?? URL(string: address) { NSWorkspace.shared.open(u) }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { self.fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { self.fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { self.errorText = nil }
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        errorText = ns.localizedDescription
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                GeometryReader { geo in
                    WebViewHost(webView: model.webView, viewportWidth: model.device.viewportWidth, availableWidth: geo.size.width)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if model.isLoading {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                        .frame(height: 2)
                }
                if let err = model.errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("Couldn't load page").font(.headline)
                        Text(err).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { model.reload() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appWindow)
                }
            }
        }
        .onAppear { model.loadInitialIfNeeded(); model.didShow() }
        .onDisappear { model.didHide() }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button(action: model.back) { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Back")
                Button(action: model.forward) { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help("Forward")
                Button(action: model.reload) { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise") }
                    .help("Reload")
                TextField("URL, localhost:3000, or search", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { model.go(model.address); addressFocused = false }
                Button(action: model.openExternally) { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in default browser")
            }
            .buttonStyle(.hover)
            Picker("Viewport", selection: $model.device) {
                ForEach(BrowserModel.Device.allCases) { d in
                    Label(d.label, systemImage: d.symbol).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Viewport width: Fit = panel width, Mobile 390, Tablet 820, Desktop 1440 (scaled to fit)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Hosts the persistent WKWebView. Emulates a device width by zooming the page so its CSS viewport
/// equals `viewportWidth` (media queries and layout behave like that device; input stays correct).
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let viewportWidth: CGFloat?
    let availableWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(container)
        let zoom: CGFloat
        if let vw = viewportWidth, availableWidth > 0 {
            zoom = max(0.2, min(2, availableWidth / vw))
        } else {
            zoom = 1
        }
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
    }

    private func attach(_ container: NSView) {
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
