import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppPickerPresentation: ObservableObject {
    @Published var targets: [AppSwitchTarget] = []
    @Published var selectedIndex = 0
    @Published var practicing = false
    @Published var instruction = "Slide with an open hand · pinch again to choose"
    var synthetic = false
}

struct AppPickerView: View {
    @ObservedObject var presentation: AppPickerPresentation
    var onCancel: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "hand.pinch.fill").foregroundStyle(.blue)
                Text(presentation.practicing ? "Practice · no app will switch" : "Pinch & slide")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Pinch again to choose").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(presentation.targets.enumerated()), id: \.element.id) { index, target in
                            VStack(spacing: 7) {
                                Group {
                                    if !presentation.synthetic, let icon = target.runningApplication?.icon {
                                        Image(nsImage: icon).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: ["safari", "note.text", "envelope", "calendar", "terminal"][index % 5])
                                            .resizable().scaledToFit().padding(6).foregroundStyle(.blue)
                                    }
                                }.frame(width: 44, height: 44)
                                Text(target.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            }.frame(width: 80, height: 88)
                                .background {
                                    if index == presentation.selectedIndex {
                                        RoundedRectangle(cornerRadius: 17).fill(.blue.opacity(0.13))
                                            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.blue.opacity(0.42), lineWidth: 1))
                                    }
                                }
                                .id(target.id)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(index == presentation.selectedIndex ? .isSelected : [])
                        }
                    }.padding(2)
                }.onChange(of: presentation.selectedIndex) { _, index in
                    guard presentation.targets.indices.contains(index) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(presentation.targets[index].id, anchor: .center) }
                }
            }.frame(height: 92)
            HStack {
                Image(systemName: "arrow.left.and.right")
                Text(presentation.instruction)
                Spacer()
                if let onCancel {
                    Button("Cancel", systemImage: "xmark.circle", action: onCancel).buttonStyle(.borderless).controlSize(.small)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20).background { GlassSurface(radius: 27).allowsHitTesting(false) }
    }
}

final class AppPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppPickerController {
    let presentation = AppPickerPresentation()
    private var panel: AppPickerPanel?
    func show(_ session: AppSwitchSession, onCancel: @escaping () -> Void) -> Bool {
        guard NSApp != nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return false }
        presentation.targets = session.targets; presentation.selectedIndex = session.selectedIndex
        presentation.practicing = session.practicing
        presentation.instruction = session.instruction
        let width = min(max(420, Double(session.targets.count) * 88 + 40), min(760, screen.visibleFrame.width - 48))
        let frame = NSRect(x: screen.visibleFrame.midX - width/2, y: screen.visibleFrame.minY + 80, width: width, height: 224)
        let window = panel ?? AppPickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Pinch & slide"; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.ignoresMouseEvents = false; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = .floating; window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: AppPickerView(presentation: presentation, onCancel: onCancel))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host; window.setFrame(frame, display: false)
        panel = window; window.orderFrontRegardless()
        return window.isVisible
    }
    func update(_ session: AppSwitchSession) {
        presentation.selectedIndex = session.selectedIndex; presentation.instruction = session.instruction
    }
    func hide() {
        panel?.orderOut(nil); panel?.contentView = nil
        presentation.targets = []; presentation.selectedIndex = 0
    }
}

struct AppSwitcherSettingsView: View {
    @Binding var settings: AppSwitcherSettings
    @State private var selectionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pinch to open, release and slide to browse, then pinch again to choose. Losing the hand pauses selection while the picker stays open.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Travel per app"); Spacer(); Text("\(Int(settings.distancePerApp * 100))% of camera width").foregroundStyle(.secondary) }
                Slider(value: $settings.distancePerApp, in: 0.04...0.2, step: 0.005).accessibilityLabel("Travel per app")
                Text("Smaller distance makes selection more sensitive.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 12))
            Toggle("Reverse slide direction", isOn: $settings.reversed)
            HStack {
                Text("Cancel after")
                Slider(value: $settings.timeout, in: 3...30, step: 1).accessibilityLabel("App picker timeout")
                Text("\(Int(settings.timeout)) seconds").monospacedDigit().frame(width: 80)
            }.font(.system(size: 12))
            Toggle("Only include chosen apps", isOn: $settings.onlyChosenApps)
            if settings.onlyChosenApps {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(settings.bundleIDs, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appName(id)).font(.system(size: 12, weight: .medium))
                                Text(id).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button { settings.bundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("Remove \(appName(id))")
                        }
                    }
                    Button("Choose apps…") { chooseApps() }.disabled(settings.bundleIDs.count >= 32)
                    Text("Only running apps from this list appear. App identities are shown for import review.").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).liquidPanel(radius: 14)
            } else {
                Text("Shows up to 20 running apps, with the current app first. Gestures stays out of the list.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let selectionError { Text(selectionError).font(.system(size: 11)).foregroundStyle(.red) }
            Text("Keep the final pose pinched. You can edit the opening movement and hand selection in Gesture, and the Option clutch in Fine-tune. Use distinct starting poses or app scopes for other enabled pinch gestures.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), let bundle = Bundle(url: url) else { return id }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? id
    }
    private func chooseApps() {
        let panel = NSOpenPanel(); panel.title = "Choose apps for pinch & slide"; panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in Task { @MainActor in
            guard response == .OK else { return }
            var proposed = settings
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                if !proposed.bundleIDs.contains(id) { proposed.bundleIDs.append(id) }
            }
            do { settings = try proposed.validated(); selectionError = nil }
            catch { selectionError = error.localizedDescription }
        } }
    }
}

struct AppSwitcherPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presentation = AppPickerPresentation()
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(title: "A pinch. A slide. A different app.", subtitle: "Preview the glass picker without a camera or app activation.")
            AppPickerView(presentation: presentation, onCancel: { dismiss() }).frame(width: 520, height: 224)
            HStack {
                Button { presentation.selectedIndex = (presentation.selectedIndex + 4) % 5 } label: { Label("Previous", systemImage: "arrow.left") }.buttonStyle(GlassButton())
                Button { presentation.selectedIndex = (presentation.selectedIndex + 1) % 5 } label: { Label("Next", systemImage: "arrow.right") }.buttonStyle(GlassButton())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(GlassButton(prominent: true))
            }
            Text("Pinch to open, release and slide your open hand to browse, then pinch again to choose. The picker stays open if you lower your hand; show one clear open hand to resume. Use Cancel to dismiss it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(28).frame(width: 576).background(WindowMaterial()).preferredColorScheme(.light)
            .onAppear {
                presentation.synthetic = true; presentation.practicing = true
                presentation.targets = ["Safari", "Notes", "Mail", "Calendar", "Terminal"].enumerated().map { .init(id: Int32($0.offset + 1), bundleID: "example.preview.\($0.offset)", name: $0.element, launchedAt: nil) }
                presentation.selectedIndex = 1
            }
    }
}
