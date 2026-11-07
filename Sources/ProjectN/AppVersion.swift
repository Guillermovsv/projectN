import AppKit
import SwiftUI

/// Version stamped into Info.plist by build.sh: VERSION file, build number (commit count), git commit, build time.
enum AppVersion {
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var commit: String? { Bundle.main.object(forInfoDictionaryKey: "ProjectNGitCommit") as? String }
    static var buildDate: Date? {
        (Bundle.main.object(forInfoDictionaryKey: "ProjectNBuildDate") as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// "v0.2.0 (4) · bdec893 · Nov 6, 15:40", or "dev build" when not run from a built app.
    static var label: String {
        guard let version else { return "dev build" }
        var parts = ["v\(version)" + (build.map { " (\($0))" } ?? "")]
        if let commit { parts.append(commit) }
        if let d = buildDate { parts.append(d.formatted(.dateTime.month(.abbreviated).day().hour().minute())) }
        return parts.joined(separator: " · ")
    }

    static var detail: String {
        guard version != nil else { return "Running outside a built app (swift run / tests)." }
        return "ProjectN \(label)\nBuilt \(buildDate?.formatted(date: .long, time: .standard) ?? "?")\nClick to copy."
    }
}

/// Small version line under Settings / Appearance in the sidebar. Click copies it.
struct VersionTag: View {
    @State private var copied = false

    var body: some View {
        Text(copied ? "Copied" : AppVersion.label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ProjectN \(AppVersion.label)", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .help(AppVersion.detail)
    }
}
