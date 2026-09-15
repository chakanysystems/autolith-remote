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

/// Keep layout bounded, pinning the current page while the user reads older output.
struct ConversationHistoryWindow {
    private(set) var firstID: String?
    private(set) var followsLatest = true
    private var browsingHistory = false
    let pageSize = 100

    func startIndex(in ids: [String]) -> Int {
        if followsLatest { return max(0, ids.count - pageSize) }
        if let firstID, let index = ids.firstIndex(of: firstID) { return index }
        return max(0, ids.count - pageSize)
    }

    func range(in ids: [String]) -> Range<Int> {
        let start = startIndex(in: ids)
        return start..<min(ids.count, start + pageSize)
    }

    mutating func setFollowing(_ follows: Bool, ids: [String]) {
        guard !browsingHistory else { return }
        update(ids)
        followsLatest = follows
    }

    mutating func update(_ ids: [String]) {
        guard !ids.isEmpty else { firstID = nil; followsLatest = true; browsingHistory = false; return }
        firstID = ids[startIndex(in: ids)]
    }

    mutating func showEarlier(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        firstID = ids[max(0, startIndex(in: ids) - pageSize)]
        followsLatest = false
        browsingHistory = true
    }

    mutating func showNewer(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let start = min(max(0, ids.count - pageSize), startIndex(in: ids) + pageSize)
        firstID = ids[start]
        followsLatest = start == max(0, ids.count - pageSize)
        browsingHistory = !followsLatest
    }

    mutating func showLatest(_ ids: [String]) {
        followsLatest = true
        browsingHistory = false
        update(ids)
    }
}
