import Foundation
import AVFoundation

extension Notification.Name {
    static let nvoiceShowGeneral = Notification.Name("nvoiceShowGeneral")
}

/// Small rolling log at ~/Library/Application Support/NVoice/nvoice.log, shown in Settings › General.
enum Diagnostics {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nvoice.log")
    }()
    private static let queue = DispatchQueue(label: "nvoice.log")

    static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
        NSLog("NVoice: %@", msg)
        queue.async {
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += line
            if text.count > 40_000 { text = String(text.suffix(30_000)) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func tail(_ lines: Int = 15) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    static func summary(tapRunning: Bool) -> String {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "granted"
        case .denied: mic = "DENIED"
        case .restricted: mic = "restricted"
        default: mic = "not asked yet"
        }
        return """
        Input Monitoring: \(HotkeyMonitor.hasInputMonitoring() ? "granted" : "MISSING")
        Accessibility: \(HotkeyMonitor.hasAccessibility(prompt: false) ? "granted" : "MISSING")
        Microphone: \(mic)
        Shortcut: \(NVoiceSettings.shared.hotkey.displayName)
        Key listener: \(tapRunning ? "running" : "NOT running")
        App: \(Bundle.main.bundlePath)
        """
    }
}
