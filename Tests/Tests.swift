import AppKit
import Foundation
import ImageIO
import SwiftUI
import MetalKit
import CoreVideo
import Carbon

@main @MainActor
struct GesturesTests {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message); print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ work: () throws -> Void) {
        checks += 1
        do { try work(); failures.append(message); print("FAIL: \(message)") } catch {}
    }
    static func hand(_ x: Double = 0.7, _ y: Double = 0.5, pose: PoseKind = .open, side: HandChoice = .right) -> TrackedHand {
        let definition = PoseDefinition(kind: pose)
        let joints = Dictionary(uniqueKeysWithValues: HandGeometry.names.map { ($0.0, Landmark(point: .init(x: x, y: y), confidence: 0.95)) })
        return .init(side: side, joints: joints, palm: .init(x: x, y: y), confidence: 0.95, fingers: Dictionary(uniqueKeysWithValues: Finger.allCases.map { ($0, definition.requirement($0) == .any ? .extended : definition.requirement($0)) }), pinchRatio: pose == .pinch ? 0.15 : 1.2)
    }
    static func swipeFrames(direction: MoveDirection = .left, pose: PoseKind = .open, start: Double = 1) -> [HandFrame] {
        var frames = (0..<15).map { HandFrame(time: start + Double($0)*0.05, hands: [hand(pose: pose)]) }
        frames += (1...12).map { i in
            let p = Point2(x: 0.7, y: 0.5) + direction.vector * (Double(i)*0.025)
            return HandFrame(time: start + 0.7 + Double(i)*0.05, hands: [hand(p.x, p.y, pose: pose)])
        }
        return frames
    }
    static func matches(_ frames: [HandFrame], rule: GestureRule) -> Int {
        var recognizer = GestureRecognizer()
        return frames.filter { recognizer.process($0, rule: rule).matched }.count
    }
    static func main() throws {
        let rule = GestureRule.examples[0]
        _ = try GestureLibrary().validated()
        expect(matches(swipeFrames(), rule: rule) == 1, "A deliberate left swipe completes once")
        expect(matches(swipeFrames(direction: .right), rule: rule) == 0, "Opposite movement cannot trigger left swipe")
        expect(matches(swipeFrames(direction: .up), rule: rule) == 0, "Perpendicular movement cannot trigger left swipe")
        expect(matches(swipeFrames(pose: .fist), rule: rule) == 0, "Wrong starting pose cannot trigger")
        expect(matches((0..<300).map { .init(time: 1 + Double($0)*0.05, hands: [hand(0.7 + sin(Double($0))*0.012)]) }, rule: rule) == 0, "Stationary hand jitter never triggers a swipe")
        var quickSwipe = rule; quickSwipe.steps.removeAll { $0.kind == .hold }
        let quickFrames = (0..<5).map { HandFrame(time: 1 + Double($0)*0.05, hands: [hand()]) } + (1...10).map { HandFrame(time: 1.2 + Double($0)*0.05, hands: [hand(0.7 - Double($0)*0.025)]) }
        expect(matches(quickFrames, rule: quickSwipe) == 1, "Pose then movement completes without an extra hold step")
        expect(matches(Array(quickFrames.prefix(9)), rule: quickSwipe) == 0, "A short partial movement cannot complete the simpler swipe")
        expect(matches((0..<300).map { .init(time: 1 + Double($0)*0.05, hands: [hand(0.7 + sin(Double($0))*0.012)]) }, rule: quickSwipe) == 0, "Removing the optional hold does not turn hand jitter into a swipe")
        var wrongSide = rule; wrongSide.hand = .left
        expect(matches(swipeFrames(), rule: wrongSide) == 0, "Hand selection excludes the other hand")
        var uncertain = swipeFrames(); for i in uncertain.indices { uncertain[i].hands[0].confidence = 0.2 }
        expect(matches(uncertain, rule: rule) == 0, "Low confidence cannot trigger")
        var badFinger = hand(); badFinger.joints["indexTip"]?.confidence = 0.4
        expect(!badFinger.matches(.init(), hand: .either, minimum: 0.55), "A low-confidence required finger cannot satisfy a pose")
        expect(!hand().matches(.init(kind: .pinch), hand: .either, minimum: 0.55), "Open thumb/index is not a pinch")
        expect(hand(pose: .pinch).matches(.init(kind: .pinch), hand: .either, minimum: 0.55), "Close thumb/index satisfies pinch")
        var custom = PoseDefinition(kind: .custom); custom.index = .extended; custom.middle = .curled; custom.ring = .curled; custom.little = .curled
        expect(hand(pose: .point).matches(custom, hand: .right, minimum: 0.55), "Custom per-finger pose is recognized")
        expect(!hand(pose: .open).matches(custom, hand: .right, minimum: 0.55), "Custom pose rejects different fingers")
        var gap = swipeFrames(); for i in 13..<gap.count { gap[i].time += 1 }
        expect(matches(gap, rule: rule) == 0, "A dropped camera stream clears a partially completed gesture")
        var lost = swipeFrames(); for i in 13..<18 { lost[i].hands = [] }
        expect(matches(lost, rule: rule) == 0, "Lost hand tracking clears a partial movement")
        var late = rule; late.steps[2].maximumDuration = 0.2
        expect(matches(swipeFrames(), rule: late) == 0, "Movement timeout prevents delayed completion")
        var releaseRule = rule; releaseRule.steps.append(.init(kind: .release, duration: 0.2))
        expect(matches(swipeFrames(), rule: releaseRule) == 0, "Release step defers dispatch while pose is present")
        let released = swipeFrames() + (1...10).map { HandFrame(time: 2.3 + Double($0)*0.05, hands: []) }
        expect(matches(released, rule: releaseRule) == 1, "Release completes after deliberate sequence and sustained absence")
        var twoMoves = rule; twoMoves.steps.append(.init(kind: .move, direction: .up, distance: 0.15))
        let elbow = Array(swipeFrames().prefix(23)) + (1...10).map { HandFrame(time: 2.1 + Double($0)*0.05, hands: [hand(0.5, 0.5 + Double($0)*0.025)]) }
        expect(matches(elbow, rule: twoMoves) == 1, "A two-direction custom path completes in order")
        var poseOnly = rule; poseOnly.steps = [.init(kind: .pose)]; poseOnly.requireNeutral = true
        var c = RecognitionCoordinator(); var total = 0
        for frame in (0..<100).map({ HandFrame(time: 10 + Double($0)*0.05, hands: [hand()]) }) { if c.process(frame, rules: [poseOnly], selected: poseOnly.id, app: "test", optionHeld: false).match != nil { total += 1 } }
        expect(total == 1, "Holding a completed pose does not repeatedly fire")
        for i in 0..<10 { _ = c.process(.init(time: 15 + Double(i)*0.05, hands: []), rules: [poseOnly], selected: poseOnly.id, app: "test", optionHeld: false) }
        for i in 0..<10 { if c.process(.init(time: 15.5 + Double(i)*0.05, hands: [hand()]), rules: [poseOnly], selected: poseOnly.id, app: "test", optionHeld: false).match != nil { total += 1 } }
        expect(total == 2, "Lowering and raising the hand rearms a gesture")
        c.reset(); var acrossApps = 0
        for i in 0..<10 { if c.process(.init(time: 20 + Double(i)*0.05, hands: [hand()]), rules: [poseOnly], selected: poseOnly.id, app: "first", optionHeld: false).match != nil { acrossApps += 1 } }
        c.activeAppChanged(to: "second", at: 20.5)
        for i in 0..<35 { if c.process(.init(time: 20.5 + Double(i)*0.05, hands: [hand()]), rules: [poseOnly], selected: poseOnly.id, app: "second", optionHeld: false).match != nil { acrossApps += 1 } }
        expect(acrossApps == 1, "Switching apps after an action preserves neutral-hand rearming")
        for i in 0..<8 { _ = c.process(.init(time: 22.3 + Double(i)*0.05, hands: []), rules: [poseOnly], selected: poseOnly.id, app: "second", optionHeld: false) }
        for i in 0..<10 { if c.process(.init(time: 22.8 + Double(i)*0.05, hands: [hand()]), rules: [poseOnly], selected: poseOnly.id, app: "second", optionHeld: false).match != nil { acrossApps += 1 } }
        expect(acrossApps == 2, "Lowering the hand rearms a background gesture in the new app")
        c.reset(); var repeatable = poseOnly; repeatable.requireNeutral = false; repeatable.cooldown = 2
        for i in 0..<10 { _ = c.process(.init(time: 30 + Double(i)*0.05, hands: [hand()]), rules: [repeatable], selected: repeatable.id, app: "first", optionHeld: false) }
        expect((0..<20).allSatisfy { c.process(.init(time: 30.5 + Double($0)*0.05, hands: [hand()]), rules: [repeatable], selected: repeatable.id, app: "second", optionHeld: false).match == nil }, "App changes cannot bypass the repeat cooldown")
        var scoped = poseOnly; scoped.id = UUID(); scoped.scope = .init(bundleID: "com.example.editor", name: "Editor"); scoped.action.kind = .previousSpace
        c.reset(); var winner: UUID?
        for i in 0..<10 { if let match = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand()]), rules: [poseOnly, scoped], selected: poseOnly.id, app: "com.example.editor", optionHeld: false).match { winner = match.rule.id } }
        expect(winner == scoped.id, "App-specific match wins over simultaneous global match")
        c.reset(); winner = nil
        for i in 0..<10 { if let match = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand()]), rules: [scoped], selected: scoped.id, app: "com.example.other", optionHeld: false).match { winner = match.rule.id } }
        expect(winner == nil, "App scope blocks a gesture in other apps")
        c.reset(); var disabled = poseOnly; disabled.enabled = false
        expect((0..<10).allSatisfy { c.process(.init(time: 1 + Double($0)*0.05, hands: [hand()]), rules: [disabled], selected: disabled.id, app: "test", optionHeld: false).match == nil }, "Disabled rules cannot dispatch")
        c.reset(); var clutch = poseOnly; clutch.requireOptionKey = true
        expect((0..<10).allSatisfy { c.process(.init(time: 1 + Double($0)*0.05, hands: [hand()]), rules: [clutch], selected: clutch.id, app: "test", optionHeld: false).match == nil }, "Option clutch blocks recognition while released")
        expect((0..<10).contains { c.process(.init(time: 2 + Double($0)*0.05, hands: [hand()]), rules: [clutch], selected: clutch.id, app: "test", optionHeld: true).match != nil }, "Holding Option allows the configured gesture")
        c.reset(); var scroll = GestureRule.examples[2]; scroll.enabled = true
        var scrollStarted = false
        for i in 0..<15 { let result = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand(pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false); scrollStarted = scrollStarted || result.match != nil }
        expect(scrollStarted, "Pinch-and-hold begins continuous scrolling")
        let pendingScroll = c.process(.init(time: 1.72, hands: [hand(0.7, 0.5, pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false)
        expect(pendingScroll.scroll == nil && pendingScroll.scrollRule == nil, "Recognition alone cannot emit scroll events while its initial action is pending")
        c.resolveAction(scroll, accepted: true)
        let delta = c.process(.init(time: 1.78, hands: [hand(0.7, 0.52, pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false)
        expect(abs((delta.scroll?.y ?? 999) - 34) < 0.0001 && delta.scroll?.x == 0, "Vertical scroll follows measured hand movement")
        let practiceGate = DispatchPermission(enabled: true, testing: true, cameraRunning: true, editing: false, frameAge: 0.02, frontApp: "test")
        expect(delta.progress.message == "Move to scroll · release to stop" && !practiceGate.allows(scroll), "Simulated continuous acceptance supplies Practice feedback while its dispatch gate remains closed")
        let capped = c.process(.init(time: 1.8, hands: [hand(0.7, 0.65, pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false)
        expect(abs(capped.scroll?.y ?? 999) <= 35.00001, "Scrolling speed is bounded per frame")
        let stopped = c.process(.init(time: 1.85, hands: []), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false)
        expect(stopped.scroll == nil && stopped.progress.message == "Scrolling stopped", "Tracking loss immediately stops scrolling")
        for cancel in [false, true] {
            c.reset()
            for i in 0..<15 { _ = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand(pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false) }
            if cancel { c.cancelPendingAction() } else { c.resolveAction(scroll, accepted: false) }
            c.resolveAction(scroll, accepted: true) // A late callback cannot revive rejected work.
            expect((0..<20).allSatisfy {
                let result = c.process(.init(time: 1.75 + Double($0)*0.05, hands: [hand(0.7, 0.52, pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false)
                return result.scroll == nil && result.match == nil
            }, "Rejected or cancelled scroll start stays stopped until the hand is lowered: \(cancel)")
        }
        c.reset()
        for i in 0..<15 { _ = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand(pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false) }
        c.activeAppChanged(to: "another", at: 1.71)
        let switchedScroll = c.process(.init(time: 1.75, hands: [hand(0.7, 0.52, pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "another", optionHeld: false)
        expect(switchedScroll.scroll == nil && switchedScroll.match == nil && switchedScroll.progress.message == "Lower your hand to reset", "Changing the active app stops continuous scroll and requires rearming")
        c.reset()
        for i in 0..<15 { _ = c.process(.init(time: 1 + Double(i)*0.05, hands: [hand(pose: .pinch)]), rules: [scroll], selected: scroll.id, app: "test", optionHeld: false) }
        var scrollDisabled = scroll; scrollDisabled.enabled = false
        expect(c.process(.init(time: 1.75, hands: [hand(0.7, 0.52, pose: .pinch)]), rules: [scrollDisabled], selected: scroll.id, app: "test", optionHeld: false).scroll == nil, "Disabling an active scroll rule stops it")
        expect(c.process(.init(time: .nan, hands: [hand()]), rules: [rule], selected: rule.id, app: "test", optionHeld: false).match == nil, "Invalid timestamps cannot fire actions")
        var gate = DispatchPermission(enabled: true, testing: false, cameraRunning: true, editing: false, frameAge: 0.1, frontApp: "com.example.editor")
        expect(gate.allows(rule), "Fresh enabled live input passes dispatch gate")
        gate.optionHeld = true; expect(gate.allows(clutch), "Dispatch accepts an Option gesture while the clutch is held")
        gate.optionHeld = false; expect(!gate.allows(clutch), "Releasing Option during a ripple blocks the final dispatch and scroll gates")
        gate.testing = true; expect(!gate.allows(rule), "Test mode never permits dispatch"); gate.testing = false
        gate.enabled = false; expect(!gate.allows(rule), "Paused control cannot dispatch"); gate.enabled = true
        gate.cameraRunning = false; expect(!gate.allows(rule), "Stopped camera cannot dispatch"); gate.cameraRunning = true
        gate.editing = true; expect(!gate.allows(rule), "Editing blocks dispatch"); gate.editing = false
        gate.frameAge = 0.4; expect(!gate.allows(rule), "Stale frames cannot dispatch")
        gate.frameAge = -.infinity; expect(!gate.allows(rule), "Invalid frame age cannot dispatch")
        gate.frameAge = .nan; expect(!gate.allows(rule), "NaN frame age cannot dispatch")
        gate.frameAge = 0.1; gate.frontApp = "com.example.other"; expect(!gate.allows(scoped), "Dispatch rechecks active-app scope")
        expect(ActionPlanner.plan(rule.action) == .key(.init(code: 124, control: true)), "Next Space maps to Control-Right")
        for code: UInt16 in 123...126 {
            let pair = try KeyboardEvents.pair(.init(code: code, control: true), systemNavigation: true, physicalFlags: [])
            expect(pair.down.flags.contains([.maskControl, .maskSecondaryFn, .maskNumericPad]), "Native arrow event metadata is present for key \(code)")
            expect(pair.down.type == .keyDown && pair.up.type == .keyUp && pair.down.getIntegerValueField(.keyboardEventKeycode) == Int64(code) && pair.up.getIntegerValueField(.keyboardEventKeycode) == Int64(code), "Navigation event has a matching down/up pair for key \(code)")
            expect(!pair.up.flags.contains(.maskControl), "Synthetic Control is released for key \(code)")
        }
        let letterPair = try KeyboardEvents.pair(.init(code: 1, command: true), systemNavigation: false, physicalFlags: [.maskShift])
        expect(!letterPair.down.flags.contains(.maskNumericPad) && !letterPair.down.flags.contains(.maskSecondaryFn), "Letter shortcuts do not acquire arrow-key flags")
        expect(letterPair.up.flags == [.maskShift], "Key release preserves physical modifiers without latching synthetic Command")
        let navigation = try NavigationKeyEvents(.init(code: 124, control: true), physicalFlags: [])
        expect(navigation.controlDown?.type == .flagsChanged && navigation.controlUp?.type == .flagsChanged, "System navigation sends real modifier transitions")
        expect(navigation.controlDown?.getIntegerValueField(.keyboardEventKeycode) == 59 && navigation.controlUp?.getIntegerValueField(.keyboardEventKeycode) == 59, "System navigation pairs the same Control key")
        expect(navigation.controlDown?.flags.contains(.maskControl) == true && navigation.arrowDown.flags.contains(.maskControl) && navigation.arrowUp.flags.contains(.maskControl), "Control stays held across the arrow press and release")
        expect(navigation.controlUp?.flags == [], "Final navigation event releases synthetic modifiers")
        let heldControl = try NavigationKeyEvents(.init(code: 123, control: true), physicalFlags: [.maskControl, .maskShift])
        expect(heldControl.controlDown == nil && heldControl.controlUp == nil && heldControl.arrowUp.flags.contains([.maskControl, .maskShift]), "Navigation does not release a physically held Control key")
        var customAction = GestureAction(kind: .keyboard); customAction.key = .init(code: 1, label: "S", command: true, control: false, shift: true)
        expect(ActionPlanner.plan(customAction) == .key(.init(code: 1, command: true, shift: true)), "Custom shortcut preserves exact key and modifiers")
        var invalid = rule; invalid.confidence = .nan; rejects("NaN settings rejected") { _ = try invalid.validated() }
        invalid = rule; invalid.steps = [.init(kind: .move)]; rejects("Sequence without starting pose rejected") { _ = try invalid.validated() }
        invalid = rule; invalid.steps.insert(.init(kind: .release), at: 1); rejects("Release in middle rejected") { _ = try invalid.validated() }
        invalid = scroll; invalid.steps.append(.init(kind: .release)); rejects("Release before continuous scrolling rejected") { _ = try invalid.validated() }
        invalid = rule; invalid.steps[0].pose = .init(kind: .custom, index: .any, middle: .any, ring: .any, little: .any); rejects("Unconstrained custom pose rejected") { _ = try invalid.validated() }
        invalid = rule; invalid.action.kind = .shortcut; invalid.action.shortcutName = "--help"; rejects("CLI option cannot be used as Shortcut name") { _ = try invalid.validated() }
        invalid.action.shortcutName = "Name\nOther"; rejects("Multiline Shortcut name rejected") { _ = try invalid.validated() }
        invalid = rule; invalid.steps.append(invalid.steps[0]); rejects("Duplicate step IDs rejected") { _ = try invalid.validated() }
        rejects("Unknown library version rejected") { _ = try GestureLibrary(version: 2).validated() }
        rejects("Duplicate rule IDs rejected") { _ = try GestureLibrary(rules: [rule, rule]).validated() }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("GesturesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("roundtrip.gestures"), original = GestureLibrary()
        try LibraryIO.save(original, to: file)
        let restored = try LibraryIO.load(file)
        expect(restored == original, "JSON round-trip preserves definitions and actions")
        let imported = try LibraryIO.merging(original, into: original)
        expect(imported.rules.count == 6 && imported.rules.suffix(3).allSatisfy { !$0.enabled }, "All imported gestures are disabled")
        expect(Set(imported.rules.map(\.id)).count == 6, "Import remaps IDs to prevent overwriting existing rules")
        var misleading = rule
        misleading.action.kind = .keyboard
        misleading.action.key = .init(code: 51, label: "Space", command: true, control: false)
        misleading.scope = .init(bundleID: "com.apple.Terminal", name: "Calculator")
        try LibraryIO.save(.init(rules: [misleading]), to: file)
        let received = try LibraryIO.merging(LibraryIO.load(file), into: .init(rules: []))
        let reviewed = received.rules[0]
        expect(!reviewed.enabled && reviewed.action.title == "⌘Delete" && reviewed.scope.display == "com.apple.Terminal", "Imported review displays the executable key and bundle ID, never supplied labels")
        expect(ActionPlanner.plan(reviewed.action) == .key(.init(code: 51, command: true)), "Canonical display preserves the original executable binding")
        expect(AppScope(bundleID: "", name: "Calculator").display == "All apps", "A supplied name cannot disguise global scope")
        expect(KeyBinding(code: 124, label: "Delete").display == "⌃→", "Legitimate special keys still display correctly despite a misleading stored label")
        let frenchSources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: "com.apple.keylayout.French"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        if let french = frenchSources.first, let raw = TISGetInputSourceProperty(french, kTISPropertyUnicodeKeyLayoutData) {
            expect(KeyDisplay.translated(0, data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()) == "Q", "Printable labels follow a non-US keyboard layout without switching the user's layout")
        } else { failures.append("French keyboard-layout fixture unavailable") }
        let link = temp.appendingPathComponent("link.gestures"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("Symlink import rejected") { _ = try LibraryIO.load(link) }
        let oversized = temp.appendingPathComponent("large.gestures"); try Data(repeating: 32, count: 2_000_001).write(to: oversized)
        rejects("Oversized import rejected before decoding") { _ = try LibraryIO.load(oversized) }
        let store = GestureStore(storage: temp.appendingPathComponent("Store"), observeSystem: false)
        expect(!store.enabled && !store.testing && store.cameraStatus == .off, "Fresh launch starts with camera and control off")
        var saved = store.selected!; saved.name = "Custom gesture persistence"; saved.steps[2].direction = .downRight; saved.action = customAction
        store.update(saved); expect(store.selected == saved, "Editor saves complete custom definition")
        store.undo(); expect(store.selected?.name == "Swipe left", "Undo restores prior gesture")
        store.redo(); expect(store.selected == saved, "Redo restores edited gesture")
        let relaunched = GestureStore(storage: store.storage, observeSystem: false)
        expect(relaunched.selected == saved && !relaunched.enabled && relaunched.cameraStatus == .off, "Relaunch restores definitions but never control or camera")
        store.trySelected(); expect(store.testing && !store.enabled && store.cameraStatus == .off, "Try it enters action-free testing without accessing camera")
        store.trySelected(); expect(!store.testing && store.notice.contains("Mac control remains off"), "Stopping a camera-off test reports the correct state")
        store.trySelected(); store.showGlassAppearance = true
        expect(store.isEditing && !store.enabled && !store.testing, "Opening Ripple settings pauses practice and live control centrally")
        store.enableControl()
        expect(!store.enabled && store.notice.contains("Finish editing"), "Menu-bar resume is rejected while Ripple settings are open")
        store.showGlassAppearance = false
        expect(!store.isEditing && !store.enabled && !store.testing, "Closing Ripple settings never silently resumes control")
        let reviewStore = GestureStore(storage: temp.appendingPathComponent("ImportReview"), observeSystem: false)
        reviewStore.update(reviewed)
        reviewStore.duplicateSelected()
        expect(reviewStore.selected?.action.title == "⌘Delete" && reviewStore.selected?.scope.display == "com.apple.Terminal", "Duplication preserves truthful review without broadening scope")
        let duplicateID = reviewStore.selected!.id
        reviewStore.undo(); reviewStore.redo(); reviewStore.select(duplicateID)
        var dormant = reviewStore.selected!
        dormant.action.kind = .nextSpace; reviewStore.update(dormant); reviewStore.setAction(.keyboard)
        expect(reviewStore.editor?.rule.action.title == "⌘Delete", "Reactivating a dormant keyboard binding cannot restore a misleading label")
        let reopenedReview = GestureStore(storage: reviewStore.storage, observeSystem: false)
        let persistedReview = reopenedReview.library.rules.first { $0.id == reviewed.id }!
        expect(persistedReview.action.title == "⌘Delete" && persistedReview.scope.display == "com.apple.Terminal", "Save and relaunch keep executable identities visible for previously imported rules")
        expect(ControlMode.resolve(cameraRunning: true, enabled: false, testing: false) == .preview, "A live camera without control is explicitly preview only")
        expect(ControlMode.resolve(cameraRunning: true, enabled: true, testing: true) == .testing, "Test mode takes precedence in status presentation")
        expect(ControlMode.resolve(cameraRunning: true, enabled: true, testing: false) == .live, "Enabled live control is distinct from preview")
        store.checkSpaceAction(); expect(!store.enabled && !store.spaceCheckPending, "Manual Space check cannot dispatch with camera and control off")
        var check = SpaceChangeCheck()
        expect(!check.observed(at: 10), "Unrelated Space changes cannot be claimed as action success")
        check.begin(at: 10); expect(!check.observed(at: 9), "Earlier Space event cannot confirm a later action")
        expect(check.observed(at: 10.4) && !check.observed(at: 10.5), "A pending action is confirmed once by a timely Space event")
        check.begin(at: 20); expect(!check.expired(at: 22) && check.expired(at: 22.6), "Missing Space event times out instead of claiming success")
        check.begin(at: 30); check.cancel(); expect(!check.observed(at: 30.5), "Pausing cancels a pending Space verification")
        expect(GlassFeedbackCue(rule: rule).direction == .left, "A left swipe drives the visual left even though Next Space sends Control-Right")
        var feedbackRule = rule; feedbackRule.steps = [.init(kind: .pose)]
        feedbackRule.action.kind = .previousSpace
        expect(GlassFeedbackCue(rule: feedbackRule).direction == .right, "A pose-only Previous Space action has a useful visual direction")
        feedbackRule.action.kind = .shortcut; feedbackRule.action.shortcutName = "Example"
        expect(GlassFeedbackCue(rule: feedbackRule).direction == nil, "A non-directional gesture gets a pulse rather than inventing hand motion")
        for direction in MoveDirection.allCases {
            feedbackRule.steps.append(.init(kind: .move, direction: direction))
            expect(GlassFeedbackCue(rule: feedbackRule).direction == direction, "The final configured move determines visual direction: \(direction.rawValue)")
        }
        var rippleSchedule = RippleActionSchedule()
        let firstRipple = rippleSchedule.begin(at: 10, allowance: 0.1)
        expect(rippleSchedule.visible(firstRipple, at: 10.05), "A timely prepared frame starts the ripple before its action")
        expect(!rippleSchedule.expired(firstRipple, at: 10.2), "Capture timeout cannot dispatch again after a ripple starts")
        expect(rippleSchedule.finished(firstRipple) && !rippleSchedule.finished(firstRipple), "The ripple finishes its action exactly once")
        let lateRipple = rippleSchedule.begin(at: 20, allowance: 0.08)
        expect(rippleSchedule.expired(lateRipple, at: 20.09), "Slow capture falls back at a bounded deadline")
        expect(!rippleSchedule.visible(lateRipple, at: 20.2), "A late screen frame cannot show after the fallback action")
        let cancelledRipple = rippleSchedule.begin(at: 30, allowance: 0.1)
        rippleSchedule.cancel()
        expect(!rippleSchedule.visible(cancelledRipple, at: 30.05) && !rippleSchedule.finished(cancelledRipple), "Pausing cancels both a pending ripple and its delayed action")
        let replacedRipple = rippleSchedule.begin(at: 40, allowance: 0.1)
        let newestRipple = rippleSchedule.begin(at: 40.02, allowance: 0.1)
        expect(!rippleSchedule.visible(replacedRipple, at: 40.04) && rippleSchedule.visible(newestRipple, at: 40.06), "An older capture cannot replace a newer interaction")
        let invalidRipple = rippleSchedule.begin(at: 50, allowance: 0.1)
        expect(!rippleSchedule.visible(invalidRipple, at: .nan), "Invalid timing cannot start the compositor")
        expect(!rippleSchedule.mayPresent(invalidRipple, at: 49.9) && !rippleSchedule.mayPresent(invalidRipple, at: 50.2), "Out-of-window frames cannot briefly flash over the desktop")
        var slowerCapture = RippleActionSchedule()
        let slowID = slowerCapture.begin(at: 10, allowance: RippleTiming.captureAllowance(frameAge: 0.02, requestedDuration: 0.4))
        expect(slowerCapture.visible(slowID, at: 10.18), "Slow still plays when the first frame takes 180ms, instead of unnecessarily skipping the wave")
        let fittedDuration = RippleTiming.duration(requested: 0.4, startingAt: 10.18, finishBy: 10 + RippleTiming.visualBudget - 0.02)
        let fittedFinish = 10.18 + fittedDuration + 0.04
        expect(abs(fittedDuration-0.39)<0.0001 && PreActionInput.isFresh(recognizedAt: 9.98, latestFrameAt: fittedFinish-0.016, now: fittedFinish), "A delayed first frame shortens Slow to fit the original gesture deadline, including presentation overhead")
        expect(abs(RippleTiming.duration(requested: 0.22, startingAt: 10.1, finishBy: 10.57)-0.22)<0.0001, "Available safety headroom never stretches the selected Fast animation")
        let durationDomain = "GesturesDurationTests-" + UUID().uuidString
        let durationPreferences = UserDefaults(suiteName: durationDomain)!
        defer { durationPreferences.removePersistentDomain(forName: durationDomain) }
        var migratedDurations = [Double]()
        for preset in RippleSpeed.allCases {
            durationPreferences.set(preset.rawValue, forKey: RippleSpeed.preferenceKey)
            migratedDurations.append(RippleDuration.milliseconds(in: durationPreferences))
        }
        expect(migratedDurations == [220,320,400], "Existing speed preferences retain their timing until a custom duration is saved")
        durationPreferences.set(275.0,forKey: RippleDuration.preferenceKey)
        expect(RippleDuration.milliseconds(in: UserDefaults(suiteName: durationDomain)!) == 275,
               "A custom duration persists and takes precedence over the old speed setting")
        expect(RippleDuration.parsed(" 275 ",fallback: 400) == 275 && RippleDuration.parsed("invalid",fallback: 275) == 275 && RippleDuration.parsed("nan",fallback: 275) == 275,
               "Typed durations accept exact milliseconds and keep the current value for invalid input")
        expect(RippleDuration.parsed("10000",fallback: 400) == 500 && RippleDuration.parsed("-1",fallback: 400) == 150 && RippleDuration.clamped(.infinity) == 400,
               "Oversized, negative, and nonfinite durations cannot escape the bounded animation range")
        let maximumDuration = RippleTiming.duration(requested: 0.5,startingAt: 10.18,finishBy: 10 + RippleTiming.visualBudget - 0.02)
        expect(abs(maximumDuration-0.39)<0.0001 && PreActionInput.isFresh(recognizedAt: 9.98,latestFrameAt: 10.60,now: 10.61),
               "The longest custom duration shortens around capture latency and preserves the original action deadline")
        expect(abs(RippleTiming.duration(requested: 0.275,startingAt: 10.1,finishBy: 10.57)-0.275)<0.0001,
               "A custom duration is honored exactly when the capture budget permits it")
        var delayedGate = DispatchPermission(enabled: true, testing: false, cameraRunning: true, editing: false, frameAge: 0.32, frontApp: "test")
        expect(delayedGate.allows(rule), "A recent camera frame still fits the original fresh-input gate")
        delayedGate.frameAge = 0.36
        expect(!delayedGate.allows(rule), "A ripple cannot extend the 350ms camera freshness limit")
        expect(PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: 10.4, now: 10.5), "A bounded prelude can proceed when the camera is still delivering fresh frames")
        expect(PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: 10, now: 10.01), "An immediate action remains allowed when the ripple is disabled")
        expect(!PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: 10.1, now: 10.5), "A camera that stopped during the effect cannot dispatch its pending action")
        expect(!PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: 10.8, now: 10.9), "A fresh camera cannot resurrect an expired gesture")
        expect(!PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: 9.9, now: 10.1), "A frame from before recognition cannot authorize a delayed action")
        expect(!PreActionInput.isFresh(recognizedAt: 10, latestFrameAt: .nan, now: 10.1), "Invalid frame timing cannot authorize a delayed action")
        expect(RippleGPU.shared != nil, "The actual Metal screen-refraction shader compiles on this Mac")
        let sampleImage = RippleSample.image()
        expect(sampleImage?.width == 1080 && sampleImage?.height == 560, "The sample desktop renders entirely from synthetic local content")
        if let sampleImage, let gpu = RippleGPU.shared {
            do {
                let texture = try RippleTexture.make(sampleImage, device: gpu.device)
                expect(texture.width == sampleImage.width && texture.height == sampleImage.height, "The actual preview image uploads successfully to Metal")
                func render(_ input: MTLTexture, progress: Float, strength: Float = Float(RippleStrength.standard*2), opacity: Float = 1, backdrop: Bool = false, width: Int = 64, height: Int = 32, direction: SIMD2<Float> = SIMD2(-1,0)) throws -> [UInt8] {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                    descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
                    guard let target = gpu.device.makeTexture(descriptor: descriptor), let command = gpu.queue.makeCommandBuffer() else { throw GestureError("GPU test allocation failed") }
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw GestureError("GPU test encoder unavailable") }
                    var uniforms = RippleUniforms(size: SIMD2(Float(input.width), Float(input.height)), direction: direction, progress: progress, strength: strength, opacity: opacity, backdrop: backdrop ? 1 : 0)
                    encoder.setRenderPipelineState(gpu.pipeline)
                    encoder.setFragmentTexture(input, index: 0)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                    guard command.status == .completed else { throw GestureError("GPU test render did not complete") }
                    var pixels = [UInt8](repeating: 0, count: width*height*4)
                    pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width*4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
                    return pixels
                }
                let sample = try render(texture, progress: 0.5, backdrop: true)
                expect(stride(from: 3, to: sample.count, by: 4).allSatisfy { sample[$0] == 255 }, "The preview includes its complete synthetic backdrop")
                let shades = Set(stride(from: 0, to: sample.count, by: 4).map { Int(sample[$0]) << 16 | Int(sample[$0+1]) << 8 | Int(sample[$0+2]) })
                expect(shades.count > 16, "The GPU output contains the sample desktop, not a blank surface")
                let corners: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255]
                let cornerImage = CGImage(width: 2,height: 2,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 8,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: CGDataProvider(data: Data(corners) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
                let cornerTexture = try RippleTexture.make(cornerImage,device: gpu.device)
                let orientation = try render(cornerTexture,progress: 0,backdrop: true,width: 2,height: 2)
                expect(orientation == [0,0,255,255, 0,255,0,255, 255,0,0,255, 0,255,255,255], "Capture normalization and GPU rendering preserve all four screen corners")
                // Exercise the production direct-buffer path, including encoded colors,
                // row stride, orientation, and ownership after the caller drops its buffer.
                var capturedPixels: CVPixelBuffer?
                let attributes = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                let allocation = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, attributes, &capturedPixels)
                guard allocation == kCVReturnSuccess, let pixels = capturedPixels else { throw GestureError("Could not allocate synthetic capture buffer") }
                CVPixelBufferLockBaseAddress(pixels, [])
                let rowStride = CVPixelBufferGetBytesPerRow(pixels)
                let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                let bgra: [UInt8] = [0,0,255,255, 0,255,0,255, 255,0,0,255, 0,255,255,255]
                for y in 0..<2 { for x in 0..<8 { base[y*rowStride+x] = bgra[y*8+x] } }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                let mapped = try RippleFrame.map(pixels, cache: gpu.textureCache)
                capturedPixels = nil
                let direct = try render(mapped.texture, progress: 0, backdrop: true, width: 2, height: 2)
                expect(mapped.texture.pixelFormat == .bgra8Unorm_srgb && direct == bgra, "The direct IOSurface mapping preserves orientation and colors without a CGImage copy")
                var unsupported: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_OneComponent8, nil, &unsupported)
                if let unsupported { rejects("Unsupported capture buffers fail safely") { _ = try RippleFrame.map(unsupported, cache: gpu.textureCache) } }
                func centroid(_ rgba: [UInt8], width: Int = 64, height: Int = 32) -> SIMD2<Double> {
                    var weight = 0.0; var center = SIMD2<Double>(repeating: 0)
                    for y in 0..<height { for x in 0..<width {
                        let a = Double(rgba[(y*width+x)*4+3]); weight += a
                        center += SIMD2(Double(x)/Double(width),Double(y)/Double(height))*a
                    } }
                    return center/max(1,weight)
                }
                for direction in MoveDirection.allCases {
                    let v = direction.vector
                    let axis = SIMD2<Float>(Float(v.x),-Float(v.y))
                    let before = centroid(try render(texture,progress: 0.22,direction: axis))
                    let after = centroid(try render(texture,progress: 0.78,direction: axis))
                    let travel = after-before
                    expect(travel.x*Double(axis.x)+travel.y*Double(axis.y)>0.25, "The visible ripple propagates with \(direction.rawValue) from the opposite display edge")
                }
                let first = try render(texture, progress: 0)
                let last = try render(texture, progress: 1)
                expect(first.allSatisfy { $0 == 0 } && last.allSatisfy { $0 == 0 }, "The real desktop effect begins and ends completely transparent")
                let rest = try render(texture, progress: 0, backdrop: true)
                let restored = try render(texture, progress: 1, backdrop: true)
                expect(rest == restored, "The sample returns exactly to its undistorted image at the end")
                let middle = try render(texture, progress: 0.5)
                let alphas = stride(from: 3, to: middle.count, by: 4).map { middle[$0] }
                expect(alphas.contains(0) && alphas.contains { $0 > 32 }, "Only the moving wave covers the desktop; unrelated pixels stay transparent")
                // Read the actual Metal output at every display boundary. The old
                // unrestricted displacement reached these pixels and stretched them.
                var affectedBorderPixels = 0
                let directions = MoveDirection.allCases.map { SIMD2<Float>(Float($0.vector.x),-Float($0.vector.y)) } + [SIMD2<Float>(0,0)]
                for axis in directions {
                    for progress: Float in [0.1,0.25,0.4,0.55,0.7,0.85] {
                        let frame = try render(texture,progress: progress,strength: Float(RippleStrength.range.upperBound*2),width: 1080,height: 560,direction: axis)
                        for y in 0..<560 { for x in 0..<1080 where x < 3 || x >= 1077 || y < 3 || y >= 557 {
                            let i = (y*1080+x)*4
                            if frame[i...i+3].contains(where: { $0 != 0 }) { affectedBorderPixels += 1 }
                        } }
                    }
                }
                print("GPU BORDER: \(affectedBorderPixels) altered border pixels across 54 maximum-strength frames")
                expect(affectedBorderPixels == 0, "All four borders and corners stay completely transparent throughout every ripple direction")
                var overbright = 0
                for progress: Float in [0.05,0.15,0.3,0.5,0.7,0.85,0.95] {
                    let fade = try render(texture, progress: progress, opacity: 0.5)
                    overbright += stride(from: 0, to: fade.count, by: 4).filter { i in Int(max(fade[i],fade[i+1],fade[i+2])) > Int(fade[i+3])+1 }.count
                }
                expect(overbright == 0, "Fading SDR pixels remain premultiplied after color encoding and cannot overbrighten the screen")
                var maxCompositeError = 0.0
                let colors: [[UInt8]] = [[0,0,0],[64,64,64],[128,128,128],[192,192,192],[255,255,255],[32,128,245]]
                for rgb in colors {
                    var bytes = [UInt8]()
                    for _ in 0..<256*256 { bytes += rgb + [255] }
                    let flat = bytes.withUnsafeMutableBytes { raw -> CGImage? in
                        CGContext(data: raw.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256*4,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
                    }!
                    let input = try RippleTexture.make(flat, device: gpu.device)
                    let flatRest = try render(input, progress: 0, backdrop: true)
                    expect(input.pixelFormat == .rgba8Unorm_srgb && zip(Array(flatRest.prefix(3)),rgb.reversed()).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "Screen texture preserves encoded source colors: \(rgb)")
                    for progress: Float in [0.07,0.25,0.5,0.8,0.95] {
                        let faded = try render(input, progress: progress, strength: Float(RippleStrength.range.upperBound*2))
                        for i in stride(from: 0, to: faded.count, by: 4) {
                            let alpha = Double(faded[i+3])/255
                            for channel in 0..<3 {
                                let original = Double(rgb[2-channel])
                                maxCompositeError = max(maxCompositeError, abs(Double(faded[i+channel])+original*(1-alpha)-original))
                            }
                        }
                    }
                }
                print("GPU FADE: overbright pixels \(overbright); maximum composited color error \(maxCompositeError) / 255")
                expect(maxCompositeError <= 2, "Dark, gray, white, and colored desktops retain brightness throughout the actual GPU fade")
                let warped = try render(texture, progress: 0.4, backdrop: true)
                expect(zip(rest,warped).filter { abs(Int($0)-Int($1)) > 2 }.count > 20, "The ripple visibly displaces source content rather than only changing opacity")
                var ramp = [UInt8]()
                for _ in 0..<768 { for x in 0..<1024 { let c = UInt8(x/4); ramp += [c,c,c,255] } }
                let rampImage = CGImage(width: 1024,height: 768,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 1024*4,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: CGDataProvider(data: Data(ramp) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
                let rampTexture = try RippleTexture.make(rampImage,device: gpu.device)
                let flatRamp = try render(rampTexture,progress: 0,backdrop: true,width: 1024,height: 768)
                for points in [RippleStrength.standard,RippleStrength.range.upperBound] {
                    let glassRamp = try render(rampTexture,progress: 0.5,strength: Float(points*2),backdrop: true,width: 1024,height: 768)
                    let largestBend = zip(flatRamp,glassRamp).map { abs(Int($0)-Int($1)) }.max() ?? 0
                    expect(abs(Double(largestBend*2)-points)<=2, "The ripple produces approximately \(Int(points)) points of refraction at 2x scale")
                    print("GPU GLASS: \(Int(points))-point setting produces approximately \(largestBend*4) pixels of displacement; all eight travel directions verified")
                }
                let restingCenter = Int(try render(rampTexture,progress: 0,backdrop: true,width: 1,height: 1)[0])
                var centerOffsets = [Int]()
                for tick in 0...100 {
                    centerOffsets.append(Int(try render(rampTexture,progress: Float(tick)/100,backdrop: true,width: 1,height: 1)[0])-restingCenter)
                }
                let firstBend = -(centerOffsets.min() ?? 0), returningBend = centerOffsets.max() ?? 0
                expect(firstBend >= 14 && returningBend >= 2 && returningBend < firstBend/2,
                       "After arrival, the actual GPU ripple bends back with a smaller decaying wave")
                expect(centerOffsets.prefix(25).allSatisfy { $0 == 0 } && centerOffsets.suffix(15).allSatisfy { $0 == 0 },
                       "Pixels remain still before wave arrival and settle back exactly afterward")
                if let folder = ProcessInfo.processInfo.environment["GESTURES_TEST_RENDER_DIR"] {
                    let url = URL(fileURLWithPath: folder, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let screenWidth = Float(NSScreen.main?.frame.width ?? 1512)
                    let previewStrength = Float(RippleStrength.standard)*Float(texture.width)/max(1,screenWidth)
                    try "Synthetic desktop only. Strength: 32 screen points, scaled to a 1080px preview of a \(screenWidth)-point display. Phases: 0, .15, .3, .45, .6, .75, .9, 1.\n".write(to: url.appendingPathComponent("README.txt"),atomically: true,encoding: .utf8)
                    for (index, progress) in [Float(0),0.15,0.3,0.45,0.6,0.75,0.9,1].enumerated() {
                        let bytes = try render(texture, progress: progress, strength: previewStrength, backdrop: true, width: 1080, height: 560)
                        let provider = CGDataProvider(data: Data(bytes) as CFData)!
                        let image = CGImage(width: 1080, height: 560, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1080*4,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                        let destination = CGImageDestinationCreateWithURL(url.appendingPathComponent("sample-\(index).png") as CFURL, "public.png" as CFString, 1, nil)!
                        CGImageDestinationAddImage(destination,image,nil)
                        guard CGImageDestinationFinalize(destination) else { throw GestureError("Could not save the synthetic QA frame") }
                    }
                }
            } catch { expect(false, "Preview texture upload: \(error.localizedDescription)") }
        }
        let preferenceName = "GesturesTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let visualStore = GestureStore(storage: temp.appendingPathComponent("VisualStore"), observeSystem: false, preferences: preferences)
        visualStore.glassFeedbackEnabled = false
        let visualRelaunch = GestureStore(storage: visualStore.storage, observeSystem: false, preferences: preferences)
        expect(!visualRelaunch.glassFeedbackEnabled && !visualRelaunch.enabled && visualRelaunch.cameraStatus == .off, "Turning off visual feedback persists without enabling the camera or Mac control")
        let suggestion = try GestureDemonstration.suggest(swipeFrames())
        expect(!suggestion.enabled && suggestion.steps.last?.direction == .left, "Demonstration suggests editable direction, disabled by default")
        rejects("Still demonstration rejected") { _ = try GestureDemonstration.suggest((0..<20).map { .init(time: Double($0)*0.05, hands: [hand()]) }) }
        var anatomical: [String: Landmark] = ["wrist": .init(point: .init(x: 0.5, y: 0.2), confidence: 0.95)]
        for (n, finger) in ["index", "middle", "ring", "little"].enumerated() { for (j, joint) in ["MCP", "PIP", "DIP", "Tip"].enumerated() { anatomical[finger + joint] = .init(point: .init(x: 0.35 + Double(n)*0.1, y: 0.4 + Double(j)*0.12), confidence: 0.95) } }
        let measured = HandGeometry.measure(joints: anatomical, side: .right, aspect: 16/9)
        expect(measured?.matches(.init(), hand: .right, minimum: 0.55) == true, "Anatomical joint geometry recognizes straight fingers at video aspect ratio")
        expect(HandGeometry.measure(joints: [:], side: .either, aspect: 1) == nil, "Incomplete hand geometry is ignored")
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GestureError("Smoke image could not be opened") }
            let tracker = VisionTracker(), frame = try tracker.detect(image: image, time: 1)
            expect(!frame.hands.isEmpty, "Apple Vision detects hand landmarks in the AI-generated concept image")
            print("VISION SMOKE: \(frame.hands.count) hand(s), \(frame.hands.map { $0.joints.count }) joints; generated image only, no camera.")
        }
        print("\(checks - failures.count)/\(checks) checks passed. No camera, keyboard events, scroll events, or Shortcuts were executed.")
        if !failures.isEmpty { exit(1) }
    }
}
