import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var store: GestureStore
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 226)
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 19) {
                header
                if store.cameraRunning { controlStatus }
                CameraStage(store: store).frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 280)
                if store.cameraRunning && (store.testing || store.enabled) { TestFeedback(tracking: store.tracking, rule: store.selected, testing: store.testing) }
                mapping
                bottomBar
                Text(store.notice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .topLeading)
            }.padding(.horizontal, 28).padding(.top, 27).padding(.bottom, 15)
        }
        .frame(minWidth: 1020, minHeight: 730)
        .background {
            ZStack {
                WindowMaterial()
                LinearGradient(colors: [.blue.opacity(0.11), .purple.opacity(0.06), .cyan.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.light).tint(.blue)
        .sheet(item: $store.editor) { draft in GestureEditor(store: store, initial: draft) }
        .sheet(isPresented: $store.showFineTune) { if let rule = store.selected { FineTuneSheet(store: store, initial: rule) } }
        .sheet(isPresented: $store.showPermissions) { PermissionsSheet(store: store) }
        .sheet(isPresented: $store.showHelp) { HelpSheet() }
        .sheet(isPresented: $store.showGlassAppearance) { GlassAppearanceSheet(store: store) }
        .sheet(isPresented: $store.showAppSwitcherPreview) { AppSwitcherPreviewSheet() }
        .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshPermissions() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 21, weight: .light)).foregroundStyle(.blue.opacity(0.75)).frame(width: 42, height: 44).liquidPanel(radius: 13)
                Text("Gestures").font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.6)
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 28)
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.visibleRules) { rule in
                        Button { store.select(rule.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: rule.symbol).font(.system(size: 17, weight: .regular)).frame(width: 25)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    if !rule.enabled { Text("Disabled").font(.system(size: 9)).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }.foregroundStyle(rule.enabled ? Color.primary : .secondary).padding(.horizontal, 14).frame(height: 57)
                                .background { if store.selectedID == rule.id { GlassSurface(radius: 17) } }
                                .contentShape(RoundedRectangle(cornerRadius: 17))
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit gesture") { store.select(rule.id); store.editSelected() }
                                Button("Duplicate") { store.select(rule.id); store.duplicateSelected() }
                                Button("Delete", role: .destructive) { store.select(rule.id); store.removeSelected() }
                            }
                    }
                    if store.visibleRules.isEmpty { Text("No gestures in this profile.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 18) }
                }.padding(.horizontal, 13)
            }
            Divider().padding(.horizontal, 25).padding(.vertical, 16)
            Button { store.newGesture() } label: { Label("New gesture", systemImage: "plus.circle").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.vertical, 7) }.buttonStyle(.plain)
            Button { store.addAppSwitcherPreset() } label: { Label("Pinch & slide", systemImage: "hand.pinch").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.vertical, 7) }.buttonStyle(.plain).help("Add or select the configurable app switcher")
            Spacer(minLength: 24)
            Menu {
                Button("All profiles") { store.selectProfile("*") }
                Button("All apps") { store.selectProfile("") }
                ForEach(store.profiles, id: \.bundleID) { profile in Button(profile.display) { store.selectProfile(profile.bundleID) } }
                Divider()
                Button("Import gestures…") { store.importLibrary() }
                Button("Export gestures…") { store.exportLibrary() }
            } label: {
                HStack { Image(systemName: "square.grid.2x2"); Text(profileName).lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    .font(.system(size: 12)).padding(14).liquidPanel(radius: 16)
            }.menuStyle(.borderlessButton).padding(.horizontal, 17)
            HStack {
                Button { store.showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("Help")
                Spacer()
                Menu {
                    GlassFeedbackMenu(store: store)
                    Divider()
                    Button("Camera & permissions…") { store.showPermissions = true }
                    Button("Import gestures…") { store.importLibrary() }
                    Button("Export gestures…") { store.exportLibrary() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
            }.foregroundStyle(.secondary).font(.system(size: 14)).padding(.horizontal, 29).padding(.top, 20).padding(.bottom, 24)
        }.background(.white.opacity(0.10))
    }
    private var profileName: String { store.selectedProfile == "*" ? "All profiles" : store.selectedProfile.isEmpty ? "All apps" : store.profiles.first(where: { $0.bundleID == store.selectedProfile })?.display ?? store.selectedProfile }
    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            Text(store.selected?.name ?? "Your gestures").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.8).lineLimit(1)
            Spacer(minLength: 10)
            Toggle("Mac control", isOn: Binding(get: { store.enabled }, set: { $0 ? store.enableControl() : store.disableControl() })).toggleStyle(.switch).controlSize(.regular).font(.system(size: 12)).fixedSize().help("Enable gestures to control the Mac")
            Button("Edit gesture") { store.editSelected() }.buttonStyle(GlassButton()).disabled(store.selected == nil || store.recording)
        }.frame(height: 44)
    }
    private var controlStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: store.enabled ? "checkmark.circle.fill" : "pause.circle.fill").foregroundStyle(store.enabled ? Color.green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.controlMode.title).font(.system(size: 12, weight: .semibold))
                Text(store.controlMode.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if store.enabled {
                Button("Run in background") { dismissWindow(id: "main") }.buttonStyle(GlassButton()).fixedSize().help("Close this window and keep gestures running from the menu bar")
            } else { Button("Enable Mac control") { store.enableControl() }.buttonStyle(GlassButton(prominent: true)).fixedSize() }
        }.padding(12).liquidPanel(radius: 16)
    }
    private var mapping: some View {
        HStack(spacing: 15) {
            Spacer(minLength: 0)
            Text("When").font(.system(size: 13)).foregroundStyle(.secondary)
            Menu {
                ForEach(store.library.rules) { rule in Button(rule.name) { store.select(rule.id) } }
                Divider(); Button("Define a new gesture…") { store.newGesture() }
            } label: {
                HStack(spacing: 10) { Image(systemName: "hand.raised"); Text(store.selected?.name ?? "Choose gesture").lineLimit(1); Spacer(minLength: 3); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 17).frame(width: 210, height: 48).liquidPanel(radius: 16)
            }.menuStyle(.borderlessButton)
            Image(systemName: "arrow.right").font(.system(size: 21, weight: .light)).foregroundStyle(.secondary)
            Menu {
                ForEach(ActionKind.allCases, id: \.self) { kind in Button(kind.rawValue) { store.setAction(kind) } }
            } label: {
                HStack(spacing: 10) { Image(systemName: store.selected?.action.kind.symbol ?? "keyboard"); Text(store.selected?.action.title ?? "Choose action").lineLimit(1); Spacer(minLength: 3); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 17).frame(width: 220, height: 48).liquidPanel(radius: 16)
            }.menuStyle(.borderlessButton).disabled(store.selected == nil)
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { store.disableControl(); store.showFineTune = true } label: { Label("Fine-tune", systemImage: "slider.horizontal.3").font(.system(size: 12)) }.buttonStyle(.plain).disabled(store.selected == nil)
            Button { store.showGlassAppearance = true } label: { Label("Ripple", systemImage: "drop").font(.system(size: 12)) }.buttonStyle(.plain).help("Preview and configure the desktop ripple")
            if store.selected?.action.kind == .switchApps {
                Button("Preview picker") { store.showAppSwitcherPreview = true }.buttonStyle(.plain).font(.system(size: 12))
            }
            Spacer()
            Menu {
                Button("Demonstrate a swipe (5 seconds)") { store.startRecording() }.disabled(!store.cameraRunning)
                Button("Define a gesture manually") { store.newGesture() }
            } label: { Image(systemName: "record.circle").font(.system(size: 18)) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Demonstrate a swipe").help("Suggest a gesture from hand landmarks, or define one manually").disabled(store.recording)
            if store.selected?.action.kind.isSpaceSwitch == true {
                Button(store.spaceCheckPending ? "Checking…" : "Switch Space now") { store.checkSpaceAction() }.buttonStyle(GlassButton()).disabled(!store.canCheckSpace).help("Send the selected Space shortcut once, independently of hand recognition")
            }
            if !store.enabled {
                Button { store.trySelected() } label: { Label(store.testing ? "Stop practice" : "Practice only", systemImage: store.testing ? "stop.fill" : "play.fill").frame(minWidth: 90) }.buttonStyle(GlassButton()).disabled(store.selected == nil || store.recording).help("Recognize this gesture without performing any Mac actions")
            }
            Button { store.save() } label: { Text("Save").frame(minWidth: 84) }.buttonStyle(GlassButton(prominent: true))
        }.padding(.top, 4)
    }
}
