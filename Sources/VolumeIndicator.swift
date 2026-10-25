import AppKit
import SwiftUI

@MainActor final class VolumePresentation: ObservableObject {
    @Published var feedback = VolumeFeedback()
    @Published var practicing = false
}

struct VolumeIndicatorView: View {
    @ObservedObject var presentation: VolumePresentation
    private var feedback: VolumeFeedback { presentation.feedback }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(presentation.practicing ? Color.orange : .blue).frame(width: 5, height: 5)
                Text(presentation.practicing ? "Practice" : "Volume").font(.system(size: 11, weight: .semibold))
            }
            Image(systemName: feedback.muted ? "speaker.slash" : feedback.level < 0.01 ? "speaker" : "speaker.wave.2")
                .font(.system(size: 22, weight: .regular)).foregroundStyle(.primary.opacity(0.8)).frame(height: 27)
            Text(feedback.preparing ? "—" : "\(Int((feedback.level * 100).rounded()))%")
                .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule().fill(feedback.muted ? Color.secondary : .blue).frame(width: 100 * max(0, min(1, feedback.level)))
                Capsule().fill(.primary.opacity(0.5)).frame(width: 2, height: 10).offset(x: 98 * feedback.maximum)
            }.frame(width: 100, height: 5).opacity(feedback.preparing ? 0.3 : 1)
            Text(feedback.label).font(.system(size: 11, weight: .medium))
            Text(presentation.practicing ? "No sound changed" : "Open hand to stop")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.vertical, 19).frame(width: 144)
            .background { GlassSurface(radius: 29).allowsHitTesting(false) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(presentation.practicing ? "Practice volume" : "Volume"), \(feedback.preparing ? "preparing" : "\(Int((feedback.level * 100).rounded())) percent"), \(feedback.label)")
    }
}

private final class VolumeIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class VolumeIndicatorController {
    private let presentation = VolumePresentation()
    private var panel: VolumeIndicatorPanel?
    @discardableResult
    func show(_ feedback: VolumeFeedback, practicing: Bool) -> Bool {
        guard NSApp != nil else { return false }
        presentation.feedback = feedback; presentation.practicing = practicing
        if panel?.isVisible == true { return true }
        let practiceScreen = practicing ? (NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen) : nil
        guard let screen = practiceScreen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return false }
        let frame = NSRect(x: screen.visibleFrame.maxX - 170, y: screen.visibleFrame.midY - 110, width: 144, height: 220)
        let window = panel ?? VolumeIndicatorPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Volume indicator"; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = .floating; window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        if panel == nil {
            let host = NSHostingView(rootView: VolumeIndicatorView(presentation: presentation))
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor; window.contentView = host
        }
        window.setFrame(frame, display: false); panel = window; window.orderFrontRegardless()
        return window.isVisible
    }
    func hide() { panel?.orderOut(nil); presentation.feedback = .init(); presentation.practicing = false }
}

struct VolumeIndicatorPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presentation = VolumePresentation()
    @State private var indicator = VolumeIndicatorController()
    @State private var showingIndicator = false
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            SheetHeading(title: "A fist. A quieter moment.", subtitle: "Preview Liquid Glass without changing your sound.")
            HStack(spacing: 28) {
                VolumeIndicatorView(presentation: presentation).padding(22)
                    .background(LinearGradient(colors: [.cyan.opacity(0.15), .blue.opacity(0.09), .purple.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Close your fist. Move up for louder, down for quieter. Open your hand to stop.")
                    Text("The small mark is your volume ceiling. Your current volume is the starting point; mute stays muted.").foregroundStyle(.secondary)
                }.font(.system(size: 12)).lineSpacing(4).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
            HStack { Text("Preview level").font(.system(size: 12)); Slider(value: $presentation.feedback.level, in: 0...1).accessibilityLabel("Preview volume level") }
            Toggle("Preview muted output", isOn: $presentation.feedback.muted).font(.system(size: 12))
            Button(showingIndicator ? "Hide floating indicator" : "Show floating indicator") {
                if showingIndicator { indicator.hide(); showingIndicator = false }
                else { showingIndicator = indicator.show(presentation.feedback, practicing: true) }
            }.buttonStyle(GlassButton())
            HStack { Text("The live indicator never captures clicks or keyboard focus.").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.buttonStyle(GlassButton(prominent: true)) }
        }.padding(28).frame(width: 550).background(WindowMaterial()).preferredColorScheme(.light)
            .onAppear { presentation.practicing = true }
            .onChange(of: presentation.feedback) { _, value in if showingIndicator { indicator.show(value, practicing: true) } }
            .onDisappear { indicator.hide() }
    }
}
