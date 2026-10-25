import Foundation

extension GesturesTests {
    static func scrollingChecks() throws {
        var rule = GestureRule.twoFingerScrollPreset
        expect(!rule.enabled && rule.steps.count == 1 && rule.steps[0].pose.kind == .victory,
               "Two-finger scrolling is opt-in and uses the existing short pose-stability gate")
        _ = try rule.validated(); rule.enabled = true
        var pinchedVictory = hand(pose: .victory); pinchedVictory.pinchRatio = 0.15
        expect(!pinchedVictory.matches(rule.steps[0].pose, hand: .either, minimum: rule.confidence), "Two-finger scrolling requires thumb/index separation so it cannot share the opening pinch")
        let frame: (Double, Double) -> HandFrame = { time, y in .init(time: time, hands: [hand(0.5, y, pose: .victory)]) }
        func armed(_ configuration: GestureRule? = nil, accepted: Bool = true) -> RecognitionCoordinator {
            let value = configuration ?? rule
            var engine = RecognitionCoordinator()
            for time in [1.0, 1.06, 1.13] {
                _ = engine.process(frame(time, 0.5), rules: [value], selected: value.id, app: "test", optionHeld: true)
            }
            if accepted { engine.resolveAction(value, accepted: true) }
            return engine
        }
        for pose in [PoseKind.open, .pinch, .fist, .point] {
            let frames = [1.0, 1.07, 1.14, 1.21].map { HandFrame(time: $0, hands: [hand(pose: pose)]) }
            expect(matches(frames, rule: rule) == 0, "Other interaction poses cannot arm two-finger scrolling: \(pose.rawValue)")
        }
        var pending = armed(accepted: false)
        let waiting = pending.process(frame(1.18, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect(waiting.scroll == nil && waiting.scrollFeedback?.preparing == true, "Scroll preparation has feedback but cannot send movement before acceptance")
        pending.resolveAction(rule, accepted: true)
        let held = pending.process(frame(1.23, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect(held.scroll?.y == 0 && held.scrollFeedback?.direction == "Ready", "Acceptance discards motion made during the ripple")
        let moved = pending.process(frame(1.28, 0.54), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
        expect((moved.scroll?.y ?? 0) > 0 && moved.scroll?.x == 0 && moved.scrollFeedback?.direction == "Up", "Two fingers drive vertical scrolling and its indicator")

        let cases: [(String, HandFrame)] = [
            ("missing hand", .init(time: 1.18, hands: [])),
            ("second hand", .init(time: 1.18, hands: [hand(pose: .victory), hand(pose: .victory, side: .left)])),
            ("released pose", .init(time: 1.18, hands: [hand(pose: .open)])),
            ("hand swap", .init(time: 1.18, hands: [hand(0.5, 0.51, pose: .victory, side: .left)])),
            ("tracking jump", frame(1.18, 0.8)),
            ("stale gap", frame(1.5, 0.51)),
            ("duplicate timestamp", frame(1.13, 0.51)),
            ("backwards timestamp", frame(1.12, 0.51))
        ]
        for (label, input) in cases {
            var engine = armed()
            let result = engine.process(input, rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            expect(result.scroll == nil && result.scrollFeedback == nil && engine.continuousRule == nil, "Scroll and indicator stop on \(label)")
            engine.resolveAction(rule, accepted: true)
            let late = engine.process(frame(2.2, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            expect(late.scroll == nil && late.match == nil, "Late acceptance cannot revive scrolling after \(label)")
        }
        var unknown = armed()
        let unknownFrame = HandFrame(time: 1.18, hands: [hand(0.5, 0.51, pose: .victory, side: .either)])
        expect(unknown.process(unknownFrame, rules: [rule], selected: rule.id, app: "test", optionHeld: false).scroll != nil,
               "Continuous confident input survives temporarily unknown handedness")
        expect(unknown.process(.init(time: 1.23, hands: [hand(0.5, 0.52, pose: .victory, side: .left)]), rules: [rule], selected: rule.id, app: "test", optionHeld: false).scroll == nil,
               "Unknown handedness does not erase the last known hand identity")
        var twoHands = RecognitionCoordinator()
        var multipleMatched = false
        for time in [1.0, 1.07, 1.14, 1.21] {
            let result = twoHands.process(.init(time: time, hands: [hand(pose: .victory), hand(pose: .victory, side: .left)]), rules: [rule], selected: rule.id, app: "test", optionHeld: false)
            multipleMatched = multipleMatched || result.match != nil
        }
        expect(!multipleMatched && twoHands.continuousRule == nil, "Two visible hands cannot arm scrolling")
        var lowConfidence = armed()
        var uncertain = hand(0.5, 0.51, pose: .victory); uncertain.joints["middleTip"]?.confidence = 0.1
        expect(lowConfidence.process(.init(time: 1.18, hands: [uncertain]), rules: [rule], selected: rule.id, app: "test", optionHeld: false).scroll == nil,
               "Uncertain required fingertip stops scrolling")
        var clutch = rule; clutch.requireOptionKey = true
        var clutched = armed(clutch)
        expect(clutched.process(frame(1.18, 0.52), rules: [clutch], selected: clutch.id, app: "test", optionHeld: false).scroll == nil, "Releasing the Option clutch stops scrolling")
        var edited = armed(); var changed = rule; changed.action.reverseScroll = true
        expect(edited.process(frame(1.18, 0.52), rules: [changed], selected: changed.id, app: "test", optionHeld: false).scroll == nil, "Changing active scroll settings cancels the session")
        var scoped = armed()
        expect(scoped.process(frame(1.18, 0.52), rules: [rule], selected: rule.id, app: "another", optionHeld: false).scroll == nil, "An app change stops global scrolling too")
        var watchdog = armed(); watchdog.stopContinuous(at: 1.4)
        watchdog.resolveAction(rule, accepted: true)
        expect(watchdog.process(frame(1.45, 0.52), rules: [rule], selected: rule.id, app: "test", optionHeld: false).scroll == nil, "The stale-frame watchdog cancels continuous acceptance")

        var motion = ScrollMotion(origin: .init(x: 0.5, y: 0.5))
        let tremors = [0.501, 0.499, 0.5015, 0.4995, 0.5].map { motion.sample(.init(x: 0.5, y: $0), elapsed: 0.03, action: rule.action) }
        expect(tremors.allSatisfy { $0 == 0 }, "Sub-threshold hand tremor produces no scroll events")
        let travel = motion.sample(.init(x: 0.5, y: 0.52), elapsed: 0.03, action: rule.action)
        expect(travel > 0 && travel <= 21, "Scroll speed remains bounded by frame time")
        expect((0..<30).allSatisfy { _ in motion.sample(.init(x: 0.5, y: 0.52), elapsed: 0.03, action: rule.action) == 0 }, "Stopping the hand produces no momentum or queued scroll tail")
        var totals: [Double] = []
        for fps in [30, 60] {
            var sample = ScrollMotion(origin: .init(x: 0.5, y: 0.5)); var total = 0.0
            for i in 1...fps { total += sample.sample(.init(x: 0.5, y: 0.5 + 0.1 * Double(i) / Double(fps)), elapsed: 1 / Double(fps), action: rule.action) }
            totals.append(total)
        }
        expect(abs(totals[0] - totals[1]) <= 1 && totals[0] > 160, "Slow scrolling preserves subpixel motion consistently at different camera frame rates")
        var horizontal = rule; horizontal.action.kind = .scrollHorizontal; horizontal.action.reverseScroll = true
        var sideways = armed(horizontal)
        let reversed = sideways.process(.init(time: 1.18, hands: [hand(0.52, 0.5, pose: .victory)]), rules: [horizontal], selected: horizontal.id, app: "test", optionHeld: false)
        expect((reversed.scroll?.x ?? 0) < 0 && reversed.scroll?.y == 0 && reversed.scrollFeedback?.horizontal == true, "Horizontal axis and reverse direction configure output and feedback together")
        var hidden = rule; hidden.action.scrolling?.showIndicator = false
        var invisible = armed(hidden)
        let invisibleResult = invisible.process(frame(1.18, 0.52), rules: [hidden], selected: hidden.id, app: "test", optionHeld: false)
        expect(invisibleResult.scroll != nil && invisibleResult.scrollFeedback == nil, "Hiding the indicator does not bypass or disable the scroll engine")

        for tolerance in [Double.nan, .infinity, -0.001, 0.02] {
            var invalid = rule; invalid.action.scrolling?.jitterTolerance = tolerance
            rejects("Invalid scroll steadiness is rejected") { _ = try invalid.validated() }
        }
        var legacy = rule; legacy.action.scrolling = nil
        let restored = try JSONDecoder().decode(GestureRule.self, from: JSONEncoder().encode(legacy))
        expect(restored.action.scrolling == nil && restored.action.scrollSettings.jitterTolerance == 0, "Old libraries retain their original sensitivity and decode without new settings")
        let roundTrip = try JSONDecoder().decode(GestureRule.self, from: JSONEncoder().encode(horizontal))
        expect(roundTrip == horizontal, "Configured scrolling survives library serialization")
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("GesturesScrollingTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = GestureStore(storage: storage, observeSystem: false)
        let original = store.library
        store.addTwoFingerScrollPreset(); let chosen = store.selectedID
        store.addTwoFingerScrollPreset()
        expect(store.library == original && store.selectedID == chosen && store.selected?.enabled == false, "Selecting the preset is idempotent and preserves existing definitions with control off")
        store.showScrollPreview = true
        expect(store.isEditing && !store.enabled && !store.cameraRunning, "Synthetic indicator preview pauses control and never starts a camera")
    }
}
