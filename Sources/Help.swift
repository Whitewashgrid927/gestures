import AppKit
import AVFoundation
import SwiftUI

struct PermissionsSheet: View {
    @ObservedObject var store: GestureStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SheetHeading(title: "You’re in control", subtitle: "Two permissions, each for a specific job.")
            permission("Camera", icon: "camera", detail: "Finds hand landmarks locally on your Mac. Camera images are never recorded or uploaded.", ready: AVCaptureDevice.authorizationStatus(for: .video) == .authorized) {
                if AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                } else { dismiss(); store.startCamera() }
            }
            permission("Accessibility", icon: "hand.tap", detail: "Sends the keyboard and scroll actions you configure. Test mode works without this permission.", ready: store.accessible) {
                ActionRunner.openAccessibilitySettings()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Camera").font(.system(size: 12, weight: .medium)); Spacer(); Button("Refresh") { store.cameras = CameraPipeline.devices() }.font(.system(size: 11)) }
                Picker("Camera", selection: $store.selectedCamera) {
                    Text("System default").tag("")
                    ForEach(store.cameras) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(store.cameraRunning || store.cameraStatus == .starting)
                Text("Stop the camera before switching devices.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16).liquidPanel()
            Text("Permission alone does not turn on control. Start the camera, try a gesture, then enable control in the main window.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack { Button("Refresh permissions") { store.refreshPermissions() }.buttonStyle(GlassButton()); Spacer(); Button("Done") { dismiss() }.buttonStyle(GlassButton(prominent: true)) }
        }.padding(28).frame(width: 540).background(WindowMaterial()).preferredColorScheme(.light)
    }
    private func permission(_ name: String, icon: String, detail: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 7) { Text(name).font(.system(size: 15, weight: .semibold)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3) }
            Spacer(minLength: 4)
            if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Permission granted") }
            else { Button("Allow", action: action).buttonStyle(GlassButton()) }
        }
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(title: "Your hands. Your shortcuts.", subtitle: "Build an interaction that feels natural to you.")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    tip("1", "Define it", "Open Edit gesture. Start with a pose, then add holds, movements, or a release. Choose Custom pose to set each finger to straight, bent, or unconstrained. Combine moves to make a path.")
                    tip("2", "Give it an action", "Choose a Space switch, keyboard shortcut, macOS Shortcut, or continuous scroll. The Where tab limits a gesture to a selected app. When gestures match together, an app-specific rule takes priority.")
                    tip("3", "Try it safely", "Start your camera, then choose Practice only. Step-by-step feedback shows what was recognized and what would run. Test mode never sends actions. It tests the selected gesture even when that rule is disabled or scoped to another app.")
                    tip("4", "Turn it on", "Enable the rule with Use gesture in its editor. When you’re ready, turn on Mac control in the main window. Accessibility permission is needed for keyboard and scroll actions. Choose Run in background or close the window to keep live gestures running. The menu-bar hand lets you pause/resume control, reopen the window, stop the camera, or quit.")
                    Divider()
                    detail("Switching Spaces", "Create at least two desktops in Mission Control. Gestures sends Control–Right or Control–Left. Enable those shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. If you use different shortcuts, record them as a Keyboard shortcut action.")
                    detail("Desktop ripple", "Open Ripple for a sample preview. The real effect subtly refracts the whole working display before sending the action. It needs Screen Recording permission to read one frame into memory; no audio, files, or uploads are used. Turn Desktop ripple off to remove it. Reduce Motion or Reduce Transparency also skips it. Slow or unavailable capture falls back to the normal action without a ripple. Input permissions, frame freshness, scope, and protected-input checks still apply after the effect.")
                    detail("Two-finger scrolling", "Choose Two-finger scroll, then try Practice only. Raise index and middle fingers with the others curled, move up or down to scroll, and relax your fingers to stop. The glass indicator shows Ready or the direction; Practice sends no scroll events. Edit gesture → Action configures speed, reverse direction, steadiness, the indicator, and Vertical or Horizontal scroll. Gesture chooses the hand, Where sets app scope, and Fine-tune retains the Option clutch. Tracking loss, a second hand, or an app change stops scrolling and requires rearming.")
                    detail("Pinch & slide", "Pinch to open the glass picker, release and slide your open hand sideways to browse, then pinch again to choose. The picker stays open if you lower your hand; selection pauses until one clear open hand returns. Use Cancel to close it. Practice never switches apps. Edit gesture → Action configures travel per app, reverse direction, a 3–30 second timeout, and included apps. Use a different pose or app scope for other pinch gestures.")
                    detail("A useful starting point", "Keep one hand fully visible, facing the camera in even light. These are configurable 2D hand rules, not a trained model for arbitrary movements. A swipe demonstration proposes a direction and distance; review and test that suggestion.")
                    detail("Private by design", "Vision runs on your Mac. Images are processed in memory, never recorded or uploaded. A demonstration temporarily keeps hand landmarks and discards them after creating a suggestion. Only gesture definitions are saved. macOS Shortcuts can perform their own actions, including using the network.")
                    detail("Deliberate actions", "Control starts off on every launch and pauses while you edit, on sleep, screen lock, protected input, or lost camera frames. Stopping a macOS Shortcut cannot undo work it has already performed. Avoid assigning irreversible actions until you’ve tested your gesture carefully.")
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button("Got it") { dismiss() }.buttonStyle(GlassButton(prominent: true)).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 650, height: 690).background(WindowMaterial()).preferredColorScheme(.light)
    }
    private func tip(_ n: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(n).font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue).frame(width: 28, height: 28).liquidPanel(radius: 14)
            detail(title, text)
        }
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 14, weight: .semibold)); Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
    }
}
