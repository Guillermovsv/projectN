import AppKit
import SwiftUI

/// Pointing-hand cursor while hovering, balanced push/pop (also undone if the view disappears mid-hover).
private struct HandCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled && !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside && pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
            .onChange(of: enabled) { _, on in if !on && pushed { NSCursor.pop(); pushed = false } }
    }
}

/// Hand cursor + a subtle rounded highlight behind the view while hovered.
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var inset: CGFloat
    var highlight: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(highlight && hovering && isEnabled ? 0.09 : 0))
            )
            .padding(-inset)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(HandCursor(enabled: isEnabled))
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Hand cursor and a highlight on hover. `inset` grows the highlight beyond the view's bounds.
    func hoverHighlight(cornerRadius: CGFloat = 6, inset: CGFloat = 3, highlight: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, inset: inset, highlight: highlight))
    }

    /// Only the pointing-hand cursor (for views that already draw their own hover state).
    func handCursor(_ enabled: Bool = true) -> some View {
        modifier(HandCursor(enabled: enabled))
    }
}

/// Icon/text button: padded, highlighted on hover, darker while pressed, hand cursor.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering && isEnabled ? 0.09 : 0)))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .handCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
