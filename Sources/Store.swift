import AppKit
import Combine
import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

extension UTType { static let gesturesLibrary = UTType(exportedAs: "org.gestures.studio.library", conformingTo: .json) }

@MainActor
final class TrackingPresentation: ObservableObject {
    @Published var frame = HandFrame(time: 0, hands: [])
    @Published var progress = RecognitionProgress()
    @Published var lastMatch = ""
    @Published var testMatches = 0
    @Published var actionStatus = ""
    @Published var completedGestures = 0
}
struct EditorDraft: Identifiable { var id: UUID { rule.id }; var rule: GestureRule; var note: String = "" }

@MainActor
final class GestureStore: ObservableObject {
    @Published private(set) var library = GestureLibrary()
    @Published var selectedID: UUID?
    @Published var selectedProfile = "*"
    @Published private(set) var enabled = false
    @Published private(set) var testing = false
    @Published private(set) var cameraStatus = CameraStatus.off
    @Published var cameras: [CameraChoice] = []
    @Published var selectedCamera = ""
    @Published var editor: EditorDraft?
    @Published var showFineTune = false
    @Published var showHelp = false
    @Published var showGlassAppearance = false {
        didSet { if showGlassAppearance { disableControl(); testing = false } }
    }
    @Published var showPermissions = false
    @Published var errorMessage: String?
    @Published var notice = "Make a gesture your own."
    @Published var accessible = ActionRunner.hasAccess
    @Published var recording = false
    @Published var recordingSeconds = 0
    @Published var shortcutNames: [String] = []
    @Published var loadingShortcuts = false
    @Published private(set) var spaceCheckPending = false
    @Published var glassFeedbackEnabled = true {
        didSet {
            desktopRipple.enabled = glassFeedbackEnabled
            preferences.set(glassFeedbackEnabled, forKey: "glassFeedbackEnabled")
        }
    }
    let tracking = TrackingPresentation()
    let storage: URL
    let runner = ActionRunner()
    private let desktopRipple = DesktopRippleController()
    private let preferences: UserDefaults
    @Published private(set) var screenRippleReady = false
    @Published private(set) var preActionPending = false
    private var preActionID = UUID()
    private var coordinator = RecognitionCoordinator()
    private var history: [GestureLibrary] = []
    private var redoHistory: [GestureLibrary] = []
    private var cameraWanted = false
    private var cameraRequest = UUID()
    private var lastFrameAt: Double = 0
    private var watchdog: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var recordedFrames: [HandFrame] = []
    private var observers: [NSObjectProtocol] = []
    private var recoveryRequired = false
    private var recognitionActivity: NSObjectProtocol?
    private var spaceCheck = SpaceChangeCheck()
    private var spaceTimeout: Task<Void, Never>?
    private(set) var manualSpaceCheck = false
    private var manualSpaceTask: Task<Void, Never>?
    private weak var spaceCheckWindow: NSWindow?
    private var spaceCheckWindowWasActive = false
    lazy var camera = CameraPipeline(onFrame: { [weak self] generation, frame in
        Task { @MainActor in guard self?.cameraRequest == generation else { return }; self?.receive(frame) }
    }, onStatus: { [weak self] generation, status in
        Task { @MainActor in guard self?.cameraRequest == generation else { return }; self?.cameraChanged(status) }
    })
    var selected: GestureRule? { library.rules.first { $0.id == selectedID } }
    var visibleRules: [GestureRule] { library.rules.filter { selectedProfile == "*" || $0.scope.bundleID == selectedProfile } }
    var profiles: [AppScope] {
        var seen: Set<String> = []
        return library.rules.map(\.scope).filter { !$0.isGlobal && seen.insert($0.bundleID).inserted }.sorted { $0.display < $1.display }
    }
    var isEditing: Bool { editor != nil || showFineTune || showGlassAppearance }
    var cameraRunning: Bool { cameraStatus == .running }
    var controlMode: ControlMode { .resolve(cameraRunning: cameraRunning, enabled: enabled, testing: testing) }
    var canCheckSpace: Bool {
        enabled && !testing && cameraRunning && !recording && !isEditing && !spaceCheckPending && !preActionPending && selected?.enabled == true && selected?.action.kind.isSpaceSwitch == true
    }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var frontApp: String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

    init(storage: URL? = nil, observeSystem: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gestures", isDirectory: true)
        glassFeedbackEnabled = preferences.object(forKey: "glassFeedbackEnabled") as? Bool ?? true
        desktopRipple.enabled = glassFeedbackEnabled
        desktopRipple.consent = preferences.bool(forKey: "screenRippleConsent")
        screenRippleReady = desktopRipple.consent && DesktopRippleController.hasScreenAccess
        if screenRippleReady { desktopRipple.prepare() }
        do {
            try FileManager.default.createDirectory(at: self.storage, withIntermediateDirectories: true)
            let file = self.storage.appendingPathComponent("Library.gestures")
            if FileManager.default.fileExists(atPath: file.path) { library = try LibraryIO.load(file) }
        } catch { errorMessage = "Your saved library could not be opened. It will be preserved when you save a repaired copy. \(error.localizedDescription)"; recoveryRequired = true }
        selectedID = library.rules.first?.id
        if observeSystem {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelPreAction() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelPreAction(); self?.desktopRipple.displaysChanged() }
            })
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopCamera(); self?.notice = "Paused for sleep or screen lock." } })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancelPreAction()
                    self.coordinator.activeAppChanged(to: self.frontApp, at: ProcessInfo.processInfo.systemUptime)
                }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                let observedAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.spaceDidChange(at: observedAt) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cameraFailed("The camera session was interrupted. Start it again when it is available.") } })
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cameraFailed("Camera access was interrupted. Control has been paused.") } })
        }
    }
    func refreshPermissions() {
        accessible = ActionRunner.hasAccess
        screenRippleReady = desktopRipple.consent && DesktopRippleController.hasScreenAccess
        if screenRippleReady { desktopRipple.prepare() }
    }
    func requestScreenRippleAccess() {
        desktopRipple.consent = true
        preferences.set(true, forKey: "screenRippleConsent")
        glassFeedbackEnabled = true
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if screenRippleReady { glassFeedbackEnabled = true; notice = "Desktop ripple is ready. Screen frames stay in memory." }
        else { notice = "Allow Gestures in System Settings → Privacy & Security → Screen & System Audio Recording. Restart Gestures if macOS asks." }
    }
    func select(_ id: UUID) { cancelPreAction(); selectedID = id; coordinator.reset(); tracking.progress = .init(); tracking.lastMatch = ""; tracking.actionStatus = "" }
    func selectProfile(_ value: String) { cancelPreAction(); selectedProfile = value; if !visibleRules.contains(where: { $0.id == selectedID }) { selectedID = visibleRules.first?.id }; coordinator.reset() }
    private func checkpoint() { history.append(library); if history.count > 40 { history.removeFirst() }; redoHistory.removeAll() }
    func save() {
        do { try saveNow(); notice = "Saved on this Mac." }
        catch { saveFailed(error) }
    }
    func saveNow() throws { try persist(library) }
    private func persist(_ value: GestureLibrary) throws {
        if recoveryRequired {
            let old = storage.appendingPathComponent("Library.gestures")
            if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.copyItem(at: old, to: storage.appendingPathComponent("Unreadable-" + UUID().uuidString + ".gestures")) }
            recoveryRequired = false
        }
        try LibraryIO.save(value, to: storage.appendingPathComponent("Library.gestures"))
        errorMessage = nil
    }
    private func saveFailed(_ error: Error) {
        disableControl()
        errorMessage = error.localizedDescription
        notice = "Changes could not be saved. Your last saved library has been kept."
    }
    func update(_ rule: GestureRule) {
        disableControl()
        do {
            _ = try rule.validated()
            if !library.rules.contains(where: { $0.id == rule.id }), library.rules.count >= 100 { throw GestureError("This library already has 100 gestures.") }
            var candidate = library
            if let i = candidate.rules.firstIndex(where: { $0.id == rule.id }) { candidate.rules[i] = rule } else { candidate.rules.append(rule) }
            try persist(candidate)
            checkpoint(); library = candidate
            selectedID = rule.id; selectedProfile = "*"; coordinator.reset(); notice = "Saved on this Mac."; editor = nil
        } catch { saveFailed(error) }
    }
    func setAction(_ kind: ActionKind) {
        guard var rule = selected else { return }
        disableControl()
        if kind == .shortcut || kind == .keyboard || kind.isContinuous {
            rule.action.kind = kind; editor = .init(rule: rule); return
        }
        rule.action.kind = kind; update(rule)
    }
    func editSelected() { guard let selected else { return }; disableControl(); testing = false; editor = .init(rule: selected) }
    func newGesture() { disableControl(); testing = false; editor = .init(rule: GestureRule(name: "My gesture", enabled: false)) }
    func duplicateSelected() {
        guard var rule = selected else { return }; rule.id = UUID(); rule.name = String((rule.name + " copy").prefix(80)); rule.enabled = false
        rule.steps = rule.steps.map { var step = $0; step.id = UUID(); return step }; update(rule)
    }
    func removeSelected() {
        guard let selectedID else { return }; disableControl()
        var candidate = library; candidate.rules.removeAll { $0.id == selectedID }
        do {
            try persist(candidate)
            checkpoint(); library = candidate; self.selectedID = library.rules.first?.id
            notice = "Saved on this Mac."
        } catch { saveFailed(error) }
    }
    func undo() {
        guard let last = history.last else { return }; disableControl()
        do {
            try persist(last)
            history.removeLast(); redoHistory.append(library); library = last; selectedID = library.rules.first?.id
            notice = "Saved on this Mac."
        } catch { saveFailed(error) }
    }
    func redo() {
        guard let last = redoHistory.last else { return }; disableControl()
        do {
            try persist(last)
            redoHistory.removeLast(); history.append(library); library = last; selectedID = library.rules.first?.id
            notice = "Saved on this Mac."
        } catch { saveFailed(error) }
    }
    func disableControl() {
        enabled = false; coordinator.reset(); runner.cancelAll(); cancelSpaceCheck(); cancelPreAction()
        if let recognitionActivity { ProcessInfo.processInfo.endActivity(recognitionActivity); self.recognitionActivity = nil }
    }
    func mainWindowClosed() {
        if enabled && cameraRunning && !testing && !recording {
            notice = "Running in the menu bar. Use the hand icon to pause or stop the camera."
        } else { stopCamera() }
    }
    func enableControl() {
        guard !isEditing, !recording else { notice = "Finish editing or demonstrating before enabling control."; return }
        refreshPermissions()
        guard cameraRunning else { notice = "Start your camera, then enable Mac control."; showPermissions = true; return }
        guard library.rules.contains(where: \.enabled) else { errorMessage = "Enable at least one gesture in its editor first."; return }
        if library.rules.contains(where: { $0.enabled && $0.action.kind.needsAccessibility }), !accessible { showPermissions = true; return }
        guard !ActionRunner.secureInput else { errorMessage = "A protected input field is active. Finish using it before enabling gestures."; return }
        enabled = true; testing = false; coordinator.reset(); tracking.lastMatch = ""; tracking.actionStatus = ""
        if recognitionActivity == nil {
            recognitionActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Recognizing enabled hand gestures")
        }
        notice = "Mac control is on. Close the window to keep using gestures from the menu bar."
    }
    func trySelected() {
        guard !enabled else { notice = "Mac control is on. Pause it before practicing without actions."; return }
        disableControl(); testing.toggle(); coordinator.reset(); tracking.testMatches = 0; tracking.lastMatch = ""; tracking.actionStatus = ""
        if !testing { notice = "Practice stopped. Mac control remains off — enable it to run actions." }
        else if !cameraRunning { notice = "Practice is ready. Start the camera when you want to try your hand gesture." }
        else { notice = "Practice only: actions are shown, never sent." }
    }
    func startCamera() {
        guard !cameraWanted else { return }
        cameraWanted = true; cameraStatus = .starting; cameras = CameraPipeline.devices()
        let request = UUID(); cameraRequest = request
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard cameraWanted, cameraRequest == request else { return }
            guard authorized else { cameraFailed("Camera permission is off. Allow Gestures in System Settings → Privacy & Security → Camera."); return }
            camera.start(deviceID: selectedCamera.isEmpty ? nil : selectedCamera, generation: request)
        }
    }
    func stopCamera() {
        cameraRequest = UUID(); cameraWanted = false; disableControl(); testing = false; cancelRecording()
        watchdog?.cancel(); watchdog = nil; cameraStatus = .off; tracking.frame = .init(time: 0, hands: []); tracking.progress = .init()
        camera.stop(); notice = "Camera and Mac control are off."
    }
    private func cameraChanged(_ status: CameraStatus) {
        if !cameraWanted {
            if status == .running { camera.stop() }
            return
        }
        cameraStatus = status
        switch status {
        case .running:
            lastFrameAt = ProcessInfo.processInfo.systemUptime; notice = "Camera preview is on. Enable Mac control to run actions, or use Practice only for recognition without actions."
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshPermissions()
                    if self.enabled && !self.accessible && self.library.rules.contains(where: { $0.enabled && $0.action.kind.needsAccessibility }) { self.disableControl(); self.notice = "Accessibility access changed. Control is paused." }
                    if self.cameraRunning && ProcessInfo.processInfo.systemUptime - self.lastFrameAt > 2.5 { self.disableControl(); self.coordinator.reset(); self.tracking.frame = .init(time: 0, hands: []); self.tracking.progress = .init(message: "Waiting for camera frames"); self.notice = "The camera stopped delivering frames. Control is paused." }
                }
            }
        case .failed(let message): cameraFailed(message)
        case .off: cameraWanted = false; disableControl()
        case .starting: break
        }
    }
    private func cameraFailed(_ message: String) {
        guard cameraWanted else { return }
        cameraRequest = UUID(); testing = false; cameraWanted = false; disableControl(); watchdog?.cancel(); watchdog = nil; cancelRecording(); camera.stop()
        cameraStatus = .failed(message); notice = message; tracking.frame = .init(time: 0, hands: []); tracking.progress = .init()
    }
    private func receive(_ frame: HandFrame) {
        guard cameraWanted, cameraRunning else { return }
        let age = ProcessInfo.processInfo.systemUptime - frame.time
        guard age >= 0, age < 0.35 else { coordinator.reset(); return }
        lastFrameAt = frame.time; tracking.frame = frame
        if recording { if recordedFrames.count < 160 { recordedFrames.append(frame) }; return }
        guard !isEditing, testing || enabled else { tracking.progress = .init(message: frame.hands.isEmpty ? "Preview only · show your hand" : "Hand detected · Mac control is off"); return }
        if manualSpaceCheck { tracking.progress = .init(message: "Checking the Space shortcut"); return }
        if ActionRunner.secureInput { disableControl(); notice = "Control paused while protected input is active."; return }
        let activeApp = frontApp
        let rules: [GestureRule]
        if testing, var rule = selected { rule.enabled = true; rule.scope = .init(); rules = [rule] }
        else { rules = library.rules }
        let optionHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        let result = coordinator.process(frame, rules: rules, selected: selectedID, app: testing ? "test" : activeApp, optionHeld: optionHeld)
        tracking.progress = result.progress
        let permission = DispatchPermission(enabled: enabled, testing: testing, cameraRunning: cameraRunning, editing: isEditing, frameAge: age, frontApp: activeApp, optionHeld: optionHeld)
        if let match = result.match {
            if testing {
                tracking.testMatches += 1; tracking.lastMatch = "Would run: \(match.rule.action.title)"
                // Simulate continuous feedback in Practice; the runner remains gated off.
                coordinator.resolveAction(match.rule, accepted: true)
            }
            else {
                tracking.completedGestures += 1
                tracking.lastMatch = "\(match.rule.name) completed"
                dispatch(match.rule, permission: permission)
            }
        }
        if let delta = result.scroll, let rule = result.scrollRule, !testing, !preActionPending { runner.scroll(delta, rule: rule, permission: permission) }
    }
    func checkSpaceAction() {
        guard canCheckSpace, let rule = selected else { notice = "Enable Mac control to check a Space action. Practice mode never sends actions."; return }
        coordinator.reset(); manualSpaceCheck = true; spaceCheckPending = true
        tracking.lastMatch = "Manual Space check"; tracking.actionStatus = "Preparing the shortcut…"
        // Let activation of this window settle before attributing a Space notification.
        manualSpaceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.manualSpaceTask = nil
            guard self.enabled, !self.testing, self.cameraRunning, self.selected?.id == rule.id else { self.cancelSpaceCheck(); return }
            let permission = DispatchPermission(enabled: self.enabled, testing: self.testing, cameraRunning: self.cameraRunning, editing: self.isEditing, frameAge: ProcessInfo.processInfo.systemUptime - self.lastFrameAt, frontApp: self.frontApp, optionHeld: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate))
            self.dispatchManualSpaceCheck(rule, permission: permission)
        }
    }
    func dispatchManualSpaceCheck(_ rule: GestureRule, permission: DispatchPermission) {
        manualSpaceCheck = true; spaceCheckPending = false
        if !dispatch(rule, permission: permission) { cancelSpaceCheck() }
    }
    @discardableResult
    private func dispatch(_ rule: GestureRule, permission: DispatchPermission) -> Bool {
        guard !preActionPending, permission.allows(rule), !ActionRunner.secureInput else { coordinator.resolveAction(rule, accepted: false); return false }
        let id = UUID(); preActionID = id; preActionPending = true
        let recognizedAt = lastFrameAt
        desktopRipple.beforeAction(GlassFeedbackCue(rule: rule), frameAge: permission.frameAge) { [weak self] proceed in
            guard let self, self.preActionID == id else { return }
            self.preActionPending = false
            guard proceed else { self.coordinator.resolveAction(rule, accepted: false); self.cancelSpaceCheck(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let current = DispatchPermission(enabled: self.enabled, testing: self.testing, cameraRunning: self.cameraRunning,
                editing: self.isEditing, frameAge: now - self.lastFrameAt, frontApp: self.frontApp, optionHeld: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate))
            guard PreActionInput.isFresh(recognizedAt: recognizedAt, latestFrameAt: self.lastFrameAt, now: now),
                  current.allows(rule), current.frontApp == permission.frontApp, !ActionRunner.secureInput else {
                self.coordinator.resolveAction(rule, accepted: false); self.cancelSpaceCheck(); self.notice = "Action cancelled because input changed during the ripple."; return
            }
            self.executeAction(rule, permission: current)
        }
        return true
    }
    private func executeAction(_ rule: GestureRule, permission: DispatchPermission) {
        if rule.action.kind.isSpaceSwitch {
            guard !spaceCheckPending else { return }
            spaceCheckWindow = NSApp?.keyWindow ?? NSApp?.mainWindow
            spaceCheckWindowWasActive = spaceCheckWindow?.isOnActiveSpace == true
            spaceCheck.begin(at: ProcessInfo.processInfo.systemUptime); spaceCheckPending = true
            tracking.actionStatus = "Sending \(rule.action.title)…"
        }
        do {
            let sent = try runner.execute(rule, permission: permission) { [weak self] text in
                self?.notice = text; self?.tracking.actionStatus = text
            }
            coordinator.resolveAction(rule, accepted: sent)
            guard sent else { cancelSpaceCheck(); return }
            if rule.action.kind.isSpaceSwitch {
                spaceTimeout?.cancel()
                spaceTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard !Task.isCancelled, let self, self.spaceCheck.expired(at: ProcessInfo.processInfo.systemUptime) else { return }
                    self.spaceCheckPending = false
                    if self.manualSpaceCheck { self.coordinator.reset() }
                    self.manualSpaceCheck = false
                    self.tracking.actionStatus = "Shortcut sent · no Space change observed"
                    self.notice = "No Space change was observed. Check that another Space exists in this direction and that Control–Arrow works."
                }
            }
        } catch {
            disableControl(); tracking.actionStatus = error.localizedDescription; errorMessage = error.localizedDescription
        }
    }
    private func spaceDidChange(at time: Double) {
        guard spaceCheck.observed(at: time) else { return }
        spaceTimeout?.cancel(); spaceTimeout = nil; spaceCheckPending = false
        if manualSpaceCheck { coordinator.reset() }
        manualSpaceCheck = false
        let windowLeftSpace = spaceCheckWindowWasActive && spaceCheckWindow?.isOnActiveSpace == false
        tracking.actionStatus = windowLeftSpace ? "Space switched ✓" : "Space change observed ✓"
        notice = windowLeftSpace ? "The Gestures window left the active desktop after the shortcut." : "macOS reported a Space change after the shortcut."
        spaceCheckWindow = nil; spaceCheckWindowWasActive = false
    }
    private func cancelSpaceCheck() {
        manualSpaceTask?.cancel(); manualSpaceTask = nil
        spaceTimeout?.cancel(); spaceTimeout = nil; spaceCheck.cancel(); spaceCheckPending = false; manualSpaceCheck = false
        spaceCheckWindow = nil; spaceCheckWindowWasActive = false
    }
    private func cancelPreAction() {
        let wasPending = preActionPending
        coordinator.cancelPendingAction()
        preActionID = UUID(); preActionPending = false
        desktopRipple.cancel()
        if wasPending { cancelSpaceCheck() }
    }
    func startRecording() {
        guard cameraRunning else { notice = "Start the camera before demonstrating a swipe."; return }
        disableControl(); testing = false; recordedFrames = []; recording = true; recordingSeconds = 5
        notice = "Show your pose, make one swipe, then keep your hand at the end position."
        recordingTask = Task { [weak self] in
            for remaining in (0..<5).reversed() {
                try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled, let self else { return }; self.recordingSeconds = remaining
            }
            guard !Task.isCancelled, let self else { return }
            self.recording = false
            do { let rule = try GestureDemonstration.suggest(self.recordedFrames); self.editor = .init(rule: rule, note: "Suggested from your demonstration. Review the steps and test them before enabling this gesture.") }
            catch { self.errorMessage = error.localizedDescription }
            self.recordedFrames = []; self.recordingTask = nil
        }
    }
    func cancelRecording() { recordingTask?.cancel(); recordingTask = nil; recording = false; recordedFrames = [] }
    func loadShortcuts() {
        guard !loadingShortcuts else { return }; loadingShortcuts = true
        Task {
            defer { loadingShortcuts = false }
            do { shortcutNames = try await Task.detached { try ActionRunner.shortcutNames() }.value }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func exportLibrary() {
        disableControl()
        let panel = NSSavePanel(); panel.title = "Export gesture definitions"; panel.allowedContentTypes = [.gesturesLibrary]; panel.nameFieldStringValue = "My Gestures.gestures"
        panel.begin { [weak self] response in Task { @MainActor in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try LibraryIO.save(self.library, to: url); self.notice = "Exported your gesture definitions." } catch { self.errorMessage = error.localizedDescription }
        } }
    }
    func importLibrary() {
        disableControl()
        let panel = NSOpenPanel(); panel.title = "Import gesture definitions"; panel.allowedContentTypes = [.gesturesLibrary, .json]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in Task { @MainActor in
            guard response == .OK, let self, let url = panel.url else { return }; self.importLibrary(at: url)
        } }
    }
    func importLibrary(at url: URL) {
        disableControl()
        do {
            let imported = try LibraryIO.load(url), merged = try LibraryIO.merging(imported, into: library)
            try persist(merged)
            checkpoint(); library = merged; selectedProfile = "*"; selectedID = library.rules.last?.id
            notice = "Imported \(imported.rules.count) gestures, all disabled. Review them in the editor."
        } catch { saveFailed(error) }
    }
}
