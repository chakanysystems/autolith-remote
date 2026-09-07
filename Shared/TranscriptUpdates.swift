import Foundation

/// Native numeric IDs are transcript sequence numbers; outbox rows are snapshots.
enum TranscriptUpdates {
    static func cursor(_ events: [Event]) -> Int { events.compactMap { Int($0.id) }.max() ?? 0 }

    static func merge(_ previous: [Event], incoming: [Event], replacing: Bool) -> [Event] {
        if replacing { return incoming }
        var result = previous.filter { !$0.id.hasPrefix("outbox-") }
        var positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        for event in incoming {
            if let index = positions[event.id] { result[index] = event }
            else { positions[event.id] = result.count; result.append(event) }
        }
        return result
    }
}
