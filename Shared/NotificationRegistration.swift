import Foundation

/// Launch-scoped APNs state. Only a current UIApplication callback supplies a token.
struct NotificationRegistration {
    struct Request: Equatable {
        let host: String
        let token: String
        fileprivate let generation: Int
    }

    private struct Registration {
        let token: String
        let date: Date
    }

    private static let retryDelays: [TimeInterval] = [2, 8, 30, 120]
    private var deviceAttempts = 0
    private var deviceRequestPending = false
    private var retryAt: Date?
    private(set) var token: String?
    private var generation = 0
    private var pending: [String: Request] = [:]
    private var registrations: [String: Registration] = [:]

    mutating func requestDeviceToken(enabled: Bool, now: Date) -> Bool {
        guard enabled, token == nil, !deviceRequestPending,
              deviceAttempts <= Self.retryDelays.count,
              retryAt.map({ now >= $0 }) ?? true else { return false }
        deviceAttempts += 1
        deviceRequestPending = true
        retryAt = nil
        return true
    }

    /// Four retries after the first attempt. Repeated activation cannot reset the limit.
    mutating func deviceRegistrationFailed(now: Date) -> TimeInterval? {
        guard deviceRequestPending else { return nil }
        deviceRequestPending = false
        guard deviceAttempts <= Self.retryDelays.count else { return nil }
        let delay = Self.retryDelays[deviceAttempts - 1]
        retryAt = now.addingTimeInterval(delay)
        return delay
    }

    mutating func receivedDeviceToken(_ value: String) {
        guard !value.isEmpty else { return }
        deviceRequestPending = false
        retryAt = nil
        guard token != value else { return }
        token = value
        generation += 1
        pending.removeAll()
        registrations.removeAll()
    }

    func usesRemoteNotifications(host: String, now: Date) -> Bool {
        guard let token, let registration = registrations[host] else { return false }
        return registration.token == token && now.timeIntervalSince(registration.date) < 3600
    }

    mutating func beginRemoteRegistration(host: String, now: Date) -> Request? {
        guard !host.isEmpty, let token, pending[host] == nil,
              !usesRemoteNotifications(host: host, now: now) else { return nil }
        // An expired or rejected registration must not suppress local completion alerts.
        registrations.removeValue(forKey: host)
        let request = Request(host: host, token: token, generation: generation)
        pending[host] = request
        return request
    }

    func isCurrent(_ request: Request) -> Bool {
        pending[request.host] == request && request.generation == generation && request.token == token
    }

    @discardableResult
    mutating func finishRemoteRegistration(_ request: Request, accepted: Bool, now: Date) -> Bool {
        guard isCurrent(request) else { return false }
        pending.removeValue(forKey: request.host)
        if accepted { registrations[request.host] = Registration(token: request.token, date: now) }
        return accepted
    }
}
