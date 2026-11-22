import AppKit
import SwiftUI
import WebKit

/// Device emulation for a browser tab: the page gets that device's CSS viewport (width *and* height), its user agent
/// (so sites serve their phone / tablet version) and is drawn as a device-sized screen, scaled down to fit the panel.
enum BrowserDevice: String, CaseIterable, Identifiable {
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
    /// Portrait CSS viewport; nil = the panel's size.
    var size: CGSize? {
        switch self {
        case .fit: return nil
        case .mobile: return CGSize(width: 390, height: 844)     // iPhone 15/16
        case .tablet: return CGSize(width: 820, height: 1180)    // iPad Air
        case .desktop: return CGSize(width: 1440, height: 900)
        }
    }
    var rotatable: Bool { self == .mobile || self == .tablet }
    /// Phone and tablet sites look at the user agent too, not just the width.
    var userAgent: String? {
        switch self {
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        case .tablet:
            return "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        default: return nil
        }
    }
    var cornerRadius: CGFloat { self == .mobile ? 36 : self == .tablet ? 18 : 6 }

    /// The viewport for this device and orientation.
    func viewport(landscape: Bool) -> CGSize? {
        guard let s = size else { return nil }
        return landscape && rotatable ? CGSize(width: s.height, height: s.width) : s
    }

    /// Scale that fits `viewport` into `available` (never enlarges).
    static func scale(_ viewport: CGSize, in available: CGSize) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return max(0.1, min(1, available.width / viewport.width, available.height / viewport.height))
    }
}

/// One workspace's browser: its tabs and which one is showing. Tabs, their URLs and device modes are remembered.
@MainActor
final class BrowserModel: ObservableObject {
    /// Whose browser this is (a workspace id, or "home"); suffixes the UserDefaults keys.
    let key: String
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var current: BrowserTab
    /// The Browser panel is showing this workspace's browser right now.
    private(set) var onScreen = false

    private var tabsKey: String { "browserTabs.\(key)" }
    private var selectedKey: String { "browserTabSelected.\(key)" }

    init(key: String = "home") {
        self.key = key
        let d = UserDefaults.standard
        var restored: [BrowserTab] = []
        if let saved = d.array(forKey: "browserTabs.\(key)") as? [[String: Any]] {
            restored = saved.map { s in
                BrowserTab(address: s["url"] as? String ?? "",
                           device: BrowserDevice(rawValue: s["device"] as? String ?? "") ?? .fit,
                           landscape: s["landscape"] as? Bool ?? false)
            }
        } else {
            // Before tabs: one remembered URL and device per workspace.
            restored = [BrowserTab(address: d.string(forKey: "browserURL.\(key)") ?? "",
                                   device: BrowserDevice(rawValue: d.string(forKey: "browserDevice.\(key)") ?? d.string(forKey: "browserDevice") ?? "") ?? .fit)]
        }
        if restored.isEmpty { restored = [BrowserTab()] }
        tabs = restored
        current = restored[min(max(0, d.integer(forKey: "browserTabSelected.\(key)")), restored.count - 1)]
        restored.forEach(adopt)
    }

    private func adopt(_ tab: BrowserTab) {
        tab.owner = self
    }

    /// Opens a tab after the current one. `configuration` is WebKit's, for a page that opened a window (window.open,
    /// target=_blank); WebKit then loads it itself.
    @discardableResult
    func newTab(_ address: String? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(address: "", device: current.device, landscape: current.landscape, configuration: configuration)
        adopt(tab)
        let i = (tabs.firstIndex { $0 === current } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: min(i, tabs.count))
        if select { self.select(tab) }
        if let address, !address.isEmpty { tab.go(address) }
        save()
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0 === tab }), tab !== current else { return }
        current = tab
        save()
    }

    /// Closes a tab; the last one is replaced by an empty tab.
    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.tearDown()
        tabs.remove(at: i)
        if tabs.isEmpty { let t = BrowserTab(); adopt(t); tabs = [t] }
        if tab === current { current = tabs[min(i, tabs.count - 1)] }
        save()
    }

    func closeOthers(_ tab: BrowserTab) {
        for t in tabs where t !== tab { t.tearDown() }
        tabs = [tab]
        current = tab
        save()
    }

    func closeAll() { tabs.forEach { $0.tearDown() } }

    /// Opens a URL: in the current tab if it's empty, otherwise in a new tab.
    func open(_ url: URL) {
        if current.hasPage || current.isLoading { newTab(url.isFileURL ? url.path : url.absoluteString) } else { current.load(url) }
    }

    func selectNext(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0 === current }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func save() {
        let d = UserDefaults.standard
        d.set(tabs.map { t -> [String: Any] in
            ["url": t.savedURL, "device": t.device.rawValue, "landscape": t.landscape]
        }, forKey: tabsKey)
        d.set(tabs.firstIndex { $0 === current } ?? 0, forKey: selectedKey)
    }

    func panelDidShow() { onScreen = true }
    func panelDidHide() { onScreen = false }
}

/// One tab: a WKWebView kept alive across tab, panel and workspace switches (unloaded after a while hidden).
@MainActor
final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    weak var owner: BrowserModel?
    @Published var address: String
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorText: String?
    /// Something has been loaded (false for a brand-new tab).
    @Published private(set) var hasPage = false
    @Published var device: BrowserDevice { didSet { if device != oldValue { applyDevice(reloadIfNeeded: true) } } }
    @Published var landscape: Bool { didSet { if landscape != oldValue { owner?.save() } } }
    /// This tab is on screen right now.
    private(set) var onScreen = false

    /// The CSS viewport being emulated (nil = panel size).
    var viewport: CGSize? { device.viewport(landscape: landscape) }

    /// What to remember for this tab (the suspended page counts, about:blank doesn't).
    var savedURL: String { suspendedURL?.absoluteString ?? webView.url.map(\.absoluteString).flatMap { $0 == "about:blank" ? nil : $0 } ?? address }

    /// Display name for the tab strip.
    var tabLabel: String {
        if !title.isEmpty { return title }
        if let host = webView.url?.host, !host.isEmpty { return host }
        return hasPage ? address : "New Tab"
    }

    private var observations: [NSKeyValueObservation] = []
    /// Console output + uncaught errors of the page (for agents: browser_console). Cleared on each navigation.
    var consoleLines: [String] = []

    init(address: String = "", device: BrowserDevice = .fit, landscape: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        webView = WKWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        self.address = address
        self.device = device
        self.landscape = landscape
        super.init()
        didInitialLoad = configuration != nil   // a window a page opened: WebKit loads it
        webView.navigationDelegate = self
        webView.uiDelegate = self
        ConsoleRouter.shared.register(webView, self)
        applyDevice(reloadIfNeeded: false)
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in MainActor.assumeIsolated { self?.progress = wv.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.title = wv.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = wv.url, u.absoluteString != "about:blank" else { return }
                    self.hasPage = true
                    self.address = u.isFileURL ? u.path : u.absoluteString
                    self.owner?.save()
                }
            },
        ]
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(WKUserScript(source: consoleHookJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(ConsoleRouter.shared, name: "pnConsole")
        return config
    }

    /// User agent for the device; reloads the page when it changes so the site can serve its mobile/desktop version.
    private func applyDevice(reloadIfNeeded: Bool) {
        let ua = device.userAgent
        if webView.customUserAgent != ua {
            webView.customUserAgent = ua
            if reloadIfNeeded, webView.url != nil, !(webView.url?.absoluteString == "about:blank") { webView.reload() }
        }
        if webView.window === Self.parking { park() }
        owner?.save()
    }

    func tearDown() {
        hiddenTimer?.invalidate()
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        webView.removeFromSuperview()
        observations = []
    }

    // MARK: Suspend while hidden (RAM)

    private var hiddenTimer: Timer?
    private var suspendedURL: URL?

    /// The tab left the screen: after `browserSuspendMinutes` the page is unloaded (about:blank)
    /// so its JS, media and web process memory are released; it reloads when the tab is shown again.
    func didHide() {
        onScreen = false
        scheduleSuspend()
    }

    /// Starts the unload timer (also used after an agent drives a tab that isn't on screen).
    func scheduleSuspend() {
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

    /// The tab is on screen again.
    func didShow() {
        onScreen = true
        wake()
        loadInitialIfNeeded()
    }

    /// Cancels a pending unload and reloads a suspended page, without claiming the screen.
    func wake() {
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
        if !address.isEmpty { go(address) }
    }

    /// An off-screen window that hosts web views that aren't in the panel, so an agent working in a background
    /// workspace or tab still gets real layout, rendering and screenshots.
    private static let parking: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1440, height: 1440),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.orderOut(nil)
        return w
    }()

    /// Make sure the web view has a size and a window (parks it off-screen if the panel isn't showing it).
    func ensureHosted() {
        if webView.window == nil { park() }
    }

    /// Off screen the page gets its device viewport at 100 %.
    private func park() {
        let size = viewport ?? {
            let s = webView.frame.size
            return s.width > 0 && s.height > 0 ? s : CGSize(width: 1024, height: 800)
        }()
        webView.autoresizingMask = []
        webView.frame = NSRect(origin: .zero, size: size)
        webView.pageZoom = 1
        if webView.superview !== Self.parking.contentView { Self.parking.contentView?.addSubview(webView) }
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
        if isLoading { webView.stopLoading(); return }
        if webView.url == nil { go(address) } else { webView.reload() }
    }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }

    func openExternally() {
        if let u = webView.url ?? URL(string: address) { NSWorkspace.shared.open(u) }
    }

    // MARK: Automation (BrowserAutomation)

    /// Waits until the page stops loading (or `timeout` seconds pass).
    func waitForLoad(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Runs `body` as an async function in the page; `args` become its local variables.
    func js(_ body: String, _ args: [String: Any]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: args, contentWorld: .page)
    }

    func screenshotJPEG(maxWidth: CGFloat) async throws -> Data {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw BrowserAutomation.Failure(description: "The browser panel isn't on screen (is ProjectN's window open?).")
        }
        let cfg = WKSnapshotConfiguration()
        // Device modes: capture at the device's real width, not the scaled-down panel size.
        let width = min(maxWidth, viewport?.width ?? webView.bounds.width)
        cfg.snapshotWidth = NSNumber(value: Double(width))
        let image = try await webView.takeSnapshot(configuration: cfg)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw BrowserAutomation.Failure(description: "Couldn't encode the screenshot.")
        }
        return jpeg
    }

    static let consoleHookJS = """
    (() => {
      const post = (level, args) => { try {
        const text = args.map(a => { if (typeof a === 'string') return a; try { return JSON.stringify(a); } catch (e) { return String(a); } }).join(' ');
        window.webkit.messageHandlers.pnConsole.postMessage(level + ': ' + text.slice(0, 2000));
      } catch (e) {} };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const orig = console[level].bind(console);
        console[level] = (...args) => { post(level, args); orig(...args); };
      }
      window.addEventListener('error', e => post('uncaught', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]));
      window.addEventListener('unhandledrejection', e => post('unhandled rejection', [e.reason && (e.reason.stack || e.reason.message) || String(e.reason)]));
    })();
    """

    func receiveConsole(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 500 { consoleLines.removeFirst(consoleLines.count - 500) }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // ⌘-click opens the link in a new background tab, like Safari/Chrome.
            if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
               let url = navigationAction.request.url, let owner {
                owner.newTab(url.absoluteString, select: navigationAction.modifierFlags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { self.consoleLines.removeAll() }
    }

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

    // MARK: WKUIDelegate (new windows → tabs)

    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            guard let owner else { return nil }
            return owner.newTab(nil, select: true, configuration: configuration).webView
        }
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated { owner?.close(self) }
    }
}

/// Routes console messages to the tab whose page sent them (tabs opened by a page share its configuration).
@MainActor
final class ConsoleRouter: NSObject, WKScriptMessageHandler {
    static let shared = ConsoleRouter()
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    func register(_ webView: WKWebView, _ tab: BrowserTab) { tabs.setObject(tab, forKey: webView) }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let line = message.body as? String, let wv = message.webView, let tab = tabs.object(forKey: wv) else { return }
            tab.receiveConsole(line)
        }
    }
}

// MARK: - Views

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(model: model)
            // A new view per tab so the old tab is told it's hidden and the new one it's shown.
            BrowserTabView(tab: model.current, model: model)
                .id(ObjectIdentifier(model.current))
        }
        .onAppear { model.panelDidShow() }
        .onDisappear { model.panelDidHide() }
    }
}

private struct BrowserTabStrip: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(model.tabs, id: \.id) { tab in
                            BrowserTabChip(tab: tab, model: model, selected: tab === model.current).id(tab.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.current.id) { _, id in withAnimation { proxy.scrollTo(id) } }
            }
            Button { model.newTab() } label: { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                .buttonStyle(.hover)
                .help("New tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var tab: BrowserTab
    let model: BrowserModel
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            if tab.isLoading {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else {
                Image(systemName: tab.device == .fit ? "globe" : tab.device.symbol)
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
            }
            Text(tab.tabLabel).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(selected || hover ? 1 : 0)
                .help("Close tab")
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 70, idealWidth: 140, maxWidth: 160, minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.appWindow : (hover ? Color.primary.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.primary.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { hover = $0 }
        .help(tab.webView.url?.absoluteString ?? tab.tabLabel)
        .contextMenu {
            Button("New Tab") { model.newTab() }
            Button("Duplicate Tab") { model.newTab(tab.savedURL) }
            Divider()
            Button("Close Tab") { model.close(tab) }
            Button("Close Other Tabs") { model.closeOthers(tab) }.disabled(model.tabs.count < 2)
        }
    }
}

private struct BrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    let model: BrowserModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                GeometryReader { geo in
                    if let vp = tab.viewport {
                        deviceStage(vp, available: geo.size)
                    } else {
                        WebViewHost(webView: tab.webView, zoom: 1, cornerRadius: 0)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                if tab.isLoading {
                    ProgressView(value: tab.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                        .frame(height: 2)
                }
                if !tab.hasPage && !tab.isLoading && tab.errorText == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                        Text("New tab").font(.headline)
                        Text("Type a URL, localhost:3000 or a search above. Each workspace keeps its own tabs, and Claude sessions open pages in the browser of the workspace they run in.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appWindow)
                }
                if let err = tab.errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("Couldn't load page").font(.headline)
                        Text(err).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { tab.reload() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appWindow)
                }
            }
        }
        .onAppear { tab.didShow(); if !tab.hasPage && tab.address.isEmpty { addressFocused = true } }
        .onDisappear { tab.didHide() }
    }

    /// The page at the device's real viewport, drawn as a device screen scaled to fit, with its size underneath.
    private func deviceStage(_ vp: CGSize, available: CGSize) -> some View {
        let labelHeight: CGFloat = 22
        let inner = CGSize(width: max(1, available.width - 24), height: max(1, available.height - 24 - labelHeight))
        let scale = BrowserDevice.scale(vp, in: inner)
        let radius = tab.device.cornerRadius * scale
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            WebViewHost(webView: tab.webView, zoom: scale, cornerRadius: radius)
                .frame(width: vp.width * scale, height: vp.height * scale)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            Text("\(tab.device.label) · \(Int(vp.width))×\(Int(vp.height)) · \(Int((scale * 100).rounded()))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(height: labelHeight - 6)
            Spacer(minLength: 0)
        }
        .frame(width: available.width, height: available.height)
        .background(Color.primary.opacity(0.06))
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button(action: tab.back) { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack).help("Back")
                Button(action: tab.forward) { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward).help("Forward")
                Button(action: tab.reload) { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                    .help(tab.isLoading ? "Stop" : "Reload")
                TextField("URL, localhost:3000, or search", text: $tab.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { tab.go(tab.address); addressFocused = false }
                Button(action: tab.openExternally) { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in default browser")
            }
            .buttonStyle(.hover)
            HStack(spacing: 4) {
                Picker("Viewport", selection: $tab.device) {
                    ForEach(BrowserDevice.allCases) { d in
                        Label(d.label, systemImage: d.symbol).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Fit = panel size · Mobile 390×844 · Tablet 820×1180 · Desktop 1440×900. Mobile and Tablet also use that device's user agent, so sites serve their phone/tablet version.")
                Button { withAnimation(.easeInOut(duration: 0.2)) { tab.landscape.toggle() } } label: {
                    Image(systemName: tab.landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                }
                .buttonStyle(.hover)
                .disabled(!tab.device.rotatable)
                .help(tab.landscape ? "Rotate to portrait" : "Rotate to landscape")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Hosts a tab's persistent WKWebView. In a device mode the web view is sized to the (scaled) device screen and
/// zoomed so its CSS viewport is exactly that device's width × height; media queries, `100vh` and layout then
/// behave like on the device while input stays correct.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    /// Scale of the device screen (1 for Fit): the page is zoomed by it so its CSS viewport stays the device's.
    let zoom: CGFloat
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(container)
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
        webView.wantsLayer = true
        webView.layer?.cornerRadius = cornerRadius
        webView.layer?.masksToBounds = cornerRadius > 0
    }

    private func attach(_ container: NSView) {
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
