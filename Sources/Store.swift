import AppKit
import Combine
import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import OSLog

extension UTType { static let gesturesLibrary = UTType(exportedAs: "org.gestures.studio.library", conformingTo: .json) }

@MainActor
final class TrackingPresentation: ObservableObject {
    @Published var frame = HandFrame(time: 0, hands: [])
    @Published var progress = RecognitionProgress()
    @Published var lastMatch = ""
    @Published var testMatches = 0
    @Published var actionStatus = ""
    @Published var appSwitchResult = ""
    @Published var volumeStatus = ""
    @Published var completedGestures = 0
}
struct EditorDraft: Identifiable { var id: UUID { rule.id }; var rule: GestureRule; var note: String = "" }

@MainActor
final class GestureStore: ObservableObject {
    private static let switchLog = Logger(subsystem: "org.gestures.studio", category: "AppSwitch")
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
    @Published var showAppSwitcherPreview = false {
        didSet { if showAppSwitcherPreview { disableControl(); testing = false } }
    }
    @Published var showScrollPreview = false {
        didSet { if showScrollPreview { disableControl(); testing = false } }
    }
    @Published var showVolumePreview = false {
        didSet { if showVolumePreview { disableControl(); testing = false } }
    }
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
    private var pendingAppSwitch = false
    private let appPicker = AppPickerController()
    private let scrollIndicator = ScrollIndicatorController()
    private let volumeIndicator = VolumeIndicatorController()
    private let volume = VolumeController()
    private var continuousWatchdog: Task<Void, Never>?
    private var appSwitch: AppSwitchSession?
    private var appSwitchWatchdog: Task<Void, Never>?
    private var expectedApp: AppSwitchTarget?
    private var appActivationTimeout: Task<Void, Never>?
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
    var isEditing: Bool { editor != nil || showFineTune || showGlassAppearance || showAppSwitcherPreview || showScrollPreview || showVolumePreview }
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
                    self.confirmAppActivation()
                    self.cancelPreAction()
                    self.coordinator.activeAppChanged(to: self.frontApp, at: ProcessInfo.processInfo.systemUptime)
                }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelPreAction() }
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
    func select(_ id: UUID) { cancelPreAction(); selectedID = id; coordinator.reset(); tracking.progress = .init(); tracking.lastMatch = ""; tracking.actionStatus = ""; tracking.volumeStatus = "" }
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
        if kind == .shortcut || kind == .keyboard || kind.isContinuous || kind == .switchApps {
            rule.action.kind = kind; editor = .init(rule: rule); return
        }
        rule.action.kind = kind; update(rule)
    }
    func editSelected() { guard let selected else { return }; disableControl(); testing = false; editor = .init(rule: selected) }
    func newGesture() { disableControl(); testing = false; editor = .init(rule: GestureRule(name: "My gesture", enabled: false)) }
    func addAppSwitcherPreset() {
        disableControl(); testing = false
        if let existing = library.rules.first(where: { $0.action.kind == .switchApps }) {
            selectedProfile = "*"; select(existing.id)
        } else { update(.appSwitcherPreset) }
        guard selected?.action.kind == .switchApps else { return }
        notice = "Pinch to open, release and slide to browse, then pinch again to choose. Try Practice first."
    }
    func addTwoFingerScrollPreset() {
        disableControl(); testing = false
        if let existing = library.rules.first(where: { $0.action.kind.isScroll && $0.steps.first?.pose.kind == .victory }) {
            selectedProfile = "*"; select(existing.id)
        } else { update(.twoFingerScrollPreset) }
        guard selected?.action.kind.isScroll == true else { return }
        notice = "Raise two fingers, move to scroll, then relax your fingers to stop. Try Practice first."
    }
    func addVolumePreset() {
        disableControl(); testing = false
        if let existing = library.rules.first(where: { $0.action.kind == .volume && $0.steps.first?.pose.kind == .fist }) {
            selectedID = existing.id; selectedProfile = "*"
        } else { update(.volumePreset) }
        notice = "Close your fist, move to change volume, then open your hand to stop. Try Practice first."
    }
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
        expectedApp = nil; appActivationTimeout?.cancel(); appActivationTimeout = nil
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
        enabled = true; testing = false; coordinator.reset(); tracking.lastMatch = ""; tracking.actionStatus = ""; tracking.volumeStatus = ""
        if recognitionActivity == nil {
            recognitionActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Recognizing enabled hand gestures")
        }
        notice = "Mac control is on. Close the window to keep using gestures from the menu bar."
    }
    func trySelected() {
        guard !enabled else { notice = "Mac control is on. Pause it before practicing without actions."; return }
        disableControl(); testing.toggle(); coordinator.reset(); tracking.testMatches = 0; tracking.lastMatch = ""; tracking.actionStatus = ""; tracking.volumeStatus = ""
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
        guard age >= 0, age < 0.35 else { cancelPreAction(); coordinator.reset(); return }
        lastFrameAt = frame.time; tracking.frame = frame
        if recording { if recordedFrames.count < 160 { recordedFrames.append(frame) }; return }
        guard !isEditing, testing || enabled else { stopContinuous(); tracking.progress = .init(message: frame.hands.isEmpty ? "Preview only · show your hand" : "Hand detected · Mac control is off"); return }
        if manualSpaceCheck { tracking.progress = .init(message: "Checking the Space shortcut"); return }
        if ActionRunner.secureInput { disableControl(); notice = "Control paused while protected input is active."; return }
        let activeApp = frontApp
        let rules: [GestureRule]
        if testing, var rule = selected { rule.enabled = true; rule.scope = .init(); rules = [rule] }
        else { rules = library.rules }
        let optionHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        if appSwitch != nil {
            continueAppSwitch(frame, optionHeld: optionHeld, frameAge: age)
            return
        }
        let result = coordinator.process(frame, rules: rules, selected: selectedID, app: testing ? "test" : activeApp, optionHeld: optionHeld)
        tracking.progress = result.progress
        if selected?.action.kind == .volume, !frame.hands.isEmpty, result.match == nil, coordinator.continuousRule == nil {
            tracking.volumeStatus = result.progress.message
        }
        let permission = DispatchPermission(enabled: enabled, testing: testing, cameraRunning: cameraRunning, editing: isEditing, frameAge: age, frontApp: activeApp, optionHeld: optionHeld)
        if let match = result.match {
            if match.rule.action.kind == .switchApps {
                beginAppSwitch(match.rule, frame: frame, permission: permission)
            } else if testing {
                tracking.testMatches += 1; tracking.lastMatch = "Would run: \(match.rule.action.title)"
                // Simulate continuous feedback in Practice; the runner remains gated off.
                do {
                    if match.rule.action.kind == .volume { try volume.begin(match.rule, practicing: true, permission: permission, at: frame.time) }
                    coordinator.resolveAction(match.rule, accepted: true)
                } catch { stopContinuous(); tracking.volumeStatus = error.localizedDescription; notice = error.localizedDescription }
            }
            else {
                tracking.completedGestures += 1
                tracking.lastMatch = "\(match.rule.name) completed"
                dispatch(match.rule, permission: permission)
            }
        }
        if let delta = result.scroll, let rule = result.scrollRule, !testing, !preActionPending {
            guard runner.scroll(delta, rule: rule, permission: permission) else { stopContinuous(); return }
        }
        if let delta = result.volume, let rule = result.volumeRule, !preActionPending {
            do { try volume.change(delta, rule: rule, permission: permission, at: frame.time) }
            catch { stopContinuous(); tracking.volumeStatus = error.localizedDescription; tracking.actionStatus = error.localizedDescription; notice = error.localizedDescription; return }
        }
        updateContinuousFeedback(result.scrollFeedback)
    }
    private func updateContinuousFeedback(_ feedback: ScrollFeedback?) {
        guard let active = coordinator.continuousRule else {
            if continuousWatchdog != nil && preActionPending { cancelPreAction() } else { stopContinuous() }
            return
        }
        if let feedback { scrollIndicator.show(feedback, practicing: testing) }
        else { scrollIndicator.hide() }
        if active.action.kind == .volume && active.action.volumeSettings.showIndicator {
            let shown = volumeIndicator.show(volume.feedback ?? .init(maximum: active.action.volumeSettings.maximum, preparing: true), practicing: testing)
            tracking.volumeStatus = shown ? "Fist accepted · volume indicator shown" : "Fist accepted · no display available for indicator"
        } else { volumeIndicator.hide() }
        guard continuousWatchdog == nil else { return }
        continuousWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let rule = self.coordinator.continuousRule else { return }
                let age = ProcessInfo.processInfo.systemUptime - self.lastFrameAt
                let option = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
                if age < 0 || age > 0.25 || !self.cameraRunning || self.isEditing || ActionRunner.secureInput ||
                    (rule.requireOptionKey && !option) || (!self.testing && (!self.enabled || (rule.action.kind.needsAccessibility && !ActionRunner.hasAccess))) {
                    self.cancelPreAction(); self.tracking.progress = .init(message: "Continuous action stopped"); return
                }
            }
        }
    }
    private func stopContinuous() {
        coordinator.stopContinuous(at: ProcessInfo.processInfo.systemUptime)
        continuousWatchdog?.cancel(); continuousWatchdog = nil; scrollIndicator.hide(); volume.cancel(); volumeIndicator.hide()
    }
    private func beginAppSwitch(_ rule: GestureRule, frame: HandFrame, permission: DispatchPermission) {
        guard !preActionPending, !spaceCheckPending, !manualSpaceCheck, appSwitch == nil,
              testing || (permission.allows(rule) && ActionRunner.hasAccess), !ActionRunner.secureInput else { return }
        let targets = AppSwitchTarget.available(settings: rule.action.switcherSettings)
        guard let session = AppSwitchSession(rule: rule, targets: targets, frame: frame, sourceApp: frontApp,
                                            currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, practicing: testing) else {
            coordinator.finishInteractiveAction(rule, at: frame.time)
            notice = targets.isEmpty ? "Open an included app before trying pinch & slide." : "Keep one pinched hand clearly visible."
            return
        }
        guard appPicker.show(session, onCancel: { [weak self] in
            self?.cancelAppSwitch(); self?.tracking.actionStatus = "Cancelled · no app switched"
        }) else { coordinator.finishInteractiveAction(rule, at: frame.time); return }
        appSwitch = session
        Self.switchLog.info("Picker opened; practice=\(self.testing, privacy: .public)")
        tracking.lastMatch = testing ? "Practice app picker" : "App picker opened"
        tracking.actionStatus = "Release, slide to browse, then pinch again to choose"
        appSwitchWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let session = self.appSwitch else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - session.startedAt > session.rule.action.switcherSettings.timeout ||
                    self.frontApp != session.sourceApp || ActionRunner.secureInput || (!session.practicing && !ActionRunner.hasAccess) {
                    Self.switchLog.info("Picker closed by timeout or context/permission change")
                    self.tracking.appSwitchResult = "Picker closed before a confirming pinch."
                    self.cancelAppSwitch(); self.notice = "App picker cancelled. No app was switched."; return
                }
                if now - session.lastFrameAt > 0.35 {
                    var paused = session; paused.pauseTracking(); self.appSwitch = paused; self.appPicker.update(paused)
                }
            }
        }
    }
    private func continueAppSwitch(_ frame: HandFrame, optionHeld: Bool, frameAge: Double) {
        guard var session = appSwitch else { return }
        let current = DispatchPermission(enabled: enabled, testing: testing, cameraRunning: cameraRunning,
                                         editing: isEditing, frameAge: frameAge, frontApp: frontApp, optionHeld: optionHeld)
        let unchanged = testing == session.practicing && (testing ? selected?.id == session.rule.id : library.rules.contains(session.rule))
        let allowed = unchanged && !isEditing && cameraRunning && !recording && !ActionRunner.secureInput &&
            (session.practicing ? testing : current.allows(session.rule) && ActionRunner.hasAccess)
        let result = session.process(frame, app: frontApp, optionHeld: optionHeld, allowed: allowed)
        if session.selectedIndex != appSwitch?.selectedIndex { Self.switchLog.info("Picker selection advanced") }
        if session.trackingPaused, appSwitch?.trackingPaused == false { Self.switchLog.info("Picker input paused") }
        if !session.awaitingOpenHand, appSwitch?.awaitingOpenHand == true { Self.switchLog.info("Picker ready for browsing") }
        appSwitch = session
        switch result {
        case .browsing:
            appPicker.update(session)
            tracking.progress = .init(step: session.rule.steps.count - 1, fraction: 1, message: session.instruction, hand: frame.hands.first)
        case .cancelled:
            Self.switchLog.info("Picker cancelled by input or permission gate")
            cancelAppSwitch(); tracking.actionStatus = "Cancelled · no app switched"
        case .commit(let target):
            Self.switchLog.info("Picker second pinch confirmed")
            cancelAppSwitch()
            if session.practicing {
                tracking.testMatches += 1; tracking.lastMatch = "Would switch to \(target.name)"; tracking.actionStatus = "Practice only · no app switched"
                tracking.appSwitchResult = "Practice would switch to \(target.name)."
            } else {
                tracking.appSwitchResult = "Confirmed \(target.name) · preparing switch…"
                tracking.completedGestures += 1; tracking.lastMatch = "\(session.rule.name) completed"
                dispatch(session.rule, permission: current, appTarget: target, direction: session.direction)
            }
        }
    }
    private func cancelAppSwitch() {
        if let session = appSwitch { coordinator.finishInteractiveAction(session.rule, at: ProcessInfo.processInfo.systemUptime) }
        appSwitch = nil; appSwitchWatchdog?.cancel(); appSwitchWatchdog = nil; appPicker.hide()
    }
    private func confirmAppActivation() {
        guard let target = expectedApp else { return }
        appActivationTimeout?.cancel(); appActivationTimeout = nil; expectedApp = nil
        if target.runningApplication?.isActive == true {
            tracking.actionStatus = "Switched to \(target.name)"; notice = tracking.actionStatus
            Self.switchLog.info("App activation verified")
        } else { tracking.actionStatus = "App switching cancelled because the active app changed."; Self.switchLog.info("App activation interrupted by another active app") }
        tracking.appSwitchResult = tracking.actionStatus
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
    private func dispatch(_ rule: GestureRule, permission: DispatchPermission, appTarget: AppSwitchTarget? = nil, direction: MoveDirection? = nil) -> Bool {
        guard !preActionPending, permission.allows(rule), !ActionRunner.secureInput else {
            if appTarget != nil { tracking.appSwitchResult = "Switch blocked before the ripple: control or input changed."; Self.switchLog.info("App switch blocked before ripple") }
            coordinator.resolveAction(rule, accepted: false); return false
        }
        guard rule.action.kind != .switchApps || appTarget != nil else { return false }
        let id = UUID(); preActionID = id; preActionPending = true
        pendingAppSwitch = appTarget != nil
        let recognizedAt = lastFrameAt
        var cue = GlassFeedbackCue(rule: rule)
        if let direction { cue.direction = direction }
        desktopRipple.beforeAction(cue, frameAge: permission.frameAge) { [weak self] proceed in
            guard let self, self.preActionID == id else { return }
            self.preActionPending = false
            self.pendingAppSwitch = false
            guard proceed else {
                if appTarget != nil { self.tracking.appSwitchResult = "Switch cancelled with the ripple."; Self.switchLog.info("App switch cancelled with ripple") }
                self.coordinator.resolveAction(rule, accepted: false); self.cancelSpaceCheck(); return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let current = DispatchPermission(enabled: self.enabled, testing: self.testing, cameraRunning: self.cameraRunning,
                editing: self.isEditing, frameAge: now - self.lastFrameAt, frontApp: self.frontApp, optionHeld: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate))
            guard PreActionInput.isFresh(recognizedAt: recognizedAt, latestFrameAt: self.lastFrameAt, now: now),
                  !rule.action.kind.isContinuous || self.coordinator.continuousRule == rule,
                  current.allows(rule), current.frontApp == permission.frontApp, !ActionRunner.secureInput else {
                if appTarget != nil { self.tracking.appSwitchResult = "Switch blocked: input or active app changed during the ripple."; Self.switchLog.info("App switch blocked after ripple") }
                self.coordinator.resolveAction(rule, accepted: false); self.cancelSpaceCheck(); self.notice = "Action cancelled because input changed during the ripple."; return
            }
            if let appTarget, rule.action.kind == .switchApps {
                do {
                    guard self.library.rules.contains(rule) else { self.tracking.appSwitchResult = "Switch cancelled because the gesture changed."; Self.switchLog.info("App switch blocked by changed rule"); return }
                    self.expectedApp = appTarget
                    guard try self.runner.activate(appTarget, rule: rule, permission: current) else {
                        self.expectedApp = nil; self.tracking.actionStatus = "macOS did not accept the app switch."
                        self.tracking.appSwitchResult = self.tracking.actionStatus; Self.switchLog.info("App activation request rejected"); return
                    }
                    self.tracking.actionStatus = "Switch requested: \(appTarget.name)"
                    self.tracking.appSwitchResult = self.tracking.actionStatus
                    Self.switchLog.info("App activation request accepted")
                    self.appActivationTimeout?.cancel()
                    self.appActivationTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, self.expectedApp == appTarget else { return }
                        if appTarget.runningApplication?.isActive == true { self.confirmAppActivation() }
                        else {
                            self.expectedApp = nil; self.tracking.actionStatus = "Switch requested · app activation was not confirmed"
                            self.tracking.appSwitchResult = self.tracking.actionStatus; Self.switchLog.info("App activation was not confirmed")
                        }
                    }
                } catch {
                    self.expectedApp = nil; self.tracking.appSwitchResult = error.localizedDescription
                    Self.switchLog.info("App activation rejected by final safety check")
                    self.disableControl(); self.errorMessage = error.localizedDescription
                }
            } else { self.executeAction(rule, permission: current) }
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
            if rule.action.kind == .volume {
                try volume.begin(rule, practicing: false, permission: permission, at: lastFrameAt)
                coordinator.resolveAction(rule, accepted: true)
                tracking.actionStatus = "Volume ready · open your hand to stop"
                return
            }
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
            if rule.action.kind == .volume { tracking.volumeStatus = error.localizedDescription }
        }
    }
    private func spaceDidChange(at time: Double) {
        stopContinuous()
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
        stopContinuous()
        cancelAppSwitch()
        let wasPending = preActionPending
        if wasPending && pendingAppSwitch { tracking.appSwitchResult = "Switch cancelled because the input context changed."; Self.switchLog.info("Pending app switch cancelled by context change") }
        pendingAppSwitch = false
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
