import Foundation

struct GestureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum HandChoice: String, Codable, CaseIterable, Sendable { case either = "Either hand", left = "Left hand", right = "Right hand" }
enum Finger: String, Codable, CaseIterable, Sendable { case thumb = "Thumb", index = "Index", middle = "Middle", ring = "Ring", little = "Little" }
enum FingerState: String, Codable, CaseIterable, Sendable { case any = "Any", extended = "Straight", curled = "Bent" }
enum PinchRequirement: String, Codable, CaseIterable, Sendable { case any = "Any", touching = "Pinched", apart = "Apart" }
enum PoseKind: String, Codable, CaseIterable, Sendable { case open = "Open palm", fist = "Fist", pinch = "Pinch", point = "Point", victory = "Two fingers", custom = "Custom pose", any = "Any pose" }

struct PoseDefinition: Codable, Equatable, Sendable {
    var kind: PoseKind = .open
    var thumb: FingerState = .any
    var index: FingerState = .extended
    var middle: FingerState = .extended
    var ring: FingerState = .extended
    var little: FingerState = .extended
    var pinch: PinchRequirement = .any
    func requirement(_ finger: Finger) -> FingerState {
        if kind == .custom {
            switch finger { case .thumb: return thumb; case .index: return index; case .middle: return middle; case .ring: return ring; case .little: return little }
        }
        switch kind {
        case .open: return finger == .thumb ? .any : .extended
        case .fist: return finger == .thumb ? .any : .curled
        case .point: return finger == .thumb ? .any : finger == .index ? .extended : .curled
        case .victory: return finger == .thumb ? .any : (finger == .index || finger == .middle) ? .extended : .curled
        default: return .any
        }
    }
    var pinchRequirement: PinchRequirement { kind == .pinch ? .touching : kind == .victory ? .apart : kind == .custom ? pinch : .any }
    var label: String { kind.rawValue }
}

enum StepKind: String, Codable, CaseIterable, Sendable { case pose = "Pose", hold = "Hold", move = "Move", slide = "Slide sideways", release = "Release" }
enum MoveDirection: String, Codable, CaseIterable, Sendable {
    case left = "Left", right = "Right", up = "Up", down = "Down", upLeft = "Up left", upRight = "Up right", downLeft = "Down left", downRight = "Down right"
    var vector: Point2 {
        let d = 1 / sqrt(2.0)
        switch self {
        case .left: return .init(x: -1, y: 0); case .right: return .init(x: 1, y: 0)
        case .up: return .init(x: 0, y: 1); case .down: return .init(x: 0, y: -1)
        case .upLeft: return .init(x: -d, y: d); case .upRight: return .init(x: d, y: d)
        case .downLeft: return .init(x: -d, y: -d); case .downRight: return .init(x: d, y: -d)
        }
    }
    var symbol: String {
        switch self { case .left: return "arrow.left"; case .right: return "arrow.right"; case .up: return "arrow.up"; case .down: return "arrow.down"; case .upLeft: return "arrow.up.left"; case .upRight: return "arrow.up.right"; case .downLeft: return "arrow.down.left"; case .downRight: return "arrow.down.right" }
    }
}
struct GestureStep: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: StepKind
    var pose = PoseDefinition()
    var duration: Double = 0.3
    var direction: MoveDirection = .left
    var distance: Double = 0.18
    var maximumDuration: Double = 2
    var label: String {
        switch kind {
        case .pose: return pose.label
        case .hold: return "Hold \(Int(duration * 1000)) ms"
        case .move: return "Move \(direction.rawValue.lowercased())"
        case .slide: return "Slide sideways"
        case .release: return "Release"
        }
    }
    var symbol: String {
        switch kind { case .pose: return "hand.raised"; case .hold: return "clock"; case .move: return direction.symbol; case .slide: return "arrow.left.arrow.right"; case .release: return "hand.wave" }
    }
}

enum ActionKind: String, Codable, CaseIterable, Sendable {
    case nextSpace = "Next Space", previousSpace = "Previous Space", missionControl = "Mission Control", appWindows = "App windows", keyboard = "Keyboard shortcut", shortcut = "macOS Shortcut", scrollVertical = "Vertical scroll", scrollHorizontal = "Horizontal scroll", switchApps = "Switch apps", volume = "Output volume"
    var isSpaceSwitch: Bool { self == .nextSpace || self == .previousSpace }
    var isScroll: Bool { self == .scrollVertical || self == .scrollHorizontal }
    var isContinuous: Bool { isScroll || self == .volume }
    var needsAccessibility: Bool { self != .shortcut && self != .volume }
    var symbol: String {
        switch self { case .nextSpace, .previousSpace: return "rectangle.on.rectangle"; case .missionControl, .appWindows: return "square.grid.2x2"; case .keyboard: return "keyboard"; case .shortcut: return "square.stack.3d.up"; case .scrollVertical: return "arrow.up.arrow.down"; case .scrollHorizontal: return "arrow.left.arrow.right"; case .switchApps: return "app.badge.checkmark"; case .volume: return "speaker.wave.2" }
    }
}
struct AppSwitcherSettings: Codable, Equatable, Sendable {
    var distancePerApp = 0.075
    var reversed = false
    var timeout = 15.0
    var onlyChosenApps = false
    var bundleIDs: [String] = []
    func validated() throws -> Self {
        guard distancePerApp.isFinite, (0.04...0.2).contains(distancePerApp), timeout.isFinite, (3...30).contains(timeout),
              bundleIDs.count <= 32, Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.allSatisfy({ !$0.isEmpty && $0.count <= 200 && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil }),
              !onlyChosenApps || !bundleIDs.isEmpty else { throw GestureError("Choose at least one app, and keep switcher distance and timeout within their supported ranges.") }
        return self
    }
    func includes(_ bundleID: String) -> Bool { !onlyChosenApps || bundleIDs.contains(bundleID) }
}
struct KeyBinding: Codable, Equatable, Sendable {
    var code: UInt16 = 124
    var label = "→" // Version-1 compatibility only; never trusted for presentation.
    var command = false
    var option = false
    var control = true
    var shift = false
    var display: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + KeyDisplay.label(for: code, command: command) }
}
struct GestureAction: Codable, Equatable, Sendable {
    var kind: ActionKind = .nextSpace
    var key = KeyBinding()
    var shortcutName = ""
    var scrollSensitivity: Double = 1
    var reverseScroll = false
    var scrolling: ScrollSettings?
    // Preserve the movement response of libraries saved before two-finger scrolling.
    var scrollSettings: ScrollSettings { scrolling ?? .init(jitterTolerance: 0) }
    // Optional for libraries saved before app switching was introduced.
    var appSwitcher: AppSwitcherSettings?
    var switcherSettings: AppSwitcherSettings { appSwitcher ?? .init() }
    var volume: VolumeSettings?
    var volumeSettings: VolumeSettings { volume ?? .init() }
    var title: String {
        switch kind { case .keyboard: return key.display; case .shortcut: return shortcutName.isEmpty ? "Choose a Shortcut" : shortcutName; default: return kind.rawValue }
    }
}
struct AppScope: Codable, Equatable, Sendable {
    var bundleID = ""
    var name = "All apps"
    var isGlobal: Bool { bundleID.isEmpty }
    var display: String { isGlobal ? "All apps" : bundleID }
}
struct GestureRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String = "My gesture"
    var enabled = true
    var hand: HandChoice = .either
    var steps: [GestureStep] = [.init(kind: .pose), .init(kind: .hold), .init(kind: .move)]
    var action = GestureAction()
    var scope = AppScope()
    var confidence: Double = 0.55
    var cooldown: Double = 0.8
    var requireNeutral = true
    var requireOptionKey = false
    var symbol: String { steps.first(where: { $0.kind == .move || $0.kind == .slide })?.symbol ?? "hand.draw" }
    var summary: String { steps.map(\.label).joined(separator: " → ") }
    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw GestureError("Give the gesture a name of up to 80 characters.") }
        guard (1...10).contains(steps.count), steps.first?.kind == .pose,
              Set(steps.map(\.id)).count == steps.count else { throw GestureError("Start with a pose and use up to ten steps.") }
        guard confidence.isFinite, (0.3...0.95).contains(confidence), cooldown.isFinite, (0.3...5).contains(cooldown) else { throw GestureError("Confidence or repeat delay is outside its supported range.") }
        for (index, step) in steps.enumerated() {
            guard step.duration.isFinite, (0.1...3).contains(step.duration),
                  step.distance.isFinite, (0.03...0.65).contains(step.distance),
                  step.maximumDuration.isFinite, (0.2...5).contains(step.maximumDuration) else { throw GestureError("A gesture step contains an invalid duration or distance.") }
            if step.kind == .release && index != steps.count - 1 { throw GestureError("Release must be the last step.") }
            if step.kind == .pose && step.pose.kind == .custom && Finger.allCases.allSatisfy({ step.pose.requirement($0) == .any }) && step.pose.pinchRequirement == .any { throw GestureError("Choose at least one finger or pinch condition for a custom pose.") }
        }
        if action.kind.isContinuous && steps.contains(where: { $0.kind == .release }) { throw GestureError("Continuous actions stop when you release the final pose. Remove the Release step.") }
        if let settings = action.appSwitcher { _ = try settings.validated() }
        if let settings = action.scrolling { _ = try settings.validated() }
        if let settings = action.volume { _ = try settings.validated() }
        if action.kind == .switchApps {
            _ = try action.switcherSettings.validated()
            guard steps.last(where: { $0.kind == .pose })?.pose.pinchRequirement == .touching,
                  !steps.contains(where: { $0.kind == .release }) else { throw GestureError("App switching must end with a pinched pose. Leave out Release: the picker handles opening your hand, browsing, and pinching again to confirm.") }
        }
        guard scope.name.count <= 100, scope.bundleID.count <= 200,
              scope.bundleID.isEmpty || scope.bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw GestureError("Choose a valid app profile.") }
        guard action.key.code <= 126, !action.key.label.isEmpty, action.key.label.count <= 40,
              action.scrollSensitivity.isFinite, (0.25...3).contains(action.scrollSensitivity),
              action.shortcutName.count <= 200, !action.shortcutName.contains("\n"), !action.shortcutName.contains("\r"), !action.shortcutName.contains("\0"), !action.shortcutName.hasPrefix("-") else { throw GestureError("This action contains an invalid setting.") }
        if action.kind == .shortcut && action.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw GestureError("Choose a macOS Shortcut for this action.") }
        return self
    }
    static var examples: [Self] {
        var left = Self(name: "Swipe left")
        var right = Self(name: "Swipe right"); right.steps[2].direction = .right; right.action.kind = .previousSpace
        left.action.kind = .nextSpace
        return [left, right, twoFingerScrollPreset, appSwitcherPreset, volumePreset]
    }
    static var volumePreset: Self {
        var rule = Self(name: "Fist & slide", enabled: false)
        rule.steps = [.init(kind: .pose, pose: .init(kind: .fist))]
        rule.action.kind = .volume; rule.action.volume = .init()
        return rule
    }
    static var twoFingerScrollPreset: Self {
        var rule = Self(name: "Two-finger scroll", enabled: false)
        rule.steps = [.init(kind: .pose, pose: .init(kind: .victory))]
        rule.action.kind = .scrollVertical; rule.action.scrolling = .init()
        return rule
    }
    static var appSwitcherPreset: Self {
        var rule = Self(name: "Pinch & slide", enabled: false)
        rule.steps = [.init(kind: .pose, pose: .init(kind: .pinch))]
        rule.action.kind = .switchApps; rule.action.appSwitcher = .init()
        return rule
    }
}
struct GestureLibrary: Codable, Equatable, Sendable {
    var version = 1
    var rules: [GestureRule] = GestureRule.examples
    func validated() throws -> Self {
        guard version == 1, rules.count <= 100, Set(rules.map(\.id)).count == rules.count else { throw GestureError("This gesture library is invalid or from an unsupported version.") }
        for rule in rules { _ = try rule.validated() }
        return self
    }
}

struct Point2: Codable, Equatable, Sendable {
    var x: Double; var y: Double
    static func +(lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func -(lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func *(lhs: Self, rhs: Double) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs) }
    var length: Double { hypot(x, y) }
    func dot(_ other: Self) -> Double { x * other.x + y * other.y }
    var finite: Bool { x.isFinite && y.isFinite }
}
struct Landmark: Sendable, Equatable { var point: Point2; var confidence: Double }
struct TrackedHand: Sendable, Equatable {
    var side: HandChoice
    var joints: [String: Landmark]
    var palm: Point2
    var confidence: Double
    var fingers: [Finger: FingerState]
    var pinchRatio: Double?
    // Joint names that positively establish a curl; generated from geometry, never from missing data.
    var curledEvidence: [Finger: [String]] = [:]
    func matches(_ pose: PoseDefinition, hand: HandChoice, minimum: Double) -> Bool {
        guard confidence.isFinite, confidence >= minimum, confidence <= 1, palm.finite,
              (0...1).contains(palm.x), (0...1).contains(palm.y),
              hand == .either || side == hand else { return false }
        for finger in Finger.allCases {
            let required = pose.requirement(finger)
            if required != .any {
                guard fingers[finger] == required else { return false }
                let prefix = finger == .little ? "little" : finger.rawValue.lowercased()
                let fullChain = finger == .thumb ? ["thumbCMC", "thumbMCP", "thumbIP", "thumbTip"] : [prefix + "MCP", prefix + "PIP", prefix + "DIP", prefix + "Tip"]
                let names = pose.kind == .fist && required == .curled ? curledEvidence[finger] ?? fullChain : fullChain
                guard names.count >= 3, names.allSatisfy({ joints[$0].map { $0.confidence >= minimum && $0.point.finite } == true }) else { return false }
            }
        }
        if pose.pinchRequirement != .any, !hasPinchLandmarks(minimum: minimum) { return false }
        switch pose.pinchRequirement {
        case .touching: guard let pinchRatio, pinchRatio.isFinite, pinchRatio >= 0, pinchRatio < 0.32 else { return false }
        case .apart: guard let pinchRatio, pinchRatio.isFinite, pinchRatio > 0.48 else { return false }
        case .any: break
        }
        return true
    }
    private func hasPinchLandmarks(minimum: Double) -> Bool {
        ["thumbTip", "indexTip", "indexMCP", "littleMCP"].allSatisfy {
            joints[$0].map { $0.confidence >= minimum && $0.point.finite } == true
        }
    }
    func pinchGuidance(minimum: Double) -> String {
        guard hasPinchLandmarks(minimum: minimum) else { return "Show thumb, index, and palm clearly" }
        guard pinchRatio != nil else { return "Face your palm toward the camera" }
        return "Bring thumb and index fingertips together"
    }
    func fistGuidance(minimum: Double) -> String {
        for finger in [Finger.index, .middle, .ring, .little] {
            let prefix = finger.rawValue.lowercased()
            let evidence = curledEvidence[finger] ?? [prefix + "MCP", prefix + "PIP", prefix + "DIP", prefix + "Tip"]
            if !evidence.allSatisfy({ joints[$0].map { $0.confidence >= minimum && $0.point.finite } == true }) {
                return "Turn your fist slightly · show \(prefix) finger"
            }
            if fingers[finger] != .curled { return "Bend your \(prefix) finger into your palm" }
        }
        return "Hold one clear fist briefly"
    }
    /// Uncertainty can freeze an existing volume session, but can never authorize movement.
    func fistIsUncertain(hand: HandChoice, minimum: Double) -> Bool {
        guard confidence.isFinite, (0.3...1).contains(confidence), palm.finite,
              (0...1).contains(palm.x), (0...1).contains(palm.y),
              hand == .either || side == hand,
              !matches(.init(kind: .fist), hand: hand, minimum: minimum) else { return false }
        for finger in [Finger.index, .middle, .ring, .little] where fingers[finger] == .extended {
            let prefix = finger.rawValue.lowercased()
            if ["MCP", "PIP", "DIP", "Tip"].allSatisfy({ suffix in
                joints[prefix + suffix].map { $0.confidence >= minimum && $0.point.finite } == true
            }) { return false } // A confidently opened finger is a release, not uncertainty.
        }
        return true
    }
    /// Arbitration only: a partially occluded fist must not fall through to pinch.
    /// Starting or moving volume still requires the complete configured fist pose.
    func isFistCandidate(hand: HandChoice, minimum: Double) -> Bool {
        guard matches(.init(kind: .any), hand: hand, minimum: minimum) else { return false }
        if matches(.init(kind: .fist), hand: hand, minimum: minimum) { return true }
        guard fistIsUncertain(hand: hand, minimum: minimum) else { return false }
        let visibleBends = [Finger.index, .middle, .ring, .little].filter { finger in
            guard fingers[finger] == .curled else { return false }
            let prefix = finger.rawValue.lowercased()
            let names = curledEvidence[finger] ?? [prefix + "MCP", prefix + "PIP", prefix + "DIP", prefix + "Tip"]
            return names.count >= 3 && names.allSatisfy { joints[$0].map { $0.confidence >= minimum && $0.point.finite } == true }
        }
        return visibleBends.count >= 3
    }
}
struct HandFrame: Sendable {
    var time: Double
    var hands: [TrackedHand]
    var width: Double = 1280
    var height: Double = 720
    var detectedHands: Int? = nil
}
