import Foundation

extension GesturesTests {
    static func appSwitchingChecks() throws {
        let preset = GestureRule.appSwitcherPreset
        _ = try preset.validated()
        expect(!preset.enabled && preset.action.kind == .switchApps, "The app-switcher preset starts disabled")
        expect(ActionPlanner.plan(preset.action) == .appPicker, "App switching requires the picker instead of synthesizing a shortcut")
        for direction in [MoveDirection.left, .right] {
            var live = preset; live.enabled = true
            var coordinator = RecognitionCoordinator(); var opened = 0
            for frame in swipeFrames(direction: direction, pose: .pinch) {
                if coordinator.process(frame, rules: [live], selected: live.id, app: "test", optionHeld: false).match != nil { opened += 1 }
            }
            expect(opened == 1, "A deliberate pinch slide opens the picker once from either side: \(direction)")
        }
        expect(matches(swipeFrames(direction: .up, pose: .pinch), rule: preset) == 0, "Vertical pinch movement cannot open the app picker")
        expect(matches(swipeFrames(direction: .left, pose: .open), rule: preset) == 0, "Open-palm Space swipes cannot open the app picker")
        let still = (0..<100).map { HandFrame(time: 1 + Double($0)*0.05, hands: [hand(0.5 + sin(Double($0))*0.008, pose: .pinch)]) }
        expect(matches(still, rule: preset) == 0, "Pinch jitter without a deliberate slide cannot open the picker")

        let targets = (0..<3).map { AppSwitchTarget(id: Int32(770001 + $0), bundleID: "com.example.fixture\($0)", name: "Fixture \($0)", launchedAt: nil) }
        var rule = preset; rule.enabled = true
        func session(_ configured: GestureRule? = nil) -> AppSwitchSession {
            AppSwitchSession(rule: configured ?? rule, targets: targets, frame: .init(time: 10, hands: [hand(0.5, pose: .pinch)]),
                             sourceApp: "com.example.source", currentPID: targets[0].id, practicing: false)!
        }
        func move(_ value: inout AppSwitchSession, count: Int = 3) {
            for i in 1...count { _ = value.process(.init(time: 10 + Double(i)*0.05, hands: [hand(0.5 + Double(i)*0.04, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true) }
        }
        func release(_ value: inout AppSwitchSession, x: Double = 0.62) -> AppSwitchUpdate {
            var result = AppSwitchUpdate.browsing
            for _ in 0..<4 { result = value.process(.init(time: value.lastFrameAt + 0.05, hands: [hand(x, pose: .open)]), app: "com.example.source", optionHeld: true, allowed: true) }
            return result
        }
        var browsing = session(); move(&browsing)
        expect(browsing.selectedIndex == 1 && !browsing.finished, "Horizontal motion selects another app without committing")
        expect(release(&browsing) == .commit(targets[1]), "A sustained, confident open pinch commits the highlighted app")
        expect(browsing.process(.init(time: 10.5, hands: [hand(0.62)]), app: "com.example.source", optionHeld: true, allowed: true) == .cancelled,
               "A finished picker cannot commit a second action")
        var untouched = session()
        expect(release(&untouched, x: 0.5) == .cancelled, "Releasing without browsing cancels instead of activating a default app")
        var jitter = session()
        for i in 1...30 { _ = jitter.process(.init(time: 10 + Double(i)*0.05, hands: [hand(0.5 + sin(Double(i))*0.01, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true) }
        expect(jitter.selectedIndex == 0 && !jitter.finished, "Selection ignores small hand tremors")
        var reverseRule = rule; reverseRule.action.appSwitcher?.reversed = true
        var reversed = session(reverseRule); move(&reversed)
        expect(reversed.selectedIndex == 2, "Reverse direction changes the browsing direction and wraps at the end")
        var sensitiveRule = rule; sensitiveRule.action.appSwitcher?.distancePerApp = 0.04
        var sensitive = session(sensitiveRule); move(&sensitive)
        expect(sensitive.selectedIndex == 2, "Configured travel distance changes selection sensitivity")

        for reason in ["missing hand", "two hands", "wrong hand", "low confidence", "tracking jump", "stale frame", "backwards time", "app changed", "paused", "Option released"] {
            var clutched = rule; clutched.requireOptionKey = true
            var value = session(clutched); move(&value)
            var frame = HandFrame(time: 10.2, hands: [hand(0.62, pose: .pinch)])
            var app = "com.example.source", option = true, allowed = true
            switch reason {
            case "missing hand": frame.hands = []
            case "two hands": frame.hands.append(hand(0.7, pose: .pinch, side: .left))
            case "wrong hand": frame.hands[0].side = .left
            case "low confidence": frame.hands[0].confidence = 0.1
            case "tracking jump": frame.hands[0].palm.x = 0.95
            case "stale frame": frame.time = 10.6
            case "backwards time": frame.time = 10.1
            case "app changed": app = "com.example.other"
            case "paused": allowed = false
            default: option = false
            }
            expect(value.process(frame, app: app, optionHeld: option, allowed: allowed) == .cancelled && value.finished,
                   "Picker cancels without committing on \(reason)")
            expect(release(&value) != .commit(targets[1]), "Later release cannot revive a picker cancelled by \(reason)")
        }
        var uncertain = session(); move(&uncertain)
        for _ in 0..<6 {
            var open = hand(0.62); open.joints["thumbTip"]?.confidence = 0.1
            let result = uncertain.process(.init(time: uncertain.lastFrameAt + 0.05, hands: [open]), app: "com.example.source", optionHeld: true, allowed: true)
            expect(result != .commit(targets[1]), "Uncertain thumb tracking is never interpreted as a deliberate release")
        }
        expect(uncertain.finished, "Uncertain release tracking cancels at its bounded deadline")
        var timeoutRule = rule; timeoutRule.action.appSwitcher?.timeout = 3
        var timed = session(timeoutRule)
        for i in 1...32 { _ = timed.process(.init(time: 10 + Double(i)*0.1, hands: [hand(0.5, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true) }
        expect(timed.finished, "A live but idle hand cannot hold the picker beyond the configured timeout")
        var cancelled = session(); move(&cancelled); cancelled.cancel()
        expect(release(&cancelled) == .cancelled, "Explicit pause or cancellation cannot be undone by release frames")
        var noDefaultFallback = session(); move(&noDefaultFallback)
        _ = noDefaultFallback.process(.init(time: 10.2, hands: [hand(0.62)]), app: "com.example.source", optionHeld: true, allowed: true)
        _ = noDefaultFallback.process(.init(time: 10.25, hands: [hand(0.62, pose: .pinch)]), app: "com.example.source", optionHeld: true, allowed: true)
        expect(!noDefaultFallback.finished, "A brief open-pinch flicker does not commit an app switch")

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
