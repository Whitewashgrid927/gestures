import Foundation
@preconcurrency import Vision
import CoreGraphics
import CoreMedia

/// Converts Apple's landmarks to the same mirrored coordinates shown in the preview.
/// Pose geometry uses square pixel coordinates; movement distances use frame fractions.
enum HandGeometry {
    static let names: [(String, VNHumanHandPoseObservation.JointName)] = [
        ("wrist", .wrist), ("thumbCMC", .thumbCMC), ("thumbMCP", .thumbMP), ("thumbIP", .thumbIP), ("thumbTip", .thumbTip),
        ("indexMCP", .indexMCP), ("indexPIP", .indexPIP), ("indexDIP", .indexDIP), ("indexTip", .indexTip),
        ("middleMCP", .middleMCP), ("middlePIP", .middlePIP), ("middleDIP", .middleDIP), ("middleTip", .middleTip),
        ("ringMCP", .ringMCP), ("ringPIP", .ringPIP), ("ringDIP", .ringDIP), ("ringTip", .ringTip),
        ("littleMCP", .littleMCP), ("littlePIP", .littlePIP), ("littleDIP", .littleDIP), ("littleTip", .littleTip)
    ]
    static let chains = [["wrist", "thumbCMC", "thumbMCP", "thumbIP", "thumbTip"], ["wrist", "indexMCP", "indexPIP", "indexDIP", "indexTip"], ["wrist", "middleMCP", "middlePIP", "middleDIP", "middleTip"], ["wrist", "ringMCP", "ringPIP", "ringDIP", "ringTip"], ["wrist", "littleMCP", "littlePIP", "littleDIP", "littleTip"], ["indexMCP", "middleMCP", "ringMCP", "littleMCP"]]
    static func convert(_ observation: VNHumanHandPoseObservation, width: Double, height: Double, mirrored: Bool = true) -> TrackedHand? {
        var joints: [String: Landmark] = [:]
        for (name, key) in names {
            if let p = try? observation.recognizedPoint(key), p.confidence > 0.15,
               p.location.x.isFinite, p.location.y.isFinite {
                joints[name] = .init(point: .init(x: mirrored ? 1 - p.location.x : p.location.x, y: p.location.y), confidence: Double(p.confidence))
            }
        }
        let side: HandChoice = observation.chirality == .left ? .left : observation.chirality == .right ? .right : .either
        return measure(joints: joints, side: side, aspect: width / max(1, height))
    }
    static func measure(joints: [String: Landmark], side: HandChoice, aspect: Double) -> TrackedHand? {
        let base = ["wrist", "indexMCP", "middleMCP", "ringMCP", "littleMCP"].compactMap { joints[$0] }.filter { $0.confidence >= 0.3 }
        guard base.count >= 4, joints["wrist"] != nil else { return nil }
        let palm = base.map(\.point).reduce(.init(x: 0, y: 0), +) * (1 / Double(base.count))
        let confidence = base.map(\.confidence).reduce(0, +) / Double(base.count)
        func point(_ key: String) -> Point2? {
            guard let p = joints[key], p.confidence >= 0.45 else { return nil }
            return .init(x: p.point.x * aspect, y: p.point.y)
        }
        func angle(_ a: Point2, _ b: Point2, _ c: Point2) -> Double {
            let u = a - b, v = c - b
            guard u.length > 0.0001, v.length > 0.0001 else { return 0 }
            return acos(max(-1, min(1, u.dot(v) / (u.length * v.length)))) * 180 / .pi
        }
        var states: [Finger: FingerState] = [:]
        var curledEvidence: [Finger: [String]] = [:]
        if let wrist = point("wrist") {
            for finger in Finger.allCases where finger != .thumb {
                let prefix = finger.rawValue.lowercased()
                if let mcp = point(prefix + "MCP"), let pip = point(prefix + "PIP"), let dip = point(prefix + "DIP") {
                    let a = angle(mcp, pip, dip)
                    if (mcp - pip).length > 0.0001, (dip - pip).length > 0.0001, a < 130 {
                        // A visible joint bend proves curl without requiring an occluded fingertip.
                        states[finger] = .curled
                        curledEvidence[finger] = [prefix + "MCP", prefix + "PIP", prefix + "DIP"]
                    } else if let tip = point(prefix + "Tip") {
                        let b = angle(pip, dip, tip)
                        if a >= 150 && b >= 145 && (tip - wrist).length > (pip - wrist).length * 1.08 { states[finger] = .extended }
                        else if (tip - wrist).length < (pip - wrist).length * 1.02 {
                            states[finger] = .curled
                            curledEvidence[finger] = ["wrist", prefix + "MCP", prefix + "PIP", prefix + "DIP", prefix + "Tip"]
                        }
                    }
                }
            }
            if let cmc = point("thumbCMC"), let mcp = point("thumbMCP"), let ip = point("thumbIP"), let tip = point("thumbTip") {
                if angle(cmc, mcp, ip) > 140 && angle(mcp, ip, tip) > 150 { states[.thumb] = .extended }
                else if angle(mcp, ip, tip) < 130 || angle(cmc, mcp, ip) < 125 { states[.thumb] = .curled }
            }
        }
        var pinch: Double?
        if let thumb = point("thumbTip"), let index = point("indexTip"), let a = point("indexMCP"), let b = point("littleMCP"), (a - b).length > 0.015 { pinch = (thumb - index).length / (a - b).length }
        return .init(side: side, joints: joints, palm: palm, confidence: confidence, fingers: states, pinchRatio: pinch, curledEvidence: curledEvidence)
    }
}

final class VisionTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest(); request.maximumHandCount = 2; return request
    }()
    func detect(buffer: CVPixelBuffer, time: Double) throws -> HandFrame {
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        return .init(time: time, hands: (request.results ?? []).compactMap { HandGeometry.convert($0, width: width, height: height) }, width: width, height: height)
    }
    func detect(image: CGImage, time: Double, mirrored: Bool = true) throws -> HandFrame {
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return .init(time: time, hands: (request.results ?? []).compactMap { HandGeometry.convert($0, width: Double(image.width), height: Double(image.height), mirrored: mirrored) }, width: Double(image.width), height: Double(image.height))
    }
}
