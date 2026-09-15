import AppIntents
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor final class MessageNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MessageNotifications()
    private let center = UNUserNotificationCenter.current()
    private var registration = NotificationRegistration()
    private var registrationRetry: Task<Void, Never>?
    private var activated = false
    private var refreshing = false
    private weak var activeConnection: Connection?

    func activate() {
        requestDeviceTokenIfNeeded()
        guard !activated else { return }
        activated = true
        // APNs tokens must come from this launch's callback, not persistent storage.
        UserDefaults.standard.removeObject(forKey: "messageDeviceToken")
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [.authenticationRequired], textInputButtonTitle: "Send", textInputPlaceholder: "Ask Autolith")
        let category = UNNotificationCategory(identifier: "autolith.message", actions: [reply], intentIdentifiers: [], options: [.customDismissAction])
        center.setNotificationCategories([category])
    }

    func enable() async {
        activate()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            UserDefaults.standard.set(granted, forKey: "messageNotificationsEnabled")
            UserDefaults.standard.set(granted ? "Response alerts enabled. Waiting for work to finish." : "Notifications are disabled in system Settings.", forKey: "messageNotificationStatus")
            if granted { requestDeviceTokenIfNeeded() }
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError") }
    }

    private func requestDeviceTokenIfNeeded() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if registration.requestDeviceToken(enabled: UserDefaults.standard.bool(forKey: "messageNotificationsEnabled"), now: Date()) {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    func receivedDeviceToken(_ token: String) {
        registrationRetry?.cancel()
        registrationRetry = nil
        registration.receivedDeviceToken(token)
        UserDefaults.standard.removeObject(forKey: "messageNotificationError")
        // The next refresh registers a changed token regardless of the host renewal timer.
    }

    func deviceRegistrationFailed(_ error: Error) {
        UserDefaults.standard.set("Local alerts remain enabled. Remote push registration failed: " + error.localizedDescription, forKey: "messageNotificationError")
        guard let delay = registration.deviceRegistrationFailed(now: Date()) else { return }
        registrationRetry?.cancel()
        registrationRetry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.requestDeviceTokenIfNeeded()
        }
    }

    /// Call before replacing saved credentials. Use a snapshot so another save
    /// cannot redirect this request to the new computer while it is suspended.
    func revoke(connection: Connection) async {
        activeConnection = connection
        let captured = connection.context
        registration.activate(context: captured)
        guard let token = registration.revoke(host: captured.host) else {
            UserDefaults.standard.set("No current device token is available to revoke previous alerts. A previous registration may continue until its seven-day lease expires.", forKey: "messageNotificationError")
            return
        }
        do {
            let reply = try await connection.call(["operation": "notification-unregister", "pushToken": token, "host": captured.host], context: captured)
            try SiriMessageReceipt.confirmed(reply.ok)
        } catch {
            UserDefaults.standard.set("Could not revoke alerts on the previous computer. Its registration may continue until the seven-day lease expires: " + error.localizedDescription, forKey: "messageNotificationError")
        }
    }

    private func observed(_ identity: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "notificationObservedEvents") ?? []).contains(identity)
    }

    private func recordObserved(_ identity: String) {
        var identities = UserDefaults.standard.stringArray(forKey: "notificationObservedEvents") ?? []
        identities.removeAll { $0 == identity }
        identities.append(identity)
        UserDefaults.standard.set(Array(identities.suffix(512)), forKey: "notificationObservedEvents")
    }

    private func eventIdentity(_ info: [AnyHashable: Any]) -> String? {
        guard let host = info["host"] as? String, let session = info["sessionID"] as? String,
              let event = info["eventID"] as? String else { return nil }
        return NotificationEventIdentity.id(host: host, sessionID: session, eventID: event)
    }

    private func valid(_ connection: Connection, _ captured: ConnectionContext) -> Bool {
        connection.isCurrent(captured) && !connection.switching && UserDefaults.standard.bool(forKey: "messageNotificationsEnabled")
    }

    private func refreshRemoteRegistration(connection: Connection, captured: ConnectionContext) async {
        guard valid(connection, captured) else { return }
        registration.activate(context: captured)
        let host = captured.host
        guard let request = registration.beginRemoteRegistration(host: host, now: Date()) else { return }
        var accepted = false
        var attempted = false
        defer {
            if registration.finishRemoteRegistration(request, accepted: accepted, now: Date()) {
                UserDefaults.standard.set("Remote notifications registered with the computer.", forKey: "messageNotificationStatus")
            }
        }
        do {
            let capabilities = try await connection.call(["operation": "capabilities"], context: captured)
            guard valid(connection, captured), registration.isCurrent(request), capabilities.pushEnabled == true else { return }
            attempted = true
            let reply = try await connection.call(["operation": "notification-register", "pushToken": request.token, "host": host], context: captured)
            try SiriMessageReceipt.confirmed(reply.ok)
            guard valid(connection, captured), registration.isCurrent(request) else {
                // A revoke may have completed while the earlier registration was
                // still in flight. Compensate on that same captured endpoint.
                let revoked = try await connection.call(["operation": "notification-unregister", "pushToken": request.token, "host": host], context: captured)
                try SiriMessageReceipt.confirmed(revoked.ok)
                return
            }
            accepted = true
        } catch {
            if attempted && (!valid(connection, captured) || !registration.isCurrent(request)) {
                // An unconfirmed response can still mean the server committed it.
                // Best-effort cleanup uses the original credentials, never the new computer.
                do {
                    let revoked = try await connection.call(["operation": "notification-unregister", "pushToken": request.token, "host": host], context: captured)
                    try SiriMessageReceipt.confirmed(revoked.ok)
                } catch {
                    UserDefaults.standard.set("Could not revoke the previous alert registration. It may continue until its seven-day lease expires. " + error.localizedDescription, forKey: "messageNotificationError")
                    return
                }
            }
            // A push failure must not prevent local completion delivery.
            UserDefaults.standard.set("Remote alert registration was not confirmed. A previous registration may persist until its seven-day lease expires. " + error.localizedDescription, forKey: "messageNotificationError")
        }
    }

    func refresh(connection: Connection) async {
        activeConnection = connection
        guard UserDefaults.standard.bool(forKey: "messageNotificationsEnabled") else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let captured = connection.context
        let host = captured.host
        guard valid(connection, captured) else { return }
        requestDeviceTokenIfNeeded()
        await refreshRemoteRegistration(connection: connection, captured: captured)
        guard valid(connection, captured) else { return }
        let key = "notificationProgress:" + host
        let saved = UserDefaults.standard.data(forKey: key)
        do {
            var state = try await BackgroundWork.run(priority: .utility) {
                saved.flatMap { try? JSONDecoder().decode(CompletionNotifications.self, from: $0) } ?? CompletionNotifications()
            }
            guard valid(connection, captured) else { return }
            for session in connection.sessions where session.isWorking && !state.working.contains(session.id) {
                let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0], context: captured).events ?? []
                guard valid(connection, captured) else { return }
                let previous = state
                state = try await BackgroundWork.run(priority: .utility) {
                    var prepared = previous
                    prepared.baseline(sessionID: session.id, events: events)
                    return prepared
                }
                guard valid(connection, captured) else { return }
            }
            let completed = state.completed(connection.sessions)
            // Registration acceptance says nothing about delivery. Keep local
            // fallback, deduplicating events actually observed on this device.
            let delivered = await center.deliveredNotifications()
            guard valid(connection, captured) else { return }
            let deliveredIDs = Set(delivered.compactMap { eventIdentity($0.request.content.userInfo) })
            for session in completed {
                let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0], context: captured).events ?? []
                guard valid(connection, captured) else { return }
                let answer = try await BackgroundWork.run(priority: .utility) { SiriContent.latestAnswerEvent(in: events) }
                guard valid(connection, captured) else { return }
                guard let answer else { continue }
                guard state.announced[session.id] != answer.id else { _ = state.acknowledge(sessionID: session.id, eventID: answer.id); continue }
                let identity = NotificationEventIdentity.id(host: host, sessionID: session.id, eventID: answer.id)
                if deliveredIDs.contains(identity) || observed(identity) {
                    _ = state.acknowledge(sessionID: session.id, eventID: answer.id)
                    continue
                }
                let content = UNMutableNotificationContent()
                content.title = session.title
                content.body = String(answer.text.prefix(300))
                content.sound = .default
                content.categoryIdentifier = "autolith.message"
                content.threadIdentifier = host + "#" + session.id
                content.userInfo = ["host": host, "sessionID": session.id, "eventID": answer.id, "notificationID": identity]
                if #available(iOS 27.0, macOS 27.0, *) {
                    let identity = SiriMessageIdentity(host: host, sessionID: session.id, eventID: answer.id)
                    content.appEntityIdentifiers = [EntityIdentifier(for: AutolithMessageEntity.self, identifier: identity.id)]
                }
                guard valid(connection, captured) else { return }
                try await center.add(UNNotificationRequest(identifier: identity, content: content, trigger: nil))
                guard valid(connection, captured) else {
                    center.removePendingNotificationRequests(withIdentifiers: [identity])
                    center.removeDeliveredNotifications(withIdentifiers: [identity])
                    return
                }
                _ = state.acknowledge(sessionID: session.id, eventID: answer.id)
            }
            let finalState = state
            let encoded = try await BackgroundWork.run(priority: .utility) { try JSONEncoder().encode(finalState) }
            guard valid(connection, captured) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError") }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await presentation(for: notification)
    }

    private func presentation(for notification: UNNotification) -> UNNotificationPresentationOptions {
        if let identity = eventIdentity(notification.request.content.userInfo) {
            guard !observed(identity) else { return [] }
            recordObserved(identity)
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await handle(response)
    }

    private func handle(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let identity = eventIdentity(info) { recordObserved(identity) }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        guard let host = info["host"] as? String, let id = info["sessionID"] as? String else { return }
        let draftKey = "notificationReplyDraft:" + NotificationEventIdentity.id(host: host, sessionID: id, eventID: "draft")
        if let reply = response as? UNTextInputNotificationResponse {
            // Save before attempting delivery, including wrong-host and offline replies.
            // Restoration only fills the composer; it never queues a send.
            UserDefaults.standard.set(reply.userText, forKey: draftKey)
        }
        let connection = activeConnection ?? Connection()
        let captured = connection.context
        guard !connection.switching, CompanionEndpoint.equivalent(captured.host, host) else {
            UserDefaults.standard.set("This notification belongs to a different computer.", forKey: "messageNotificationError")
            return
        }
        if let reply = response as? UNTextInputNotificationResponse {
            do {
                _ = try SiriContent.question(reply.userText)
                let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                let requestID = UUID().uuidString
                let result = try await connection.call(["operation": "message-send", "id": id, "requestID": requestID, "text": text], context: captured)
                _ = try SiriMessageReceipt.accepted(events: result.events ?? [], requestID: requestID, text: text)
                UserDefaults.standard.removeObject(forKey: draftKey)
                guard connection.isCurrent(captured), !connection.switching else { return }
                SiriConversationMemory.sent(id: id, host: host)
                if #available(iOS 27.0, macOS 27.0, *) {
                    await SiriMessageMaintenance.update(host: captured.host, sessionID: id) { }
                }
            } catch {
                SiriNavigationState.shared.draft = (host: host, id: id, text: reply.userText)
                UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError")
                let content = UNMutableNotificationContent()
                content.title = "Autolith reply was not confirmed"
                content.body = "Open the conversation before sending again. " + error.localizedDescription
                content.userInfo = ["host": host, "sessionID": id]
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        } else {
            SiriNavigationState.shared.sessionID = (host: host, id: id)
            if let text = UserDefaults.standard.string(forKey: draftKey) {
                SiriNavigationState.shared.draft = (host: host, id: id, text: text)
            }
            if let eventID = info["eventID"] as? String {
                do {
                    let events = try await connection.call(["operation": "transcript", "id": id, "after": 0], context: captured).events ?? []
                    guard connection.isCurrent(captured) else { return }
                    if let event = events.first(where: { $0.id == eventID }) {
                        _ = try await SiriMessageReading.read(event, sessionID: id, connection: connection)
                    }
                } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError") }
            }
        }
    }
}

#if os(iOS)
@MainActor final class NotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MessageNotifications.shared.receivedDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MessageNotifications.shared.deviceRegistrationFailed(error)
    }
}
#endif

struct MessageNotificationSettings: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("messageNotificationsEnabled") private var enabled = false
    @AppStorage("messageNotificationStatus") private var status = "Notifications have not been enabled."
    @AppStorage("messageNotificationError") private var error = ""
    var body: some View {
        Button(enabled ? "Notification settings" : "Enable response notifications") {
            if enabled {
                #if os(iOS)
                openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                #endif
            } else { Task { await MessageNotifications.shared.enable() } }
        }
        Text(status).font(.caption).foregroundStyle(.secondary)
        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
    }
}
