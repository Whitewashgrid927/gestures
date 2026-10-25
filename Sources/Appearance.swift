import AppKit
import SwiftUI

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .underWindowBackground; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct GlassSurface: NSViewRepresentable {
    var radius: CGFloat = 18
    var clear = false
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView(); view.contentView = NSView(); view.cornerRadius = radius; view.style = clear ? .clear : .regular; return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) { view.cornerRadius = radius; view.style = clear ? .clear : .regular }
}
extension View {
    func liquidPanel(radius: CGFloat = 18, clear: Bool = false) -> some View {
        background(GlassSurface(radius: radius, clear: clear).allowsHitTesting(false).accessibilityHidden(true))
    }
}
struct GlassButton: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.blue.opacity(configuration.isPressed ? 0.65 : 0.90) : .clear, in: RoundedRectangle(cornerRadius: 15))
            .liquidPanel(radius: 15)
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
    }
}
struct SheetHeading: View {
    var title: String; var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
