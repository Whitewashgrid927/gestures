import Foundation

struct RecognitionProgress: Sendable {
    var step = 0
    var fraction: Double = 0
    var message = "Show your hand"
    var matched = false
    var hand: TrackedHand?
}

struct FistStability {
    static let uncertaintyLimit = 0.15
    private var first: Double?
    private var last: Double?
    private var samples = 0
    mutating func accept(at time: Double) -> (fraction: Double, complete: Bool) {
        if let last, time <= last || time - last > Self.uncertaintyLimit { self = .init() }
        if first == nil { first = time }
        last = time; samples += 1
        let fraction = min(1, max(0, (time - (first ?? time)) / 0.12))
        return (fraction, fraction >= 1 && samples >= 3)
    }
    mutating func uncertain(at time: Double) {
        if let last, time - last > Self.uncertaintyLimit { self = .init() }
    }
}

struct GestureRecognizer {
    private(set) var index = 0
    private var stepStarted: Double?
    private var poseSince: Double?
    private var anchor: Point2?
    private var lastHand: TrackedHand?
    private var lastSeen: Double?
    private var lastFrameTime: Double?
    private var sequenceStarted: Double?
    private var activePose = PoseDefinition()
    private var releaseSince: Double?
    private var fistStability = FistStability()
    mutating func reset() { self = Self() }

    mutating func process(_ frame: HandFrame, rule: GestureRule) -> RecognitionProgress {
        guard frame.time.isFinite, !rule.steps.isEmpty else { reset(); return .init() }
        if let lastFrameTime, frame.time <= lastFrameTime || frame.time - lastFrameTime > 0.45 { reset() }
        lastFrameTime = frame.time
        if let sequenceStarted, frame.time - sequenceStarted > 20 { reset(); lastFrameTime = frame.time }
        if index >= rule.steps.count { reset(); lastFrameTime = frame.time }
        let fistPose = rule.action.kind == .volume && rule.steps[index].kind == .pose && rule.steps[index].pose.kind == .fist
        let candidates = frame.hands.filter {
            ($0.confidence >= rule.confidence || (fistPose && $0.fistIsUncertain(hand: rule.hand, minimum: rule.confidence))) &&
            $0.palm.finite && (rule.hand == .either || $0.side == rule.hand)
        }
        let hand: TrackedHand?
        if let previous = lastHand, let lastSeen, frame.time - lastSeen < 0.35 {
            hand = candidates.filter { previous.side == .either || $0.side == .either || $0.side == previous.side }
                .min(by: { ($0.palm - previous.palm).length < ($1.palm - previous.palm).length })
                .flatMap { ($0.palm - previous.palm).length < 0.27 ? $0 : nil }
        } else { hand = candidates.max(by: { $0.confidence < $1.confidence }) }
        if let hand { lastHand = hand; lastSeen = frame.time }
        let step = rule.steps[index]
        if stepStarted == nil { stepStarted = frame.time; anchor = hand?.palm }
        let elapsed = frame.time - (stepStarted ?? frame.time)
        var progress = RecognitionProgress(step: index, message: step.label, hand: hand)
        if step.kind != .release, hand == nil {
            if fistPose { fistStability = .init(); poseSince = nil }
            if let lastSeen, frame.time - lastSeen < 0.16 { progress.message = "Keep your hand visible"; return progress }
            reset(); progress = .init(message: "Show a clear \(rule.hand == .either ? "hand" : rule.hand.rawValue.lowercased())")
            return progress
        }
        func match(_ pose: PoseDefinition) -> Bool { hand?.matches(pose, hand: rule.hand, minimum: rule.confidence) == true }
        var complete = false
        switch step.kind {
        case .pose:
            if match(step.pose) {
                if poseSince == nil { poseSince = frame.time; sequenceStarted = frame.time }
                progress.fraction = min(1, (frame.time - (poseSince ?? frame.time)) / 0.12)
                if step.pose.kind == .pinch { progress.message = "Pinch seen · keep fingers together" }
                if step.pose.kind == .fist { progress.message = "Fist seen · keep it closed" }
                complete = progress.fraction >= 1
                if rule.action.kind == .volume && step.pose.kind == .fist {
                    let stability = fistStability.accept(at: frame.time)
                    progress.fraction = stability.fraction; complete = stability.complete
                }
                if complete { activePose = step.pose }
            } else {
                poseSince = nil
                if rule.action.kind == .volume && step.pose.kind == .fist,
                   hand?.fistIsUncertain(hand: rule.hand, minimum: rule.confidence) == true {
                    fistStability.uncertain(at: frame.time)
                } else { fistStability = .init() }
                if step.pose.kind == .fist { progress.message = hand?.fistGuidance(minimum: rule.confidence) ?? "Show a clear hand" }
                else { progress.message = step.pose.kind == .pinch ? (hand?.pinchGuidance(minimum: rule.confidence) ?? "Show a clear hand") : "Show \(step.pose.label.lowercased())" }
            }
        case .hold:
            guard match(activePose), let hand else { reset(); return .init(message: "Hold the same pose") }
            if anchor == nil { anchor = hand.palm; stepStarted = frame.time }
            if let anchor, (hand.palm - anchor).length > 0.045 { self.anchor = hand.palm; stepStarted = frame.time }
            progress.fraction = min(1, (frame.time - (stepStarted ?? frame.time)) / step.duration)
            progress.message = "Hold still · \(Int(progress.fraction * 100))%"
            complete = progress.fraction >= 1
        case .move, .slide:
            guard match(activePose), let hand else { reset(); return .init(message: "Keep the same hand pose") }
            if anchor == nil { anchor = hand.palm; stepStarted = frame.time }
            guard elapsed <= step.maximumDuration else { reset(); return .init(message: "Try a quicker movement") }
            let delta = hand.palm - (anchor ?? hand.palm)
            let forward = step.kind == .slide ? abs(delta.x) : delta.dot(step.direction.vector)
            let cross = step.kind == .slide ? abs(delta.y) : abs(delta.x * step.direction.vector.y - delta.y * step.direction.vector.x)
            let direction = step.kind == .slide ? "sideways" : step.direction.rawValue.lowercased()
            if forward < -0.06 || cross > max(step.kind == .slide ? 0.04 : 0.09, abs(forward) * 0.85) { reset(); return .init(message: "Move \(direction) in a clear line") }
            progress.fraction = max(0, min(1, forward / step.distance))
            progress.message = "Move \(direction) · \(Int(progress.fraction * 100))%"
            complete = forward >= step.distance && elapsed >= 0.1
        case .release:
            if !match(activePose) {
                if releaseSince == nil { releaseSince = frame.time }
                progress.fraction = min(1, (frame.time - (releaseSince ?? frame.time)) / step.duration)
                complete = progress.fraction >= 1
            } else { releaseSince = nil; progress.message = "Lower your hand or change pose" }
            if elapsed > 5 { reset(); return .init(message: "Start the gesture again") }
        }
        if complete {
            index += 1; stepStarted = frame.time; anchor = hand?.palm; poseSince = nil; releaseSince = nil; fistStability = .init()
            if index == rule.steps.count { progress.matched = true; progress.fraction = 1; progress.message = "\(rule.name) detected" }
            else { progress.step = index; progress.fraction = 0; progress.message = rule.steps[index].label }
        }
        return progress
    }
}

struct GestureMatch: Sendable { var rule: GestureRule; var hand: TrackedHand? }
struct CoordinatorResult: Sendable {
    var progress = RecognitionProgress()
    var match: GestureMatch?
    var scroll: Point2?
    var scrollRule: GestureRule?
    var scrollFeedback: ScrollFeedback?
    var volume: Double?
    var volumeRule: GestureRule?
}
struct RecognitionCoordinator {
    private var recognizers: [UUID: GestureRecognizer] = [:]
    private var cooldownUntil: Double = 0
    private var neutralRule: GestureRule?
    private var neutralSince: Double?
    private var activeScope = ""
    private var continuous: ContinuousGestureSession?
    private var continuousAccepted = false
    var continuousRule: GestureRule? { continuous?.rule }
    var continuousConfidenceDeadline: Double? { continuous?.confidenceDeadline }
    var continuousNeedsConfidence: Bool { continuous?.confidenceDeadline != nil }
    mutating func resolveAction(_ rule: GestureRule, accepted: Bool) {
        guard let active = continuous, active.rule == rule else { return }
        if accepted {
            continuousAccepted = true
            continuous?.motion = .init(origin: active.hand.palm)
            continuous?.volumeMotion = .init(origin: active.hand.palm)
        }
        else {
            continuous = nil; continuousAccepted = false
            if active.rule.requireNeutral { neutralRule = active.rule; neutralSince = nil }
        }
    }
    mutating func cancelPendingAction() {
        if let active = continuous, !continuousAccepted { resolveAction(active.rule, accepted: false) }
    }
    mutating func stopContinuous(at time: Double) {
        guard let active = continuous else { return }
        continuous = nil; continuousAccepted = false; recognizers.removeAll()
        cooldownUntil = max(cooldownUntil, (time.isFinite ? time : active.time) + active.rule.cooldown)
        if active.rule.requireNeutral { neutralRule = active.rule; neutralSince = nil }
    }
    mutating func reset() { self = Self() }
    mutating func finishInteractiveAction(_ rule: GestureRule, at time: Double) {
        recognizers.removeAll()
        if time.isFinite { cooldownUntil = max(cooldownUntil, time + rule.cooldown) }
        if rule.requireNeutral { neutralRule = rule; neutralSince = nil }
    }
    mutating func activeAppChanged(to app: String, at time: Double) {
        guard app != activeScope else { return }
        recognizers.removeAll(); activeScope = app
        if let active = continuous {
            cooldownUntil = max(cooldownUntil, (time.isFinite ? time : active.time) + active.rule.cooldown)
            if active.rule.requireNeutral { neutralRule = active.rule; neutralSince = nil }
        }
        continuous = nil
        // A Space switch may activate another app. Keep its cooldown and neutral latch.
    }
    mutating func process(_ frame: HandFrame, rules: [GestureRule], selected: UUID?, app: String, optionHeld: Bool) -> CoordinatorResult {
        guard frame.time.isFinite else { reset(); return .init() }
        if app != activeScope { activeAppChanged(to: app, at: frame.time) }
        var result = CoordinatorResult()
        if var active = continuous {
            guard (!active.rule.requireOptionKey || optionHeld),
                  rules.contains(where: { $0 == active.rule && $0.enabled && ($0.scope.isGlobal || $0.scope.bundleID == app) }),
                  let pixels = active.sample(frame) else {
                stopContinuous(at: frame.time)
                result.progress.message = active.rule.action.kind == .volume ? "Volume stopped" : "Scrolling stopped"; return result
            }
            let volume = active.rule.action.kind == .volume
            if continuousAccepted {
                if volume { result.volume = pixels; result.volumeRule = active.rule }
                else {
                    result.scroll = active.rule.action.kind == .scrollVertical ? .init(x: 0, y: pixels) : .init(x: pixels, y: 0)
                    result.scrollRule = active.rule
                }
            }
            if !volume { result.scrollFeedback = .init(action: active.rule.action, amount: continuousAccepted ? pixels : 0, preparing: !continuousAccepted) }
            let instruction = volume ? (active.confidenceDeadline == nil ? "Move to adjust volume · open your hand to stop" : "Keep fist visible · volume paused") : "Move to scroll · release to stop"
            result.progress = .init(step: active.rule.steps.count - 1, fraction: 1, message: continuousAccepted ? instruction : (volume ? "Preparing volume…" : "Preparing scroll…"), hand: active.hand)
            continuous = active
            return result
        }
        if let neutralRule {
            let start = neutralRule.steps.first?.pose ?? .init()
            if frame.hands.contains(where: { $0.matches(start, hand: neutralRule.hand, minimum: neutralRule.confidence) }) { neutralSince = nil }
            else if neutralSince == nil { neutralSince = frame.time }
            if let neutralSince, frame.time - neutralSince >= 0.25 { self.neutralRule = nil; self.neutralSince = nil }
            else { result.progress.message = "Lower your hand to reset"; return result }
        }
        if frame.time < cooldownUntil { result.progress.message = "Ready in a moment"; return result }
        let eligible = rules.filter { $0.enabled && ($0.scope.isGlobal || $0.scope.bundleID == app) }
            .sorted { !$0.scope.isGlobal && $1.scope.isGlobal }
        let allowedIDs = Set(eligible.map(\.id)); recognizers = recognizers.filter { allowedIDs.contains($0.key) }
        var candidates: [(GestureRule, RecognitionProgress)] = []
        // A closed fist can also bring thumb and index together. Give an enabled fist
        // volume rule precedence over the less-specific opening pinch, without changing saved poses.
        let fistVolume = eligible.contains { rule in
            rule.action.kind == .volume && rule.steps.first?.pose.kind == .fist &&
            (!rule.requireOptionKey || optionHeld) && frame.hands.count == 1 &&
            frame.hands[0].matches(rule.steps[0].pose, hand: rule.hand, minimum: rule.confidence)
        }
        for rule in eligible {
            if fistVolume && rule.action.kind == .switchApps { recognizers[rule.id] = nil; continue }
            if rule.action.kind.isContinuous && (frame.hands.count != 1 || (rule.action.kind == .volume && (frame.detectedHands ?? frame.hands.count) != 1)) {
                recognizers[rule.id] = nil
                if rule.id == selected { result.progress.message = frame.hands.isEmpty ? "No hand tracked · show your hand" : "Ambiguous hands · keep one visible" }
                continue
            }
            if rule.requireOptionKey && !optionHeld { recognizers[rule.id] = nil; if rule.id == selected { result.progress.message = "Hold Option to use this gesture" }; continue }
            var recognizer = recognizers[rule.id] ?? GestureRecognizer()
            let progress = recognizer.process(frame, rule: rule)
            recognizers[rule.id] = recognizer
            if rule.id == selected { result.progress = progress }
            if progress.matched { candidates.append((rule, progress)) }
        }
        if let (rule, progress) = candidates.first {
            result.match = .init(rule: rule, hand: progress.hand); result.progress = progress
            recognizers.removeAll(); cooldownUntil = frame.time + rule.cooldown
            if rule.action.kind.isContinuous, let hand = progress.hand {
                continuous = .init(rule: rule, hand: hand, time: frame.time)
                continuousAccepted = false
                if rule.action.kind.isScroll { result.scrollFeedback = .init(action: rule.action, amount: 0, preparing: true) }
            } else if rule.requireNeutral { neutralRule = rule }
        }
        return result
    }
}
