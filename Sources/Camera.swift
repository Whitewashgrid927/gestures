import Foundation
@preconcurrency import AVFoundation
import CoreMedia

struct CameraChoice: Identifiable, Sendable { var id: String; var name: String }
enum CameraStatus: Sendable, Equatable { case off, starting, running, failed(String) }

/// All session setup and frame processing are serialized on this private queue.
/// Only landmark values cross to the main actor; pixel buffers are not retained.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "gestures.camera", qos: .userInitiated)
    private let onFrame: @Sendable (UUID, HandFrame) -> Void
    private let onStatus: @Sendable (UUID, CameraStatus) -> Void
    private let tracker = VisionTracker()
    private var lastTime: Double = 0
    private var running = false
    private var failureCount = 0
    private var generation = UUID()
    init(onFrame: @escaping @Sendable (UUID, HandFrame) -> Void, onStatus: @escaping @Sendable (UUID, CameraStatus) -> Void) {
        self.onFrame = onFrame; self.onStatus = onStatus
    }
    static func devices() -> [CameraChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices.map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }
    func start(deviceID: String?, generation: UUID) {
        queue.async { [self] in
            guard !running else { return }
            self.generation = generation
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { onStatus(generation, .failed("Allow Camera access in System Settings, then try again.")); return }
            onStatus(generation, .starting)
            do {
                let choices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
                guard let device = choices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) else { throw GestureError("No camera is available. Connect one and try again.") }
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.sessionPreset = .hd1280x720
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw GestureError("This camera cannot be opened.") }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else { throw GestureError("Could not start camera processing.") }
                    session.addOutput(output)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                    }
                    session.commitConfiguration()
                } catch { session.commitConfiguration(); throw error }
                failureCount = 0; lastTime = 0; running = true
                session.startRunning()
                guard session.isRunning else { running = false; throw GestureError("The camera could not start. It may be unavailable or in use.") }
                onStatus(generation, .running)
            } catch { onStatus(generation, .failed(error.localizedDescription)) }
        }
    }
    func stop() {
        queue.async { [self] in
            running = false
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
            onStatus(generation, .off)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        guard running, time - lastTime >= 1 / 20, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastTime = time
        do { let frame = try tracker.detect(buffer: buffer, time: time); failureCount = 0; onFrame(generation, frame) }
        catch {
            failureCount += 1
            onFrame(generation, .init(time: time, hands: []))
            if failureCount == 20 { running = false; session.stopRunning(); onStatus(generation, .failed("Hand tracking stopped. Restart the camera to try again.")) }
        }
    }
}
