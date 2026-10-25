import Foundation

extension GesturesTests {
    static func appSwitchingChecks() throws {
        let preset = GestureRule.appSwitcherPreset
        _ = try preset.validated()
        expect(!preset.enabled && preset.action.kind == .switchApps, "The app-switcher preset starts disabled")
        expect(ActionPlanner.plan(preset.action) == .appPicker, "App switching requires the picker instead of synthesizing a shortcut")
        let pinchFrames = (0..<10).map { HandFrame(time: 1 + Double($0)*0.05, hands: [hand(pose: .pinch)]) }
        expect(matches(Array(pinchFrames.prefix(3)), rule: preset) == 0, "A brief pinch still cannot pass the 120 ms stability check")
        expect(matches(Array(pinchFrames.prefix(4)), rule: preset) == 1, "A stable pinch opens the picker without a hidden movement gate")
        var deliberate = preset; deliberate.steps.append(.init(kind: .slide, distance: 0.04))
        for direction in [MoveDirection.left, .right] {
            var live = deliberate; live.enabled = true
            var coordinator = RecognitionCoordinator(); var opened = 0
            for frame in swipeFrames(direction: direction, pose: .pinch) {
                if coordinator.process(frame, rules: [live], selected: live.id, app: "test", optionHeld: false).match != nil { opened += 1 }
            }
            expect(opened == 1, "An optional sideways entry step opens the picker once from either side: \(direction)")
        }
        expect(matches(swipeFrames(direction: .up, pose: .pinch), rule: deliberate) == 0, "An optional sideways entry rejects vertical movement")
        expect(matches(swipeFrames(direction: .left, pose: .open), rule: preset) == 0, "Open-palm Space swipes cannot open the app picker")
        let still = (0..<100).map { HandFrame(time: 1 + Double($0)*0.05, hands: [hand(0.5 + sin(Double($0))*0.008, pose: .pinch)]) }
        expect(matches(still, rule: deliberate) == 0, "An optional sideways entry rejects pinch jitter")

        let targets = (0..<3).map { AppSwitchTarget(id: Int32(770001 + $0), bundleID: "com.example.fixture\($0)", name: "Fixture \($0)", launchedAt: nil) }
        var rule = preset; rule.enabled = true
        func opening(_ configured: GestureRule? = nil) -> AppSwitchSession {
            AppSwitchSession(rule: configured ?? rule, targets: targets, frame: .init(time: 10, hands: [hand(0.5, pose: .pinch)]),
                             sourceApp: "com.example.source", currentPID: targets[0].id, practicing: false)!
        }
        func openHand(_ value: inout AppSwitchSession, x: Double = 0.5) {
            for _ in 0..<4 { _ = value.process(.init(time: value.lastFrameAt + 0.05, hands: [hand(x)]), app: "com.example.source", optionHeld: true, allowed: true) }
        }
        func session(_ configured: GestureRule? = nil) -> AppSwitchSession {
            var value = opening(configured); openHand(&value); return value
        }
        func move(_ value: inout AppSwitchSession, count: Int = 3) {
            for i in 1...count { _ = value.process(.init(time: value.lastFrameAt + 0.05, hands: [hand(0.5 + Double(i)*0.04)]), app: "com.example.source", optionHeld: true, allowed: true) }
        }
        func confirm(_ value: inout AppSwitchSession, x: Double = 0.62) -> AppSwitchUpdate {
            var result = AppSwitchUpdate.browsing
            for _ in 0..<4 { result = value.process(.init(time: value.lastFrameAt + 0.05, hands: [hand(x, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true) }
            return result
        }
        var heldOpening = opening()
        expect(confirm(&heldOpening, x: 0.5) == .browsing && heldOpening.awaitingOpenHand && !heldOpening.finished,
               "The opening pinch cannot also confirm; the picker persists until the hand opens")
        var browsing = session(); move(&browsing)
        expect(browsing.selectedIndex == 1 && !browsing.finished, "Horizontal open-hand motion selects another app without committing")
        openHand(&browsing, x: 0.62)
        expect(!browsing.finished && browsing.selectedIndex == 1, "Relaxing the pinch keeps the selected app visible without switching")
        expect(confirm(&browsing) == .commit(targets[1]), "A second sustained, confident pinch commits the highlighted app")
        expect(browsing.process(.init(time: 10.5, hands: [hand(0.62)]), app: "com.example.source", optionHeld: true, allowed: true) == .cancelled,
               "A finished picker cannot commit a second action")
        var untouched = session()
        expect(confirm(&untouched, x: 0.5) == .browsing && !untouched.finished, "Pinching without browsing keeps the picker open without activating a default app")
        var vertical = session()
        for i in 1...4 { _ = vertical.process(.init(time: vertical.lastFrameAt + 0.05, hands: [hand(0.5, 0.5 + Double(i)*0.02)]), app: "com.example.source", optionHeld: true, allowed: true) }
        expect(confirm(&vertical, x: 0.5) == .browsing && !vertical.finished, "Vertical movement cannot select or activate an app")
        var hiddenTip = hand(pose: .pinch); hiddenTip.joints["thumbTip"]?.confidence = 0.2
        expect(!hiddenTip.matches(.init(kind: .pinch), hand: .either, minimum: 0.55) && hiddenTip.pinchGuidance(minimum: 0.55) == "Show thumb, index, and palm clearly", "Uncertain fingertips stay blocked with useful guidance")
        var jitter = session()
        for i in 1...30 { _ = jitter.process(.init(time: jitter.lastFrameAt + 0.05, hands: [hand(0.5 + sin(Double(i))*0.01)]), app: "com.example.source", optionHeld: true, allowed: true) }
        expect(jitter.selectedIndex == 0 && !jitter.finished, "Selection ignores small hand tremors")
        var reverseRule = rule; reverseRule.action.appSwitcher?.reversed = true
        var reversed = session(reverseRule); move(&reversed)
        expect(reversed.selectedIndex == 2, "Reverse direction changes the browsing direction and wraps at the end")
        var sensitiveRule = rule; sensitiveRule.action.appSwitcher?.distancePerApp = 0.04
        var sensitive = session(sensitiveRule); move(&sensitive)
        expect(sensitive.selectedIndex == 2, "Configured travel distance changes selection sensitivity")

        for reason in ["backwards time", "app changed", "paused", "Option released"] {
            var clutched = rule; clutched.requireOptionKey = true
            var value = session(clutched); move(&value)
            var frame = HandFrame(time: value.lastFrameAt + 0.05, hands: [hand(0.62, pose: .pinch)])
            var app = "com.example.source", option = true, allowed = true
            switch reason {
            case "backwards time": frame.time = value.lastFrameAt - 0.01
            case "app changed": app = "com.example.other"
            case "paused": allowed = false
            default: option = false
            }
            expect(value.process(frame, app: app, optionHeld: option, allowed: allowed) == .cancelled && value.finished,
                   "Picker cancels without committing on \(reason)")
            expect(confirm(&value) != .commit(targets[1]), "A later pinch cannot revive a picker cancelled by \(reason)")
        }
        for reason in ["missing hand", "two hands", "wrong hand", "low confidence", "tracking jump", "stale frame"] {
            var value = session(); move(&value)
            let selection = value.selectedIndex
            var frame = HandFrame(time: value.lastFrameAt + 0.05, hands: [hand(0.62)])
            switch reason {
            case "missing hand": frame.hands = []
            case "two hands": frame.hands.append(hand(0.7, side: .left))
            case "wrong hand": frame.hands[0].side = .left
            case "low confidence": frame.hands[0].confidence = 0.1
            case "tracking jump": frame.hands[0].palm.x = 0.95
            default: frame.time = value.lastFrameAt + 0.6
            }
            expect(value.process(frame, app: "com.example.source", optionHeld: true, allowed: true) == .browsing && value.trackingPaused && !value.finished && value.selectedIndex == selection,
                   "Picker stays visible but freezes selection on \(reason)")
            expect(confirm(&value) == .browsing && value.awaitingOpenHand,
                   "A returning pinch cannot activate an old selection after \(reason)")
            openHand(&value, x: 0.62)
            expect(!value.awaitingOpenHand && value.selectedIndex == selection,
                   "A clear open hand resumes from a fresh anchor after \(reason)")
            expect(confirm(&value) == .commit(targets[selection]), "Only a new deliberate pinch confirms after rearming: \(reason)")
        }
        var uncertain = session(); move(&uncertain)
        for _ in 0..<6 {
            var open = hand(0.62); open.joints["thumbTip"]?.confidence = 0.1
            let result = uncertain.process(.init(time: uncertain.lastFrameAt + 0.05, hands: [open]), app: "com.example.source", optionHeld: true, allowed: true)
            expect(result != .commit(targets[1]), "Uncertain thumb tracking never confirms an app switch")
        }
        expect(uncertain.trackingPaused && !uncertain.finished, "Sustained uncertainty disarms selection while keeping the picker visible")
        expect(confirm(&uncertain) == .browsing, "Uncertain tracking must be rearmed by an open hand before confirmation")
        var timeoutRule = rule; timeoutRule.action.appSwitcher?.timeout = 3
        var timed = session(timeoutRule)
        for _ in 0..<32 { _ = timed.process(.init(time: timed.lastFrameAt + 0.1, hands: []), app: "com.example.source", optionHeld: true, allowed: true) }
        expect(timed.finished, "A persistent picker with no hand still closes at its configured timeout")
        var cancelled = session(); move(&cancelled); cancelled.cancel()
        expect(confirm(&cancelled) == .cancelled, "Explicit Cancel cannot be undone by later pinch frames")
        var noDefaultFallback = session(); move(&noDefaultFallback)
        _ = noDefaultFallback.process(.init(time: noDefaultFallback.lastFrameAt + 0.05, hands: [hand(0.62, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true)
        openHand(&noDefaultFallback, x: 0.62)
        expect(!noDefaultFallback.finished && noDefaultFallback.selectedIndex == 1, "A brief pinch flicker cannot commit or add selection travel")

        for defect in ["open pose", "Release step", "NaN", "out of range", "empty app selection", "invalid app ID", "duplicate app ID"] {
            var invalid = preset
            switch defect {
            case "open pose": invalid.steps[0].pose.kind = .open
            case "Release step": invalid.steps.append(.init(kind: .release))
            case "NaN": invalid.action.appSwitcher?.distancePerApp = .nan
            case "out of range": invalid.action.appSwitcher?.timeout = 100
            case "empty app selection": invalid.action.appSwitcher?.onlyChosenApps = true
            case "invalid app ID": invalid.action.appSwitcher?.bundleIDs = ["bad/path"]
            default: invalid.action.appSwitcher?.bundleIDs = ["com.example.app", "com.example.app"]
            }
            rejects("Switcher rejects \(defect)") { _ = try invalid.validated() }
        }
        var chosen = rule; chosen.action.appSwitcher?.onlyChosenApps = true; chosen.action.appSwitcher?.bundleIDs = [targets[1].bundleID]
        expect(AppSwitchSession(rule: chosen, targets: targets, frame: .init(time: 10, hands: [hand(0.5, pose: .pinch)]), sourceApp: "test", currentPID: nil, practicing: false) == nil,
               "A picker cannot include apps outside its configured allowlist")
        let roundTrip = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(GestureLibrary(rules: [chosen])))
        expect(roundTrip.rules[0].action.appSwitcher == chosen.action.appSwitcher, "Switcher settings survive save and reload")
        let imported = try LibraryIO.merging(roundTrip, into: .init(rules: []))
        expect(imported.rules.count == 1 && !imported.rules[0].enabled, "Imported app switchers remain disabled for review")
        var legacy = GestureRule.examples[0]; legacy.action.appSwitcher = nil
        let legacyData = try JSONEncoder().encode(legacy)
        expect(!String(decoding: legacyData, as: UTF8.self).contains("appSwitcher"), "Legacy gesture encoding remains free of optional switcher settings")
        let oldRule = try JSONDecoder().decode(GestureRule.self, from: legacyData)
        expect(oldRule == legacy && oldRule.action.switcherSettings == .init(), "Old libraries without app-switcher fields still load with safe defaults")
        var repeatable = rule; repeatable.requireNeutral = false
        var coordinator = RecognitionCoordinator()
        coordinator.finishInteractiveAction(repeatable, at: 50)
        expect(coordinator.process(.init(time: 50.1, hands: [hand(pose: .pinch)]), rules: [repeatable], selected: repeatable.id, app: "test", optionHeld: true).progress.message == "Ready in a moment",
               "Completing or cancelling a picker restarts the existing cooldown")
        let runner = ActionRunner()
        let practice = DispatchPermission(enabled: true, testing: true, cameraRunning: true, editing: false, frameAge: 0.02, frontApp: "test")
        rejects("Practice cannot activate an app even with an apparently valid target") { _ = try runner.activate(targets[1], rule: rule, permission: practice) }
        let paused = DispatchPermission(enabled: false, testing: false, cameraRunning: true, editing: false, frameAge: 0.02, frontApp: "test")
        rejects("Paused Mac control cannot activate an app") { _ = try runner.activate(targets[1], rule: rule, permission: paused) }
    }
}
