import Foundation

/// A short visual prelude must not turn an old gesture into a delayed command.
/// Camera freshness is checked again using the latest delivered frame.
enum PreActionInput {
    static func isFresh(recognizedAt: Double, latestFrameAt: Double, now: Double) -> Bool {
        recognizedAt.isFinite && latestFrameAt.isFinite && now.isFinite &&
        now >= recognizedAt && now - recognizedAt <= 0.65 &&
        latestFrameAt >= recognizedAt && now >= latestFrameAt && now - latestFrameAt <= 0.35
    }
}

enum ControlMode: Equatable {
    case cameraOff, preview, testing, live
    static func resolve(cameraRunning: Bool, enabled: Bool, testing: Bool) -> Self {
        guard cameraRunning else { return .cameraOff }
        if testing { return .testing }
        return enabled ? .live : .preview
    }
    var title: String {
        switch self {
        case .cameraOff: return "Camera and Mac control are off"
        case .preview: return "Preview only · Mac control is off"
        case .testing: return "Practice only · actions are off"
        case .live: return "Mac control is on"
        }
    }
    var detail: String {
        switch self {
        case .cameraOff: return "Start the camera, then enable Mac control when you’re ready."
        case .preview: return "Seeing your hand does not run actions. Enable Mac control to use your gestures."
        case .testing: return "Recognition only. Enable Mac control when you want gestures to perform actions."
        case .live: return "Gestures work in other apps too. Close this window to keep running from the menu bar."
        }
    }
}

/// Confirms a system Space-change notification only while a sent action is pending.
/// It records timing only, never window names, desktop contents, or camera data.
struct SpaceChangeCheck {
    private(set) var started: Double?
    mutating func begin(at time: Double) { started = time.isFinite ? time : nil }
    mutating func cancel() { started = nil }
    mutating func observed(at time: Double) -> Bool {
        guard let started, time.isFinite, time >= started, time - started < 2.5 else { return false }
        self.started = nil
        return true
    }
    mutating func expired(at time: Double) -> Bool {
        guard let started, time.isFinite, time - started >= 2.5 else { return false }
        self.started = nil
        return true
    }
}
