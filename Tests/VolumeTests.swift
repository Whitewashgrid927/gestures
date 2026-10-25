import AppKit
import Foundation

@MainActor private final class FakeVolumeDevice: OutputVolumeDevice {
    var state = OutputVolume(device: 1, uid: "test-output", level: 0.5, muted: false)
    var reads = 0
    var writes: [Double] = []
    var reject = false
    var acknowledge = true
    func read() throws -> OutputVolume { reads += 1; if reject { throw GestureError("Unsupported output") }; return state }
    func write(_ level: Double, expecting: OutputVolume) throws {
        guard !reject, state == expecting else { throw GestureError("Changed output") }
        writes.append(level)
        if acknowledge { state = .init(device: state.device, uid: state.uid, level: level, muted: state.muted) }
    }
}

extension GesturesTests {
    static func volumeChecks() throws {
        // Actual geometry, rather than preclassified synthetic finger states: a closed
        // finger can have a confident knuckle bend while its tip is hidden in the palm.
        var joints: [String: Landmark] = ["wrist": .init(point: .init(x: 0.5, y: 0.2), confidence: 0.95)]
        for (i, prefix) in ["index", "middle", "ring", "little"].enumerated() {
            let x = 0.35 + Double(i) * 0.1
            joints[prefix + "MCP"] = .init(point: .init(x: x, y: 0.4), confidence: 0.95)
            joints[prefix + "PIP"] = .init(point: .init(x: x, y: 0.58), confidence: 0.95)
            joints[prefix + "DIP"] = .init(point: .init(x: x + 0.04, y: 0.48), confidence: 0.95)
            joints[prefix + "Tip"] = .init(point: .init(x: x + 0.02, y: 0.35), confidence: 0.1)
        }
        let fist = PoseDefinition(kind: .fist)
        let measured = HandGeometry.measure(joints: joints, side: .right, aspect: 16.0 / 9)
        expect(measured?.matches(fist, hand: .either, minimum: 0.55) == true, "Four confident visible bends establish a fist even with hidden fingertips")
        var missingTips = joints
        for prefix in ["index", "middle", "ring", "little"] { missingTips[prefix + "Tip"] = nil }
        expect(HandGeometry.measure(joints: missingTips, side: .right, aspect: 16.0 / 9)?.matches(fist, hand: .either, minimum: 0.55) == true, "A measured fist does not require imaginary fingertip coordinates")
        for prefix in ["index", "middle", "ring", "little"] {
            var uncertain = joints; uncertain[prefix + "DIP"]?.confidence = 0.54
            let value = HandGeometry.measure(joints: uncertain, side: .right, aspect: 16.0 / 9)
            expect(value?.matches(fist, hand: .either, minimum: 0.55) == false, "A weak visible bend still blocks the fist: \(prefix)")
            expect(value?.fistGuidance(minimum: 0.55).contains(prefix) == true, "Fist guidance identifies the finger that needs visibility: \(prefix)")
            var straight = missingTips
            let straightX = straight[prefix + "PIP"]!.point.x
            straight[prefix + "DIP"]?.point = .init(x: straightX, y: 0.7)
            expect(HandGeometry.measure(joints: straight, side: .right, aspect: 16.0 / 9)?.matches(fist, hand: .either, minimum: 0.55) == false, "Missing tip plus a straight joint is never assumed curled: \(prefix)")
        }
        var incomplete = missingTips; incomplete["ringDIP"] = nil
        expect(HandGeometry.measure(joints: incomplete, side: .right, aspect: 16.0 / 9)?.matches(fist, hand: .either, minimum: 0.55) == false, "Three bent fingers are insufficient for a fist")
        var collapsed = joints; let collapsedPoint = collapsed["indexPIP"]!.point
        collapsed["indexDIP"]?.point = collapsedPoint; collapsed["indexTip"] = nil
        expect(HandGeometry.measure(joints: collapsed, side: .right, aspect: 16.0 / 9)?.matches(fist, hand: .either, minimum: 0.55) == false, "Collapsed joint coordinates cannot provide bend evidence")
        if let measured {
            var realistic = GestureRule.volumePreset; realistic.enabled = true
            expect(matches([1.0, 1.06, 1.13].map { .init(time: $0, hands: [measured]) }, rule: realistic) == 1,
                   "Measured fist geometry completes the stable-pose gate")
        }
        var rule = GestureRule.volumePreset
        var diagnostic = VolumeRecognitionCheck()
        diagnostic.observe(.init(time: 1, hands: [], detectedHands: 1), rule: rule, progress: .init(), accepted: false)
        expect(diagnostic.summary.contains("palm could not be tracked"), "Diagnostic distinguishes a discarded palm from no Vision detection")
        var partial = hand(pose: .fist); partial.fingers[.ring] = .extended; partial.confidence = 0.62
        diagnostic.observe(.init(time: 2, hands: [partial]), rule: rule, progress: .init(), accepted: false)
        let strongest = diagnostic.summary
        diagnostic.observe(.init(time: 3, hands: [hand(pose: .open)]), rule: rule, progress: .init(), accepted: false)
        diagnostic.observe(.init(time: 4, hands: []), rule: rule, progress: .init(), accepted: false)
        expect(diagnostic.summary == strongest && strongest.contains("3/4 bent"), "Lowering or opening the hand does not overwrite the strongest fist diagnostic")
        diagnostic.observe(.init(time: 5, hands: [hand(pose: .fist)]), rule: rule, progress: .init(fraction: 0.5), accepted: false)
        expect(diagnostic.summary.contains("held 60/120 ms"), "Diagnostic reports the actual stability progress")
        diagnostic.observe(.init(time: 6, hands: [hand(pose: .fist)]), rule: rule, progress: .init(fraction: 1), accepted: true)
        expect(diagnostic.summary == "Fist recognition passed this attempt.", "Accepted recognition is reported independently of volume dispatch")
        diagnostic = .init()
        expect(diagnostic.summary.contains("no hand detected"), "Starting another attempt clears the in-memory diagnostic")
        expect(!rule.enabled && rule.steps.count == 1 && rule.steps[0].pose.kind == .fist, "Fist volume is opt-in with the existing brief pose stability gate")
        rule.enabled = true; _ = try rule.validated()
        let frame: (Double, Double) -> HandFrame = { time, y in .init(time: time, hands: [hand(0.5, y, pose: .fist)]) }
        func weakFrame(_ time: Double, _ y: Double = 0.5) -> HandFrame {
            var value = hand(0.5, y, pose: .fist); value.joints["ringTip"]?.confidence = 0.1
            return .init(time: time, hands: [value])
        }
        let flicker = [frame(1, 0.5), weakFrame(1.03), frame(1.07, 0.5), weakFrame(1.1), frame(1.14, 0.5)]
        expect(matches(flicker, rule: rule) == 1, "Three confident fist observations arm across brief finger-confidence flicker")
        expect(matches([frame(1, 0.5), weakFrame(1.05), weakFrame(1.1), frame(1.14, 0.5)], rule: rule) == 0,
               "Uncertain observations cannot replace the three positive fist observations")
        expect(matches([frame(1, 0.5), weakFrame(1.1), weakFrame(1.2), frame(1.22, 0.5), frame(1.27, 0.5)], rule: rule) == 0,
               "An uncertainty gap beyond 150 ms resets fist arming")
        var opened = hand(0.5, 0.5, pose: .fist); opened.fingers[.index] = .extended
        expect(matches([frame(1, 0.5), frame(1.06, 0.5), .init(time: 1.1, hands: [opened]), frame(1.14, 0.5)], rule: rule) == 0,
               "One confidently opened finger resets fist arming")
        func armed(_ configuration: GestureRule? = nil, accepted: Bool = true) -> RecognitionCoordinator {
            let value = configuration ?? rule; var engine = RecognitionCoordinator()
            for time in [1.0, 1.06, 1.13] { _ = engine.process(frame(time, 0.5), rules: [value], selected: value.id, app: "test", optionHeld: true) }
            if accepted { engine.resolveAction(value, accepted: true) }; return engine
        }
        var pending = armed(accepted: false)
        expect(pending.process(frame(1.18, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false).volume == nil, "Pending volume cannot move before acceptance")
        pending.resolveAction(rule, accepted: true)
        expect(pending.process(frame(1.23, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false).volume == 0, "Ripple preparation motion is discarded for volume")
        let moved = pending.process(frame(1.28, 0.54), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect((moved.volume ?? 0) > 0 && moved.scroll == nil && moved.scrollFeedback == nil, "Fist volume produces scalar movement, never scrolling")
        let cases: [(String, HandFrame)] = [
            ("release", .init(time: 1.18, hands: [hand(pose: .open)])),
            ("loss", .init(time: 1.18, hands: [])),
            ("second hand", .init(time: 1.18, hands: [hand(pose: .fist), hand(pose: .fist, side: .left)])),
            ("untracked second observation", .init(time: 1.18, hands: [hand(0.5, 0.5, pose: .fist)], detectedHands: 2)),
            ("opened finger", .init(time: 1.18, hands: [opened])),
            ("hand swap", .init(time: 1.18, hands: [hand(0.5, 0.51, pose: .fist, side: .left)])),
            ("jump", frame(1.18, 0.8)), ("stale", frame(1.5, 0.52)), ("duplicate time", frame(1.13, 0.52)), ("backwards", frame(1.12, 0.52))
        ]
        for (label, input) in cases {
            var engine = armed(); let result = engine.process(input, rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            expect(result.volume == nil && engine.continuousRule == nil, "Volume stops on \(label)")
            engine.resolveAction(rule, accepted: true)
            expect(engine.process(frame(2, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false).match == nil, "Late callbacks cannot revive volume after \(label)")
        }
        var clutch = rule; clutch.requireOptionKey = true; var engine = armed(clutch)
        expect(engine.process(frame(1.18, 0.52), rules: [clutch], selected: clutch.id, app: "test", optionHeld: false).volume == nil, "Volume stops on Option release")
        engine = armed(); var edited = rule; edited.action.volume?.maximum = 0.6
        expect(engine.process(frame(1.18, 0.52), rules: [edited], selected: edited.id, app: "test", optionHeld: false).volume == nil, "Editing active volume settings cancels the session")
        engine = armed()
        expect(engine.process(frame(1.18, 0.52), rules: [rule], selected: rule.id, app: "another", optionHeld: false).volume == nil, "Global volume cancels on foreground changes too")
        engine = armed()
        let paused = engine.process(weakFrame(1.18, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect(paused.volume == 0 && engine.continuousRule != nil && engine.continuousNeedsConfidence,
               "Brief finger uncertainty freezes volume while retaining the indicator")
        let deadline = engine.continuousConfidenceDeadline
        expect(deadline.map { abs($0 - 1.28) < 1e-9 } == true, "Uncertainty deadline is bounded from the last confident observation")
        let stillPaused = engine.process(weakFrame(1.23, 0.54), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect(stillPaused.volume == 0 && engine.continuousConfidenceDeadline == deadline, "Repeated weak observations cannot extend the pause deadline")
        let recovered = engine.process(frame(1.26, 0.56), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect(recovered.volume == 0 && !engine.continuousNeedsConfidence, "Recovery discards movement made while confidence was low")
        expect(engine.process(frame(1.3, 0.56), rules: [rule], selected: rule.id, app: "test", optionHeld: false).volume == 0, "Recovery has no delayed movement tail")
        expect((engine.process(frame(1.34, 0.58), rules: [rule], selected: rule.id, app: "test", optionHeld: false).volume ?? 0) > 0, "New confident movement resumes volume control")
        for input in [weakFrame(1.29, 0.54), frame(1.29, 0.54)] {
            engine = armed(); _ = engine.process(weakFrame(1.18, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            let expired = engine.process(input, rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            expect(expired.volume == nil && engine.continuousRule == nil, "Expired uncertainty stops even when a clear frame arrives late")
        }
        var lowPalm = weakFrame(1.18, 0.52); lowPalm.hands[0].confidence = 0.4
        engine = armed()
        expect(engine.process(lowPalm, rules: [rule], selected: rule.id, app: "test", optionHeld: false).volume == 0 && engine.continuousNeedsConfidence,
               "Low palm confidence can pause but cannot authorize volume movement")
        var ambiguous = RecognitionCoordinator(); var ambiguousMatch = false
        for time in [1.0, 1.06, 1.13] {
            var input = frame(time, 0.5); input.detectedHands = 2
            ambiguousMatch = ambiguousMatch || ambiguous.process(input, rules: [rule], selected: rule.id, app: "test", optionHeld: false).match != nil
        }
        expect(!ambiguousMatch && ambiguous.continuousRule == nil, "A second detected hand blocks volume arming even if its palm is untracked")
        var pinch = GestureRule.appSwitcherPreset; pinch.enabled = true
        var closed = hand(pose: .fist); closed.pinchRatio = 0.15
        var priority = RecognitionCoordinator(); var winner: ActionKind?
        for time in [1.0, 1.06, 1.13] { winner = priority.process(.init(time: time, hands: [closed]), rules: [pinch, rule], selected: rule.id, app: "test", optionHeld: false).match?.rule.action.kind ?? winner }
        expect(winner == .volume, "A fist with touching thumb/index does not open the pinch picker")
        rule.enabled = false; priority.reset(); winner = nil
        for time in [1.0, 1.06, 1.13] { winner = priority.process(.init(time: time, hands: [closed]), rules: [pinch, rule], selected: pinch.id, app: "test", optionHeld: false).match?.rule.action.kind ?? winner }
        expect(winner == .switchApps, "A disabled volume preset cannot change existing pinch recognition"); rule.enabled = true

        let settings = VolumeSettings()
        expect(settings.target(from: 0.9, delta: 0.02) == 0.9 && settings.target(from: 0.9, delta: -0.02) == 0.88, "Engaging above the ceiling never jumps down or raises volume")
        expect(settings.target(from: 0.79, delta: 0.02) == 0.8 && settings.target(from: 0.01, delta: -0.02) == 0, "Volume respects ceiling and zero")
        var motion = VolumeMotion(origin: .init(x: 0.5, y: 0.5))
        expect([0.501, 0.499, 0.502, 0.5].allSatisfy { motion.sample(.init(x: 0.5, y: $0), elapsed: 0.03, settings: settings) == 0 }, "Volume steadiness absorbs small tremors")
        let step = motion.sample(.init(x: 0.5, y: 0.6), elapsed: 0.03, settings: settings)
        expect(step > 0 && step <= 0.0105, "Volume rate is bounded by elapsed time")
        expect((0..<20).allSatisfy { _ in abs(motion.sample(.init(x: 0.5, y: 0.6), elapsed: 0.03, settings: settings)) < 1e-12 }, "No residual volume tail when the hand stops")
        var horizontal = settings; horizontal.axis = .horizontal; horizontal.reversed = true
        motion = .init(origin: .init(x: 0.5, y: 0.5))
        expect(motion.sample(.init(x: 0.52, y: 0.5), elapsed: 0.05, settings: horizontal) < 0, "Axis and reversal configure volume direction")
        for invalid in [Double.nan, .infinity, -1, 4] {
            var bad = rule; bad.action.volume?.sensitivity = invalid; rejects("Invalid volume sensitivity rejected") { _ = try bad.validated() }
            bad = rule; bad.action.volume?.maximum = invalid; rejects("Invalid volume ceiling rejected") { _ = try bad.validated() }
            bad = rule; bad.action.volume?.jitterTolerance = invalid; rejects("Invalid volume steadiness rejected") { _ = try bad.validated() }
        }
        var release = rule; release.steps.append(.init(kind: .release)); rejects("Volume cannot wait for a release before starting") { _ = try release.validated() }
        let decoded = try JSONDecoder().decode(GestureRule.self, from: JSONEncoder().encode(rule))
        expect(decoded == rule, "Volume configuration round trips")
        var legacy = GestureRule.twoFingerScrollPreset; legacy.action.volume = nil
        let legacyDecoded = try JSONDecoder().decode(GestureRule.self, from: JSONEncoder().encode(legacy))
        expect(legacyDecoded.action.volume == nil, "Older saved rules decode without volume settings")

        let fake = FakeVolumeDevice(); let control = VolumeController(device: fake)
        var permission = DispatchPermission(enabled: true, testing: false, cameraRunning: true, editing: false, frameAge: 0.02, frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        try control.begin(rule, practicing: true, permission: permission, at: 1)
        try control.change(0.02, rule: rule, permission: permission, at: 1.1)
        expect(fake.reads == 0 && fake.writes.isEmpty && (control.feedback?.level ?? 0) > 0.5, "Practice simulates the indicator without reading or writing audio devices")
        control.cancel()
        try control.begin(rule, practicing: false, permission: permission, at: 2)
        expect(fake.writes.isEmpty && control.feedback?.level == 0.5, "Arming reads the starting volume without a jump")
        try control.change(1, rule: rule, permission: permission, at: 2.05)
        expect(fake.writes.count == 1 && abs(fake.writes[0] - 0.5175) < 1e-9, "Final driver boundary bounds oversized requests")
        try control.change(0, rule: rule, permission: permission, at: 2.1)
        expect(fake.writes.count == 1 && abs((control.feedback?.level ?? 0) - 0.5175) < 1e-9, "Indicator uses readback and stillness issues no writes")
        fake.state = .init(device: 2, uid: "another-output", level: 0.2, muted: false)
        rejects("Changing output cancels instead of applying an old baseline") { try control.change(0.01, rule: rule, permission: permission, at: 2.15) }
        expect(control.feedback == nil && fake.writes.count == 1, "Output change clears volume session")
        fake.state = .init(device: 1, uid: "test-output", level: 0.5, muted: true)
        try control.begin(rule, practicing: false, permission: permission, at: 3)
        try control.change(0.02, rule: rule, permission: permission, at: 3.1)
        expect(fake.writes.count == 1 && control.feedback?.muted == true, "Muted output remains untouched")
        fake.state = .init(device: 1, uid: "test-output", level: 0.5, muted: false)
        rejects("Unmuting elsewhere requires rearming") { try control.change(0.02, rule: rule, permission: permission, at: 3.2) }
        try control.begin(rule, practicing: false, permission: permission, at: 4)
        fake.state = .init(device: 1, uid: "test-output", level: 0.6, muted: false)
        rejects("A hardware or system volume adjustment cancels the gesture") { try control.change(0.01, rule: rule, permission: permission, at: 4.1) }
        fake.reject = true
        rejects("Unsupported outputs fail closed") { try control.begin(rule, practicing: false, permission: permission, at: 5) }; fake.reject = false
        permission.enabled = false
        rejects("Paused control cannot arm volume") { try control.begin(rule, practicing: false, permission: permission, at: 6) }
        permission.enabled = true; permission.testing = true
        rejects("Practice permission cannot arm a real device") { try control.begin(rule, practicing: false, permission: permission, at: 6) }
        permission.testing = false
        try control.begin(rule, practicing: false, permission: permission, at: 6)
        permission.editing = true
        rejects("Opening settings blocks volume writes") { try control.change(0.02, rule: rule, permission: permission, at: 6.1) }
        permission.editing = false
        fake.acknowledge = false
        try control.begin(rule, practicing: false, permission: permission, at: 7)
        try control.change(0.02, rule: rule, permission: permission, at: 7.1)
        let count = fake.writes.count
        try control.change(0.02, rule: rule, permission: permission, at: 7.2)
        expect(fake.writes.count == count, "Unacknowledged changes never accumulate more writes")
        try control.change(0, rule: rule, permission: permission, at: 7.3)
        rejects("Missing audio acknowledgment times out") { try control.change(0, rule: rule, permission: permission, at: 7.4) }
        fake.acknowledge = true
        try control.begin(rule, practicing: false, permission: permission, at: 8)
        rejects("Nonfinite volume movement cancels") { try control.change(.nan, rule: rule, permission: permission, at: 8.1) }
        try control.begin(rule, practicing: false, permission: permission, at: 9)
        rejects("Stale volume frames cancel at the device boundary") { try control.change(0.02, rule: rule, permission: permission, at: 9.3) }
        try control.begin(rule, practicing: false, permission: permission, at: 10)
        control.cancel()
        rejects("Cancelled volume cannot be revived by late movement") { try control.change(0.02, rule: rule, permission: permission, at: 10.1) }
        fake.state = .init(device: 1, uid: "test-output", level: .nan, muted: false)
        rejects("Invalid hardware readings cannot arm volume") { try control.begin(rule, practicing: false, permission: permission, at: 11) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GesturesVolumeTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GestureStore(storage: folder.appendingPathComponent("Library.gestures"), observeSystem: false)
        let original = store.library; store.addVolumePreset(); let chosen = store.selectedID; store.addVolumePreset()
        expect(store.selectedID == chosen && store.library == original, "Selecting the built-in volume preset is idempotent and preserves the library")
        store.showVolumePreview = true
        expect(store.isEditing && !store.enabled && !store.testing, "Volume preview pauses control and simulates sound only")
    }
}
