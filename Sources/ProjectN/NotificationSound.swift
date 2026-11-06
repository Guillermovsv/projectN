import AppKit

/// The chime played when a chat stops for input or finishes (the yellow highlight).
@MainActor
enum NotificationSound {
    /// macOS system sounds, from /System/Library/Sounds.
    static let available: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        return names.isEmpty ? ["Glass"] : names
    }()

    private static var lastPlayed = Date.distantPast

    static func play(_ settings: AppSettings) {
        guard settings.notificationSound else { return }
        // Several panes changing in the same moment ring once.
        let now = Date()
        guard now.timeIntervalSince(lastPlayed) > 1.5 else { return }
        lastPlayed = now
        preview(settings.notificationSoundName)
    }

    static func preview(_ name: String) {
        (NSSound(named: NSSound.Name(name)) ?? NSSound(named: "Glass"))?.play()
    }
}
