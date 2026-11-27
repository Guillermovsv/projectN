import AppKit
import Testing
import WebKit
@testable import ProjectN

/// Runs the pointing script on a real page with popups and stacked layers.
@MainActor
struct BrowserPointingPageTests {
    private final class Inbox: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if let d = m.body as? [String: Any] { messages.append(d) }
        }
    }

    @Test func pointsAtPopupsWithoutClosingThem() async throws {
        let inbox = Inbox()
        let config = WKWebViewConfiguration()
        // Synthetic events stand in for the mouse, so the test drops the "real input only" check.
        let script = BrowserPointing.script.replacingOccurrences(of: " || !e.isTrusted", with: "")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: BrowserPointing.world))
        config.userContentController.add(inbox, contentWorld: BrowserPointing.world, name: "pnPoint")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(web)
        web.loadHTMLString("""
        <style>body { margin: 0 } div, button { position: absolute }</style>
        <button id="under" style="left:20px;top:20px;width:200px;height:40px">Under</button>
        <div id="ghost" style="left:0;top:0;width:300px;height:100px"></div>
        <div id="menu" style="left:20px;top:150px;width:200px;height:60px;background:#eee">Menu item</div>
        <div id="widget" style="left:400px;top:20px;width:200px;height:60px"></div>
        <dialog id="dlg"><p id="inside">Inside the dialog</p></dialog>
        <script>
          window.seen = [];
          for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'keydown'])
            document.addEventListener(t, () => seen.push(t), true);
          widget.attachShadow({ mode: 'open' }).innerHTML = '<button id="deep" style="width:200px;height:60px">Deep</button>';
        </script>
        """, baseURL: URL(string: "http://localhost/"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }

        func page(_ js: String) async throws -> Any? { try await web.callAsyncJavaScript(js, contentWorld: .page) }
        func pointing(_ js: String) async throws {
            _ = try await web.callAsyncJavaScript(BrowserPointing.script + "\n" + js + "; return true;",
                                                  contentWorld: BrowserPointing.world)
        }
        /// Clicks the middle of the element and returns what got pointed out.
        func click(_ target: String) async throws -> String? {
            let before = inbox.messages.count
            _ = try await page("""
            const el = \(target), r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
            const hit = document.elementFromPoint(x, y);
            for (const t of ['pointermove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'])
              hit.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t,
                { bubbles: true, composed: true, cancelable: true, clientX: x, clientY: y, button: 0 }));
            """)
            for _ in 0..<40 where inbox.messages.count == before { try await Task.sleep(nanoseconds: 25_000_000) }
            return inbox.messages.count > before ? inbox.messages.last?["selector"] as? String : nil
        }

        try await pointing("P.setPicking(true)")
        #expect(try await click("under") == "#under")          // through the invisible layer
        #expect(try await click("menu") == "#menu")
        let deep = try await click("widget")
        #expect(deep == "#widget >>> #deep")
        _ = try await page("dlg.showModal()")
        #expect(try await click("inside") == "#inside")
        // The overlay is in the top layer, inside the dialog, so it draws over it.
        #expect(try await page("return dlg.querySelector('projectn-pointing')?.matches(':popover-open')") as? Bool == true)
        #expect(try await page("return seen.length") as? Int == 0)
        _ = try await page("dlg.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))")
        #expect(try await page("return seen.length + (dlg.open ? 0 : 100)") as? Int == 0)
        // Done pointing: the page gets its events again.
        _ = try await click("inside")
        #expect((try await page("return seen.length") as? Int ?? 0) > 0)
        window.close()
    }
}
