import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Payload used when dragging a pane header onto another pane's chat box (to tag that agent).
enum PaneDrag {
    static let prefix = "projectn-pane:"
    static func encode(_ r: Store.PaneRef) -> String { "\(prefix)\(r.workspaceID.uuidString):\(r.paneID.uuidString)" }
    static func decode(_ s: String) -> Store.PaneRef? {
        guard s.hasPrefix(prefix) else { return nil }
        let parts = s.dropFirst(prefix.count).split(separator: ":")
        guard parts.count == 2, let w = UUID(uuidString: String(parts[0])), let p = UUID(uuidString: String(parts[1])) else { return nil }
        return Store.PaneRef(workspaceID: w, paneID: p)
    }
}

/// Handles files, images and dragged pane headers dropped on a pane.
enum PaneDrop {
    static let types: [UTType] = [.fileURL, .utf8PlainText, .plainText]

    @MainActor
    static func handle(_ providers: [NSItemProvider], pane: Pane, workspaceID: UUID, store: Store) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { attachFile(url, pane: pane, workspaceID: workspaceID, store: store) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    DispatchQueue.main.async {
                        if let ref = PaneDrag.decode(s) {
                            guard ref.paneID != pane.id, pane.tool != .terminal else { return }
                            store.composer(pane.id).addRecipient(ref)
                        } else if pane.tool != .terminal {
                            store.composer(pane.id).text += s
                        } else {
                            store.runtimes[pane.id]?.send(s)
                        }
                    }
                }
            }
        }
        if handled { store.focusPane(pane.id, in: workspaceID) }
        return handled
    }

    @MainActor
    private static func attachFile(_ url: URL, pane: Pane, workspaceID: UUID, store: Store) {
        if pane.tool == .terminal {
            // Shells just get the quoted path, like dropping onto Terminal.app.
            store.runtimes[pane.id]?.send(Shell.quote(url.path) + " ")
        } else {
            store.composer(pane.id).attach([url])
        }
    }
}

/// Chat-style input at the bottom of a Claude/Codex pane.
struct ComposerView: View, Equatable {
    @EnvironmentObject var store: Store
    let state: Store.ComposerState
    let pane: Pane
    let workspaceID: UUID
    let runtime: TerminalSession?

    @State private var focused = false
    @State private var focusTrigger = 0
    @State private var showMentions = false
    @State private var mentionQuery = ""
    @State private var attachments: [URL]
    @State private var recipients: [Store.PaneRef]
    @State private var hasText: Bool
    @State private var compact = false

    init(state: Store.ComposerState, pane: Pane, workspaceID: UUID, runtime: TerminalSession?) {
        self.state = state
        self.pane = pane
        self.workspaceID = workspaceID
        self.runtime = runtime
        _attachments = State(initialValue: state.attachments)
        _recipients = State(initialValue: state.recipients)
        _hasText = State(initialValue: !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.pane == rhs.pane && lhs.workspaceID == rhs.workspaceID
            && lhs.runtime === rhs.runtime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty || !recipients.isEmpty { chips }
            // Fixed four-line height (longer text scrolls inside): the terminal above never resizes while you type,
            // so Claude/Codex don't redraw their whole screen on every new line. ⏎ sends, ⇧⏎ / ⌥⏎ new line.
            ComposerEditor(state: state, placeholder: placeholder, focusTrigger: focusTrigger,
                        onSubmit: send, onAt: { showMentions = true },
                        onFocus: { focused = true; store.focusPane(pane.id, in: workspaceID) },
                        onBlur: { focused = false })
                .frame(height: PromptInput.height(lines: 4))
                .popover(isPresented: $showMentions, arrowEdge: .top) { mentionPicker }
            // Full controls when there's room; icon-only model/effort/permission menus when the pane is narrow.
            // Decided from the measured width, not ViewThatFits: that built and measured both sets of native
            // menus in every pane on each layout pass, which made opening a space or the Agents view take seconds.
            controls(compact: compact)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < LaunchOptionMenus.fullControlsWidth(pane: pane, settings: store.settings)
        } action: { compact = $0 }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.appElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.appAccent.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onTapGesture { focusTrigger += 1; store.focusPane(pane.id, in: workspaceID) }
        // Keystrokes update only the editor. The controls need an update when Send
        // becomes enabled/disabled, or attachments/recipients change, not per letter.
        .onReceive(state.$text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.removeDuplicates()) { hasText = $0 }
        .onReceive(state.$attachments.removeDuplicates()) { attachments = $0 }
        .onReceive(state.$recipients.removeDuplicates()) { recipients = $0 }
    }

    private var placeholder: String {
        recipients.isEmpty
            ? "Message \(pane.tool.label)… (@ to tag)"
            : "Message to \(recipients.count == 1 ? "1 agent" : "\(recipients.count) agents")…"
    }

    private var canSend: Bool { hasText || !attachments.isEmpty }

    private func send() {
        guard !state.isEmpty else { return }
        store.sendComposer(paneID: pane.id, in: workspaceID)
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recipients, id: \.self) { r in
                    if let (_, s, p) = store.paneLocation(r) {
                        Chip(icon: AnyView(Image(systemName: p.tool.symbol).foregroundStyle(toolColor(p.tool))),
                             text: "→ \(store.paneTitle(p)) · \(s.name)",
                             tint: Color.appAccent) { state.recipients.removeAll { $0 == r } }
                    }
                }
                ForEach(attachments, id: \.self) { url in
                    Chip(icon: AnyView(Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)),
                         text: url.lastPathComponent,
                         tint: .secondary) { state.attachments.removeAll { $0 == url } }
                        .help(url.path)
                }
            }
        }
    }

    // MARK: Bottom controls

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button("Attach Files or Images…") { pickFiles() }
                Button("Attach This Pane's Recent Output") {
                    if let u = store.writeHandoff(from: pane.id, in: workspaceID) { state.attach([u]) }
                }
                .disabled(runtime == nil)
            } label: {
                Image(systemName: "paperclip")
            }
            .menuStyle(.borderlessButton)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach files, images, or this pane's output (or drop them on the pane)")

            Button { showMentions = true } label: { Image(systemName: "at") }
                .buttonStyle(.hover)
                .help("Send to another agent (or drag a pane's title here)")

            Divider().frame(height: 14).padding(.horizontal, 2)

            LaunchOptionMenus(pane: pane, workspaceID: workspaceID, compact: compact)

            Spacer(minLength: 4)

            if pane.tool != .terminal {
                Toggle(isOn: Binding(get: { pane.isAutoComplete },
                                     set: { store.setAutoComplete($0, pane: pane.id, in: workspaceID) })) {
                    Image(systemName: "bolt.fill")
                }
                .toggleStyle(.button)
                .buttonStyle(.hover)
                .foregroundStyle(pane.isAutoComplete ? Color.yellow : Color.secondary)
                .help(pane.isAutoComplete ? "Auto · Complete is on" : "Auto · Complete: answer yes/no prompts automatically")
            }

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canSend ? (state.recipients.isEmpty ? toolColor(pane.tool) : Color.appAccent) : Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 14, inset: 2)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(state.recipients.isEmpty ? "Send to \(pane.tool.label) (⏎ · ⇧⏎ for a new line)" : "Send to tagged agents (⏎ · ⇧⏎ for a new line)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        if let p = store.project(pane.projectID) { panel.directoryURL = URL(fileURLWithPath: p.path) }
        guard panel.runModal() == .OK else { return }
        state.attach(panel.urls)
    }

    // MARK: Mentions

    private var mentionPicker: some View {
        let all = store.mentionCandidates(excluding: pane.id)
        let q = mentionQuery.lowercased()
        let filtered = q.isEmpty ? all : all.filter { (w, s, p) in
            "\(store.paneTitle(p)) \(s.name) \(w.name) \(p.tool.label)".lowercased().contains(q)
        }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Search agents…", text: $mentionQuery)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text("No other panes").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.2.id) { (w, s, p) in
                        Button {
                            state.addRecipient(Store.PaneRef(workspaceID: w.id, paneID: p.id))
                            showMentions = false
                            mentionQuery = ""
                            focusTrigger += 1
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: p.tool.symbol).foregroundStyle(toolColor(p.tool)).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(store.paneTitle(p)).font(.callout)
                                    Text("\(w.name) › \(s.name)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.runtimes[p.id]?.needsInput == true {
                                    Circle().fill(Color.yellow).frame(width: 7, height: 7)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(inset: 0)
                    }
                }
            }
            .frame(maxHeight: 240)
            Text("The message is typed into that pane, prefixed with who it's from.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// The only subtree that observes the full draft, including every typed character.
private struct ComposerEditor: View {
    @ObservedObject var state: Store.ComposerState
    let placeholder: String
    let focusTrigger: Int
    let onSubmit: () -> Void
    let onAt: () -> Void
    let onFocus: () -> Void
    let onBlur: () -> Void

    var body: some View {
        PromptInput(text: $state.text, placeholder: placeholder, lines: 4, focusTrigger: focusTrigger,
                    onSubmit: onSubmit, onAt: onAt, onFocus: onFocus, onBlur: onBlur)
    }
}

private struct Chip: View {
    let icon: AnyView
    let text: String
    let tint: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(text).font(.caption).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.hover)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
    }
}

/// Model / Effort / Permissions as three small menus in the chat box. Always explicit values (no "Default").
/// Claude applies model/effort live (/model, /effort); permissions and Codex changes restart + resume the pane.
struct LaunchOptionMenus: View {
    @EnvironmentObject var store: Store
    let pane: Pane
    let workspaceID: UUID
    var compact = false

    /// Always concrete values (unset fields resolved from the CLI's own config).
    private var o: LaunchOptions { LaunchCatalog.explicit(pane.launchOptions, tool: pane.tool, settings: store.settings) }

    /// Width the chat box's bottom row needs with labelled menus (otherwise they're shown icon-only).
    /// Measured from the label text, so no menu has to be built to find out.
    static func fullControlsWidth(pane: Pane, settings: AppSettings) -> CGFloat {
        let o = LaunchCatalog.explicit(pane.launchOptions, tool: pane.tool, settings: settings)
        let s = LaunchCatalog.summary(o, tool: pane.tool, settings: settings)
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let labels = pane.tool == .cursor ? [s.model, s.permission] : [s.model, s.effort, s.permission]
        // Each menu: icon + gap + text + its horizontal padding/hover inset.
        let menus = labels.reduce(CGFloat(0)) { $0 + 16 + 6 + ($1 as NSString).size(withAttributes: [.font: font]).width + 16 }
        // Paperclip, @, divider, Auto toggle, send button, spacing and the chat box's own padding.
        return menus + 190
    }

    var body: some View {
        let s = LaunchCatalog.summary(o, tool: pane.tool, settings: store.settings)
        HStack(spacing: 2) {
            menu(icon: "cpu", value: s.model, help: "Model") {
                ForEach(models.filter { !$0.older }, id: \.value) { c in
                    item(c.label + (c.detail.map { " — \($0)" } ?? ""), o.model == c.value) { chooseModel(c.value) }
                }
                if models.contains(where: \.older) {
                    Divider()
                    Menu("Previous versions") {
                        ForEach(models.filter(\.older), id: \.value) { c in
                            item(c.label, o.model == c.value) { chooseModel(c.value) }
                        }
                    }
                }
            }
            if pane.tool != .cursor {
                menu(icon: "gauge.with.dots.needle.50percent", value: s.effort, help: "Effort") {
                    ForEach(efforts, id: \.self) { e in item(e, o.effort == e) { set { $0.effort = e } } }
                }
            }
            menu(icon: dangerous ? "exclamationmark.shield" : "lock.shield", value: s.permission, help: "Permissions", tint: dangerous ? .red : nil) {
                ForEach(permissions) { c in
                    item("\(c.dangerous ? "⚠︎ " : "")\(c.label) — \(c.detail ?? "")", o.permission == c.value) { set { $0.permission = c.value } }
                }
                Divider()
                Button("Use Current Settings as Default for New Panes") { store.setDefaults(o, for: pane.tool) }
            }
        }
    }

    private var models: [LaunchCatalog.Choice] {
        var list: [LaunchCatalog.Choice]
        switch pane.tool {
        case .claude: list = LaunchCatalog.claudeModels
        case .cursor: list = LaunchCatalog.cursorModels(settings: store.settings)
        default: list = LaunchCatalog.codexModels(settings: store.settings).map { LaunchCatalog.Choice(value: $0.slug, label: $0.slug) }
        }
        if let m = o.model, !list.contains(where: { $0.value == m }) { list.insert(LaunchCatalog.Choice(value: m, label: m), at: 0) }
        return list
    }

    private var efforts: [String] {
        var list: [String]
        if pane.tool == .claude {
            list = LaunchCatalog.claudeEfforts
        } else {
            let e = LaunchCatalog.codexModels(settings: store.settings).first { $0.slug == o.model }?.efforts ?? []
            list = e.isEmpty ? ["low", "medium", "high", "xhigh"] : e
        }
        if let e = o.effort, !list.contains(e) { list.insert(e, at: 0) }
        return list
    }

    private var permissions: [LaunchCatalog.Choice] {
        LaunchCatalog.permissions(for: pane.tool)
    }

    private var dangerous: Bool { permissions.first { $0.value == o.permission }?.dangerous ?? false }

    private func chooseModel(_ value: String) {
        set { x in
            x.model = value
            // Keep the effort valid for the newly chosen Codex model.
            if pane.tool == .codex,
               let m = LaunchCatalog.codexModels(settings: store.settings).first(where: { $0.slug == value }),
               !m.efforts.isEmpty, let e = x.effort, !m.efforts.contains(e) {
                x.effort = m.efforts.contains("medium") ? "medium" : m.efforts.first
            }
        }
    }

    private func set(_ change: (inout LaunchOptions) -> Void) {
        var x = o
        change(&x)
        store.setLaunchOptions(x, pane: pane.id, in: workspaceID)
    }

    private func item(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func menu<C: View>(icon: String, value: String, help: String, tint: Color? = nil, @ViewBuilder content: () -> C) -> some View {
        Menu { content() } label: {
            if compact {
                Label(value, systemImage: icon).labelStyle(.iconOnly)
            } else {
                Label(value, systemImage: icon)
            }
        }
        .menuStyle(.borderlessButton)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 4)
        .help(pane.tool == .claude && help != "Permissions"
              ? "\(help): \(value) — applied live in the running session"
              : "\(help): \(value) — changing it restarts the pane and resumes the conversation")
    }
}
