import Foundation

/// Only user scrolling changes whether the conversation follows new output.
struct ConversationScrollState {
    private(set) var followsLatest = true
    private(set) var userIsScrolling = false
    var shouldFollow: Bool { followsLatest && !userIsScrolling }

    mutating func geometryChanged(distanceFromBottom: Double) {
        if userIsScrolling { followsLatest = distanceFromBottom <= 64 }
    }

    mutating func userScrollChanged(active: Bool, distanceFromBottom: Double) {
        if active || userIsScrolling { followsLatest = distanceFromBottom <= 64 }
        userIsScrolling = active
    }
}

/// Limit initial layout work without moving the reader's window on append.
struct ConversationHistoryWindow {
    private(set) var firstID: String?
    let pageSize = 100

    func startIndex(in ids: [String]) -> Int {
        if let firstID, let index = ids.firstIndex(of: firstID) { return index }
        return max(0, ids.count - pageSize)
    }

    mutating func update(_ ids: [String]) {
        guard !ids.isEmpty else { firstID = nil; return }
        firstID = ids[startIndex(in: ids)]
    }

    mutating func showEarlier(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        firstID = ids[max(0, startIndex(in: ids) - pageSize)]
    }
}
