import AppKit
import Foundation
import WebKit

/// Lets the Claude sessions ProjectN starts drive the built-in Browser (right panel) through MCP tools, so opening
/// a site, testing a local server or searching the web happens where you can watch it instead of in Chrome.
///
///   claude --mcp-config ~/.projectn/browser-mcp.json   →   pn-agent browser (stdio MCP)
///          →  127.0.0.1:$PROJECTN_BROWSER_PORT + $PROJECTN_BROWSER_TOKEN  →  this class  →  BrowserModel
///
/// The token is random per app run and lives only in the panes' environment and in memory here.
@MainActor
final class BrowserAutomation {
    static let shared = BrowserAutomation()

    static let serverName = "projectn-browser"
    nonisolated static let token = UUID().uuidString
    nonisolated static var configFile: URL { AppHome.root.appendingPathComponent("browser-mcp.json") }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _port: UInt16?
    /// Port of the listener once it's up (read from the launch queue, hence the lock).
    nonisolated static var port: UInt16? {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock() }
    }

    private let bridge = AgentBridge()
    private weak var panel: RightPanelModel?
    private var browser: BrowserModel? { panel?.browser }

    func start(panel: RightPanelModel) {
        self.panel = panel
        guard let helper = AgentBridge.helperPath else { return }
        writeConfig(helper: helper)
        bridge.handler = { [weak self] req, reply in self?.handle(req, reply: reply) }
        bridge.start()
        bridge.waitUntilReady()
        Self.port = bridge.port
    }

    private func writeConfig(helper: String) {
        let obj: [String: Any] = ["mcpServers": [Self.serverName: ["command": helper, "args": ["browser"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.configFile, options: .atomic)
    }

    // MARK: Launch integration

    /// Environment for every pane: how `pn-agent browser` reaches the app.
    nonisolated static func environment() -> [String: String] {
        guard let port else { return [:] }
        return ["PROJECTN_BROWSER_PORT": String(port), "PROJECTN_BROWSER_TOKEN": token]
    }

    nonisolated static let systemPrompt = """
    # ProjectN built-in browser
    You are running inside ProjectN, which has a built-in browser in its right-hand panel that the user watches. \
    It is your default browser: whenever a task needs a web page — opening or previewing a website or a local dev \
    server, testing or debugging a web app, searching ("googling") something for the user, reading docs or an \
    install/download page, checking a deploy — use the \(serverName) tools (mcp__\(serverName)__browser_navigate, \
    browser_snapshot, browser_click, browser_type, browser_screenshot, browser_evaluate, browser_console, \
    browser_set_viewport). Use Claude in Chrome (mcp__claude-in-chrome__*) or another browser only when the user \
    explicitly asks for Chrome or for their own browser session/profile (for example a site they're logged into \
    there). Don't launch the system browser (`open https://…`) unless the user asks. WebSearch / WebFetch are still \
    fine for quick background lookups that the user doesn't need to see.
    """

    /// Adds the browser's MCP server and instructions to a Claude command line (merging with flags already there).
    nonisolated static func applyToClaude(_ parts: inout [String]) {
        guard port != nil, FileManager.default.fileExists(atPath: configFile.path) else { return }
        if let i = parts.firstIndex(of: "--mcp-config") {
            parts.insert(configFile.path, at: i + 1)       // variadic: one more config file
        } else {
            parts += ["--mcp-config", configFile.path]
        }
        if let i = parts.firstIndex(of: "--append-system-prompt"), i + 1 < parts.count {
            parts[i + 1] += "\n\n" + systemPrompt
        } else {
            parts += ["--append-system-prompt", systemPrompt]
        }
    }

    // MARK: Requests

    private func handle(_ req: [String: Any], reply: @escaping AgentBridge.Reply) {
        guard req["token"] as? String == Self.token else {
            reply(["text": "Not a ProjectN session.", "isError": true]); return
        }
        switch req["op"] as? String {
        case "tools":
            reply(["tools": Self.tools])
        case "call":
            let name = req["name"] as? String ?? ""
            let args = req["arguments"] as? [String: Any] ?? [:]
            Task { @MainActor in
                do { reply(try await self.call(name, args)) }
                catch { reply(["text": "\(error)", "isError": true]) }
            }
        default:
            reply(["text": "Unknown operation", "isError": true])
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private func call(_ name: String, _ a: [String: Any]) async throws -> [String: Any] {
        guard let panel, let b = browser else { throw Failure(description: "ProjectN's browser isn't available.") }
        AuditLog.record("browser.tool", ["tool": name])
        switch name {
        case "browser_navigate":
            let target = (a["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { throw Failure(description: "Give a url (or search words, or back / forward / reload).") }
            panel.show(.browser)
            switch target.lowercased() {
            case "back": b.back()
            case "forward": b.forward()
            case "reload": b.reload()
            default: b.go(target)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            await b.waitForLoad(timeout: 30)
            return ["text": try await summary(b)]
        case "browser_snapshot":
            b.didShow()
            return ["text": try await snapshot(b, maxText: a["max_text"] as? Int ?? 12000)]
        case "browser_click":
            b.didShow()
            let r = try await b.js(Self.findJS + Self.clickJS, ["ref": a["ref"] ?? NSNull(), "selector": a["selector"] ?? NSNull(),
                                                                "text": a["text"] ?? NSNull()])
            try await Task.sleep(nanoseconds: 400_000_000)
            await b.waitForLoad(timeout: 15)
            return ["text": "\(r)\n\n" + (try await summary(b))]
        case "browser_type":
            b.didShow()
            let r = try await b.js(Self.findJS + Self.typeJS, ["ref": a["ref"] ?? NSNull(), "selector": a["selector"] ?? NSNull(),
                                                               "text": NSNull(), "value": a["text"] as? String ?? "",
                                                               "clear": a["clear"] as? Bool ?? true, "submit": a["submit"] as? Bool ?? false])
            if a["submit"] as? Bool == true {
                try await Task.sleep(nanoseconds: 400_000_000)
                await b.waitForLoad(timeout: 15)
                return ["text": "\(r)\n\n" + (try await summary(b))]
            }
            return ["text": "\(r)"]
        case "browser_screenshot":
            panel.show(.browser)
            try await Task.sleep(nanoseconds: 300_000_000)
            let data = try await b.screenshotJPEG(maxWidth: 1280)
            return ["text": "Screenshot of \(b.webView.url?.absoluteString ?? "the page") (viewport: \(b.device.label))",
                    "image": data.base64EncodedString(), "mimeType": "image/jpeg"]
        case "browser_evaluate":
            guard let script = a["script"] as? String, !script.isEmpty else { throw Failure(description: "Give a script.") }
            b.didShow()
            let r = try await b.js("const __r = await (async () => { \(script) })(); return __r === undefined ? 'undefined' : JSON.stringify(__r, null, 2);", [:])
            return ["text": String(describing: r).prefixString(20000)]
        case "browser_console":
            let lines = b.consoleLines.suffix(a["limit"] as? Int ?? 100)
            if a["clear"] as? Bool == true { b.consoleLines.removeAll() }
            return ["text": lines.isEmpty ? "No console messages since the last page load." : lines.joined(separator: "\n")]
        case "browser_set_viewport":
            guard let d = BrowserModel.Device(rawValue: (a["device"] as? String ?? "").lowercased()) else {
                throw Failure(description: "device must be fit, mobile, tablet or desktop.")
            }
            panel.show(.browser)
            b.device = d
            return ["text": "Viewport set to \(d.label)" + (d.viewportWidth.map { " (\(Int($0)) px wide)" } ?? " (panel width)") + "."]
        default:
            throw Failure(description: "Unknown tool \(name)")
        }
    }

    private func summary(_ b: BrowserModel) async throws -> String {
        var s = "URL: \(b.webView.url?.absoluteString ?? b.address)\nTitle: \(b.title)"
        if let e = b.errorText { s += "\nLoad error: \(e)" }
        s += "\n\nUse browser_snapshot to read the page and get element refs, or browser_screenshot to see it."
        return s
    }

    private func snapshot(_ b: BrowserModel, maxText: Int) async throws -> String {
        let raw = try await b.js(Self.snapshotJS, ["maxText": max(500, min(maxText, 60000))])
        guard let json = raw as? String, let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "\(raw ?? "")" }
        var s = "URL: \(o["url"] ?? "")\nTitle: \(o["title"] ?? "")\n"
        if let e = b.errorText { s += "Load error: \(e)\n" }
        s += "\n## Interactive elements (use ref with browser_click / browser_type)\n"
        s += (o["elements"] as? [String] ?? []).joined(separator: "\n")
        s += "\n\n## Page text\n\(o["text"] ?? "")"
        if o["truncated"] as? Bool == true { s += "\n…(truncated; pass a larger max_text or use browser_evaluate)" }
        return s
    }

    // MARK: Tool definitions

    static let tools: [[String: Any]] = {
        func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": desc,
             "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
        }
        let str: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let target: [String: Any] = [
            "ref": str("Element ref from browser_snapshot, e.g. \"12\"."),
            "selector": str("CSS selector (alternative to ref)."),
        ]
        return [
            tool("browser_navigate", "Open a URL in ProjectN's built-in browser (the panel the user watches) and wait for it to load. Accepts a full URL, \"localhost:3000\", \"3000\", a file path, plain search words (searched on the web), or back / forward / reload. This is the default browser for opening sites, previewing local servers, testing and searching.",
                 ["url": str("URL, host:port, file path, search words, or back / forward / reload.")], required: ["url"]),
            tool("browser_snapshot", "Read the current page: URL, title, the visible interactive elements (numbered refs for browser_click / browser_type) and the page text.",
                 ["max_text": ["type": "integer", "description": "Max characters of page text (default 12000)."]]),
            tool("browser_click", "Click an element on the current page (by ref from browser_snapshot, CSS selector, or visible text), then wait for any navigation.",
                 target.merging(["text": str("Visible text of a link/button to click (alternative to ref).")]) { a, _ in a }),
            tool("browser_type", "Type into an input, textarea, select or editable element (React/Vue friendly). Optionally submit (Enter / form submit).",
                 target.merging(["text": str("Text to enter (for a select: the option's value or label)."),
                                 "clear": ["type": "boolean", "description": "Replace the current value (default true)."],
                                 "submit": ["type": "boolean", "description": "Submit afterwards (default false)."]]) { a, _ in a },
                 required: ["text"]),
            tool("browser_screenshot", "Take a screenshot of what the built-in browser shows right now (JPEG). Costs more tokens than browser_snapshot; use it to check layout and visuals."),
            tool("browser_evaluate", "Run JavaScript in the page as the body of an async function; `return` a JSON-serializable value.",
                 ["script": str("e.g. return document.querySelectorAll('img').length")], required: ["script"]),
            tool("browser_console", "Recent console messages and uncaught errors from the page (newest last).",
                 ["limit": ["type": "integer", "description": "Max lines (default 100)."],
                  "clear": ["type": "boolean", "description": "Clear the log after reading."]]),
            tool("browser_set_viewport", "Emulate a device width to test responsive layouts: fit (panel width), mobile (390), tablet (820), desktop (1440).",
                 ["device": ["type": "string", "enum": ["fit", "mobile", "tablet", "desktop"]]], required: ["device"]),
        ]
    }()

    // MARK: Page scripts (run with callAsyncJavaScript; arguments arrive as variables)

    static let snapshotJS = """
    const sel = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[contenteditable=""],[contenteditable=true],[onclick]';
    document.querySelectorAll('[data-pn-ref]').forEach(e => e.removeAttribute('data-pn-ref'));
    const out = []; let n = 0;
    for (const el of document.querySelectorAll(sel)) {
      const r = el.getBoundingClientRect(); const st = getComputedStyle(el);
      if (r.width === 0 || r.height === 0 || st.visibility === 'hidden' || st.display === 'none') continue;
      if (n >= 300) { out.push('…more elements not listed'); break; }
      const ref = String(++n); el.setAttribute('data-pn-ref', ref);
      const tag = el.tagName.toLowerCase();
      const kind = tag === 'input' ? 'input[' + (el.type || 'text') + ']' : (el.getAttribute('role') || tag);
      const label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.name || el.alt || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
      let extra = '';
      if (tag === 'a') extra += ' -> ' + el.getAttribute('href');
      if (el.disabled) extra += ' (disabled)';
      if (el.type === 'checkbox' || el.type === 'radio') extra += el.checked ? ' (checked)' : ' (unchecked)';
      if (r.bottom < 0 || r.top > innerHeight) extra += ' (offscreen)';
      out.push('[' + ref + '] ' + kind + ' "' + label + '"' + extra);
    }
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
    return JSON.stringify({ url: location.href, title: document.title, elements: out, text: text.slice(0, maxText), truncated: text.length > maxText });
    """

    /// Defines `el` from ref / selector / text, or throws.
    static let findJS = """
    let el = null;
    if (ref !== null && ref !== undefined && ref !== '') el = document.querySelector('[data-pn-ref="' + String(ref) + '"]');
    else if (selector) el = document.querySelector(selector);
    else if (text) {
      const want = String(text).trim().toLowerCase();
      const cands = [...document.querySelectorAll('a,button,[role=button],[role=link],[role=tab],[role=menuitem],input[type=submit],input[type=button],summary,label')]
        .filter(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
      const label = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' ').toLowerCase();
      el = cands.find(e => label(e) === want) || cands.find(e => label(e).includes(want));
    }
    if (!el) throw new Error('Element not found' + (ref ? ' (ref ' + ref + ' — refs change after navigation; take a new browser_snapshot)' : '') + '.');
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const desc = el.tagName.toLowerCase() + ' "' + (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' ').slice(0, 60) + '"';

    """

    static let clickJS = """
    if (el.focus) el.focus({ preventScroll: true });
    el.click();
    return 'Clicked ' + desc + '.';
    """

    static let typeJS = """
    el.focus();
    if (el instanceof HTMLSelectElement) {
      const opt = [...el.options].find(o => o.value === value || o.text.trim() === value);
      if (!opt) throw new Error('No option "' + value + '" in ' + desc + '.');
      el.value = opt.value;
    } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, clear ? value : el.value + value);
    } else if (el.isContentEditable) {
      if (clear) { document.execCommand('selectAll', false, null); }
      document.execCommand('insertText', false, value);
    } else {
      throw new Error(desc + ' is not editable.');
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (submit) {
      const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const go = el.dispatchEvent(new KeyboardEvent('keydown', opts));
      el.dispatchEvent(new KeyboardEvent('keyup', opts));
      if (go && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    return 'Typed into ' + desc + (submit ? ' and submitted' : '') + '.';
    """
}

private extension String {
    func prefixString(_ n: Int) -> String { count > n ? String(prefix(n)) + "\n…(truncated)" : self }
}
