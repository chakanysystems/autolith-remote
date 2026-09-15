import SwiftUI
import AppIntents

@MainActor final class SiriNavigationState: ObservableObject {
    static let shared = SiriNavigationState()
    @Published var search: String?
    @Published var sessionID: (host: String, id: String)?
    @Published var draft: (host: String, id: String, text: String)?
}

struct SiriNavigation: ViewModifier {
    @ObservedObject private var navigation = SiriNavigationState.shared
    @ObservedObject var connection: Connection
    @Binding var search: String
    func body(content: Content) -> some View {
        content
            .userActivity("com.chakany.autolith.session", isActive: connection.selection != nil) { activity in
                guard let session = connection.sessions.first(where: { $0.id == connection.selection }) else { return }
                activity.title = session.title
                activity.isEligibleForPublicIndexing = false
                if #available(iOS 27.0, macOS 27.0, *) {
                    activity.appEntityIdentifier = EntityIdentifier(for: AutolithConversationEntity.self, identifier: connection.host + "#" + session.id)
                } else if #available(iOS 18.2, macOS 15.2, *) {
                    activity.appEntityIdentifier = EntityIdentifier(for: AutolithSessionEntity(session: session, host: connection.host))
                }
            }
            .modifier(AutolithConversationAnnotation(host: connection.host, sessionID: connection.selection))
            .onReceive(navigation.$search) { query in
                if let query { search = query; navigation.search = nil }
            }
            .onReceive(navigation.$sessionID) { target in
                if let target {
                    navigation.sessionID = nil
                    guard CompanionEndpoint.equivalent(target.host, connection.host) else { return }
                    connection.selection = target.id
                }
            }
            .onReceive(navigation.$draft) { value in
                if let (host, id, text) = value {
                    navigation.draft = nil
                    guard CompanionEndpoint.equivalent(host, connection.host) else { return }
                    connection.drafts[id] = text
                    connection.selection = id
                }
            }
            .onChange(of: connection.online) { _, online in
                if online { AutolithShortcuts.updateAppShortcutParameters() }
            }
    }
}

private struct AutolithConversationAnnotation: ViewModifier {
    let host: String
    let sessionID: String?
    func body(content: Content) -> some View {
        if #available(iOS 27.0, macOS 27.0, *) {
            // Keep the navigation container's identity stable when selection changes.
            content.appEntityIdentifier(sessionID.map {
                EntityIdentifier(for: AutolithConversationEntity.self, identifier: host + "#" + $0)
            })
        } else { content }
    }
}

struct AutolithMessageAnnotation: ViewModifier {
    let connection: Connection
    let host: String
    let sessionID: String
    let event: Event
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 27.0, macOS 27.0, *), SiriMessageIdentity.date(for: event) != nil {
                content.appEntityIdentifier(EntityIdentifier(for: AutolithMessageEntity.self,
                    identifier: SiriMessageIdentity(host: host, sessionID: sessionID, eventID: event.id).id))
            } else { content }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: visible && scenePhase == .active && !event.hasBeenRead) {
            guard visible, scenePhase == .active, !event.hasBeenRead,
                  SiriMessageIdentity.date(for: event) != nil else { return }
            guard connection.host == host else { return }
            connection.queueRead(event, sessionID: sessionID)
        }
    }
}
