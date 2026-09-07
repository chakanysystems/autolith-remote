import Foundation

enum SiriConversationSelection {
    static func latest(in sessions: [Session], preferredID: String?) -> Session? {
        if let preferredID, let remembered = sessions.first(where: { $0.id == preferredID }) { return remembered }
        return sessions.sorted {
            let left = $0.updatedAt ?? 0, right = $1.updatedAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }.first
    }

    static func progress(sessions: [Session], selected: Session) -> String {
        let working = sessions.filter(\.isWorking).count
        let activity = working == 0 ? "Nothing is running." : working == 1 ? "One conversation is working." : "\(working) conversations are working."
        return "\(activity) Your conversation, \(selected.title), is \(selected.state)."
    }
}
