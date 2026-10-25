import AppKit
import SwiftUI

struct GlassFeedbackCue: Equatable {
    var direction: MoveDirection?
    init(rule: GestureRule) {
        direction = rule.steps.last(where: { $0.kind == .move })?.direction
        if direction == nil {
            switch rule.action.kind {
            case .nextSpace: direction = .left
            case .previousSpace: direction = .right
            case .missionControl: direction = .up
            case .appWindows: direction = .down
            default: break
            }
        }
    }
}

struct GlassFeedbackMenu: View {
    @ObservedObject var store: GestureStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Toggle("Desktop ripple", isOn: $store.glassFeedbackEnabled)
        Button("Ripple appearance…") {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            store.showGlassAppearance = true
        }
    }
}

struct GlassAppearanceSheet: View {
    @ObservedObject var store: GestureStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(RippleStrength.preferenceKey) private var storedStrength = RippleStrength.standard
    @AppStorage(RippleDuration.preferenceKey) private var storedDuration = RippleDuration.milliseconds()
    @State private var durationText = ""
    @FocusState private var editingDuration: Bool
    @State private var previewID = UUID()
    private var limited: Bool { reduceMotion || reduceTransparency }
    private var strength: Binding<Double> {
        Binding(get: { RippleStrength.clamped(storedStrength) }, set: { storedStrength = RippleStrength.clamped($0) })
    }
    private var duration: Binding<Double> {
        Binding(get: { RippleDuration.clamped(storedDuration) }, set: {
            storedDuration = RippleDuration.clamped($0)
            durationText = String(Int(storedDuration))
        })
    }
    private func setDuration(_ milliseconds: Double) {
        duration.wrappedValue = milliseconds
        previewID = UUID()
    }
    private func commitDurationText() {
        setDuration(RippleDuration.parsed(durationText, fallback: duration.wrappedValue))
    }
    private var strengthLabel: String {
        switch strength.wrappedValue {
        case ..<16: "Soft"
        case ..<28: "Medium"
        case ..<40: "Strong"
        default: "Extra strong"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "Your desktop, in motion.", subtitle: "A glass wave. Then the action.")
            Group {
                if limited {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22).fill(.secondary.opacity(0.08))
                        Text("Ripple paused for your accessibility settings.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    ZStack {
                        if let image = RippleSample.stillImage { Image(decorative: image, scale: 2).resizable() }
                        RippleSampleView(direction: store.selected.flatMap { GlassFeedbackCue(rule: $0).direction }).id(previewID)
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 22))
            HStack {
                Button("Replay preview") { previewID = UUID() }.buttonStyle(GlassButton()).disabled(limited)
                Text("Sample desktop · actual timing").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Strength").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(strengthLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Slider(value: strength, in: RippleStrength.range, step: 1,
                       label: { Text("Ripple strength") },
                       minimumValueLabel: { Text("Soft").font(.system(size: 10)) },
                       maximumValueLabel: { Text("Extra strong").font(.system(size: 10)) },
                       onEditingChanged: { editing in if !editing { previewID = UUID() } })
                .accessibilityValue(Text(strengthLabel))
                .disabled(limited)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Duration").font(.system(size: 12, weight: .medium))
                    Spacer()
                    TextField("Milliseconds", text: $durationText)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
                        .focused($editingDuration).onSubmit { commitDurationText() }
                        .accessibilityLabel("Ripple duration in milliseconds")
                        .accessibilityHint("150 to 500 milliseconds. Press Return to apply.")
                    Text("ms").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Slider(value: duration, in: RippleDuration.range, step: 10,
                       label: { Text("Ripple duration") },
                       minimumValueLabel: { Text("150 ms").font(.system(size: 10)) },
                       maximumValueLabel: { Text("500 ms").font(.system(size: 10)) },
                       onEditingChanged: { editing in if !editing { previewID = UUID() } })
                    .accessibilityValue(Text("\(Int(duration.wrappedValue)) milliseconds"))
                HStack(spacing: 8) {
                    ForEach(RippleSpeed.allCases, id: \.self) { preset in
                        Button("\(preset.title) · \(Int(preset.duration*1000)) ms") {
                            setDuration(preset.duration*1000); editingDuration = false
                        }.buttonStyle(GlassButton(prominent: duration.wrappedValue == preset.duration*1000))
                    }
                }
                Text("Longer duration slows the wave. It may finish sooner to keep your gesture responsive.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(limited)
                .onChange(of: editingDuration) { _, editing in if !editing { commitDurationText() } }
            Toggle("Desktop ripple", isOn: $store.glassFeedbackEnabled).toggleStyle(.switch)
            Text("A glass wave travels in your swipe direction, then your action happens.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !store.screenRippleReady {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Screen access is needed for the real desktop.").font(.system(size: 12, weight: .medium))
                    Text("Each ripple briefly reads one screen frame into memory. No audio, saved images, recording files, or uploads. This sample preview needs no screen access.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Allow desktop ripple…") { store.requestScreenRippleAccess() }.buttonStyle(GlassButton())
                }.padding(15).liquidPanel(radius: 18)
            } else {
                Label("Screen access allowed · frames stay in memory", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Local only · no saved frames").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { commitDurationText(); dismiss() }.buttonStyle(GlassButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 620).background(WindowMaterial())
            .task {
                durationText = String(Int(duration.wrappedValue))
                // Reattach the drawable after the native sheet's opening transition.
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                previewID = UUID()
            }
    }
}
