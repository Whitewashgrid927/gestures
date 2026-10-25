import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GestureEditor: View {
    @ObservedObject var store: GestureStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: GestureRule
    @State private var selectedStep: UUID?
    @State private var tab = "Gesture"
    @State private var localError: String?
    private let note: String
    init(store: GestureStore, initial: EditorDraft) {
        self.store = store; _rule = State(initialValue: initial.rule); _selectedStep = State(initialValue: initial.rule.steps.first?.id); note = initial.note
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                SheetHeading(title: "Make it your gesture", subtitle: "Define a movement, then choose what it does.")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Close editor")
            }
            HStack(spacing: 20) {
                TextField("Gesture name", text: $rule.name).textFieldStyle(.roundedBorder).font(.system(size: 16, weight: .medium))
                Toggle("Use gesture", isOn: $rule.enabled).toggleStyle(.switch).fixedSize()
            }
            if !note.isEmpty { Label(note, systemImage: "sparkle").font(.system(size: 11)).foregroundStyle(.secondary).padding(11).frame(maxWidth: .infinity, alignment: .leading).liquidPanel(radius: 12) }
            Picker("Editor", selection: $tab) { Text("Gesture").tag("Gesture"); Text("Action").tag("Action"); Text("Where").tag("Where") }.pickerStyle(.segmented)
            Group {
                switch tab { case "Action": actionEditor; case "Where": scopeEditor; default: gestureEditor }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let localError { Text(localError).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("Changes take effect after you save. Mac control is paused.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(GlassButton())
                Button("Save gesture") {
                    do { _ = try rule.validated(); store.update(rule); if store.errorMessage == nil { dismiss() } }
                    catch { localError = error.localizedDescription }
                }.buttonStyle(GlassButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 850, height: 660)
            .background(WindowMaterial()).preferredColorScheme(.light)
    }
    private var gestureEditor: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 13) {
                Text("YOUR SEQUENCE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(rule.steps.enumerated()), id: \.element.id) { index, step in
                            Button { selectedStep = step.id } label: {
                                HStack(spacing: 10) {
                                    Text(String(index + 1)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: 19, height: 19).background(.white.opacity(0.45), in: Circle())
                                    Image(systemName: step.symbol).frame(width: 20)
                                    Text(step.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity)
                                    .background(selectedStep == step.id ? Color.blue.opacity(0.10) : Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedStep == step.id ? Color.blue.opacity(0.35) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Menu {
                        ForEach(StepKind.allCases, id: \.self) { kind in Button(kind.rawValue) { let step = GestureStep(kind: kind); rule.steps.append(step); selectedStep = step.id } }
                    } label: { Label("Add step", systemImage: "plus") }.disabled(rule.steps.count >= 10)
                    Spacer()
                    Button { moveStep(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).help("Move step earlier")
                    Button { moveStep(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain).help("Move step later")
                    Button { removeStep() } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete this step").disabled(rule.steps.count <= 1)
                }.font(.system(size: 11))
            }.frame(width: 260)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    Picker("Which hand?", selection: $rule.hand) { ForEach(HandChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if let i = rule.steps.firstIndex(where: { $0.id == selectedStep }) { stepEditor($rule.steps[i]) }
                    else { Text("Select a step to edit it.").foregroundStyle(.secondary) }
                }.padding(.horizontal, 1).padding(.bottom, 20)
            }
        }
    }
    @ViewBuilder private func stepEditor(_ step: Binding<GestureStep>) -> some View {
        switch step.wrappedValue.kind {
        case .pose:
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a hand pose").font(.system(size: 18, weight: .medium, design: .rounded))
                Picker("Pose", selection: step.pose.kind) { ForEach(PoseKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if step.wrappedValue.pose.kind == .custom {
                    Text("Define your own combination. “Any” leaves that finger unconstrained.").font(.system(size: 11)).foregroundStyle(.secondary)
                    fingerPicker("Thumb", value: step.pose.thumb)
                    fingerPicker("Index finger", value: step.pose.index)
                    fingerPicker("Middle finger", value: step.pose.middle)
                    fingerPicker("Ring finger", value: step.pose.ring)
                    fingerPicker("Little finger", value: step.pose.little)
                    Picker("Thumb + index", selection: step.pose.pinch) { ForEach(PinchRequirement.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } else {
                    Image(systemName: step.wrappedValue.pose.kind == .pinch ? "hand.pinch" : step.wrappedValue.pose.kind == .point ? "hand.point.up" : "hand.raised")
                        .font(.system(size: 55, weight: .ultraLight)).foregroundStyle(.blue.opacity(0.7)).frame(maxWidth: .infinity).padding(22)
                    Text(poseExplanation(step.wrappedValue.pose.kind)).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                }
            }
        case .hold:
            VStack(alignment: .leading, spacing: 20) {
                Text("Hold it still").font(.system(size: 18, weight: .medium, design: .rounded))
                settingSlider("Duration", value: step.duration, range: 0.1...3, display: "\(Int(step.wrappedValue.duration * 1000)) ms")
                Text("Keep the preceding hand pose still for this long. Moving too far restarts the hold.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .move, .slide:
            VStack(alignment: .leading, spacing: 20) {
                Text("Define the movement").font(.system(size: 18, weight: .medium, design: .rounded))
                if step.wrappedValue.kind == .move {
                    Picker("Direction", selection: step.direction) { ForEach(MoveDirection.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) } }
                } else { Text("Either left or right opens the picker. Vertical movement does not complete this step.").font(.system(size: 12)).foregroundStyle(.secondary) }
                settingSlider("Travel distance", value: step.distance, range: 0.03...0.65, display: "\(Int(step.wrappedValue.distance * 100))% of frame")
                settingSlider("Complete within", value: step.maximumDuration, range: 0.2...5, display: String(format: "%.1f seconds", step.wrappedValue.maximumDuration))
                Text("Keep the preceding pose while moving. Directions match the mirrored preview. Chain several Move steps to define a path.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
        case .release:
            VStack(alignment: .leading, spacing: 20) {
                Text("Finish with a release").font(.system(size: 18, weight: .medium, design: .rounded))
                settingSlider("Release duration", value: step.duration, range: 0.1...3, display: "\(Int(step.wrappedValue.duration * 1000)) ms")
                Text("Lower your hand out of view or change the preceding pose. Release must be the final step. The action waits until this step finishes.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }
    private func fingerPicker(_ title: String, value: Binding<FingerState>) -> some View { Picker(title, selection: value) { ForEach(FingerState.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
    private func poseExplanation(_ kind: PoseKind) -> String {
        switch kind {
        case .open: return "Extend your four fingers. Your thumb can rest naturally."
        case .fist: return "Bend your four fingers into your palm. Your thumb can rest naturally."
        case .pinch: return "Bring your thumb and index fingertip together. The other fingers can be relaxed."
        case .point: return "Extend your index finger and bend the other three fingers."
        case .victory: return "Extend your index and middle fingers, and bend your ring and little fingers."
        case .any: return "Any confidently detected hand pose starts this step. Add a hold or movement to make the gesture deliberate."
        case .custom: return ""
        }
    }
    private var actionEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("What should happen?").font(.system(size: 19, weight: .medium, design: .rounded))
                Picker("Action", selection: $rule.action.kind) { ForEach(ActionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 530)
                switch rule.action.kind {
                case .switchApps:
                    AppSwitcherSettingsView(settings: Binding(get: { rule.action.switcherSettings }, set: { rule.action.appSwitcher = $0 }))
                    Button("Use pinch & slide sequence") { rule.steps = GestureRule.appSwitcherPreset.steps; selectedStep = rule.steps.first?.id }
                case .keyboard:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your keyboard shortcut").font(.system(size: 12, weight: .medium))
                        ShortcutRecorder(value: rule.action.key) { rule.action.key = $0 }.frame(width: 300, height: 42)
                        Text("Click the field, then press the keys. Escape cancels recording. This key combination is sent to the active app.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .shortcut:
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            TextField("Exact macOS Shortcut name", text: $rule.action.shortcutName).textFieldStyle(.roundedBorder)
                            Button(store.loadingShortcuts ? "Loading…" : "Load Shortcuts") { store.loadShortcuts() }.disabled(store.loadingShortcuts)
                        }
                        if !store.shortcutNames.isEmpty {
                            Picker("Choose", selection: $rule.action.shortcutName) {
                                Text("Select a Shortcut").tag("")
                                if !rule.action.shortcutName.isEmpty, !store.shortcutNames.contains(rule.action.shortcutName) { Text(rule.action.shortcutName).tag(rule.action.shortcutName) }
                                ForEach(store.shortcutNames, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Text("The selected Shortcut can perform whatever actions you have configured in Shortcuts. Review it there before enabling this gesture. Only one run is started at a time.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                case .scrollVertical, .scrollHorizontal:
                    VStack(alignment: .leading, spacing: 19) {
                        settingSlider("Scroll sensitivity", value: $rule.action.scrollSensitivity, range: 0.25...3, display: String(format: "%.2f×", rule.action.scrollSensitivity))
                        Toggle("Reverse scroll direction", isOn: $rule.action.reverseScroll)
                        Text("After the sequence matches, move your hand while holding its final pose. Releasing the pose or losing tracking stops scrolling. Use a pose followed by a short hold; leave out a Release step.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                default:
                    Label(rule.action.kind == .nextSpace || rule.action.kind == .previousSpace ? "Uses the Mac’s Control–Arrow shortcut. Keep that shortcut enabled in Keyboard settings." : "Uses the standard Mission Control keyboard shortcut.", systemImage: "keyboard").font(.system(size: 12)).foregroundStyle(.secondary).padding(18).liquidPanel()
                }
                Spacer(minLength: 10)
                Text("Try it on the main screen to see the proposed action without executing it.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 3).padding(.vertical, 5)
        }
    }
    private var scopeEditor: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Where should this work?").font(.system(size: 19, weight: .medium, design: .rounded))
            HStack {
                Label(rule.scope.display, systemImage: rule.scope.isGlobal ? "square.grid.2x2" : "app").font(.system(size: 16, weight: .medium)).padding(18).frame(maxWidth: .infinity, alignment: .leading).liquidPanel()
                Button("All apps") { rule.scope = .init() }
                Button("Choose app…") { chooseApp() }
            }
            Menu("Choose a running app") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? "App") { rule.scope = .init(bundleID: app.bundleIdentifier!, name: app.localizedName ?? "App") }
                }
            }.fixedSize()
            Text("An app-specific rule works only while that app is in front. When several rules are recognized together, a rule for the active app takes priority over an All apps rule. Only one action fires.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            Text("Test mode ignores app scope so you can tune the gesture here.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }
    private func moveStep(_ delta: Int) {
        guard let i = rule.steps.firstIndex(where: { $0.id == selectedStep }), rule.steps.indices.contains(i + delta) else { return }
        rule.steps.swapAt(i, i + delta)
    }
    private func removeStep() {
        guard rule.steps.count > 1, let i = rule.steps.firstIndex(where: { $0.id == selectedStep }) else { return }
        rule.steps.remove(at: i); selectedStep = rule.steps[min(i, rule.steps.count - 1)].id
    }
    private func chooseApp() {
        let panel = NSOpenPanel(); panel.title = "Choose an app profile"; panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
                rule.scope = .init(bundleID: id, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent)
            }
        }
    }
}

func settingSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
        HStack { Text(label); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 12))
        Slider(value: value, in: range).controlSize(.regular).accessibilityLabel(label)
    }
}

struct FineTuneSheet: View {
    @ObservedObject var store: GestureStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: GestureRule
    init(store: GestureStore, initial: GestureRule) { self.store = store; _rule = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            SheetHeading(title: "Fine-tune", subtitle: rule.name)
            settingSlider("Tracking confidence", value: $rule.confidence, range: 0.3...0.95, display: "\(Int(rule.confidence * 100))%")
            settingSlider("Pause between actions", value: $rule.cooldown, range: 0.3...5, display: String(format: "%.1f seconds", rule.cooldown))
            Toggle("Lower your hand between gestures", isOn: $rule.requireNeutral)
            Toggle("Also hold the Option key to activate", isOn: $rule.requireOptionKey)
            Text("Higher confidence asks for a clearer hand view. A pause and a neutral hand position help prevent accidental repeats.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(GlassButton()); Button("Save") { store.update(rule); if store.errorMessage == nil { dismiss() } }.buttonStyle(GlassButton(prominent: true)) }
        }.padding(28).frame(width: 470).background(WindowMaterial()).preferredColorScheme(.light)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var value: KeyBinding; var onChange: (KeyBinding) -> Void
    func makeNSView(context: Context) -> KeyCaptureButton { let button = KeyCaptureButton(); button.onChange = onChange; button.binding = value; button.refresh(); return button }
    func updateNSView(_ button: KeyCaptureButton, context: Context) { button.onChange = onChange; button.binding = value; button.refresh() }
}
final class KeyCaptureButton: NSButton {
    var onChange: ((KeyBinding) -> Void)?
    var binding = KeyBinding()
    private var recording = false
    init() { super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(begin); setAccessibilityLabel("Record keyboard shortcut") }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    func refresh() { title = recording ? "Press your shortcut… (Esc to cancel)" : binding.display + "   ·   Click to record" }
    @objc private func begin() { recording.toggle(); if recording { window?.makeFirstResponder(self) }; refresh() }
    override func resignFirstResponder() -> Bool { recording = false; refresh(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { capture(event); return true }; return super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) { if recording { capture(event) } else { super.keyDown(with: event) } }
    private func capture(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { recording = false; refresh(); return }
        let label = KeyDisplay.label(for: event.keyCode, command: event.modifierFlags.contains(.command))
        guard event.keyCode <= 126, !label.isEmpty else { return }
        let flags = event.modifierFlags
        binding = .init(code: event.keyCode, label: String(label.prefix(40)), command: flags.contains(.command), option: flags.contains(.option), control: flags.contains(.control), shift: flags.contains(.shift))
        recording = false; refresh(); onChange?(binding)
    }
}
