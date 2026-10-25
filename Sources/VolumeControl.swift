import AppKit
import CoreAudio

enum VolumeAxis: String, Codable, CaseIterable, Sendable { case vertical = "Up / down", horizontal = "Left / right" }

/// Aggregate, in-memory feedback. No coordinates, images, timestamps, or device identifiers.
struct VolumeRecognitionCheck: Equatable, Sendable {
    private var sawObservation = false
    private var sawTrackedHand = false
    private var bent = -1
    private var clear = 0
    private var confidence = 0.0
    private var minimum = 0.55
    private var hold = 0.0
    private var matched = false
    mutating func observe(_ frame: HandFrame, rule: GestureRule, progress: RecognitionProgress, accepted: Bool) {
        guard rule.action.kind == .volume else { return }
        minimum = rule.confidence
        sawObservation = sawObservation || (frame.detectedHands ?? frame.hands.count) > 0
        sawTrackedHand = sawTrackedHand || !frame.hands.isEmpty
        matched = matched || accepted
        if rule.steps.indices.contains(progress.step), rule.steps[progress.step].kind == .pose,
           rule.steps[progress.step].pose.kind == .fist, progress.fraction.isFinite,
           frame.hands.contains(where: { $0.matches(.init(kind: .fist), hand: rule.hand, minimum: rule.confidence) }) {
            hold = max(hold, min(1, max(0, progress.fraction)))
        }
        for hand in frame.hands where hand.confidence.isFinite {
            var bends = 0; var clearBends = 0
            for finger in [Finger.index, .middle, .ring, .little] where hand.fingers[finger] == .curled {
                bends += 1
                let prefix = finger.rawValue.lowercased()
                let evidence = hand.curledEvidence[finger] ?? [prefix + "MCP", prefix + "PIP", prefix + "DIP", prefix + "Tip"]
                if evidence.count >= 3 && evidence.allSatisfy({ hand.joints[$0].map { $0.confidence >= rule.confidence && $0.point.finite } == true }) { clearBends += 1 }
            }
            if bends > bent || (bends == bent && (clearBends > clear || (clearBends == clear && hand.confidence > confidence))) {
                bent = bends; clear = clearBends; confidence = min(1, max(0, hand.confidence))
            }
        }
    }
    var summary: String {
        if matched { return "Fist recognition passed this attempt." }
        if !sawObservation { return "This attempt: no hand detected by the camera yet." }
        if !sawTrackedHand { return "This attempt: a hand was seen, but its palm could not be tracked clearly." }
        return "Best fist: \(max(0, bent))/4 bent · \(clear)/4 clear at \(Int((minimum * 100).rounded()))% · hand \(Int((confidence * 100).rounded()))% · held \(Int((hold * 120).rounded()))/120 ms"
    }
}

struct VolumeSettings: Codable, Equatable, Sendable {
    var axis = VolumeAxis.vertical
    var sensitivity = 1.0
    var reversed = false
    var jitterTolerance = 0.003
    var maximum = 0.8
    var showIndicator = true
    func validated() throws -> Self {
        guard sensitivity.isFinite, (0.25...3).contains(sensitivity),
              jitterTolerance.isFinite, (0...0.015).contains(jitterTolerance),
              maximum.isFinite, (0.1...1).contains(maximum) else { throw GestureError("Keep volume sensitivity, steadiness, and ceiling within their supported ranges.") }
        return self
    }
    func target(from current: Double, delta: Double) -> Double {
        // Engaging above the ceiling must not abruptly lower the current volume.
        if delta > 0 { return max(current, min(maximum, current + delta)) }
        return max(0, current + delta)
    }
}

struct VolumeMotion {
    private var anchor: Point2
    init(origin: Point2) { anchor = origin }
    mutating func sample(_ point: Point2, elapsed: Double, settings: VolumeSettings) -> Double {
        guard point.finite, elapsed.isFinite, elapsed > 0, elapsed <= 0.25 else { return 0 }
        let delta = settings.axis == .vertical ? point.y - anchor.y : point.x - anchor.x
        let slack = settings.jitterTolerance
        guard abs(delta) > slack else { return 0 }
        let movement = delta - (delta > 0 ? slack : -slack)
        if settings.axis == .vertical { anchor.y += movement } else { anchor.x += movement }
        // Discard clipped excess. A stationary hand never continues changing volume.
        let cap = min(0.025, elapsed * 0.35)
        return max(-cap, min(cap, movement * 2 * settings.sensitivity * (settings.reversed ? -1 : 1)))
    }
}

struct OutputVolume: Equatable {
    let device: UInt32
    let uid: String // Session identity only. Never persisted or displayed.
    let level: Double
    let muted: Bool
    var valid: Bool { device != 0 && !uid.isEmpty && level.isFinite && (0...1).contains(level) }
    func sameDevice(as other: Self) -> Bool { device == other.device && uid == other.uid }
}

@MainActor protocol OutputVolumeDevice {
    func read() throws -> OutputVolume
    func write(_ level: Double, expecting: OutputVolume) throws
}

/// Only a writable main scalar is supported. Never guess channel layouts or alter balance/mute.
@MainActor final class CoreAudioVolumeDevice: OutputVolumeDevice {
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var property = address(selector, scope: scope); var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout.size(ofValue: value) else { throw GestureError("Audio output is unavailable. Release your hand and try again.") }
        return value
    }
    private func defaultDevice() throws -> AudioObjectID {
        try integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
    }
    func read() throws -> OutputVolume {
        let device = try defaultDevice()
        guard device != kAudioObjectUnknown,
              try integer(device, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal) == 1 else { throw GestureError("No active audio output. Release your hand and try again.") }
        var property = address(kAudioDevicePropertyVolumeScalar)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &property),
              AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue else {
            throw GestureError("This output has no supported system volume control. Use its own volume controls or choose another output in Sound settings.")
        }
        var value: Float32 = 0; var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout.size(ofValue: value) else { throw GestureError("Could not read the output volume.") }
        var uid: Unmanaged<CFString>?
        property = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        size = UInt32(MemoryLayout.size(ofValue: uid))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid) == noErr,
              let uid else { throw GestureError("Could not identify the audio output.") }
        let identity = uid.takeRetainedValue() as String
        property = address(kAudioDevicePropertyMute)
        let muted = AudioObjectHasProperty(device, &property) ? try integer(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) != 0 : false
        let result = OutputVolume(device: device, uid: identity, level: Double(value), muted: muted)
        guard result.valid, try defaultDevice() == device else { throw GestureError("Audio output changed. Release your hand and try again.") }
        return result
    }
    func write(_ level: Double, expecting: OutputVolume) throws {
        guard level.isFinite, (0...1).contains(level) else { throw GestureError("Invalid volume change was blocked.") }
        // Re-read immediately before each write; never carry a baseline to a different output.
        let current = try read()
        guard current.sameDevice(as: expecting), !current.muted,
              abs(current.level - expecting.level) < 0.0001 else { throw GestureError("Audio output or volume changed elsewhere. Release your hand and try again.") }
        var property = address(kAudioDevicePropertyVolumeScalar); var value = Float32(level)
        guard AudioObjectSetPropertyData(current.device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr else {
            throw GestureError("The audio output rejected the volume change.")
        }
    }
}

struct VolumeFeedback: Equatable {
    var level = 0.5
    var maximum = 0.8
    var muted = false
    var preparing = false
    var label: String { preparing ? "Preparing" : muted ? "Muted" : level >= maximum - 0.005 ? "At ceiling" : "Output volume" }
}

/// One synchronous write at a time, with readback before another change. Practice uses no device API.
@MainActor final class VolumeController {
    private let device: any OutputVolumeDevice
    private var rule: GestureRule?
    private var practicing = false
    private var output: OutputVolume?
    private var desired = 0.5
    private var requested: (level: Double, time: Double)?
    private var lastTime = 0.0
    private(set) var feedback: VolumeFeedback?
    init(device: any OutputVolumeDevice = CoreAudioVolumeDevice()) { self.device = device }
    private func allowed(_ rule: GestureRule, _ permission: DispatchPermission) -> Bool {
        permission.allows(rule) && !ActionRunner.secureInput && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == permission.frontApp
    }
    func begin(_ rule: GestureRule, practicing: Bool, permission: DispatchPermission, at time: Double) throws {
        cancel()
        guard rule.action.kind == .volume, time.isFinite, practicing || allowed(rule, permission) else { throw GestureError("Volume control is paused.") }
        _ = try rule.validated()
        let current = practicing ? nil : try device.read()
        guard current == nil || current?.valid == true else { throw GestureError("Invalid audio output state.") }
        self.rule = rule; self.practicing = practicing; output = current; lastTime = time
        desired = current?.level ?? min(0.5, rule.action.volumeSettings.maximum)
        feedback = .init(level: desired, maximum: rule.action.volumeSettings.maximum, muted: current?.muted ?? false)
    }
    func change(_ delta: Double, rule: GestureRule, permission: DispatchPermission, at time: Double) throws {
        do {
            guard self.rule == rule, delta.isFinite, time.isFinite, time > lastTime, time - lastTime <= 0.25,
                  practicing || allowed(rule, permission) else { throw GestureError("Volume control stopped. Release your hand to reset.") }
            let elapsed = time - lastTime; lastTime = time
            let bounded = max(-min(0.025, elapsed * 0.35), min(min(0.025, elapsed * 0.35), delta))
            let settings = rule.action.volumeSettings
            if practicing {
                desired = settings.target(from: desired, delta: bounded)
                feedback = .init(level: desired, maximum: settings.maximum); return
            }
            guard let previous = output else { throw GestureError("Volume control is not armed.") }
            let current = try device.read()
            guard current.valid, current.sameDevice(as: previous), current.muted == previous.muted else { throw GestureError("Audio output or mute changed. Release your hand to reset.") }
            if let pending = requested {
                // Hardware may quantize scalar values. Wait for acknowledgment; never build a write queue.
                if abs(current.level - pending.level) <= 0.002 { requested = nil }
                else if time - pending.time <= 0.25 {
                    guard abs(current.level - previous.level) < 0.0001 else { throw GestureError("Volume changed elsewhere. Release your hand to reset.") }
                    return
                } else { throw GestureError("The audio output did not confirm the volume change.") }
            } else if abs(current.level - previous.level) > 0.0001 {
                throw GestureError("Volume changed elsewhere. Release your hand to reset.")
            }
            output = current
            feedback = .init(level: current.level, maximum: settings.maximum, muted: current.muted)
            guard !current.muted else { return } // Never unmute or adjust a muted output behind the user's back.
            desired = settings.target(from: desired, delta: bounded)
            // Stationary hands issue no writes, even if the hardware rounded a previous request.
            guard bounded != 0, abs(desired - current.level) >= 0.005 else { return }
            let cap = min(0.025, elapsed * 0.35)
            let target = settings.target(from: current.level, delta: max(-cap, min(cap, desired - current.level)))
            desired = target
            try device.write(target, expecting: current)
            requested = (target, time)
        } catch { cancel(); throw error }
    }
    func cancel() { rule = nil; output = nil; requested = nil; feedback = nil; practicing = false }
}
