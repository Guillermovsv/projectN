import AppKit
import SwiftUI

/// The GitHub repo this build came from (stamped into Info.plist by build.sh as ProjectNRepoURL).
struct UpdateSource: Equatable {
    let owner: String
    let name: String

    static let fallback = UpdateSource(owner: "Guillermovsv", name: "projectN")

    /// Accepts https://github.com/o/r(.git) and git@github.com:o/r(.git). Any credentials in the URL are dropped.
    init?(url: String) {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("git@github.com:") {
            s = String(s.dropFirst("git@github.com:".count))
        } else if let r = s.range(of: "github.com/") {
            s = String(s[r.upperBound...])
        } else {
            return nil
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = parts[0]
        name = parts[1]
    }

    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    var slug: String { "\(owner)/\(name)" }
    var cloneURL: String { "https://github.com/\(owner)/\(name).git" }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
}

/// In-app updates, built from source: checks GitHub for commits on main newer than this build, and on
/// request clones/pulls the repo into ~/.projectn/updates/source, runs build.sh there and stages the
/// new app. Installing (quit → replace the app → reopen) only happens after the user confirms.
///
/// Building locally means no Apple signing or notarization is needed: a locally built app carries no
/// quarantine flag, and build.sh signs it with "ProjectN Local Signing" when that identity exists,
/// so macOS keeps its permissions across updates.
@MainActor
final class UpdateModel: ObservableObject {
    struct Commit: Identifiable, Hashable {
        let sha: String
        let title: String
        /// The rest of the commit message (trailers like Co-Authored-By removed); may be empty.
        var body: String = ""
        let author: String
        let date: Date?
        let url: URL?
        var id: String { sha }
        var short: String { String(sha.prefix(7)) }
    }

    enum Phase: Equatable {
        case idle
        case building(String)
        /// A new app is staged, built from this commit (full sha).
        case ready(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Commits on main this build doesn't have, newest first.
    @Published private(set) var pending: [Commit] = []
    /// This build's commit isn't on GitHub (local, unpushed build): `pending` is just main's latest commits.
    @Published private(set) var baseUnknown = false
    @Published private(set) var remoteHead: String?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkError: String?
    @Published private(set) var log = ""
    @Published private(set) var toolsMissing = false
    @Published var autoPrepare = UserDefaults.standard.bool(forKey: "updatesAutoPrepare") {
        didSet {
            UserDefaults.standard.set(autoPrepare, forKey: "updatesAutoPrepare")
            if autoPrepare { maybeAutoPrepare() }
        }
    }

    let repo: UpdateSource
    /// This build's commit (short sha, without "+dirty"); nil when not running from a built app.
    let localCommit: String?
    private var timer: Timer?

    static let checkInterval: TimeInterval = 12 * 60 * 60
    static var dir: URL { AppHome.root.appendingPathComponent("updates") }
    static var sourceDir: URL { dir.appendingPathComponent("source") }
    static var stagedApp: URL { dir.appendingPathComponent("ProjectN.app") }
    static var logFile: URL { dir.appendingPathComponent("build.log") }

    init() {
        let stamped = Bundle.main.object(forInfoDictionaryKey: "ProjectNRepoURL") as? String
        repo = stamped.flatMap(UpdateSource.init(url:)) ?? .fallback
        localCommit = AppVersion.commit.map { $0.replacingOccurrences(of: "+dirty", with: "") }.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        restoreStaged()
    }

    var available: Bool { !pending.isEmpty }
    var isBuilding: Bool { if case .building = phase { return true } else { return false } }
    /// Why updates are off (tests / `swift run`), else nil.
    var disabledReason: String? {
        localCommit == nil ? "Build de desarrollo: las actualizaciones solo funcionan en la app compilada con build.sh." : nil
    }
    /// Something for the user to act on: new commits, or a staged update.
    var needsAttention: Bool {
        if case .ready = phase { return true }
        return available
    }

    func start() {
        guard timer == nil, disabledReason == nil, !AppHome.isTestProcess else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkNow() }
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Check

    func checkNow() {
        guard let local = localCommit, !checking else { return }
        checking = true
        let repo = repo
        Task {
            let result = await Self.fetchPending(repo: repo, local: local)
            checking = false
            lastChecked = Date()
            switch result {
            case .success(let r):
                pending = r.commits
                baseUnknown = r.baseUnknown
                remoteHead = r.head
                checkError = nil
            case .failure(let e):
                checkError = e.message
            }
            maybeAutoPrepare()
        }
    }

    struct CheckResult {
        var commits: [Commit]
        var head: String?
        var baseUnknown: Bool
    }

    struct UpdateError: Error { let message: String }

    nonisolated private static func fetchPending(repo: UpdateSource, local: String) async -> Result<CheckResult, UpdateError> {
        let api = "https://api.github.com/repos/\(repo.owner)/\(repo.name)"
        switch await getJSON("\(api)/compare/\(local)...main") {
        case .success(let obj):
            guard let d = obj as? [String: Any] else { return .failure(UpdateError(message: "Respuesta inesperada de GitHub")) }
            return .success(parseCompare(d))
        case .failure(let e) where e.message == "HTTP 404":
            // This build's commit isn't on GitHub: show main's latest commits instead.
            switch await getJSON("\(api)/commits?sha=main&per_page=10") {
            case .success(let obj):
                let commits = (obj as? [[String: Any]] ?? []).compactMap(parseCommit)
                return .success(CheckResult(commits: commits, head: commits.first?.sha, baseUnknown: true))
            case .failure(let e):
                return .failure(e)
            }
        case .failure(let e):
            return .failure(e)
        }
    }

    /// GitHub's compare (base = this build, head = main). Only "ahead"/"diverged" mean main has commits we lack.
    nonisolated static func parseCompare(_ d: [String: Any]) -> CheckResult {
        let status = d["status"] as? String ?? ""
        let commits = (d["commits"] as? [[String: Any]] ?? []).compactMap(parseCommit)
        let head = commits.last?.sha ?? ((d["base_commit"] as? [String: Any])?["sha"] as? String)
        guard status == "ahead" || status == "diverged" else { return CheckResult(commits: [], head: head, baseUnknown: false) }
        return CheckResult(commits: commits.reversed(), head: head, baseUnknown: false)
    }

    nonisolated static func parseCommit(_ c: [String: Any]) -> Commit? {
        guard let sha = c["sha"] as? String else { return nil }
        let inner = c["commit"] as? [String: Any]
        let message = inner?["message"] as? String ?? ""
        let author = inner?["author"] as? [String: Any]
        let date = (author?["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let (title, body) = splitMessage(message)
        return Commit(sha: sha,
                      title: title,
                      body: body,
                      author: author?["name"] as? String ?? "",
                      date: date,
                      url: (c["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// First line → title; the rest → body, without git trailers (Co-Authored-By:, Signed-off-by:, …).
    nonisolated static func splitMessage(_ message: String) -> (title: String, body: String) {
        let lines = message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return ("", "") }
        let trailers = ["co-authored-by:", "signed-off-by:", "reviewed-by:", "change-id:"]
        let rest = lines[(first + 1)...].filter { line in
            let l = line.lowercased()
            return !trailers.contains { l.hasPrefix($0) }
        }
        let body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (lines[first].trimmingCharacters(in: .whitespaces), body)
    }

    /// One sentence describing what the pending update brings.
    nonisolated static func summary(of commits: [Commit]) -> String {
        let titles = commits.map(\.title).filter { !$0.isEmpty }
        func clean(_ t: String) -> String { t.hasSuffix(".") ? String(t.dropLast()) : t }
        switch titles.count {
        case 0: return ""
        case 1: return clean(titles[0]) + "."
        case 2: return "\(clean(titles[0])); y \(clean(titles[1]))."
        default: return "\(clean(titles[0])); \(clean(titles[1])); y \(titles.count - 2) \(titles.count - 2 == 1 ? "cambio más" : "cambios más")."
        }
    }

    nonisolated private static func getJSON(_ url: String) async -> Result<Any, UpdateError> {
        guard let u = URL(string: url) else { return .failure(UpdateError(message: "URL inválida")) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ProjectN", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return .failure(UpdateError(message: code == 403 || code == 429 ? "GitHub limitó las consultas; se reintenta más tarde" : "HTTP \(code)"))
            }
            return .success(try JSONSerialization.jsonObject(with: data))
        } catch {
            return .failure(UpdateError(message: error.localizedDescription))
        }
    }

    // MARK: Build

    private func maybeAutoPrepare() {
        guard autoPrepare, available, let head = remoteHead else { return }
        switch phase {
        case .idle: prepare()
        case .ready(let built) where built != head: prepare()
        default: break
        }
    }

    /// Fetch main into the private clone, build it and stage the new app. Runs in the background.
    func prepare() {
        guard !isBuilding, disabledReason == nil else { return }
        phase = .building("Comprobando herramientas…")
        toolsMissing = false
        log = ""
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        fm.createFile(atPath: Self.logFile.path, contents: nil)

        let script = #"""
        set -euo pipefail
        echo "==> Comprobando herramientas…"
        if ! xcrun --find swift >/dev/null 2>&1; then
          echo "PN_TOOLS_MISSING"
          exit 70
        fi
        if [ ! -d "$PN_SRC/.git" ]; then
          echo "==> Descargando el repositorio…"
          rm -rf "$PN_SRC"
          git clone "$PN_URL" "$PN_SRC"
        fi
        cd "$PN_SRC"
        echo "==> Descargando cambios…"
        git remote set-url origin "$PN_URL"
        git fetch --prune origin main
        git reset --hard origin/main
        git clean -fdq -x -e .build -e build
        echo "==> Compilando (puede tardar unos minutos)…"
        ./build.sh
        echo "==> Preparando la nueva versión…"
        rm -rf "$PN_OUT"
        ditto build/ProjectN.app "$PN_OUT"
        echo "PN_BUILT $(git rev-parse HEAD)"
        """#
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["PN_SRC"] = Self.sourceDir.path
        env["PN_URL"] = repo.cloneURL
        env["PN_OUT"] = Self.stagedApp.path

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let logHandle = try? FileHandle(forWritingTo: Self.logFile)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            try? logHandle?.write(contentsOf: data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            try? logHandle?.write(contentsOf: rest)
            try? logHandle?.close()
            let text = String(decoding: rest, as: UTF8.self)
            let status = proc.terminationStatus
            Task { @MainActor in
                if !text.isEmpty { self?.consume(text) }
                self?.finish(status: status)
            }
        }
        do {
            try p.run()
        } catch {
            phase = .failed("No se pudo iniciar la compilación: \(error.localizedDescription)")
        }
    }

    private var builtSHA: String?

    private func consume(_ text: String) {
        log += text
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("==> ") { phase = .building(String(line.dropFirst(4))) }
            if line == "PN_TOOLS_MISSING" { toolsMissing = true }
            if line.hasPrefix("PN_BUILT ") { builtSHA = String(line.dropFirst("PN_BUILT ".count)).trimmingCharacters(in: .whitespaces) }
        }
    }

    private func finish(status: Int32) {
        if status == 0, let sha = builtSHA, FileManager.default.fileExists(atPath: Self.stagedApp.path) {
            UserDefaults.standard.set(sha, forKey: "updatesStagedSHA")
            phase = .ready(sha)
        } else if toolsMissing {
            phase = .failed("Faltan las herramientas de compilación de Xcode (Command Line Tools).")
        } else {
            let last = log.split(separator: "\n").last(where: { $0.contains("error") }).map(String.init)
            phase = .failed(last.map { "La compilación falló: \($0.prefix(160))" } ?? "La compilación falló (código \(status)). Revisa el log.")
        }
        builtSHA = nil
    }

    /// A staged app from an earlier session: offer it again, unless it's the version now running.
    private func restoreStaged() {
        let fm = FileManager.default
        guard let sha = UserDefaults.standard.string(forKey: "updatesStagedSHA"), fm.fileExists(atPath: Self.stagedApp.path) else { return }
        if let local = localCommit, sha.hasPrefix(local) {
            try? fm.removeItem(at: Self.stagedApp)
            UserDefaults.standard.removeObject(forKey: "updatesStagedSHA")
        } else {
            phase = .ready(sha)
        }
    }

    func installTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }

    func openLog() { NSWorkspace.shared.open(Self.logFile) }

    // MARK: Install

    /// Quit (everything is saved and restored on launch), replace the app with the staged one, reopen it.
    func installAndRelaunch() {
        guard case .ready = phase, FileManager.default.fileExists(atPath: Self.stagedApp.path) else { return }
        let current = Bundle.main.bundleURL
        let dest = current.pathExtension == "app" ? current : URL(fileURLWithPath: "/Applications/ProjectN.app")
        let script = Self.dir.appendingPathComponent("install.sh")
        let body = """
        #!/bin/bash
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW=\(Self.shellQuote(Self.stagedApp.path))
        DEST=\(Self.shellQuote(dest.path))
        for _ in $(seq 1 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        if rm -rf "$DEST" && ditto "$NEW" "$DEST"; then
          rm -rf "$NEW"
          open "$DEST"
        else
          open "$NEW"
        fi
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Detached so it outlives ProjectN.
            p.arguments = ["-c", "nohup /bin/bash \(Self.shellQuote(script.path)) >/dev/null 2>&1 &"]
            try p.run()
            p.waitUntilExit()
        } catch {
            phase = .failed("No se pudo instalar: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.removeObject(forKey: "updatesStagedSHA")
        NSApp.terminate(nil)
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Views

/// Top-right button in every top bar: shows when there are new commits on main, a build in progress,
/// or an update ready to install. Opens the Updates panel.
struct UpdatesButton: View {
    @EnvironmentObject var updates: UpdateModel
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            label
                .padding(.horizontal, 7)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 7, inset: 0)
        .help(help)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            UpdatesPanel().environmentObject(updates)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch updates.phase {
        case .building:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Actualizando").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Reiniciar", systemImage: "arrow.clockwise.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        default:
            Image(systemName: updates.available ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(updates.available ? Color.appAccent : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    if updates.available {
                        Text("\(min(updates.pending.count, 99))")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 7, y: -6)
                    }
                }
        }
    }

    private var help: String {
        switch updates.phase {
        case .building(let step): return "Actualizando ProjectN: \(step)"
        case .ready: return "Actualización lista. Click para reiniciar e instalar."
        case .failed(let m): return "Actualización: \(m)"
        case .idle:
            return updates.available
                ? "\(updates.pending.count) \(updates.pending.count == 1 ? "cambio nuevo" : "cambios nuevos") en ProjectN. Click para ver."
                : "Actualizaciones de ProjectN"
        }
    }
}

struct UpdatesPanel: View {
    @EnvironmentObject var updates: UpdateModel
    @State private var confirmRestart = false
    @State private var showLog = false
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actualizaciones").font(.headline)
                Spacer()
                Button { updates.checkNow() } label: {
                    if updates.checking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.hover)
                .disabled(updates.disabledReason != nil)
                .help("Buscar ahora")
            }
            Text("Instalada: \(AppVersion.label)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let reason = updates.disabledReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            } else {
                content
                Divider()
                Toggle("Compilar automáticamente cuando haya cambios", isOn: $updates.autoPrepare)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Text("Antes de reiniciar siempre se te pide confirmación.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .confirmationDialog("¿Reiniciar ProjectN para instalar la actualización?", isPresented: $confirmRestart) {
            Button("Reiniciar e instalar") { updates.installAndRelaunch() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("ProjectN se cerrará y abrirá la nueva versión. Tus espacios, terminales y conversaciones se restauran al abrir.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .ready(let sha):
            Label("Actualización lista (\(sha.prefix(7)))", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
            if let head = updates.remoteHead, head != sha, updates.available {
                HStack {
                    Text("Ya hay cambios más nuevos en main.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Compilar de nuevo") { updates.prepare() }.controlSize(.small)
                }
            }
            commitList
            Button { confirmRestart = true } label: {
                Label("Reiniciar e instalar…", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .building(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout)
            }
            Text("Se compila en segundo plano; puedes seguir trabajando.")
                .font(.caption).foregroundStyle(.secondary)
            logView

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reintentar") { updates.prepare() }
                if updates.toolsMissing { Button("Instalar herramientas…") { updates.installTools() } }
                Spacer()
                Button("Abrir log") { updates.openLog() }.buttonStyle(.link)
            }
            .controlSize(.small)
            logView

        case .idle:
            if updates.available {
                Text(updates.baseUnknown
                     ? "Tu versión (\(updates.localCommit ?? "?")) no está en GitHub. Últimos cambios de main:"
                     : "\(updates.pending.count) \(updates.pending.count == 1 ? "cambio nuevo" : "cambios nuevos") en main")
                    .font(.callout.weight(.semibold))
                commitList
                Button { updates.prepare() } label: {
                    Label("Descargar y compilar", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Se compila en segundo plano. Cuando esté lista te pedimos confirmar el reinicio.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let e = updates.checkError {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if updates.lastChecked != nil {
                Label("Estás al día", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Buscando actualizaciones…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A one-sentence summary of the update; "Ver más" expands every change with its full description.
    @ViewBuilder
    private var commitList: some View {
        if !updates.pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(UpdateModel.summary(of: updates.pending))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if showDetails {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(updates.pending) { c in commitRow(c) }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Label(showDetails ? "Ver menos" : "Ver más (\(updates.pending.count) \(updates.pending.count == 1 ? "cambio" : "cambios"))",
                          systemImage: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func commitRow(_ c: UpdateModel.Commit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.title).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !c.body.isEmpty {
                Text(c.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Text(c.short).monospaced()
                if !c.author.isEmpty { Text("· \(c.author)") }
                if let d = c.date { Text("· \(d.formatted(.relative(presentation: .named)))") }
                if let u = c.url {
                    Button("Ver en GitHub") { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logView: some View {
        DisclosureGroup("Log", isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(String(updates.log.suffix(6000)))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 150)
                .onChange(of: updates.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(updates.repo.slug) { NSWorkspace.shared.open(updates.repo.webURL) }
                .buttonStyle(.link)
            Text("· cada 12 h")
            if let d = updates.lastChecked { Text("· revisado \(d.formatted(.relative(presentation: .named)))") }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
