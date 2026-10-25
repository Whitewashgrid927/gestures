import AppKit
import ApplicationServices
import Carbon
import Foundation

struct PlannedKey: Equatable, Sendable {
    var code: UInt16
    var command = false; var option = false; var control = false; var shift = false
}
enum ActionPlan: Equatable, Sendable { case key(PlannedKey), shortcut(String), continuous, appPicker }
enum ActionPlanner {
    static func plan(_ action: GestureAction) -> ActionPlan {
        switch action.kind {
        case .nextSpace: return .key(.init(code: 124, control: true))
        case .previousSpace: return .key(.init(code: 123, control: true))
        case .missionControl: return .key(.init(code: 126, control: true))
        case .appWindows: return .key(.init(code: 125, control: true))
        case .keyboard: return .key(.init(code: action.key.code, command: action.key.command, option: action.key.option, control: action.key.control, shift: action.key.shift))
        case .shortcut: return .shortcut(action.shortcutName)
        case .scrollVertical, .scrollHorizontal: return .continuous
        case .switchApps: return .appPicker
        }
    }
}
struct DispatchPermission: Sendable {
    var enabled: Bool
    var testing: Bool
    var cameraRunning: Bool
    var editing: Bool
    var frameAge: Double
    var frontApp: String
    var optionHeld = false
    func allows(_ rule: GestureRule) -> Bool {
        enabled && !testing && cameraRunning && !editing && frameAge >= 0 && frameAge <= 0.35 && rule.enabled &&
        (!rule.requireOptionKey || optionHeld) && (rule.scope.isGlobal || rule.scope.bundleID == frontApp)
    }
}

/// Builds complete key pairs without posting them, so event metadata is testable.
enum KeyboardEvents {
    static func flags(for key: PlannedKey) -> CGEventFlags {
        var flags: CGEventFlags = []
        if key.command { flags.insert(.maskCommand) }; if key.option { flags.insert(.maskAlternate) }
        if key.control { flags.insert(.maskControl) }; if key.shift { flags.insert(.maskShift) }
        if (123...126).contains(key.code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        return flags
    }
    static func pair(_ key: PlannedKey, systemNavigation: Bool, physicalFlags: CGEventFlags) throws -> (source: CGEventSource, down: CGEvent, up: CGEvent) {
        guard let source = CGEventSource(stateID: systemNavigation ? .hidSystemState : .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else { throw GestureError("macOS could not create the keyboard action.") }
        down.flags = flags(for: key)
        // Release synthetic modifiers while preserving the user's physical modifiers.
        let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskAlphaShift, .maskSecondaryFn]
        up.flags = physicalFlags.intersection(modifiers)
        if (123...126).contains(key.code) { up.flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        return (source, down, up)
    }
}

/// System shortcuts need the modifier's own transitions as well as arrow flags.
/// This factory creates events only; the runner controls posting and cleanup.
struct NavigationKeyEvents {
    let source: CGEventSource
    let controlDown: CGEvent?
    let arrowDown: CGEvent
    let arrowUp: CGEvent
    let controlUp: CGEvent?

    init(_ key: PlannedKey, physicalFlags: CGEventFlags) throws {
        guard key.control, (123...126).contains(key.code),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else { throw GestureError("macOS could not create the navigation action.") }
        self.source = source
        down.flags = KeyboardEvents.flags(for: key)
        up.flags = down.flags
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        arrowDown = down; arrowUp = up
        if physicalFlags.contains(.maskControl) {
            controlDown = nil; controlUp = nil
            up.flags.formUnion(physicalFlags)
        } else {
            guard let press = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: true),
                  let release = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: false) else { throw GestureError("macOS could not create the Control key action.") }
            press.flags = .maskControl
            release.flags = physicalFlags
            controlDown = press; controlUp = release
        }
    }
}

@MainActor
final class ActionRunner {
    private var shortcut: Process?
    private var shortcutTimeout: Task<Void, Never>?
    private var lastAction: Double = 0
    private var pendingKeyUps: [CGEvent] = []
    private var keySource: CGEventSource?
    private var keyReleaseTask: Task<Void, Never>?
    static var hasAccess: Bool { CGPreflightPostEventAccess() }
    static var secureInput: Bool { IsSecureEventInputEnabled() }

    static func openAccessibilitySettings() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @discardableResult
    func execute(_ rule: GestureRule, permission: DispatchPermission, completion: @escaping @MainActor (String) -> Void) throws -> Bool {
        guard permission.allows(rule), !Self.secureInput else { throw GestureError("Control is paused. No action was sent.") }
        _ = try rule.validated()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAction >= 0.3 else { return false }
        if rule.action.kind.needsAccessibility && !Self.hasAccess { throw GestureError("Allow Gestures in Accessibility before enabling Mac control.") }
        switch ActionPlanner.plan(rule.action) {
        case .key(let key):
            let systemNavigation = rule.action.kind.isSpaceSwitch || rule.action.kind == .missionControl || rule.action.kind == .appWindows
            let physicalFlags = CGEventSource.flagsState(.hidSystemState)
            releasePendingKey()
            if systemNavigation {
                let events = try NavigationKeyEvents(key, physicalFlags: physicalFlags)
                keySource = events.source
                if let down = events.controlDown, let up = events.controlUp {
                    pendingKeyUps = [up]; postKey(down)
                }
                keyReleaseTask = Task { [weak self] in
                    if events.controlDown != nil { try? await Task.sleep(for: .milliseconds(20)) }
                    guard !Task.isCancelled, let self else { return }
                    guard Self.hasAccess, !Self.secureInput else { self.releasePendingKey(); return }
                    self.pendingKeyUps.insert(events.arrowUp, at: 0); self.postKey(events.arrowDown)
                    completion("Sent \(rule.action.title)")
                    try? await Task.sleep(for: .milliseconds(45))
                    guard !Task.isCancelled else { return }
                    self.releaseNextKey()
                    if events.controlUp != nil { try? await Task.sleep(for: .milliseconds(20)) }
                    guard !Task.isCancelled else { return }
                    self.releasePendingKey()
                }
            } else {
                let pair = try KeyboardEvents.pair(key, systemNavigation: false, physicalFlags: physicalFlags)
                keySource = pair.source; pendingKeyUps = [pair.up]; postKey(pair.down)
                completion("Sent \(rule.action.title)")
                keyReleaseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(45))
                    guard !Task.isCancelled else { return }
                    self?.releasePendingKey()
                }
            }
            lastAction = now
        case .shortcut(let name):
            guard shortcut == nil else { completion("The previous Shortcut is still running"); return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in
                    guard let self else { return }
                    self.shortcutTimeout?.cancel(); self.shortcutTimeout = nil; self.shortcut = nil
                    completion(status == 0 ? "Shortcut finished" : "Shortcut stopped or failed (\(status))")
                }
            }
            try process.run(); shortcut = process; lastAction = now
            shortcutTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.cancelShortcut()
            }
            completion("Running \(name)")
        case .continuous: lastAction = now; completion("Scrolling · release the pose to stop")
        case .appPicker: throw GestureError("Choose an app in the pinch-and-slide picker before switching.")
        }
        return true
    }
    func activate(_ target: AppSwitchTarget, rule: GestureRule, permission: DispatchPermission) throws -> Bool {
        guard rule.action.kind == .switchApps, permission.allows(rule), Self.hasAccess, !Self.secureInput,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == permission.frontApp,
              rule.action.switcherSettings.includes(target.bundleID) else { throw GestureError("App switching is paused. No app was activated.") }
        _ = try rule.validated()
        guard let app = target.runningApplication else { throw GestureError("That app is no longer running. Try the gesture again.") }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAction >= 0.3 else { return false }
        let accepted: Bool
        if NSRunningApplication.current.isActive, let application = NSApp {
            application.yieldActivation(to: app)
            accepted = app.activate(from: .current, options: [.activateAllWindows])
        } else {
            accepted = app.activate(options: [.activateAllWindows])
        }
        if accepted { lastAction = now }
        return accepted
    }
    @discardableResult
    func scroll(_ delta: Point2, rule: GestureRule, permission: DispatchPermission) -> Bool {
        guard permission.allows(rule), rule.action.kind.isContinuous, !Self.secureInput, Self.hasAccess, delta.finite,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == permission.frontApp else { return false }
        let x = Int32(max(-45, min(45, delta.x)).rounded()), y = Int32(max(-45, min(45, delta.y)).rounded())
        if x == 0 && y == 0 { return true }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
    private func postKey(_ event: CGEvent) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.post(tap: .cghidEventTap)
    }
    private func releaseNextKey() {
        guard !pendingKeyUps.isEmpty else { return }
        postKey(pendingKeyUps.removeFirst())
    }
    private func releasePendingKey() {
        keyReleaseTask?.cancel(); keyReleaseTask = nil
        while !pendingKeyUps.isEmpty { releaseNextKey() }
        keySource = nil
    }
    func cancelAll() { releasePendingKey(); cancelShortcut() }
    func cancelShortcut() { if let shortcut, shortcut.isRunning { shortcut.terminate() }; shortcutTimeout?.cancel(); shortcutTimeout = nil }

    nonisolated static func shortcutNames() throws -> [String] {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); process.arguments = ["list"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0, data.count < 1_000_000 else { throw GestureError("Could not list your Shortcuts. You can enter an exact Shortcut name instead.") }
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).sorted().prefix(300).map { $0 }
    }
}
