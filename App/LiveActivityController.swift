import Foundation
import UIKit
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor final class LiveActivityController {
    static let shared = LiveActivityController()
    private var updating = false
    private var epoch = UUID()

    /// Synchronously detach callbacks before any credential-switch suspension.
    func quiesce() {
        epoch = UUID()
        updating = false
        #if !targetEnvironment(macCatalyst)
        tokenTask?.cancel(); tokenTask = nil
        registeredToken = nil; registeredAt = .distantPast
        activity = nil; lastState = nil; lastUpdate = .distantPast
        #endif
    }
    #if !targetEnvironment(macCatalyst)
    private var activity: Activity<WorkActivityAttributes>?
    private var lastState: WorkSummary?
    private var lastUpdate = Date.distantPast
    private var tokenTask: Task<Void, Never>?
    private var registeredToken: String?
    private var registeredAt = Date.distantPast
    private var enabled: Bool { UserDefaults.standard.bool(forKey: "liveActivitiesEnabled") }
    #endif
    func update(_ sessions: [Session], connection: Connection) async {
        #if !targetEnvironment(macCatalyst)
        guard !connection.switching, !updating else { return }
        let identity = connection.context, operation = epoch
        updating = true
        defer { if epoch == operation { updating = false } }
        guard enabled else {
            await end()
            guard connection.isCurrent(identity) else { return }
            connection.activityError = nil
            connection.activityStatus = "Off"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            connection.activityError = "Live Activities are disabled in system Settings."
            connection.activityStatus = "Disabled by iPadOS"
            return
        }
        let summary = WorkSummary.from(sessions)
        guard summary.sessions > 0 else {
            await finish(host: connection.host)
            guard connection.isCurrent(identity), epoch == operation else { return }
            let retained = Activity<WorkActivityAttributes>.activities.contains {
                $0.attributes.host == connection.host && $0.activityState == .ended
            }
            connection.activityStatus = retained ? "No active work · Kept on the Lock Screen" : "Waiting for a session to start working."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            connection.activityStatus = "Open Autolith to start or update the activity."
            return
        }
        if activity?.activityState == .ended { activity = nil }
        if activity == nil {
            activity = Activity<WorkActivityAttributes>.activities.first {
                $0.attributes.host == connection.host && ($0.activityState == .active || $0.activityState == .stale)
            }
        }
        let content = ActivityContent(state: summary, staleDate: Date().addingTimeInterval(60))
        do {
            if let activity {
                guard activity.activityState == .active || activity.activityState == .stale else {
                    connection.activityStatus = "Dismissed or ended. Tap Show on Lock Screen to start again."
                    return
                }
                if lastState != summary || Date().timeIntervalSince(lastUpdate) > 30 {
                    await activity.update(content)
                    guard connection.isCurrent(identity), epoch == operation, !Task.isCancelled else { return }
                    lastState = summary; lastUpdate = Date()
                }
            } else {
                connection.activityStatus = "Starting Live Activity…"
                let capabilities = try? await connection.call(["operation": "capabilities"], context: identity)
                guard connection.isCurrent(identity), epoch == operation, !Task.isCancelled else { return }
                guard enabled, UIApplication.shared.applicationState == .active else {
                    connection.activityStatus = "Open Autolith to finish starting the activity."
                    return
                }
                let push = capabilities?.pushEnabled == true
                for previous in Activity<WorkActivityAttributes>.activities
                    where previous.attributes.host == connection.host && previous.activityState == .ended {
                    await previous.end(nil, dismissalPolicy: .immediate)
                    guard connection.isCurrent(identity), epoch == operation, !Task.isCancelled else { return }
                }
                do {
                    activity = try Activity.request(attributes: WorkActivityAttributes(host: connection.host), content: content, pushType: push ? .token : nil)
                } catch {
                    guard push else { throw error }
                    connection.activityError = "Push registration is unavailable in this build. The activity will update while Autolith is open."
                    activity = try Activity.request(attributes: WorkActivityAttributes(host: connection.host), content: content, pushType: nil)
                }
                lastState = summary; lastUpdate = Date()
            }
            connection.activityStatus = "Running on the Lock Screen · \(summary.sessions) working"
            if tokenTask == nil, let activity {
                tokenTask = Task { [weak self, weak connection] in
                    for await token in activity.pushTokenUpdates {
                        guard let self, let connection, !Task.isCancelled,
                              self.epoch == operation, connection.isCurrent(identity) else { return }
                        await self.register(token, activity: activity, connection: connection, identity: identity, epoch: operation)
                    }
                }
            }
            if let activity, let token = activity.pushToken {
                await register(token, activity: activity, connection: connection, identity: identity, epoch: operation)
            }
        } catch {
            guard connection.isCurrent(identity), epoch == operation else { return }
            let detail = error as NSError
            connection.activityError = "Could not start Live Activity: \(detail.localizedDescription) (\(detail.domain), \(detail.code))"
            connection.activityStatus = "Could not start Live Activity"
        }
        #endif
    }
    #if !targetEnvironment(macCatalyst)
    private func finish(host: String) async {
        let operation = epoch
        registeredToken = nil; registeredAt = .distantPast
        tokenTask?.cancel(); tokenTask = nil
        activity = nil; lastState = nil; lastUpdate = .distantPast
        for current in Activity<WorkActivityAttributes>.activities
            where current.attributes.host == host && (current.activityState == .active || current.activityState == .stale) {
            let content = ActivityContent(state: current.content.state.finished, staleDate: nil)
            await current.end(content, dismissalPolicy: .default)
            guard epoch == operation else { return }
        }
    }

    private func register(_ token: Data, activity: Activity<WorkActivityAttributes>, connection: Connection,
                          identity: ConnectionContext, epoch operation: UUID) async {
        let lease = ConnectionCallbackLease(context: identity, epoch: operation)
        guard lease.accepts(current: connection.context, epoch: epoch), !connection.switching, !Task.isCancelled,
              activity.attributes.host == identity.host else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard registeredToken != hex || Date().timeIntervalSince(registeredAt) > 60 else { return }
        do {
            _ = try await connection.call(["operation": "activity-register", "activityId": activity.id, "pushToken": hex], context: identity)
            guard lease.accepts(current: connection.context, epoch: epoch), !Task.isCancelled else { return }
            registeredToken = hex; registeredAt = Date()
        } catch {
            guard lease.accepts(current: connection.context, epoch: epoch), !Task.isCancelled else { return }
            connection.activityError = "Background activity updates are unavailable: \(error.localizedDescription)"
        }
    }
    #endif
    func end() async {
        quiesce()
        #if !targetEnvironment(macCatalyst)
        let retiring = Activity<WorkActivityAttributes>.activities
        for activity in retiring { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
