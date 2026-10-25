import AppKit
import SwiftUI

@MainActor final class ScrollPresentation: ObservableObject {
    @Published var feedback = ScrollFeedback()
    @Published var practicing = false
}

struct ScrollIndicatorView: View {
    @ObservedObject var presentation: ScrollPresentation
    private var feedback: ScrollFeedback { presentation.feedback }
    private var offset: CGFloat { CGFloat(min(1, max(-1, feedback.amount / 32))) * 21 }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(presentation.practicing ? Color.orange : .blue).frame(width: 5, height: 5)
                Text(presentation.practicing ? "Practice" : "Scroll").font(.system(size: 11, weight: .semibold))
            }
            ZStack {
                Capsule().fill(.primary.opacity(0.10))
                    .frame(width: feedback.horizontal ? 54 : 4, height: feedback.horizontal ? 4 : 54)
                Circle().fill(.blue).frame(width: 9, height: 9)
                    .offset(x: feedback.horizontal ? -offset : 0, y: feedback.horizontal ? 0 : -offset)
            }.frame(height: 58)
            Text(feedback.direction).font(.system(size: 12, weight: .medium)).monospacedDigit()
            Text(presentation.practicing ? "No scrolling sent" : "Release to stop")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.vertical, 17).frame(width: 124)
            .background { GlassSurface(radius: 27).allowsHitTesting(false) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(presentation.practicing ? "Practice scrolling" : "Scrolling"): \(feedback.direction)")
    }
}

private final class ScrollIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ScrollIndicatorController {
    private let presentation = ScrollPresentation()
    private var panel: ScrollIndicatorPanel?
    func show(_ feedback: ScrollFeedback, practicing: Bool) {
        guard NSApp != nil else { return }
        presentation.feedback = feedback; presentation.practicing = practicing
        if panel?.isVisible == true { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = NSRect(x: screen.visibleFrame.maxX - 150, y: screen.visibleFrame.midY - 84, width: 124, height: 168)
        let window = panel ?? ScrollIndicatorPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Scroll indicator"; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = .floating; window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        if window.contentView == nil || panel == nil {
            let host = NSHostingView(rootView: ScrollIndicatorView(presentation: presentation))
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView = host
        }
        window.setFrame(frame, display: false); panel = window; window.orderFrontRegardless()
    }
    func hide() {
        panel?.orderOut(nil); presentation.feedback = .init(); presentation.practicing = false
    }
}

struct ScrollIndicatorPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presentation = ScrollPresentation()
    @State private var amount = 0.0
    @State private var horizontal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            SheetHeading(title: "Two fingers. A gentle scroll.", subtitle: "Preview the indicator without a camera or scroll events.")
            HStack(spacing: 28) {
                ScrollIndicatorView(presentation: presentation).padding(24)
                    .background(LinearGradient(colors: [.cyan.opacity(0.15), .blue.opacity(0.09), .purple.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Raise index and middle fingers. Move your hand to scroll, and relax your fingers to stop.")
                    Text("The dot shows direction and intensity. It rests in the center when your hand is still.").foregroundStyle(.secondary)
                }.font(.system(size: 12)).lineSpacing(4).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Horizontal scrolling", isOn: $horizontal).font(.system(size: 12))
            HStack {
                Text("Motion").font(.system(size: 12))
                Slider(value: $amount, in: -32...32).accessibilityLabel("Preview scroll motion")
                Button("Still") { amount = 0 }
            }
            HStack { Text("The live indicator never captures clicks or keyboard focus.").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.buttonStyle(GlassButton(prominent: true)) }
        }.padding(28).frame(width: 550).background(WindowMaterial()).preferredColorScheme(.light)
            .onAppear { presentation.practicing = true }
            .onChange(of: amount) { _, value in presentation.feedback = .init(horizontal: horizontal, amount: value) }
            .onChange(of: horizontal) { _, value in presentation.feedback = .init(horizontal: value, amount: amount) }
    }
}
