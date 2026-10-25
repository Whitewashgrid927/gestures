import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: GestureStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { store?.stopCamera(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct GesturesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = GestureStore()
    var body: some Scene {
        Window("Gestures", id: "main") {
            MainView(store: store)
                .onAppear { delegate.store = store }
                .onOpenURL { url in if url.isFileURL { store.importLibrary(at: url) } }
                .onDisappear { store.mainWindowClosed() }
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New gesture") { store.newGesture() }.keyboardShortcut("n") }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo gesture change") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.isEditing)
                Button("Redo gesture change") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo || store.isEditing)
            }
            CommandMenu("Gestures") {
                Button("Pause Mac control") { store.disableControl(); store.notice = "Mac control is paused." }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Stop camera") { store.stopCamera() }
                Divider()
                GlassFeedbackMenu(store: store)
                Divider()
                Button("Import gestures…") { store.importLibrary() }
                Button("Export gestures…") { store.exportLibrary() }
                Divider()
                Button("Camera & permissions…") { store.showPermissions = true }
            }
            CommandGroup(replacing: .help) { Button("Gestures Help") { store.showHelp = true } }
        }
        MenuBarExtra { StatusMenu(store: store) } label: { Image(systemName: store.enabled ? "hand.raised.fill" : "hand.raised") }
    }
}

struct StatusMenu: View {
    @ObservedObject var store: GestureStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.enabled ? "Mac control is on" : store.testing ? "Practice only · actions off" : "Mac control is paused")
        Text(store.cameraRunning ? "Camera is on" : "Camera is off")
        Divider()
        Button("Open Gestures") { showWindow() }
        if store.enabled {
            Button("Pause Mac control") { store.disableControl(); store.notice = "Mac control is paused." }
        } else {
            Button("Resume Mac control") {
                store.enableControl()
                if store.showPermissions || store.errorMessage != nil || store.isEditing { showWindow() }
            }.disabled(!store.cameraRunning || store.recording)
        }
        if store.cameraStatus == .off {
            Button("Start camera…") { showWindow(); store.startCamera() }
        } else {
            Button("Stop camera") { store.stopCamera() }
        }
        MenuActivity(tracking: store.tracking)
        Divider()
        GlassFeedbackMenu(store: store)
        Divider()
        Button("Quit Gestures") { NSApp.terminate(nil) }
    }
    private func showWindow() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}

struct MenuActivity: View {
    @ObservedObject var tracking: TrackingPresentation
    var body: some View {
        if !tracking.lastMatch.isEmpty {
            Divider()
            Text(tracking.lastMatch)
            if !tracking.actionStatus.isEmpty { Text(tracking.actionStatus) }
        }
    }
}
