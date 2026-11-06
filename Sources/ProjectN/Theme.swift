import AppKit
import SwiftTerm
import SwiftUI

/// App + terminal color themes. Selected in Settings → Appearance or the palette menu in the sidebar.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let accent: NSColor
    /// nil = use the system's dynamic colors for that surface.
    let window: NSColor?
    let surface: NSColor?
    let sidebar: NSColor?
    let elevated: NSColor?
    let termBackground: NSColor
    let termForeground: NSColor
    let cursor: NSColor
    /// 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
    let ansi: [NSColor]

    static func == (a: AppTheme, b: AppTheme) -> Bool { a.id == b.id }

    // MARK: Catalog

    static let midnight = AppTheme(
        id: "midnight", name: "Midnight", dark: true,
        accent: .systemBlue, window: nil, surface: nil, sidebar: nil, elevated: nil,
        termBackground: hex(0x141419), termForeground: hex(0xE6E6E6), cursor: .systemTeal,
        ansi: [0x1E1E24, 0xF2777A, 0x99CC99, 0xFFCC66, 0x6699CC, 0xCC99CC, 0x66CCCC, 0xD0D0D0,
               0x5C5C66, 0xFF8F91, 0xB5E8B5, 0xFFE08A, 0x8CB8E6, 0xE6B8E6, 0x8AE6E6, 0xFFFFFF].map(hex))

    static let daylight = AppTheme(
        id: "daylight", name: "Daylight", dark: false,
        accent: .systemBlue, window: nil, surface: nil, sidebar: nil, elevated: nil,
        termBackground: hex(0xFBFBFA), termForeground: hex(0x24292F), cursor: .systemBlue,
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0550AE, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F].map(hex))

    static let nord = AppTheme(
        id: "nord", name: "Nord", dark: true,
        accent: hex(0x88C0D0), window: hex(0x2E3440), surface: hex(0x272C36), sidebar: hex(0x2B303B), elevated: hex(0x3B4252),
        termBackground: hex(0x2E3440), termForeground: hex(0xD8DEE9), cursor: hex(0x88C0D0),
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4].map(hex))

    static let dracula = AppTheme(
        id: "dracula", name: "Dracula", dark: true,
        accent: hex(0xBD93F9), window: hex(0x282A36), surface: hex(0x21222C), sidebar: hex(0x252631), elevated: hex(0x343746),
        termBackground: hex(0x282A36), termForeground: hex(0xF8F8F2), cursor: hex(0xFF79C6),
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF].map(hex))

    static let solarized = AppTheme(
        id: "solarized", name: "Solarized Dark", dark: true,
        accent: hex(0x2AA198), window: hex(0x073642), surface: hex(0x002B36), sidebar: hex(0x05303B), elevated: hex(0x0B4250),
        termBackground: hex(0x002B36), termForeground: hex(0x93A1A1), cursor: hex(0x2AA198),
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x586E75, 0xCB4B16, 0x93A1A1, 0x839496, 0x6C71C4, 0xD33682, 0x93A1A1, 0xFDF6E3].map(hex))

    static let all: [AppTheme] = [midnight, daylight, nord, dracula, solarized]

    static func named(_ id: String) -> AppTheme { all.first { $0.id == id } ?? midnight }

    /// The active theme (set by the Store when settings change).
    @MainActor static var current: AppTheme = .midnight

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// SwiftTerm palette (16-bit channels).
    var terminalPalette: [SwiftTerm.Color] {
        ansi.map { c in
            let s = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535), blue: UInt16(s.blueComponent * 65535))
        }
    }
}

/// Theme-aware colors used throughout the UI.
@MainActor
extension SwiftUI.Color {
    static var appAccent: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.accent) }
    static var appWindow: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.window ?? .windowBackgroundColor) }
    static var appSurface: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.surface ?? .underPageBackgroundColor) }
    static var appSidebar: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.sidebar ?? .underPageBackgroundColor) }
    static var appElevated: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.elevated ?? .controlBackgroundColor) }
    static var appTerminal: SwiftUI.Color { SwiftUI.Color(nsColor: AppTheme.current.termBackground) }
    /// Text color that stays readable on top of the accent (dark text on light accents like Nord's).
    static var onAccent: SwiftUI.Color {
        let c = AppTheme.current.accent.usingColorSpace(.sRGB) ?? AppTheme.current.accent
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? SwiftUI.Color.black.opacity(0.85) : .white
    }
}

/// Small preview card used in the Appearance settings.
struct ThemePreview: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Rectangle().fill(SwiftUI.Color(nsColor: theme.sidebar ?? (theme.dark ? AppTheme.hex(0x2A2A2E) : AppTheme.hex(0xEDEDED))))
                    .frame(width: 26)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 2).fill(SwiftUI.Color(nsColor: theme.accent)).frame(width: 16, height: 5).padding(.top, 8)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1).fill(SwiftUI.Color(nsColor: theme.ansi[[2, 4, 3, 5][i]])).frame(width: 14, height: 4)
                            RoundedRectangle(cornerRadius: 1).fill(SwiftUI.Color(nsColor: theme.termForeground).opacity(0.7)).frame(width: CGFloat([40, 28, 48, 22][i]), height: 4)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SwiftUI.Color(nsColor: theme.termBackground))
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SwiftUI.Color.primary.opacity(0.15)))
            HStack(spacing: 5) {
                Image(systemName: theme.dark ? "moon.fill" : "sun.max.fill").font(.caption2).foregroundStyle(.secondary)
                Text(theme.name).font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(SwiftUI.Color(nsColor: theme.accent)) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(SwiftUI.Color.primary.opacity(selected ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? SwiftUI.Color(nsColor: theme.accent) : .clear, lineWidth: 2))
    }
}
