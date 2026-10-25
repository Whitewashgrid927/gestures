import Foundation

enum LibraryIO {
    static func load(_ url: URL) throws -> GestureLibrary {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (1...2_000_000).contains(size) else { throw GestureError("Choose a gesture library smaller than 2 MB. Symbolic links are not supported.") }
        return try JSONDecoder().decode(GestureLibrary.self, from: Data(contentsOf: url)).validated()
    }
    static func save(_ library: GestureLibrary, to url: URL) throws {
        _ = try library.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= 2_000_000 else { throw GestureError("This gesture library is too large to save.") }
        try data.write(to: url, options: .atomic)
    }
    static func merging(_ imported: GestureLibrary, into current: GestureLibrary) throws -> GestureLibrary {
        _ = try imported.validated(); _ = try current.validated()
        guard current.rules.count + imported.rules.count <= 100 else { throw GestureError("A library supports up to 100 gestures.") }
        var merged = current
        for var rule in imported.rules {
            rule.id = UUID(); rule.enabled = false
            for index in rule.steps.indices { rule.steps[index].id = UUID() }
            merged.rules.append(rule)
        }
        return try merged.validated()
    }
}

enum GestureDemonstration {
    static func suggest(_ frames: [HandFrame]) throws -> GestureRule {
        let hands = frames.compactMap { frame -> (Double, TrackedHand)? in
            guard let hand = frame.hands.max(by: { $0.confidence < $1.confidence }), hand.confidence >= 0.55 else { return nil }
            return (frame.time, hand)
        }
        guard hands.count >= 12, let first = hands.first else { throw GestureError("Keep one hand clearly visible while demonstrating a swipe.") }
        let sameHand = hands.filter { first.1.side == .either || $0.1.side == first.1.side }
        guard sameHand.count >= 12, let last = sameHand.last else { throw GestureError("Use the same hand for the entire demonstration.") }
        let start = sameHand.prefix(3).map { $0.1.palm }.reduce(.init(x: 0, y: 0), +) * (1 / 3.0)
        let end = sameHand.suffix(3).map { $0.1.palm }.reduce(.init(x: 0, y: 0), +) * (1 / 3.0)
        let delta = end - start
        guard delta.length >= 0.08, delta.length < 0.8, last.0 > first.0 else { throw GestureError("Make one clear swipe, then leave your hand at the end position until recording finishes.") }
        let direction = MoveDirection.allCases.max(by: { delta.dot($0.vector) < delta.dot($1.vector) }) ?? .left
        let pose = [PoseKind.pinch, .open, .fist, .point, .victory].first { first.1.matches(.init(kind: $0), hand: .either, minimum: 0.55) } ?? .any
        var rule = GestureRule(name: "My \(direction.rawValue.lowercased()) swipe")
        rule.hand = first.1.side; rule.enabled = false
        rule.steps = [.init(kind: .pose, pose: .init(kind: pose)), .init(kind: .hold, duration: 0.2), .init(kind: .move, direction: direction, distance: min(0.45, max(0.06, delta.length * 0.75)), maximumDuration: 3)]
        return try rule.validated()
    }
}
