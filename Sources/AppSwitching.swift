import AppKit
import Foundation

/// A picker snapshots process identities, not paths or commands. Never persisted.
struct AppSwitchTarget: Identifiable, Equatable, Sendable {
    var id: Int32
    var bundleID: String
    var name: String
    var launchedAt: Date?
    @MainActor var runningApplication: NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: id), !app.isTerminated,
              app.activationPolicy == .regular, app.bundleIdentifier == bundleID,
              app.launchDate == launchedAt else { return nil }
        return app
    }
    @MainActor static func available(settings: AppSwitcherSettings) -> [Self] {
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app -> Self? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = app.bundleIdentifier, settings.includes(bundleID) else { return nil }
            return .init(id: app.processIdentifier, bundleID: bundleID,
                         name: app.localizedName ?? bundleID, launchedAt: app.launchDate)
        }.sorted {
            if ($0.id == current) != ($1.id == current) { return $0.id == current }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }.prefix(20).map { $0 }
    }
}

enum AppSwitchUpdate: Equatable { case browsing, commit(AppSwitchTarget), cancelled }

/// The picker can remain visible while input is paused. Only a new, confident
/// pinch after open-hand browsing may commit; visibility never grants permission.
struct AppSwitchSession {
    let rule: GestureRule
    let targets: [AppSwitchTarget]
    let sourceApp: String
    let practicing: Bool
    let startedAt: Double
    private let sourcePID: Int32?
    private(set) var selectedIndex: Int
    private(set) var lastFrameAt: Double
    private(set) var direction: MoveDirection?
    private(set) var finished = false
    private var previousHand: TrackedHand?
    private var trackedSide: HandChoice
    private var filteredX: Double
    private var anchorX: Double
    private var releaseSince: Double?
    private var confirmSince: Double?
    private var uncertainSince: Double?
    private var moved = false
    private(set) var awaitingOpenHand = true
    private(set) var trackingPaused = false
    var selected: AppSwitchTarget { targets[selectedIndex] }
    var instruction: String {
        if trackingPaused { return "Selection paused · show one open hand" }
        if awaitingOpenHand { return "Release your pinch to browse" }
        if confirmSince != nil { return "Pinch to confirm \(selected.name)" }
        return "Slide with an open hand · pinch again to choose"
    }

    init?(rule: GestureRule, targets: [AppSwitchTarget], frame: HandFrame, sourceApp: String,
          currentPID: Int32?, practicing: Bool) {
        guard (try? rule.validated()) != nil, rule.action.kind == .switchApps,
              !targets.isEmpty, targets.count <= 20, Set(targets.map(\.id)).count == targets.count,
              targets.allSatisfy({ rule.action.switcherSettings.includes($0.bundleID) }), frame.time.isFinite,
              frame.hands.count == 1, let hand = frame.hands.first,
              hand.matches(.init(kind: .pinch), hand: rule.hand, minimum: rule.confidence) else { return nil }
        self.rule = rule; self.targets = targets; self.sourceApp = sourceApp; self.practicing = practicing
        sourcePID = currentPID
        startedAt = frame.time; lastFrameAt = frame.time; previousHand = hand
        trackedSide = hand.side
        filteredX = hand.palm.x; anchorX = hand.palm.x
        selectedIndex = targets.firstIndex(where: { $0.id == currentPID }) ?? 0
    }
    mutating func cancel() { finished = true }
    mutating func pauseTracking() {
        guard !finished else { return }
        awaitingOpenHand = true; trackingPaused = true; previousHand = nil
        trackedSide = .either
        releaseSince = nil; confirmSince = nil; uncertainSince = nil
    }
    private mutating func anchor(at hand: TrackedHand) {
        filteredX = hand.palm.x; anchorX = hand.palm.x
    }
    mutating func process(_ frame: HandFrame, app: String, optionHeld: Bool, allowed: Bool) -> AppSwitchUpdate {
        guard !finished else { return .cancelled }
        let settings = rule.action.switcherSettings
        guard allowed, app == sourceApp, frame.time.isFinite, frame.time > lastFrameAt,
              frame.time - startedAt <= settings.timeout,
              !rule.requireOptionKey || optionHeld else { finished = true; return .cancelled }
        let dt = frame.time - lastFrameAt
        lastFrameAt = frame.time
        guard dt <= 0.25, frame.hands.count == 1, let hand = frame.hands.first,
              hand.matches(.init(kind: .any), hand: rule.hand, minimum: rule.confidence) else {
            pauseTracking(); return .browsing
        }
        if let previousHand, (hand.palm - previousHand.palm).length >= 0.15 {
            pauseTracking(); return .browsing
        }
        // Vision may omit handedness while fingertips overlap. Retain the last
        // known side so unknown does not look like a new hand or hide a real swap.
        if hand.side != .either {
            guard trackedSide == .either || hand.side == trackedSide else { pauseTracking(); return .browsing }
            trackedSide = hand.side
        }
        previousHand = hand
        let apart = PoseDefinition(kind: .custom, thumb: .any, index: .any, middle: .any, ring: .any, little: .any, pinch: .apart)
        let open = hand.matches(apart, hand: rule.hand, minimum: rule.confidence)
        let pinched = hand.matches(.init(kind: .pinch), hand: rule.hand, minimum: rule.confidence)
        if awaitingOpenHand {
            if open {
                if releaseSince == nil { releaseSince = frame.time }
                if frame.time - (releaseSince ?? frame.time) >= 0.12 {
                    awaitingOpenHand = false; trackingPaused = false; releaseSince = nil
                    anchor(at: hand)
                }
            } else { releaseSince = nil }
            return .browsing
        }
        if pinched {
            uncertainSince = nil
            if confirmSince == nil { confirmSince = frame.time }
            guard frame.time - (confirmSince ?? frame.time) >= 0.12 else { return .browsing }
            guard moved, selected.id != sourcePID else {
                awaitingOpenHand = true; confirmSince = nil; return .browsing
            }
            finished = true; return .commit(selected)
        }
        if open {
            // Neither a partial confirmation nor uncertain tracking adds travel.
            if confirmSince != nil || uncertainSince != nil { anchor(at: hand) }
            confirmSince = nil; uncertainSince = nil
            filteredX += (hand.palm.x - filteredX) * (1 - exp(-dt / 0.055))
            let offset = filteredX - anchorX
            let steps = Int(abs(offset) / settings.distancePerApp)
            if steps > 0 {
                let physical = offset > 0 ? 1 : -1
                let logical = settings.reversed ? -physical : physical
                selectedIndex = (selectedIndex + logical * steps % targets.count + targets.count) % targets.count
                anchorX += Double(physical * steps) * settings.distancePerApp
                moved = true; direction = physical > 0 ? .right : .left
            }
            return .browsing
        }
        confirmSince = nil
        if uncertainSince == nil { uncertainSince = frame.time }
        if frame.time - (uncertainSince ?? frame.time) > 0.18 { pauseTracking() }
        return .browsing
    }
}
