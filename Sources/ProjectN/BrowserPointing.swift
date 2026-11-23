import AppKit
import WebKit

/// Something pointed out in the browser ("señalar"): an element, an area or a text selection. It lives in a pane's
/// chat box as a numbered chip, stays highlighted on the page with the same number, and is sent with the message as
/// a reference block (URL, selector, text, HTML and a cropped screenshot) the agent can act on.
struct BrowserMark: Identifiable, Hashable {
    enum Kind: String { case element, area, text }

    /// The id the page uses for its highlight.
    let id: String
    let number: Int
    let tabID: UUID
    let kind: Kind
    let url: String
    /// Short name, e.g. `h1.hero__title`, `Area 420×300`, `"Precios desde…"`.
    let label: String
    let selector: String
    let text: String
    let html: String
    /// Elements inside an area (label — selector — text).
    let contents: [String]
    /// Size and position on the page (CSS px, document coordinates).
    let box: String
    var imagePath: String?

    var chipText: String { "\(number) · \(label)" }

    var helpText: String {
        var lines = ["[\(number)] \(kind == .area ? "Area" : kind == .text ? "Text" : "Element") on \(url)"]
        if !selector.isEmpty { lines.append(selector) }
        if !text.isEmpty { lines.append("“\(text.prefix(160))”") }
        lines.append("Click × to remove · hover to find it on the page")
        return lines.joined(separator: "\n")
    }

    /// The block appended to the message.
    static func promptBlock(_ marks: [BrowserMark]) -> String {
        guard !marks.isEmpty else { return "" }
        var out = ["Pointed out in the browser (numbers match the [n] in my message and the badges on the page):"]
        for m in marks.sorted(by: { $0.number < $1.number }) {
            switch m.kind {
            case .element: out.append("[\(m.number)] Element \(m.label) on \(m.url)")
            case .area: out.append("[\(m.number)] Area of the page (\(m.box)) on \(m.url)")
            case .text: out.append("[\(m.number)] Selected text on \(m.url)")
            }
            if !m.selector.isEmpty { out.append("    selector: \(m.selector)") }
            if m.kind != .area { out.append("    position: \(m.box)") }
            if !m.text.isEmpty { out.append("    text: \"\(m.text)\"") }
            if !m.html.isEmpty { out.append("    html: \(m.html)") }
            if !m.contents.isEmpty {
                out.append("    contains:")
                out.append(contentsOf: m.contents.map { "      - \($0)" })
            }
            if let p = m.imagePath { out.append("    screenshot: \(Shell.quote(p))") }
        }
        return out.joined(separator: "\n")
    }

    static func from(_ d: [String: Any], number: Int, tabID: UUID) -> BrowserMark? {
        guard let id = d["id"] as? String, let kind = Kind(rawValue: d["kind"] as? String ?? "") else { return nil }
        return BrowserMark(id: id, number: number, tabID: tabID, kind: kind,
                           url: d["url"] as? String ?? "",
                           label: d["label"] as? String ?? kind.rawValue,
                           selector: d["selector"] as? String ?? "",
                           text: d["text"] as? String ?? "",
                           html: d["html"] as? String ?? "",
                           contents: d["contents"] as? [String] ?? [],
                           box: d["box"] as? String ?? "",
                           imagePath: nil)
    }
}

/// Finds the tab a mark lives in, to update or remove its highlight.
@MainActor
enum BrowserPointing {
    private static let tabs = NSHashTable<BrowserTab>.weakObjects()

    static func register(_ tab: BrowserTab) { tabs.add(tab) }

    static func tab(_ id: UUID) -> BrowserTab? { tabs.allObjects.first { $0.id == id } }

    /// Removes the page highlights of marks that left a chat box (removed or sent).
    static func unmark(_ marks: [BrowserMark]) {
        for m in marks { tab(m.tabID)?.pointJS("P.unmark(id)", ["id": m.id]) }
    }

    /// Briefly pulses a mark's highlight (hovering its chip) and scrolls it into view.
    static func flash(_ m: BrowserMark) {
        tab(m.tabID)?.pointJS("P.flash(id)", ["id": m.id])
    }

    /// Screenshots of marks; files older than a week are removed.
    static var imagesDir: URL {
        let dir = AppHome.root.appendingPathComponent("pointing")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pruneImages() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for u in (try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// Pointing runs in its own JavaScript world: the page's scripts can't see or break it, and it can't clash with them.
    static let world = WKContentWorld.world(name: "projectn-pointing")

    /// Installed on demand (idempotent). `P` is the API used by the Swift side.
    static let script = #"""
    if (!window.__pnPoint) window.__pnPoint = (() => {
      const ACCENT = '#ff5a1f';
      const post = (m) => { try { window.webkit.messageHandlers.pnPoint.postMessage(m); } catch (e) {} };
      const host = document.createElement('projectn-pointing');
      host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block;';
      const shadow = host.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `<style>
        :host { all: initial; }
        .box { position: fixed; box-sizing: border-box; border: 2px solid ${ACCENT}; background: rgba(255,90,31,.10);
               border-radius: 3px; pointer-events: none; transition: box-shadow .2s; }
        .box.hover { border-style: dashed; background: rgba(255,90,31,.07); }
        .box.flash { box-shadow: 0 0 0 6px rgba(255,90,31,.45); }
        .box.pending .badge { opacity: .6; }
        .tag { position: absolute; left: -2px; top: -24px; font: 600 11px/1 -apple-system, system-ui, sans-serif;
               background: ${ACCENT}; color: #fff; padding: 5px 7px; border-radius: 5px; white-space: nowrap;
               max-width: 420px; overflow: hidden; text-overflow: ellipsis; }
        .tag.in { top: 2px; left: 2px; }
        .tag small { font-weight: 400; opacity: .85; margin-left: 6px; }
        .badge { position: absolute; left: -12px; top: -12px; min-width: 22px; height: 22px; border-radius: 11px;
                 background: ${ACCENT}; color: #fff; font: 700 12px/22px -apple-system, system-ui, sans-serif;
                 text-align: center; padding: 0 6px; box-sizing: border-box; box-shadow: 0 1px 5px rgba(0,0,0,.35); }
        .drag { position: fixed; box-sizing: border-box; border: 2px dashed ${ACCENT}; background: rgba(255,90,31,.12);
                pointer-events: none; display: none; }
        .shield { position: fixed; inset: 0; pointer-events: auto; cursor: crosshair; background: transparent; display: none; }
        .hidden { visibility: hidden; }
      </style><div class="layer"><div class="shield"></div><div class="marks"></div><div class="box hover" style="display:none"><div class="tag"></div></div><div class="drag"></div></div>`;
      const layer = shadow.querySelector('.layer');
      const shield = shadow.querySelector('.shield');
      const marksEl = shadow.querySelector('.marks');
      const hoverBox = shadow.querySelector('.box.hover');
      const hoverTag = hoverBox.querySelector('.tag');
      const dragBox = shadow.querySelector('.drag');
      const marks = new Map();   // id -> { kind, el, range, doc: {x,y,w,h}, node }
      let picking = false, hoverEl = null, stack = [], down = null, dragging = false, seq = 0;

      const attach = () => { if (!host.isConnected) document.documentElement.appendChild(host); };
      const isOurs = (el) => el === host;

      // ---- describing elements ----
      const cleanClasses = (el) => [...el.classList].filter(c => c.length < 40 && !/^(css|sc|jsx|svelte|emotion)-|[0-9a-f]{6,}|^_/.test(c));
      const short = (el) => {
        let s = el.localName;
        if (el.id && el.id.length < 40) s += '#' + el.id;
        const c = cleanClasses(el).slice(0, 2);
        if (c.length) s += '.' + c.join('.');
        return s;
      };
      const selectorFor = (el) => {
        const parts = [];
        let e = el;
        while (e && e.nodeType === 1 && e !== document.documentElement && parts.length < 7) {
          if (e.id && /^[A-Za-z][\w-]*$/.test(e.id) && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) {
            parts.unshift('#' + CSS.escape(e.id)); break;
          }
          let p = e.localName;
          const c = cleanClasses(e).slice(0, 2);
          if (c.length) p += '.' + c.map(x => CSS.escape(x)).join('.');
          const par = e.parentElement;
          if (par) {
            const same = [...par.children].filter(x => x.localName === e.localName);
            if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
          }
          parts.unshift(p);
          if (e === document.body) break;
          e = par;
        }
        return parts.join(' > ');
      };
      const squash = (s, n) => { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };
      const htmlOf = (el) => {
        let h = el.outerHTML || '';
        h = h.replace(/\s+/g, ' ').replace(/ (style|data-[\w-]*-id)="[^"]{120,}"/g, ' $1="…"');
        return h.length > 900 ? h.slice(0, 900) + '…' : h;
      };
      const docRect = (r) => ({ x: Math.round(r.left + scrollX), y: Math.round(r.top + scrollY), w: Math.round(r.width), h: Math.round(r.height) });
      const boxText = (d) => `${d.w}×${d.h} px at x ${d.x}, y ${d.y} of the page`;
      const sizeOf = (r) => `${Math.round(r.width)}×${Math.round(r.height)}`;
      const view = (r) => ({ x: r.left, y: r.top, w: r.width, h: r.height });

      // ---- drawing ----
      const place = (node, r) => {
        node.style.left = r.left + 'px'; node.style.top = r.top + 'px';
        node.style.width = Math.max(2, r.width) + 'px'; node.style.height = Math.max(2, r.height) + 'px';
      };
      const rectOf = (m) => {
        if (m.el && m.el.isConnected) return m.el.getBoundingClientRect();
        if (m.range) { try { const r = m.range.getBoundingClientRect(); if (r.width || r.height) return r; } catch (e) {} }
        const d = m.doc; return new DOMRect(d.x - scrollX, d.y - scrollY, d.w, d.h);
      };
      let raf = 0;
      const tick = () => {
        raf = 0;
        for (const m of marks.values()) place(m.node, rectOf(m));
        if (marks.size) raf = requestAnimationFrame(tick);
      };
      const loop = () => { if (!raf) raf = requestAnimationFrame(tick); };

      const addBox = (kind, el, range, r) => {
        attach();
        const id = 'm' + (++seq) + '-' + Date.now().toString(36);
        const node = document.createElement('div');
        node.className = 'box pending';
        node.innerHTML = '<div class="badge">…</div>';
        marksEl.appendChild(node);
        const m = { kind, el, range, doc: docRect(r), node };
        marks.set(id, m);
        place(node, r);
        loop();
        return { id, m };
      };

      // ---- picking ----
      const elementAt = (x, y) => {
        const all = document.elementsFromPoint(x, y);
        return all.find(e => !isOurs(e) && e !== document.documentElement) || null;
      };
      const showHover = () => {
        if (!hoverEl || dragging) { hoverBox.style.display = 'none'; return; }
        const r = hoverEl.getBoundingClientRect();
        hoverBox.style.display = 'block';
        place(hoverBox, r);
        hoverTag.innerHTML = '';
        hoverTag.textContent = short(hoverEl);
        const sm = document.createElement('small'); sm.textContent = sizeOf(r); hoverTag.appendChild(sm);
        hoverTag.classList.toggle('in', r.top < 26);
      };
      const setHover = (el) => { hoverEl = el; stack = []; showHover(); };

      const onMove = (e) => {
        if (down) {
          const dx = e.clientX - down.x, dy = e.clientY - down.y;
          if (!dragging && Math.hypot(dx, dy) > 6) dragging = true;
          if (dragging) {
            hoverBox.style.display = 'none';
            dragBox.style.display = 'block';
            place(dragBox, new DOMRect(Math.min(down.x, e.clientX), Math.min(down.y, e.clientY), Math.abs(dx), Math.abs(dy)));
            return;
          }
        }
        const el = elementAt(e.clientX, e.clientY);
        if (el !== hoverEl && !stack.length) setHover(el);
        else if (el !== hoverEl && stack.length && !stack.includes(el)) setHover(el);
      };
      const onDown = (e) => { if (e.button !== 0) return; e.preventDefault(); down = { x: e.clientX, y: e.clientY }; dragging = false; };
      const onUp = (e) => {
        if (!down) return;
        e.preventDefault();
        const start = down; down = null;
        if (dragging) {
          dragging = false;
          dragBox.style.display = 'none';
          const r = new DOMRect(Math.min(start.x, e.clientX), Math.min(start.y, e.clientY), Math.abs(e.clientX - start.x), Math.abs(e.clientY - start.y));
          markArea(r);
        } else if (hoverEl) {
          markElement(hoverEl);
        }
        showHover();
      };
      const onKey = (e) => {
        if (!picking) return;
        if (e.key === 'Alt') { shield.style.pointerEvents = e.type === 'keydown' ? 'none' : 'auto'; hoverBox.style.display = e.type === 'keydown' ? 'none' : hoverBox.style.display; return; }
        if (e.type !== 'keydown') return;
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); setPicking(false); post({ type: 'exit' }); }
        else if (e.key === 'ArrowUp' && hoverEl && hoverEl.parentElement && hoverEl.parentElement !== document.documentElement) {
          e.preventDefault(); e.stopPropagation(); stack.push(hoverEl); hoverEl = hoverEl.parentElement; showHover();
        } else if (e.key === 'ArrowDown' && stack.length) {
          e.preventDefault(); e.stopPropagation(); hoverEl = stack.pop(); showHover();
        } else if (e.key === 'Enter' && hoverEl) {
          e.preventDefault(); e.stopPropagation(); markElement(hoverEl);
        }
      };
      // ⌥ lets the page through: select text with ⌥ held, it's pointed out when you release the mouse.
      const onPageUp = () => { if (picking && shield.style.pointerEvents === 'none') setTimeout(() => { if (markSelection()) getSelection().removeAllRanges(); }, 0); };
      const onScroll = () => { if (picking) showHover(); };

      const setPicking = (on) => {
        picking = !!on;
        attach();
        shield.style.display = picking ? 'block' : 'none';
        shield.style.pointerEvents = 'auto';
        if (!picking) { hoverEl = null; stack = []; down = null; dragging = false; dragBox.style.display = 'none'; }
        showHover();
        return picking;
      };
      shield.addEventListener('mousemove', onMove, true);
      shield.addEventListener('mousedown', onDown, true);
      shield.addEventListener('mouseup', onUp, true);
      shield.addEventListener('click', e => { e.preventDefault(); e.stopPropagation(); }, true);
      shield.addEventListener('contextmenu', e => { e.preventDefault(); setPicking(false); post({ type: 'exit' }); }, true);
      window.addEventListener('keydown', onKey, true);
      window.addEventListener('keyup', onKey, true);
      window.addEventListener('blur', () => { if (picking) shield.style.pointerEvents = 'auto'; });
      document.addEventListener('mouseup', onPageUp, true);
      window.addEventListener('scroll', onScroll, true);

      // ---- marks ----
      const send = (id, payload, r) => post(Object.assign({ type: 'mark', id, url: location.href, rect: view(r), dpr: devicePixelRatio }, payload));
      const markElement = (el) => {
        const r = el.getBoundingClientRect();
        const { id, m } = addBox('element', el, null, r);
        const extra = [];
        for (const a of ['href', 'src', 'alt', 'aria-label', 'placeholder', 'data-testid']) {
          const v = el.getAttribute && el.getAttribute(a); if (v) extra.push(`${a}="${squash(v, 120)}"`);
        }
        send(id, { kind: 'element', label: '<' + short(el) + '>', selector: selectorFor(el),
                   text: squash(el.innerText || el.textContent, 400), html: htmlOf(el), box: boxText(m.doc),
                   contents: extra.length ? ['attributes: ' + extra.join(' ')] : [] }, r);
      };
      const markArea = (r) => {
        if (r.width < 4 || r.height < 4) return;
        const inside = [];
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
        const within = (b) => b.width > 0 && b.height > 0 && b.left >= r.left - 2 && b.top >= r.top - 2 && b.right <= r.right + 2 && b.bottom <= r.bottom + 2;
        let n = walker.nextNode();
        while (n && inside.length < 15) {
          if (!isOurs(n) && within(n.getBoundingClientRect()) && !inside.some(p => p.contains(n))) inside.push(n);
          n = walker.nextNode();
        }
        // The smallest element that holds the whole area, as context.
        let around = elementAt(r.left + r.width / 2, r.top + r.height / 2);
        while (around && around.parentElement && !(() => { const b = around.getBoundingClientRect(); return b.left <= r.left && b.top <= r.top && b.right >= r.right && b.bottom >= r.bottom; })()) around = around.parentElement;
        const { id, m } = addBox('area', null, null, r);
        send(id, { kind: 'area', label: 'Area ' + sizeOf(r), selector: around ? selectorFor(around) : '',
                   text: squash(inside.map(e => e.innerText || '').join(' '), 400), html: '', box: boxText(m.doc),
                   contents: inside.map(e => `<${short(e)}> — ${selectorFor(e)}${(e.innerText || '').trim() ? ' — "' + squash(e.innerText, 100) + '"' : ''}`) }, r);
      };
      const markSelection = () => {
        const sel = getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount) return false;
        const text = sel.toString().trim();
        if (!text) return false;
        const range = sel.getRangeAt(0).cloneRange();
        const r = range.getBoundingClientRect();
        let el = range.commonAncestorContainer; if (el.nodeType !== 1) el = el.parentElement;
        const { id, m } = addBox('text', null, range, r);
        send(id, { kind: 'text', label: '"' + squash(text, 28) + '"', selector: el ? selectorFor(el) : '',
                   text: squash(text, 600), html: el ? htmlOf(el) : '', box: boxText(m.doc),
                   contents: el ? ['inside <' + short(el) + '>'] : [] }, r);
        return true;
      };

      return {
        setPicking, markSelection,
        isPicking: () => picking,
        confirm(id, n) { const m = marks.get(id); if (m) { m.node.classList.remove('pending'); m.node.querySelector('.badge').textContent = String(n); } },
        unmark(id) { const m = marks.get(id); if (m) { m.node.remove(); marks.delete(id); } },
        flash(id) {
          const m = marks.get(id); if (!m) return;
          const r = rectOf(m);
          if (r.bottom < 0 || r.top > innerHeight) scrollBy({ top: r.top - innerHeight / 3, behavior: 'smooth' });
          m.node.classList.add('flash'); setTimeout(() => m.node.classList.remove('flash'), 700);
        },
        rect(id) { const m = marks.get(id); return m ? view(rectOf(m)) : null; },
        async hideOverlay(hidden) {
          layer.classList.toggle('hidden', !!hidden);
          await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        },
      };
    })();
    const P = window.__pnPoint;
    """#
}

extension BrowserTab {
    /// Runs `body` with `P` = the pointing API (installed first if this page doesn't have it yet).
    @discardableResult
    func pointEval(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        try? await webView.callAsyncJavaScript(BrowserPointing.script + "\nreturn await (async () => { return \(body); })();",
                                               arguments: args, in: nil, contentWorld: BrowserPointing.world)
    }

    /// Fire-and-forget `pointEval`.
    func pointJS(_ body: String, _ args: [String: Any] = [:]) {
        Task { @MainActor in await pointEval(body, args) }
    }

    /// The ◎ button: with text selected on the page it points that out; otherwise it turns picking on / off.
    func togglePointing() {
        if pointing { setPointing(false); return }
        Task { @MainActor in
            let marked = await pointEval("P.markSelection()") as? Bool ?? false
            if marked {
                await pointEval("(getSelection().removeAllRanges(), true)")
            } else {
                setPointing(true)
            }
        }
    }

    func setPointing(_ on: Bool) {
        pointing = on
        pointJS("P.setPicking(on)", ["on": on])
        if on { webView.window?.makeFirstResponder(webView) }
    }

    /// A message from the page's pointing script.
    func receivePointing(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "exit": pointing = false
        case "mark": Task { await addMark(body) }
        default: break
        }
    }

    private func addMark(_ body: [String: Any]) async {
        guard let id = body["id"] as? String else { return }
        guard let store = owner?.store, let target = store.pointingTarget(workspaceID: owner?.workspaceID),
              let (_, pane) = store.pane(target.paneID, in: target.workspaceID) else {
            pointJS("P.unmark(id)", ["id": id])
            showPointingNotice("Open a Claude or Codex pane in this workspace to point things out to it.")
            return
        }
        let composer = store.composer(target.paneID)
        let number = (composer.marks.map(\.number).max() ?? 0) + 1
        guard var mark = BrowserMark.from(body, number: number, tabID: self.id) else { return }
        pointJS("P.confirm(id, n)", ["id": id, "n": number])
        mark.imagePath = await snapshotMark(id: id, rect: body["rect"] as? [String: Any], number: number)
        composer.marks.append(mark)
        if composer.hidden { composer.hidden = false }
        showPointingNotice("[\(number)] added to \(store.paneTitle(pane))’s prompt")
    }

    /// A screenshot of what was pointed out (without the highlight), saved for the agent to look at.
    private func snapshotMark(id: String, rect: [String: Any]?, number: Int) async -> String? {
        guard let rect, let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let w = rect["w"] as? Double, let h = rect["h"] as? Double, w >= 4, h >= 4,
              webView.bounds.width > 0 else { return nil }
        let zoom = webView.pageZoom * webView.magnification
        let pad = 8.0
        let r = CGRect(x: (x - pad) * zoom, y: (y - pad) * zoom, width: (w + 2 * pad) * zoom, height: (h + 2 * pad) * zoom)
            .intersection(webView.bounds)
        guard !r.isNull, r.width >= 4, r.height >= 4 else { return nil }
        await pointEval("P.hideOverlay(true)")
        let cfg = WKSnapshotConfiguration()
        cfg.rect = r
        // Full CSS resolution, at most 1600 px wide.
        cfg.snapshotWidth = NSNumber(value: min(1600, Double(r.width / zoom)))
        let image = try? await webView.takeSnapshot(configuration: cfg)
        await pointEval("P.hideOverlay(false)")
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        BrowserPointing.pruneImages()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = BrowserPointing.imagesDir.appendingPathComponent("point-\(f.string(from: Date()))-\(number).png")
        do { try png.write(to: url); return url.path } catch { return nil }
    }

    private func showPointingNotice(_ text: String) {
        pointingNotice = text
        let shown = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.pointingNotice == shown { self?.pointingNotice = nil }
        }
    }
}
