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

    private func refreshRemoteRegistration(connection: Connection, host: String) async {
        guard let request = registration.beginRemoteRegistration(host: host, now: Date()) else { return }
        var accepted = false
        defer {
            if registration.finishRemoteRegistration(request, accepted: accepted, now: Date()) {
                UserDefaults.standard.set("Remote notifications registered with the Mac.", forKey: "messageNotificationStatus")
            }
        }
        do {
            let capabilities = try await connection.call(["operation": "capabilities"])
            guard connection.host == host, registration.isCurrent(request), capabilities.pushEnabled == true else { return }
            let reply = try await connection.call(["operation": "notification-register", "pushToken": request.token, "host": host])
            try SiriMessageReceipt.confirmed(reply.ok)
            accepted = connection.host == host
        } catch {
            // A push failure must not prevent local completion delivery.
            UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError")
        }
    }

    func refresh(connection: Connection) async {
        guard UserDefaults.standard.bool(forKey: "messageNotificationsEnabled") else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let host = connection.host
        requestDeviceTokenIfNeeded()
        await refreshRemoteRegistration(connection: connection, host: host)
        guard connection.host == host else { return }
        let key = "notificationProgress:" + host
        let saved = UserDefaults.standard.data(forKey: key)
        do {
            var state = try await BackgroundWork.run(priority: .utility) {
                saved.flatMap { try? JSONDecoder().decode(CompletionNotifications.self, from: $0) } ?? CompletionNotifications()
            }
            guard connection.host == host else { return }
            for session in connection.sessions where session.isWorking && !state.working.contains(session.id) {
                let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0]).events ?? []
                guard connection.host == host else { return }
                let previous = state
                state = try await BackgroundWork.run(priority: .utility) {
                    var prepared = previous
                    prepared.baseline(sessionID: session.id, events: events)
                    return prepared
                }
                guard connection.host == host else { return }
            }
            let completed = state.completed(connection.sessions)
            // Only an unexpired registration for this host and current token replaces local alerts.
            if !registration.usesRemoteNotifications(host: host, now: Date()) {
                UserDefaults.standard.set("Local notifications while Autolith can refresh. Background delivery needs APNs on the Mac.", forKey: "messageNotificationStatus")
                for session in completed {
                    let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0]).events ?? []
                    guard connection.host == host else { return }
                    let answer = try await BackgroundWork.run(priority: .utility) { SiriContent.latestAnswerEvent(in: events) }
                    guard connection.host == host else { return }
                    guard let answer else { continue }
                    guard state.announced[session.id] != answer.id else { _ = state.acknowledge(sessionID: session.id, eventID: answer.id); continue }
                    let content = UNMutableNotificationContent()
                    content.title = session.title
                    content.body = String(answer.text.prefix(300))
                    content.sound = .default
                    content.categoryIdentifier = "autolith.message"
                    content.threadIdentifier = host + "#" + session.id
                    content.userInfo = ["host": host, "sessionID": session.id, "eventID": answer.id]
                    if #available(iOS 27.0, macOS 27.0, *) {
                        let identity = SiriMessageIdentity(host: host, sessionID: session.id, eventID: answer.id)
                        content.appEntityIdentifiers = [EntityIdentifier(for: AutolithMessageEntity.self, identifier: identity.id)]
                    }
                    try await center.add(UNNotificationRequest(identifier: host + "#" + session.id + "#" + answer.id, content: content, trigger: nil))
                    _ = state.acknowledge(sessionID: session.id, eventID: answer.id)
                }
            }
            let finalState = state
            let encoded = try await BackgroundWork.run(priority: .utility) { try JSONEncoder().encode(finalState) }
            guard connection.host == host else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError") }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await handle(response)
    }

    private func handle(_ response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        guard let host = info["host"] as? String, let id = info["sessionID"] as? String else { return }
        let connection = Connection()
        guard CompanionEndpoint.equivalent(connection.host, host) else {
            UserDefaults.standard.set("This notification belongs to a different Mac.", forKey: "messageNotificationError")
            return
        }
        if let reply = response as? UNTextInputNotificationResponse {
            do {
                _ = try SiriContent.question(reply.userText)
                let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                let requestID = UUID().uuidString
                let result = try await connection.call(["operation": "message-send", "id": id, "requestID": requestID, "text": text])
                _ = try SiriMessageReceipt.accepted(events: result.events ?? [], requestID: requestID, text: text)
                SiriConversationMemory.sent(id: id, host: host)
                if #available(iOS 27.0, macOS 27.0, *) {
                    await SiriMessageMaintenance.update(host: connection.host, sessionID: id) { }
                }
            } catch {
                UserDefaults.standard.set(error.localizedDescription, forKey: "messageNotificationError")
                let content = UNMutableNotificationContent()
                content.title = "Autolith reply was not confirmed"
                content.body = "Open the conversation before sending again. " + error.localizedDescription
                content.userInfo = ["host": host, "sessionID": id]
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        } else {
            SiriNavigationState.shared.sessionID = id
            if let eventID = info["eventID"] as? String {
                do {
                    let events = try await connection.call(["operation": "transcript", "id": id, "after": 0]).events ?? []
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
