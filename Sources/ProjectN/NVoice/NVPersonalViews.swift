import SwiftUI

// MARK: - Correction (learn from edits)

/// Edit what NVoice wrote; the differences become correction rules for the person who dictated it.
struct CorrectionView: View {
    let record: DictationRecord
    var onDone: () -> Void

    @State private var text: String
    @State private var learned: ProfileStore.Learned?
    @State private var copyFixed = true

    /// Enhanced dictations are corrected on the original transcript — the AI rewrite isn't the speech engine's mistake.
    private var source: String { record.enhanced ? (record.rawText ?? record.text) : record.text }

    init(record: DictationRecord, onDone: @escaping () -> Void) {
        self.record = record
        self.onDone = onDone
        _text = State(initialValue: record.enhanced ? (record.rawText ?? record.text) : record.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.enhanced ? "Fix the words in the original transcript" : "Fix the words NVoice got wrong")
                .font(.headline)
            Text("NVoice compares your version with what it wrote and remembers each fix for \(profileName). Next time it will write it correctly.")
                .font(.callout).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .frame(minHeight: 140)

            if let learned {
                VStack(alignment: .leading, spacing: 4) {
                    if learned.rules.isEmpty {
                        Label("No word changes found — nothing to learn.", systemImage: "info.circle").foregroundStyle(.secondary)
                    } else {
                        Label("Learned \(learned.rules.count) correction\(learned.rules.count == 1 ? "" : "s"):", systemImage: "brain.head.profile")
                            .foregroundStyle(.green)
                        ForEach(Array(learned.rules.enumerated()), id: \.offset) { _, r in
                            Text("“\(r.heard)” → “\(r.replacement)”").font(.callout.monospaced())
                        }
                    }
                }
            }

            HStack {
                Toggle("Copy corrected text to clipboard", isOn: $copyFixed).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(learned == nil ? "Save & learn" : "Done") {
                    if learned == nil { save() } else { onDone() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(learned == nil && text == source)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 340)
    }

    private var profileName: String {
        let ps = ProfileStore.shared
        return ps.profiles.first(where: { $0.id == (record.profileID ?? ps.defaultProfileID) })?.name ?? "you"
    }

    private func save() {
        let ps = ProfileStore.shared
        let owner = record.profileID ?? ps.defaultProfileID
        learned = ps.learn(original: source, corrected: text, profileID: owner)
        MetricsStore.shared.update(record.id) { r in
            if r.enhanced { r.rawText = text } else { r.text = text }
            r.corrected = true
        }
        if copyFixed && !record.enhanced {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

// MARK: - People (profiles, language, dictionary, corrections)

struct PeopleView: View {
    @ObservedObject var store = ProfileStore.shared
    @State private var locales: [Locale] = []
    @State private var newTerm = ""
    @State private var newHeard = ""
    @State private var newReplacement = ""
    @State private var confirmDelete = false
    @State private var newPersonName = ""
    @State private var addingPerson = false

    private var p: Profile { store.active }

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Person", selection: $store.activeID) {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                    Button { addingPerson = true } label: { Image(systemName: "plus") }.help("Add a person")
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .disabled(store.profiles.count < 2).help("Delete this person")
                }
                TextField("Name", text: Binding(get: { p.name }, set: { v in store.update { $0.name = v } }))
                Picker("Language", selection: Binding(get: { p.localeID }, set: { v in store.update { $0.localeID = v } })) {
                    if !locales.contains(where: { $0.identifier == p.localeID }) { Text(p.localeID).tag(p.localeID) }
                    ForEach(locales, id: \.identifier) { l in
                        Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                    }
                }
                Picker("Also detect", selection: Binding(get: { p.secondLocaleID ?? "" }, set: { v in store.update { $0.secondLocaleID = v.isEmpty ? nil : v } })) {
                    Text("None (one language)").tag("")
                    Divider()
                    ForEach(locales.filter { $0.identifier != p.localeID }, id: \.identifier) { l in
                        Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                    }
                }
                Text("With a second language, NVoice transcribes both at once and keeps whichever it’s more confident about — speak English or Spanish without switching. (Mixing both inside one sentence works best for English words you add to the dictionary.)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Each person has their own language, dictionary, corrections, history and metrics. Transcription uses Apple’s built-in on-device speech model; a language is downloaded once the first time you pick it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Person") }

            Section {
                HStack {
                    TextField("Add a word or phrase", text: $newTerm, prompt: Text("e.g. Acme, Kubernetes, Monterrey"))
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if p.dictionary.isEmpty {
                    Text("Names, brands, products and jargon this person says. NVoice tells the speech engine to expect them and writes them with the right capitalization.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowTags(tags: p.dictionary) { t in store.update { $0.dictionary.removeAll { $0 == t } } }
                }
            } header: { Text("Personal dictionary (\(p.dictionary.count))") }

            Section {
                HStack {
                    TextField("When I hear", text: $newHeard, prompt: Text("for v marketing"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Write", text: $newReplacement, prompt: Text("Acme"))
                    Button("Add") {
                        store.addRule(heard: newHeard, replacement: newReplacement, learned: false)
                        newHeard = ""; newReplacement = ""
                    }
                    .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if p.rules.isEmpty {
                    Text("Corrections are learned automatically when you fix a dictation (Fix in History, or menu bar › Correct last dictation). You can also add them here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(p.rules.sorted { $0.createdAt > $1.createdAt }) { r in
                    HStack {
                        Text(r.heard).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(r.replacement).fontWeight(.medium)
                        Spacer()
                        if r.learned { Text("learned").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.purple.opacity(0.15))) }
                        Text("used \(r.uses)×").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button { store.update { $0.rules.removeAll { $0.id == r.id } } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                    }
                }
            } header: { Text("Corrections (\(p.rules.count))") }
        }
        .formStyle(.grouped)
        .task { locales = await Transcriber.supportedLocales() }
        .alert("Add a person", isPresented: $addingPerson) {
            TextField("Name", text: $newPersonName)
            Button("Add") {
                let name = newPersonName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.activeID = store.addProfile(name: name).id }
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) { newPersonName = "" }
        }
        .confirmationDialog("Delete \(p.name)? Their dictionary, corrections and history are removed.", isPresented: $confirmDelete) {
            Button("Delete \(p.name)", role: .destructive) {
                let id = p.id
                MetricsStore.shared.removeRecords(of: id)
                store.deleteProfile(id)
            }
        }
    }

    private func addTerm() {
        store.addTerm(newTerm)
        newTerm = ""
    }
}

/// Wrapping row of removable tags.
struct FlowTags: View {
    let tags: [String]
    var onRemove: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 4) {
                    Text(t)
                    Button { onRemove(t) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 400, subviews: subviews)
        return CGSize(width: proposal.width ?? 400, height: rows.last.map { $0.y + $0.h } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in rows.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.x, y: bounds.minY + f.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> [(x: CGFloat, y: CGFloat, h: CGFloat)] {
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            out.append((x, y, size.height))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return out
    }
}
