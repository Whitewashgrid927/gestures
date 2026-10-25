import Foundation

struct ScrollSettings: Codable, Equatable, Sendable {
    var jitterTolerance = 0.002
    var showIndicator = true
    func validated() throws -> Self {
        guard jitterTolerance.isFinite, (0...0.015).contains(jitterTolerance) else {
            throw GestureError("Keep scroll steadiness between 0 and 1.5% of the camera frame.")
        }
        return self
    }
}

/// A small spatial dead zone absorbs tremor without queuing motion or adding inertia.
struct ScrollMotion {
    private var anchor: Point2
    private var remainder = 0.0
    init(origin: Point2) { anchor = origin }
    mutating func sample(_ point: Point2, elapsed: Double, action: GestureAction) -> Double {
        guard point.finite, elapsed.isFinite, elapsed > 0, elapsed <= 0.25 else { return 0 }
        let vertical = action.kind == .scrollVertical
        let delta = vertical ? point.y - anchor.y : point.x - anchor.x
        let slack = action.scrollSettings.jitterTolerance
        guard abs(delta) > slack else { return 0 }
        let movement = delta - (delta > 0 ? slack : -slack)
        if vertical { anchor.y += movement } else { anchor.x += movement }
        let amount = movement * 1700 * action.scrollSensitivity * (action.reverseScroll ? -1 : 1)
        if amount * remainder < 0 { remainder = 0 }
        let cap = min(45, elapsed * 700)
        let bounded = max(-cap, min(cap, amount + remainder))
        let pixels = bounded.rounded(.towardZero)
        remainder = bounded - pixels
        return pixels
    }
}

struct ScrollFeedback: Equatable, Sendable {
    var horizontal = false
    var amount = 0.0
    var preparing = false
    init(horizontal: Bool = false, amount: Double = 0, preparing: Bool = false) {
        self.horizontal = horizontal; self.amount = amount; self.preparing = preparing
    }
    init?(action: GestureAction, amount: Double, preparing: Bool) {
        guard action.scrollSettings.showIndicator else { return nil }
        self.init(horizontal: action.kind == .scrollHorizontal, amount: amount, preparing: preparing)
    }
    var direction: String {
        if preparing { return "Preparing" }
        if amount == 0 { return "Ready" }
        return horizontal ? (amount > 0 ? "Left" : "Right") : (amount > 0 ? "Up" : "Down")
    }
    var intensity: Double { min(1, abs(amount) / 32) }
}

struct ContinuousScrollSession {
    let rule: GestureRule
    let pose: PoseDefinition
    var hand: TrackedHand
    var time: Double
    var knownSide: HandChoice
    var motion: ScrollMotion
    init(rule: GestureRule, hand: TrackedHand, time: Double) {
        self.rule = rule; self.hand = hand; self.time = time; knownSide = hand.side
        pose = rule.steps.last(where: { $0.kind == .pose })?.pose ?? .init()
        motion = .init(origin: hand.palm)
    }
    mutating func sample(_ frame: HandFrame) -> Double? {
        guard frame.hands.count == 1, let next = frame.hands.first,
              next.matches(pose, hand: rule.hand, minimum: rule.confidence),
              knownSide == .either || next.side == .either || next.side == knownSide,
              frame.time > time, frame.time - time <= 0.25,
              (next.palm - hand.palm).length < 0.15 else { return nil }
        let pixels = motion.sample(next.palm, elapsed: frame.time - time, action: rule.action)
        if next.side != .either { knownSide = next.side }
        hand = next; time = frame.time
        return pixels
    }
}
