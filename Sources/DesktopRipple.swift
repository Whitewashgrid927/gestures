import AppKit
import MetalKit
import SwiftUI
import OSLog
import CoreVideo
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum RippleStrength {
    static let preferenceKey = "desktopRippleStrengthPoints"
    static let standard = 32.0
    static let range = 8.0...48.0
    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound,max(range.lowerBound,value)) : standard
    }
}

enum RippleSpeed: String, CaseIterable {
    case fast, medium, slow
    static let preferenceKey = "desktopRippleSpeed"
    var title: String {
        switch self { case .fast: "Fast"; case .medium: "Medium"; case .slow: "Slow" }
    }
    var duration: Double {
        switch self { case .fast: 0.22; case .medium: 0.32; case .slow: 0.40 }
    }
}

enum RippleDuration {
    static let preferenceKey = "desktopRippleDurationMilliseconds"
    static let standard = 400.0
    static let range = 150.0...500.0
    static func clamped(_ milliseconds: Double) -> Double {
        milliseconds.isFinite ? min(range.upperBound,max(range.lowerBound,milliseconds.rounded())) : standard
    }
    static func milliseconds(in preferences: UserDefaults = .standard) -> Double {
        if let saved = preferences.object(forKey: preferenceKey) as? NSNumber {
            return clamped(saved.doubleValue)
        }
        // Preserve the user's previous speed until they choose a numeric duration.
        let speed = preferences.string(forKey: RippleSpeed.preferenceKey).flatMap(RippleSpeed.init(rawValue:)) ?? .slow
        return speed.duration*1000
    }
    static var current: Double { milliseconds()/1000 }
    static func parsed(_ text: String, fallback: Double) -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return clamped(fallback) }
        return clamped(value)
    }
}

enum RippleTiming {
    // Leave 60 ms for queued presentation before the unchanged 650 ms action gate.
    static let visualBudget = 0.59
    static func captureAllowance(frameAge: Double, requestedDuration: Double) -> Double {
        max(0,min(0.25,visualBudget-frameAge-min(requestedDuration,RippleSpeed.fast.duration)))
    }
    static func duration(requested: Double, startingAt time: Double, finishBy deadline: Double) -> Double {
        max(0.001,min(requested,deadline-time))
    }
}

/// Resolves capture/timeout/cancellation races without ever completing an action twice.
struct RippleActionSchedule {
    enum Phase { case idle, preparing, animating }
    private(set) var phase = Phase.idle
    private(set) var id = UUID()
    private var deadline = 0.0
    private var began = 0.0
    mutating func begin(at time: Double, allowance: Double) -> UUID {
        id = UUID(); phase = .preparing; began = time; deadline = time + max(0, min(0.25, allowance)); return id
    }
    mutating func visible(_ id: UUID, at time: Double) -> Bool {
        guard mayPresent(id, at: time) else { return false }
        phase = .animating; return true
    }
    mutating func expired(_ id: UUID, at time: Double) -> Bool {
        guard self.id == id, phase == .preparing, time.isFinite, time >= deadline else { return false }
        phase = .idle; return true
    }
    mutating func finished(_ id: UUID) -> Bool {
        guard self.id == id, phase == .animating else { return false }
        phase = .idle; return true
    }
    func accepts(_ id: UUID) -> Bool { self.id == id && phase != .idle }
    func mayPresent(_ id: UUID, at time: Double) -> Bool { self.id == id && phase == .preparing && time.isFinite && time >= began && time <= deadline }
    mutating func cancel() { id = UUID(); phase = .idle }
}

@MainActor
final class DesktopRippleController {
    var enabled = false { didSet { if !enabled { cancel() } } }
    var consent = false { didSet { if !consent { cancel(); filters = [:] } } }
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var preparing = false
    private var captureBusy = false
    private var schedule = RippleActionSchedule()
    private var captureTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var ending: Task<Void, Never>?
    private var completion: (@MainActor (Bool) -> Void)?
    private var surface: RippleSurface?
    private var renderer: RippleRenderer?
    private let gpu = RippleGPU.shared
    private static let log = Logger(subsystem: "org.gestures.studio", category: "DesktopRipple")
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }
    private var accessibleEffect: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    private var workingScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }
    private func prepareSurface(on screen: NSScreen) {
        guard let gpu else { return }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if surface?.displayID != number?.uint32Value {
            surface?.close()
            surface = RippleSurface(screen: screen, gpu: gpu)
        }
    }

    func prepare() {
        guard NSApp != nil, consent, Self.hasScreenAccess else { return }
        if enabled, let screen = workingScreen, !schedule.accepts(schedule.id) { prepareSurface(on: screen) }
        guard filters.isEmpty, !preparing else { return }
        preparing = true
        Task { [weak self] in
            defer { self?.preparing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true), let self,
                  self.consent, Self.hasScreenAccess else { return }
            self.filters = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, SCContentFilter(display: $0, excludingWindows: [])) })
            Self.log.info("Screen filters prepared.")
        }
    }

    /// `proceed` runs only after the visual is gone, or immediately if it is unavailable.
    /// Cancelling a pending visual cancels its action instead of dispatching it late.
    func beforeAction(_ cue: GlassFeedbackCue, frameAge: Double, proceed: @escaping @MainActor (Bool) -> Void) {
        Self.log.info("Before-action ripple requested.")
        cancel()
        guard enabled, consent, Self.hasScreenAccess, accessibleEffect, gpu != nil, NSApp != nil, !captureBusy else { Self.log.info("Ripple skipped: disabled, unavailable, or capture busy."); proceed(true); return }
        guard let screen = workingScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let filter = filters[number.uint32Value] else { Self.log.info("Ripple skipped: display filter not ready."); prepare(); proceed(true); return }
        // Snapshot duration for the whole interaction: capture budget, renderer,
        // and watchdog must agree even if the preference changes during capture.
        let duration = RippleDuration.current
        let allowance = RippleTiming.captureAllowance(frameAge: frameAge, requestedDuration: duration)
        guard allowance >= 0.015 else { Self.log.info("Ripple skipped: input age \(frameAge), remaining capture allowance \(allowance)."); proceed(true); return }
        completion = proceed
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let finishBy = CACurrentMediaTime() + RippleTiming.visualBudget - frameAge
        let id = schedule.begin(at: requestedAt, allowance: allowance)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(allowance))
            guard !Task.isCancelled, let self, self.schedule.expired(id, at: ProcessInfo.processInfo.systemUptime) else { return }
            Self.log.info("Capture deadline reached; action proceeds without a ripple.")
            self.complete(true)
        }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        guard config.width > 0, config.height > 0, Double(config.width) * Double(config.height) <= 40_000_000 else { Self.log.info("Ripple skipped: display exceeds bounded texture size."); complete(true); return }
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureDynamicRange = .SDR
        config.colorSpaceName = CGColorSpace.displayP3
        config.captureResolution = .best
        // Let WindowServer prepare the empty surface while capture runs.
        // The layer is transparent and cannot intercept input.
        prepareSurface(on: screen)
        surface?.prime()
        captureBusy = true
        captureTask = Task { [weak self] in
            defer { self?.captureBusy = false }
            do {
                let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, let self, self.schedule.accepts(id), self.enabled, self.consent, Self.hasScreenAccess else { return }
                guard self.schedule.mayPresent(id, at: ProcessInfo.processInfo.systemUptime) else { self.complete(true); return }
                let capturedAt = ProcessInfo.processInfo.systemUptime
                guard let gpu = self.gpu, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
                      let pixels = CMSampleBufferGetImageBuffer(sample) else { self.complete(true); return }
                let frame = try RippleFrame.map(pixels, cache: gpu.textureCache)
                let mappedAt = ProcessInfo.processInfo.systemUptime
                guard self.schedule.mayPresent(id, at: mappedAt) else { self.complete(true); return }
                Self.log.info("Capture ready in \((capturedAt-requestedAt)*1000) ms; direct texture map \((mappedAt-capturedAt)*1000) ms.")
                self.show(frame, on: screen, cue: cue, duration: duration, finishBy: finishBy, id: id, requestedAt: requestedAt)
            } catch {
                guard let self, self.schedule.accepts(id) else { return }
                Self.log.info("Screen capture failed; action proceeds without a ripple.")
                self.filters = [:]
                self.complete(true)
            }
        }
    }

    private func show(_ frame: RippleFrame, on screen: NSScreen, cue: GlassFeedbackCue, duration: Double, finishBy: Double, id: UUID, requestedAt: Double) {
        prepareSurface(on: screen)
        guard let surface, let gpu else { complete(true); return }
        let drawing = RippleRenderer(view: surface.view, frame: frame, gpu: gpu, direction: cue.direction, preview: false, duration: duration, finishBy: finishBy)
        drawing.onFirstPresented = { [weak self] effectiveDuration in
            guard let self, self.schedule.visible(id, at: ProcessInfo.processInfo.systemUptime) else { return }
            Self.log.info("First transparent frame presented after \((ProcessInfo.processInfo.systemUptime-requestedAt)*1000) ms.")
            Self.log.info("Ripple timeline \(effectiveDuration*1000) ms; selected duration \(duration*1000) ms.")
            self.timeout?.cancel(); self.timeout = nil
            self.ending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(effectiveDuration + 0.12))
                guard !Task.isCancelled, let self, self.schedule.finished(id) else { return }
                Self.log.info("Ripple presentation stalled; clearing the effect before the action gate.")
                self.complete(true)
            }
        }
        drawing.onFinished = { [weak self] in
            guard let self, self.schedule.finished(id) else { return }
            Self.log.info("Transparent final frame reached the display; clearing before action. Total \((ProcessInfo.processInfo.systemUptime-requestedAt)*1000) ms.")
            self.complete(true)
        }
        renderer = drawing
        surface.window.orderFrontRegardless()
        surface.view.draw()
    }

    private func complete(_ proceed: Bool) {
        let callback = completion; completion = nil
        cancel()
        callback?(proceed)
    }
    func cancel() {
        let callback = completion; completion = nil
        schedule.cancel()
        captureTask?.cancel(); captureTask = nil
        timeout?.cancel(); timeout = nil; ending?.cancel(); ending = nil
        let needsScrub = renderer != nil && renderer?.finishedTransparent != true
        renderer?.stop(); renderer = nil
        surface?.hide(scrub: needsScrub)
        if let gpu { CVMetalTextureCacheFlush(gpu.textureCache, 0) }
        callback?(false)
    }
    func displaysChanged() { cancel(); surface?.close(); surface = nil; filters = [:]; prepare() }
}

/// Keep an empty host ready. Image-containing drawables are released after every
/// interaction, so reusing the window never keeps a previous desktop snapshot.
@MainActor
final class RippleSurface {
    let window: RipplePanel
    private(set) var view: MTKView
    let displayID: CGDirectDisplayID
    init(screen: NSScreen, gpu: RippleGPU) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        window = RipplePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Desktop ripple"; window.colorSpace = .displayP3
        window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        window.animationBehavior = .none; window.isMovable = false
        view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: gpu.device)
        view.wantsLayer = true; view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        view.clearColor = MTLClearColorMake(0,0,0,0); view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.isPaused = true; view.enableSetNeedsDisplay = false
        window.contentView = view; window.setFrame(screen.frame, display: false)
    }
    func prime() {
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
    }
    func hide(scrub: Bool = false) {
        window.orderOut(nil); view.isPaused = true; view.delegate = nil; view.releaseDrawables()
        if scrub {
            // A cancelled animation may leave nontransparent pixels in the layer.
            // Replace that layer while hidden, before any later interaction starts.
            let clean = MTKView(frame: view.frame, device: view.device)
            clean.isPaused = true; clean.wantsLayer = true; clean.colorPixelFormat = .bgra8Unorm
            clean.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            clean.clearColor = MTLClearColorMake(0,0,0,0); clean.layer?.isOpaque = false
            (clean.layer as? CAMetalLayer)?.maximumDrawableCount = 2
            window.contentView = nil; view = clean; window.contentView = clean
        }
    }
    func close() { hide(); window.contentView = nil; window.close() }
}

final class RipplePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RippleGPU {
    static let shared = try? RippleGPU()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw GestureError("Metal is unavailable.") }
        self.device = device; self.queue = queue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw GestureError("The screen texture cache is unavailable.") }
        textureCache = cache
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rippleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rippleFragment")
        // WindowServer expects encoded, premultiplied color. An sRGB render target
        // would apply its transfer curve AFTER premultiplication and brighten fades.
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float2 size; float2 direction; float progress; float strength; float opacity; float backdrop; };
    vertex Vertex rippleVertex(uint id [[vertex_id]]) {
        float2 positions[3] = { float2(-1,-1), float2(-1,3), float2(3,-1) };
        Vertex out; out.position = float4(positions[id],0,1);
        out.uv = (positions[id]+1)*0.5; out.uv.y = 1-out.uv.y; return out;
    }
    fragment half4 rippleFragment(Vertex in [[stage_in]], texture2d<half> image [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler sampling(coord::normalized, address::clamp_to_zero, filter::linear);
        float p = clamp(u.progress,0.0,1.0);
        float2 position = in.uv*u.size;
        float2 origin = u.size*0.5;
        if (length(u.direction)>0.1) {
            float2 travel = normalize(u.direction);
            float2 reach = origin/max(abs(travel),float2(0.0001));
            // Launch from the opposite edge so the wave propagates with the swipe.
            origin -= travel*min(reach.x,reach.y);
        }
        float2 delta = position-origin;
        float distance = length(delta);
        float2 normal = delta/max(distance,1.0);
        float farthest = max(1.0,length(max(origin,u.size-origin)));
        // Adapted from Apple's WWDC24 Ripple.metal: arrival delay followed by an
        // exponentially damped sine. See Resources/AppleRipple-LICENSE.txt.
        // Virtual time keeps the same wave shape at every selected playback speed.
        float age = max(0.0,2.0*p-1.4*distance/farthest);
        // Normalize the first peak so Strength still means peak displacement.
        float wave = sin(15.0*age)*exp(-8.0*age)*2.016999;
        float fade = smoothstep(0.0,0.035,p)*(1.0-smoothstep(0.82,1.0,p));
        // Pin the border, then smoothly introduce refraction. The ramp is at least
        // 2.5 amplitudes wide, bounding displacement below the available clearance.
        // Thus every filtered sample stays inside the captured image, even at 48pt.
        float2 clearance = min(position-0.5,u.size-0.5-position);
        float edgeDistance = min(clearance.x,clearance.y);
        float shortSide = min(u.size.x,u.size.y);
        float guardWidth = max(2.0,0.004*shortSide);
        float edgeRamp = max(2.5*abs(u.strength),0.05*shortSide);
        float edgeMask = smoothstep(guardWidth,guardWidth+edgeRamp,edgeDistance);
        float2 displacement = normal*(wave*u.strength*fade*edgeMask)/u.size;
        float coverage = smoothstep(0.0,0.002,age)*(1.0-smoothstep(0.55,0.85,age));
        float alpha = clamp(u.opacity,0.0,1.0)*fade*edgeMask*coverage;
        float3 linear = float3(image.sample(sampling,in.uv+displacement).rgb);
        float3 encoded = select(1.055*pow(max(linear,0.0),float3(1.0/2.4))-0.055,12.92*linear,linear<=0.0031308);
        float3 premultiplied = encoded*alpha;
        if (u.backdrop > 0.5) {
            float3 base = float3(image.sample(sampling,in.uv).rgb);
            float3 background = select(1.055*pow(max(base,0.0),float3(1.0/2.4))-0.055,12.92*base,base<=0.0031308);
            return half4(half3(premultiplied+background*(1.0-alpha)),1);
        }
        return half4(half3(premultiplied),half(alpha));
    }
    """
}

struct RippleUniforms {
    var size: SIMD2<Float>
    var direction: SIMD2<Float>
    var progress: Float
    var strength: Float
    var opacity: Float
    var backdrop: Float = 0
}

/// Immutable ownership of a captured IOSurface and its Metal mapping. Every GPU
/// command retains this owner until completion, including after a cancelled effect.
final class RippleFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let pixels: CVPixelBuffer?
    private let mapping: CVMetalTexture?
    init(texture: MTLTexture) { self.texture = texture; pixels = nil; mapping = nil }
    private init(texture: MTLTexture, pixels: CVPixelBuffer, mapping: CVMetalTexture) {
        self.texture = texture; self.pixels = pixels; self.mapping = mapping
    }
    static func map(_ pixels: CVPixelBuffer, cache: CVMetalTextureCache) throws -> RippleFrame {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width > 0, height > 0, Double(width)*Double(height) <= 40_000_000,
              !CVPixelBufferIsPlanar(pixels), CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { throw GestureError("Unsupported screen buffer format.") }
        var mapping: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, .bgra8Unorm_srgb, width, height, 0, &mapping)
        // BGRA image buffers and the fullscreen vertex shader both use top-left
        // image coordinates. Do not invert them based on Core Video's GL-style
        // flipped flag; the four-corner GPU test covers the actual memory layout.
        guard status == kCVReturnSuccess, let mapping,
              let texture = CVMetalTextureGetTexture(mapping) else { throw GestureError("Could not map the screen buffer into Metal.") }
        return RippleFrame(texture: texture, pixels: pixels, mapping: mapping)
    }
}

enum RippleTexture {
    static func make(_ image: CGImage, device: MTLDevice) throws -> MTLTexture {
        // Normalize to the same wide-gamut profile as the capture and output layer.
        // Display P3 uses the sRGB transfer curve. Create an explicit sRGB-format
        // texture: MTKTextureLoader can return an untagged rgba8Unorm texture for
        // a wide-color CGImage even when its SRGB option is true.
        guard image.width > 0, image.height > 0, Double(image.width) * Double(image.height) <= 40_000_000,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let pixels = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                     bytesPerRow: image.width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GestureError("Could not prepare the in-memory ripple texture.") }
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: image.width, height: image.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let data = pixels.data, let texture = device.makeTexture(descriptor: descriptor) else { throw GestureError("Could not create the ripple texture.") }
        texture.replace(region: MTLRegionMake2D(0,0,image.width,image.height), mipmapLevel: 0, withBytes: data, bytesPerRow: pixels.bytesPerRow)
        return texture
    }
}

@MainActor
final class RippleRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let gpu: RippleGPU
    private var frame: RippleFrame?
    private let direction: SIMD2<Float>
    private let preview: Bool
    private var duration: Double
    private let finishBy: Double?
    private let strengthPoints: Float
    private var started: Double?
    private var stopped = false
    private var presentedFrames = 0
    private var firstPresentedTime = 0.0
    private var lastPresentedTime = 0.0
    private var maximumFrameGap = 0.0
    private var firstMotionPresented = false
    private(set) var finishedTransparent = false
    private static let log = Logger(subsystem: "org.gestures.studio", category: "RippleRenderer")
    var onFirstPresented: (@MainActor (Double) -> Void)?
    var onFinished: (@MainActor () -> Void)?
    convenience init(view: MTKView, image: CGImage, direction: MoveDirection?, preview: Bool) throws {
        guard let gpu = RippleGPU.shared else { throw GestureError("Metal is unavailable.") }
        let frame = RippleFrame(texture: try RippleTexture.make(image, device: gpu.device))
        self.init(view: view, frame: frame, gpu: gpu, direction: direction, preview: preview, duration: RippleDuration.current)
    }
    init(view: MTKView, frame: RippleFrame, gpu: RippleGPU, direction: MoveDirection?, preview: Bool, duration: Double, finishBy: Double? = nil) {
        self.gpu = gpu; self.view = view; self.preview = preview
        self.duration = duration
        self.finishBy = finishBy
        let savedStrength = UserDefaults.standard.object(forKey: RippleStrength.preferenceKey) as? Double ?? RippleStrength.standard
        self.strengthPoints = Float(RippleStrength.clamped(savedStrength))
        let vector = direction?.vector ?? Point2(x: 0, y: 0)
        self.direction = SIMD2(Float(vector.x), -Float(vector.y))
        self.frame = frame
        super.init()
        view.wantsLayer = true
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        let refresh = (view.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        view.preferredFramesPerSecond = max(30,min(120,refresh > 0 ? refresh : 60)); view.enableSetNeedsDisplay = false
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer { layer.displaySyncEnabled = true; layer.maximumDrawableCount = 2 }
        view.delegate = self; view.isPaused = false
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard !stopped, let frame, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let buffer = gpu.queue.makeCommandBuffer() else { return }
        let texture = frame.texture
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - (started ?? now))
        let previewEnd = 1.4 + duration
        let progress = preview ? (elapsed >= previewEnd ? 1 : min(1, elapsed.truncatingRemainder(dividingBy: 0.7) / duration)) : min(1, elapsed / duration)
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        // A miniature desktop keeps the same relative bend as the full display.
        let screenWidth = Float((view.window?.screen ?? NSScreen.main)?.frame.width ?? 1512)
        let strength = strengthPoints * (preview ? Float(texture.width)/max(1,screenWidth) : scale)
        var uniforms = RippleUniforms(size: SIMD2(Float(texture.width), Float(texture.height)), direction: direction,
                                      progress: Float(progress), strength: strength,
                                      opacity: 1, backdrop: preview ? 1 : 0)
        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let finalFrame = preview ? elapsed >= previewEnd : progress >= 1
        let hasMotion = progress >= 0.10 && progress < 0.86
        drawable.addPresentedHandler { [weak self] presented in
            let time = presented.presentedTime
            Task { @MainActor [weak self] in self?.didPresent(at: time, final: finalFrame, hasMotion: hasMotion) }
        }
        buffer.present(drawable)
        let logger = Self.log
        buffer.addCompletedHandler { [frame] command in
            withExtendedLifetime(frame) {}
            if let error = command.error { logger.error("Ripple frame failed: \(error.localizedDescription)") }
        }
        buffer.commit()
    }
    private func didPresent(at time: Double, final: Bool, hasMotion: Bool) {
        guard !stopped, time.isFinite, time > 0 else { return }
        presentedFrames += 1
        if started == nil {
            if let finishBy { duration = RippleTiming.duration(requested: duration, startingAt: time, finishBy: finishBy) }
            started = time
            firstPresentedTime = time
            let callback = onFirstPresented; onFirstPresented = nil
            callback?(duration)
        }
        if lastPresentedTime > 0 { maximumFrameGap = max(maximumFrameGap,time-lastPresentedTime) }
        lastPresentedTime = time
        if hasMotion, !firstMotionPresented, !preview {
            firstMotionPresented = true
            Self.log.info("First directional deformation presented \((time-self.firstPresentedTime)*1000) ms after the initial frame.")
        }
        guard final, !stopped else { return }
        finishedTransparent = !preview
        view?.isPaused = true
        if !preview {
            Self.log.info("Ripple presented \(self.presentedFrames) frames over \(time-self.firstPresentedTime) seconds; largest frame gap \(self.maximumFrameGap*1000) ms; final frame transparent.")
        }
        let callback = onFinished; onFinished = nil
        stop()
        callback?()
    }
    func stop() {
        stopped = true; view?.isPaused = true; view?.delegate = nil
        frame = nil; onFirstPresented = nil; onFinished = nil
    }
}

struct RippleSampleView: NSViewRepresentable {
    var direction: MoveDirection?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 280))
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 560, height: 280), device: RippleGPU.shared?.device)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if let sample = RippleSample.image() {
            do { context.coordinator.renderer = try RippleRenderer(view: view, image: sample, direction: direction, preview: true) }
            catch { Logger(subsystem: "org.gestures.studio", category: "RippleRenderer").error("Sample renderer could not initialize: \(error.localizedDescription)") }
        }
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.renderer?.stop(); coordinator.renderer = nil }
    @MainActor final class Coordinator { var renderer: RippleRenderer? }
}

@MainActor enum RippleSample {
    static let stillImage = image()
    /// Synthetic content made in memory; the preview does not inspect the desktop.
    static func image() -> CGImage? {
        let size = NSSize(width: 1080, height: 560)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(size.width) * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = NSRect(origin: .zero, size: size)
            NSGradient(colors: [NSColor(red: 0.28, green: 0.47, blue: 0.69, alpha: 1), NSColor(red: 0.80, green: 0.73, blue: 0.64, alpha: 1)])?.draw(in: rect, angle: -25)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 145, y: 88, width: 790, height: 384), xRadius: 24, yRadius: 24).fill()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: 173 + index*22, y: 437, width: 12, height: 12)).fill()
            }
            let textColor = NSColor(calibratedWhite: 0.19, alpha: 1)
            ("A quiet shift." as NSString).draw(at: NSPoint(x: 195, y: 330), withAttributes: [.font: NSFont.systemFont(ofSize: 43, weight: .medium), .foregroundColor: textColor])
            ("The desktop bends gently. Then your action happens." as NSString).draw(at: NSPoint(x: 196, y: 285), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: textColor.withAlphaComponent(0.65)])
            for i in 0..<4 {
                NSColor(calibratedWhite: 0.3, alpha: 0.1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 196, y: 155 + i*26, width: i == 0 ? 360 : 650, height: 7), xRadius: 3, yRadius: 3).fill()
            }
        return context.makeImage()
    }
}
