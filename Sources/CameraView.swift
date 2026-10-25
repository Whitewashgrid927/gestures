import AppKit
import SwiftUI
@preconcurrency import AVFoundation

struct CameraFeed: NSViewRepresentable {
    let pipeline: CameraPipeline
    func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface(); view.preview.session = pipeline.session; view.configureMirroring(); return view
    }
    func updateNSView(_ view: PreviewSurface, context: Context) { view.configureMirroring() }
}
final class PreviewSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; preview.videoGravity = .resizeAspect; layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); preview.frame = bounds; CATransaction.commit(); configureMirroring() }
    func configureMirroring() {
        if let connection = preview.connection, connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
    }
}

struct HandOverlay: View {
    @ObservedObject var tracking: TrackingPresentation
    var body: some View {
        Canvas { context, size in
            let frame = tracking.frame, scale = min(size.width / max(1, frame.width), size.height / max(1, frame.height))
            let width = frame.width * scale, height = frame.height * scale
            let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
            func position(_ point: Point2) -> CGPoint { .init(x: origin.x + point.x * width, y: origin.y + (1 - point.y) * height) }
            for hand in frame.hands {
                for chain in HandGeometry.chains {
                    for i in 1..<chain.count {
                        if let a = hand.joints[chain[i-1]], let b = hand.joints[chain[i]], a.confidence >= 0.45, b.confidence >= 0.45 {
                            var path = Path(); path.move(to: position(a.point)); path.addLine(to: position(b.point)); context.stroke(path, with: .color(.cyan.opacity(0.85)), style: .init(lineWidth: 1.7, lineCap: .round))
                        }
                    }
                }
                for joint in hand.joints.values where joint.confidence >= 0.45 {
                    let p = position(joint.point), r: CGFloat = 3.1
                    context.fill(Path(ellipseIn: .init(x: p.x-r, y: p.y-r, width: r*2, height: r*2)), with: .color(Color(red: 0.8, green: 0.94, blue: 1)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct TrackingBadge: View {
    @ObservedObject var tracking: TrackingPresentation
    var testing: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(tracking.frame.hands.isEmpty ? Color.orange : .green).frame(width: 7, height: 7)
            Text(tracking.progress.message).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.padding(.horizontal, 12).padding(.vertical, 9).liquidPanel(radius: 14)
    }
}
struct TestFeedback: View {
    @ObservedObject var tracking: TrackingPresentation
    let rule: GestureRule?
    var testing = true
    var body: some View {
        VStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                if let rule {
                    ForEach(Array(rule.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 5) {
                            Image(systemName: index < tracking.progress.step || tracking.progress.matched ? "checkmark.circle.fill" : step.symbol)
                            Text(step.label)
                        }.font(.system(size: 10, weight: index == tracking.progress.step ? .semibold : .regular))
                            .foregroundStyle(index <= tracking.progress.step ? Color.blue : .secondary)
                        if index < rule.steps.count - 1 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    }
                }
              }.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Text(tracking.lastMatch.isEmpty ? (testing ? "Practice only · no actions are sent" : "Complete every step to run the action") : tracking.lastMatch)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(tracking.lastMatch.isEmpty ? Color.secondary : .blue)
            if !testing && !tracking.actionStatus.isEmpty { Text(tracking.actionStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            if rule?.action.kind == .switchApps, !tracking.appSwitchResult.isEmpty {
                Text("Last switch: \(tracking.appSwitchResult)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(12).liquidPanel(radius: 15)
    }
}
struct CameraStage: View {
    @ObservedObject var store: GestureStore
    var body: some View {
        ZStack {
            if store.cameraRunning {
                CameraFeed(pipeline: store.camera)
                HandOverlay(tracking: store.tracking)
                VStack {
                    HStack {
                        TrackingBadge(tracking: store.tracking, testing: store.testing)
                        Spacer()
                        Text(store.testing ? "Practice · actions off" : store.enabled ? "Control on" : "Preview only").font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9).liquidPanel(radius: 14)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button { store.stopCamera() } label: { Label("Stop camera", systemImage: "video.slash").font(.system(size: 11)) }.buttonStyle(GlassButton())
                    }
                }.padding(16)
            } else {
                RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [Color(red: 0.76, green: 0.84, blue: 0.99), Color(red: 0.91, green: 0.88, blue: 0.99), Color(red: 0.78, green: 0.87, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(.white.opacity(0.33)).frame(width: 230).blur(radius: 30).offset(x: 150, y: -80)
                VStack(spacing: 15) {
                    Image(systemName: "hand.raised").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(Color.blue.opacity(0.75)).frame(height: 80)
                    Text("Your gestures start here.").font(.system(size: 23, weight: .medium, design: .rounded))
                    Text("Start your camera to define and try a movement.").font(.system(size: 12)).foregroundStyle(.secondary)
                    if store.cameraStatus == .starting { ProgressView().controlSize(.small).padding(9) }
                    else { Button { store.startCamera() } label: { Label("Start camera", systemImage: "video").padding(.horizontal, 5) }.buttonStyle(GlassButton(prominent: true)) }
                    Text("Processed on your Mac. Video is never saved.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
                }.padding(24)
                if case .failed(let message) = store.cameraStatus {
                    VStack { Spacer(); Text(message).font(.system(size: 11)).multilineTextAlignment(.center).padding(14).frame(maxWidth: .infinity).background(.regularMaterial) }
                }
            }
            if store.recording {
                Color.black.opacity(0.2)
                VStack(spacing: 12) {
                    Text(String(store.recordingSeconds)).font(.system(size: 48, weight: .light, design: .rounded))
                    Text("Make one swipe, then hold its end position").font(.system(size: 13))
                    Button("Cancel") { store.cancelRecording() }.buttonStyle(GlassButton())
                }.padding(22).liquidPanel(radius: 22)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.4), lineWidth: 1))
    }
}
