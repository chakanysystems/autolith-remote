import SwiftUI
import Observation
import Security

extension Session {
    var color: Color {
        switch state {
        case "idle": .green
        case "active", "working": .blue
        case "failed": .red
        case "paused", "cancelling": .orange
        default: .secondary
        }
    }
}
struct ModelOption: Codable, Identifiable, Sendable { let id: String; let provider: String; let description: String }
struct CompletionOption: Codable, Identifiable, Sendable { let name: String; let hint: String; let description: String; var id: String { name } }
struct Reply: Codable, Sendable {
    var directory: String?; var directories: [String]?
    var sessions: [Session]?; var events: [Event]?; var id: String?; var error: String?
    var models: [ModelOption]?; var completions: [CompletionOption]?; var pushEnabled: Bool?; var replaceEvents: Bool?
    var ok: Bool?
    var revision: String?; var baseRevision: String?; var eventOrder: [String]?; var notModified: Bool?
    var readIDs: [String]?
    var state: String?; var requestID: String?
}

@MainActor @Observable final class Connection {
    var sessions: [Session] = []
    var events: [String: [Event]] = [:]
    var drafts: [String: String] = [:]
    var selection: String? { didSet {
        if oldValue != selection {
            restartStream()
            if let id = selection { Task { await self.loadTranscript(id) } }
        }
    } }
    private(set) var streamStatus = "Live activity disconnected"
    private(set) var streamConnected = false
    private(set) var liveEvents: [Event] = []
    private var foreground = false
    private var streamTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var activityPublishTask: Task<Void, Never>?
    private var transcriptDirty = false
    private var transcriptFullRefresh = false
    private var transcriptRefreshedAt: [String: Date] = [:]
    private var stream: SessionStream?
    private var streamGeneration = UUID()
    var online = false
    var error: String?
    private var creatingSession = false
    private var commands = SessionCommandState()
    var busy: Bool { creatingSession || selection.map { commands.contains($0) } == true }
    func isBusy(_ id: String) -> Bool { creatingSession || commands.contains(id) }
    private(set) var host = UserDefaults.standard.string(forKey: "host") ?? ""
    private(set) var token = ""
    private(set) var refreshing = false
    private(set) var loadingTranscript: String?
    private(set) var loadingCatalog = false
    var models: [ModelOption] = []
    var completions: [CompletionOption] = []
    var catalogError: String?
    var activityError: String?
    var activityStatus = "Waiting for session status." {
        didSet { UserDefaults.standard.set(activityStatus, forKey: "liveActivityStatus") }
    }
    let activities = LiveActivityController.shared
    private var catalogSession: String?
    private var catalogRequest = UUID()
    private var generation = 0
    var context: ConnectionContext { ConnectionContext(host: host, token: token, generation: generation) }
    func isCurrent(_ captured: ConnectionContext) -> Bool { context == captured }
    private(set) var switching = false
    @ObservationIgnored private var cached: [String: CachedTranscript] = [:]
    private var fetches: [String: Task<Void, Never>] = [:]
    private var sessionEpochs: [String: UUID] = [:]
    private var persistTask: Task<Void, Never>?
    private var persistenceRevision = 0
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDirty = false
    private var readQueue: [String: Set<String>] = [:]
    private var readTask: Task<Void, Never>?
    private func keychainFailure(_ status: OSStatus) -> Error {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown security error"
        let hint = status == errSecMissingEntitlement
            ? " Install a build signed with the app’s Keychain access entitlement." : ""
        return failure("Could not save the token in Keychain: \(detail) (\(status)).\(hint)")
    }
    init(restoreCache: Bool = false) {
        CompanionEndpoint.migratePreferences()
        host = (try? CompanionEndpoint.canonical(host)) ?? host
        MessageNotifications.shared.activate()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Autolith", kSecAttrAccount as String: "companion", kSecReturnData as String: true]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data { token = String(decoding: data, as: UTF8.self) }
        // Siri and notification queries fetch authoritative state directly. Only
        // the navigation connection restores snapshots for immediate presentation.
        guard restoreCache else { return }
        let key = TranscriptCache.key(host: host, token: token)
        Task {
            guard generation == 0 else { return }
            try? await TranscriptCache.shared.activate(key: key, initializing: true)
            let snapshot = await TranscriptCache.shared.load(key: key)
            guard generation == 0 else { return }
            if sessions.isEmpty, !online { sessions = snapshot.sessions }
            let valid = Set(sessions.map(\.id))
            for (id, transcript) in snapshot.transcripts where valid.contains(id) && cached[id] == nil && fetches[id] == nil {
                cached[id] = transcript
                events[id] = transcript.events
            }
            for session in sessions where sessionEpochs[session.id] == nil { sessionEpochs[session.id] = UUID() }
            trimCache()
        }
    }
    func updateOutbox(_ operation: String, event: Event, sessionID: String, context captured: ConnectionContext) async {
        let allowed = operation == "message-retry" ? event.canRetryDelivery : operation == "message-abandon" && event.canAbandonDelivery
        guard isCurrent(captured), !switching, !creatingSession, allowed,
              let command = commands.begin(sessionID) else { return }
        defer { commands.finish(sessionID, token: command) }
        do {
            let reply = try await call(["operation": operation, "id": sessionID, "eventID": event.id], context: captured)
            guard isCurrent(captured), !Task.isCancelled else { return }
            if operation == "message-abandon" { try SiriMessageReceipt.confirmed(reply.ok) }
            else {
                _ = try SiriMessageReceipt.accepted(events: reply.events ?? [], requestID: event.outboxRequestID ?? "", text: event.text)
            }
            if let pending = fetches[sessionID] { await pending.value }
            guard isCurrent(captured), !Task.isCancelled else { return }
            await loadTranscript(sessionID)
        } catch {
            guard isCurrent(captured), !Task.isCancelled else { return }
            self.error = error.localizedDescription
            // Read the authoritative result; never replay an uncertain mutation.
            if let pending = fetches[sessionID] { await pending.value }
            guard isCurrent(captured), !Task.isCancelled else { return }
            await loadTranscript(sessionID)
        }
    }

    /// Probe without mutating the active connection or its drafts.
    func apply(host: String, token: String) async throws {
        guard !switching else { throw CancellationError() }
        switching = true
        defer { switching = false; restartStream() }
        let previous = context
        let candidate = ConnectionContext(host: try CompanionEndpoint.canonical(host), token: token, generation: generation)
        try await ConnectionCandidateProbe.validate(previous: previous, candidate: candidate, current: { self.context }) { candidate in
            let reply = try await self.call(["operation": "list"], context: candidate)
            guard reply.sessions != nil else { throw self.failure("The computer did not return a session list.") }
        }
        guard previous.host != candidate.host || previous.token != candidate.token else { return }
        // Invalidate in-flight UI work before waiting for old-identity revocation.
        generation += 1
        refreshing = false; commands.clear(); creatingSession = false; loadingTranscript = nil; loadingCatalog = false
        catalogRequest = UUID()
        persistTask?.cancel(); persistTask = nil; maintenanceTask?.cancel(); maintenanceTask = nil
        readTask?.cancel(); readTask = nil
        fetches.values.forEach { $0.cancel() }; fetches = [:]
        stopStream()
        let retiring = context
        activities.quiesce()
        await MessageNotifications.shared.revoke(connection: self)
        guard isCurrent(retiring), !Task.isCancelled else { throw CancellationError() }
        await activities.end()
        guard isCurrent(retiring), !Task.isCancelled else { throw CancellationError() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Autolith", kSecAttrAccount as String: "companion"]
        let values: [String: Any] = [kSecValueData as String: Data(candidate.token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainFailure(addStatus) }
        } else if status != errSecSuccess { throw keychainFailure(status) }
        self.host = candidate.host; self.token = candidate.token
        UserDefaults.standard.set(candidate.host, forKey: "host")
        generation += 1
        persistTask?.cancel(); persistTask = nil; maintenanceTask?.cancel(); maintenanceTask = nil
        readTask?.cancel(); readTask = nil; readQueue = [:]
        fetches.values.forEach { $0.cancel() }; fetches = [:]; cached = [:]; sessionEpochs = [:]
        stopStream()
        events = [:]; sessions = []; drafts = [:]; online = false
        refreshing = false; loadingTranscript = nil; commands.clear(); creatingSession = false; loadingCatalog = false
        models = []; completions = []; catalogSession = nil; catalogRequest = UUID(); selection = nil
        let saved = context
        try await TranscriptCache.shared.activate(key: TranscriptCache.key(host: saved.host, token: saved.token))
        guard isCurrent(saved) else { throw CancellationError() }
        if #available(iOS 27.0, macOS 27.0, *), previous.host != saved.host {
            await AutolithConversationContext.retireOtherHosts(saved.host)
        }
    }
    func failure(_ message: String) -> NSError { NSError(domain: "Autolith", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func endpoint() throws -> URL {
        let address = try CompanionEndpoint.canonical(host)
        guard let url = URL(string: address) else { throw failure("Enter the computer's HTTPS address.") }
        guard !token.isEmpty else { throw failure("Enter your companion token.") }
        return url.appendingPathComponent("rpc")
    }
    func call(_ payload: [String: Any], context captured: ConnectionContext? = nil) async throws -> Reply {
        let identity = captured ?? context
        var request = URLRequest(url: try identity.endpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await BoundedHTTP.data(for: request, limit: BoundedHTTP.limit(operation: payload["operation"] as? String ?? ""))
        guard response.statusCode == 200 else { throw failure("The computer companion rejected the request (\(response.statusCode)).") }
        let reply = try await BackgroundWork.run {
            let interval = PerformanceInterval(.decoding)
            defer { interval.finish(bytes: data.count) }
            return try JSONDecoder().decode(Reply.self, from: data)
        }
        if let message = reply.error { throw failure(message) }
        return reply
    }
    func refresh() async {
        guard !switching, !refreshing, !host.isEmpty, !token.isEmpty else { return }
        refreshing = true
        let generation = self.generation
        defer { if generation == self.generation { refreshing = false; loadingTranscript = nil } }
        var listSucceeded = false
        do {
            let reply = try await call(["operation": "list"])
            guard generation == self.generation else { return }
            listSucceeded = true
            if let updated = reply.sessions, sessions != updated { sessions = updated; persistCache() }
            if !online { online = true }
            let valid = Set(sessions.map(\.id))
            var removedCachedSession = false
            for id in Set(cached.keys).union(sessionEpochs.keys) where !valid.contains(id) {
                removedCachedSession = true
                cached[id] = nil; events[id] = nil; sessionEpochs[id] = nil
                fetches[id]?.cancel(); fetches[id] = nil
                readQueue[id] = nil
            }
            for id in valid where sessionEpochs[id] == nil { sessionEpochs[id] = UUID() }
            if let selection, !valid.contains(selection) { self.selection = nil }
            if removedCachedSession {
                await persistCacheNow()
                guard generation == self.generation else { return }
            }
            let tracked = Set([selection, SiriConversationMemory.lastSentIdentifier(host: host)].compactMap { $0 })
            for id in tracked where sessions.contains(where: { $0.id == id }) {
                if id == selection && streamConnected {
                    if events[id] == nil || Date().timeIntervalSince(transcriptRefreshedAt[id] ?? .distantPast) >= 30 {
                        scheduleTranscript(id: id, full: true)
                    }
                    continue
                }
                await loadTranscript(id)
            }
            // Load the visible transcript before notification and Siri maintenance.
            guard generation == self.generation else { return }
            await activities.update(sessions, connection: self)
            guard generation == self.generation else { return }
            flushReadReceipts()
            scheduleMaintenance()
        } catch {
            guard generation == self.generation else { return }
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            if !listSucceeded && !streamConnected { online = false }
            self.error = error.localizedDescription
        }
    }

    func loadTranscript(_ id: String) async {
        if let pending = fetches[id] { await pending.value; return }
        guard sessions.contains(where: { $0.id == id }), !token.isEmpty else { return }
        cached[id]?.accessed = Date()
        if sessionEpochs[id] == nil { sessionEpochs[id] = UUID() }
        let epoch = sessionEpochs[id], generation = self.generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation, self.sessionEpochs[id] == epoch { self.fetches[id] = nil; if self.loadingTranscript == id { self.loadingTranscript = nil } } }
            if self.events[id] == nil { self.loadingTranscript = id }
            do {
                let snapshot = self.cached[id] ?? CachedTranscript(revision: "", events: [], accessed: Date())
                var request: [String: Any] = ["operation": "transcript-sync", "id": id]
                if !snapshot.revision.isEmpty { request["revision"] = snapshot.revision }
                var reply = try await self.call(request)
                guard !Task.isCancelled, self.generation == generation, self.sessionEpochs[id] == epoch else { return }
                guard reply.revision != nil else { throw self.failure("Update the computer companion to enable transcript synchronization.") }
                var prepared: (snapshot: CachedTranscript, changed: Bool)
                do {
                    prepared = try await Self.prepareTranscript(snapshot, reply: reply)
                } catch CachedTranscript.CacheError.invalidRevision {
                    guard !Task.isCancelled, self.generation == generation, self.sessionEpochs[id] == epoch else { return }
                    reply = try await self.call(["operation": "transcript-sync", "id": id])
                    guard !Task.isCancelled, self.generation == generation, self.sessionEpochs[id] == epoch else { return }
                    guard reply.revision != nil, reply.eventOrder == nil, reply.notModified != true else { throw CachedTranscript.CacheError.invalidRevision }
                    prepared = try await Self.prepareTranscript(snapshot, reply: reply)
                }
                guard !Task.isCancelled, self.generation == generation, self.sessionEpochs[id] == epoch else { return }
                let publication = PerformanceInterval(.publication)
                self.cached[id] = prepared.snapshot
                if prepared.changed || self.events[id] == nil { self.events[id] = prepared.snapshot.events; self.scheduleMaintenance() }
                publication.finish()
                self.transcriptRefreshedAt[id] = Date()
                self.trimCache()
                if prepared.changed || snapshot.revision != prepared.snapshot.revision { self.persistCache() }
            } catch {
                if !Task.isCancelled, self.generation == generation { self.error = error.localizedDescription }
            }
        }
        fetches[id] = task
        await task.value
    }

    nonisolated private static func prepareTranscript(_ original: CachedTranscript, reply: Reply) async throws -> (snapshot: CachedTranscript, changed: Bool) {
        try await BackgroundWork.run {
            let interval = PerformanceInterval(.reconciliation)
            defer { interval.finish() }
            guard let revision = reply.revision else { throw CachedTranscript.CacheError.invalidRevision }
            var snapshot = original
            try snapshot.reconcile(revision: revision, base: reply.baseRevision, order: reply.eventOrder,
                                   changes: reply.events, unchanged: reply.notModified == true)
            return (snapshot, snapshot.events != original.events)
        }
    }

    private func trimCache() {
        var bytes = cached.values.reduce(0) { $0 + ($1.byteCost ?? 0) }
        for id in cached.keys.sorted(by: { cached[$0]!.accessed < cached[$1]!.accessed }) {
            guard cached.count > 12 || bytes > 32 * 1024 * 1024 else { break }
            guard id != selection else { continue }
            if let old = cached.removeValue(forKey: id) { bytes -= old.byteCost ?? 0 }
            events[id] = nil
        }
    }

    func queueRead(_ event: Event, sessionID: String) {
        guard !event.hasBeenRead, !event.id.hasPrefix("outbox-") else { return }
        readQueue[sessionID, default: []].insert(event.id)
        flushReadReceipts()
    }

    func presentation(eventID: String, sessionID: String) -> EventPresentation? {
        cached[sessionID]?.presentations[eventID]
    }

    func eventIdentifiers(for sessionID: String) -> [String] {
        cached[sessionID]?.eventIDs ?? []
    }

    func shareText(for sessionID: String) -> String {
        cached[sessionID]?.shareText ?? ""
    }

    private func flushReadReceipts() {
        guard readTask == nil, !readQueue.isEmpty else { return }
        let generation = self.generation
        readTask = Task {
            defer { if self.generation == generation { readTask = nil } }
            do {
                try await Task.sleep(for: .milliseconds(300))
                while let id = readQueue.keys.first, self.generation == generation {
                    guard sessions.contains(where: { $0.id == id }) else { readQueue[id] = nil; continue }
                    let batch = Array((readQueue[id] ?? []).prefix(100))
                    let reply = try await call(["operation": "messages-read", "id": id, "eventIDs": batch])
                    guard !Task.isCancelled, self.generation == generation else { return }
                    guard reply.ok == true, let confirmed = reply.readIDs else { throw failure("Read receipts were not confirmed.") }
                    readQueue[id]?.subtract(batch)
                    if readQueue[id]?.isEmpty == true { readQueue[id] = nil }
                    // Finish any pre-acknowledgment fetch before reconciling read state.
                    if let pending = fetches[id] { await pending.value }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if var snapshot = cached[id], snapshot.confirmRead(Set(confirmed).intersection(batch)) {
                        cached[id] = snapshot
                        events[id] = snapshot.events
                        persistCache()
                        scheduleMaintenance()
                    }
                }
            } catch { if !Task.isCancelled { UserDefaults.standard.set(error.localizedDescription, forKey: "readReceiptError") } }
        }
    }

    private func persistCache() {
        persistenceRevision += 1
        guard persistTask == nil else { return }
        let key = TranscriptCache.key(host: host, token: token)
        let generation = self.generation
        persistTask = Task {
            defer { if self.generation == generation { persistTask = nil } }
            do {
                var saved: Int
                repeat {
                    try await Task.sleep(for: .milliseconds(500))
                    saved = persistenceRevision
                    try await TranscriptCache.shared.save(.init(sessions: sessions, transcripts: cached), key: key)
                } while generation == self.generation && saved != persistenceRevision
            } catch { if !Task.isCancelled { UserDefaults.standard.set(error.localizedDescription, forKey: "transcriptCacheError") } }
        }
    }

    private func persistCacheNow() async {
        let generation = self.generation
        let key = TranscriptCache.key(host: host, token: token)
        do { try await TranscriptCache.shared.save(.init(sessions: sessions, transcripts: cached), key: key) }
        catch { if self.generation == generation { UserDefaults.standard.set(error.localizedDescription, forKey: "transcriptCacheError") } }
    }

    private func scheduleMaintenance() {
        maintenanceDirty = true
        guard maintenanceTask == nil else { return }
        let generation = self.generation
        maintenanceTask = Task {
            defer { if self.generation == generation { maintenanceTask = nil } }
            repeat {
                maintenanceDirty = false
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !Task.isCancelled, self.generation == generation else { return }
                if #available(iOS 27.0, macOS 27.0, *) {
                    await AutolithConversationContext.retireUnavailable(connection: self)
                    await AutolithConversationContext.synchronize(connection: self)
                }
                await MessageNotifications.shared.refresh(connection: self)
            } while maintenanceDirty && !Task.isCancelled
        }
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        restartStream()
    }

    private func stopStream() {
        streamGeneration = UUID()
        streamTask?.cancel(); streamTask = nil
        transcriptTask?.cancel(); transcriptTask = nil
        activityPublishTask?.cancel(); activityPublishTask = nil
        transcriptDirty = false
        stream = nil; liveEvents = []; streamConnected = false
        streamStatus = "Live activity disconnected"
    }

    private func restartStream() {
        stopStream()
        guard foreground, let id = selection else { return }
        do {
            var components = URLComponents(url: try endpoint(), resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.path = "/events"
            guard let url = components.url else { return }
            let token = self.token
            let request = streamGeneration
            stream = SessionStream(sessionID: id)
            streamTask = Task { [weak self] in
                await SessionEventStream.run(endpoint: url, token: token, sessionID: id, cursor: { [weak self] in
                    self?.stream?.cursor
                }, receive: { [weak self] data in
                    guard let self, self.streamGeneration == request else { throw CancellationError() }
                    let previousEpoch = self.stream?.cursor?.epoch
                    let original = self.stream ?? SessionStream(sessionID: id)
                    do {
                        let prepared = try await BackgroundWork.run {
                            var stream = original
                            let changed = try stream.receive(data)
                            return (stream, changed)
                        }
                        guard self.streamGeneration == request, !Task.isCancelled else { throw CancellationError() }
                        self.stream = prepared.0
                        guard prepared.1 else { return }
                    } catch {
                        if self.streamGeneration == request {
                            self.stream = SessionStream(sessionID: id)
                            self.liveEvents = []
                        }
                        throw error
                    }
                    if self.stream?.activityChanged == true { self.scheduleActivityPublication() }
                    if self.stream?.statusChanged == true, let status = self.stream?.status {
                        if let index = self.sessions.firstIndex(where: { $0.id == id }) {
                            let updated = self.sessions[index].mergingStreamStatus(status)
                            if self.sessions[index] != updated { self.sessions[index] = updated }
                        } else { self.sessions.append(status) }
                    }
                    if self.stream?.transcriptChanged == true {
                        self.scheduleTranscript(id: id, full: previousEpoch != self.stream?.cursor?.epoch)
                    }
                }, state: { [weak self] state in
                    guard let self, self.streamGeneration == request else { return }
                    if self.streamStatus != state { self.streamStatus = state }
                    let connected = state == "Live activity connected"
                    if self.streamConnected != connected { self.streamConnected = connected }
                    if connected && !self.online { self.online = true }
                })
            }
        } catch { streamStatus = "Live activity disconnected: \(error.localizedDescription)" }
    }

    /// Publish only changed worker rows. Reasoning tokens do not affect the status bar.
    private func scheduleActivityPublication() {
        guard activityPublishTask == nil else { return }
        let request = streamGeneration
        activityPublishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.streamGeneration == request else { return }
            let rows = (self.stream?.activity ?? []).filter { $0.role == "status" }
            if !self.liveEvents.elementsEqual(rows, by: { $0.id == $1.id && $0.tool == $1.tool && $0.text == $1.text }) {
                self.liveEvents = rows
            }
            self.activityPublishTask = nil
        }
    }

    /// Coalesce deltas without postponing the refresh while output continues.
    private func scheduleTranscript(id: String, full: Bool = false) {
        transcriptDirty = true
        transcriptFullRefresh = transcriptFullRefresh || full
        guard transcriptTask == nil else { return }
        let request = streamGeneration
        transcriptTask = Task { [weak self] in
            do {
                repeat {
                    try await Task.sleep(for: .milliseconds(150))
                    guard let self, self.streamGeneration == request else { return }
                    self.transcriptDirty = false
                    self.transcriptFullRefresh = false
                    await self.loadTranscript(id)
                    guard self.streamGeneration == request, !Task.isCancelled else { return }
                } while self?.transcriptDirty == true
                if let self, self.streamGeneration == request { self.transcriptTask = nil }
            } catch {
                guard let self, self.streamGeneration == request else { return }
                self.transcriptTask = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func visibleLiveEvents(for id: String) -> [Event] {
        guard selection == id, sessions.first(where: { $0.id == id })?.isWorking == true else { return [] }
        return liveEvents.filter { cached[id]?.presentations[$0.id] == nil }
    }
    func loadCatalog(for session: Session, force: Bool = false) async {
        guard session.isRunning, force || catalogSession != session.id else { return }
        let request = UUID(); catalogRequest = request
        loadingCatalog = true; catalogError = nil; models = []; completions = []
        defer { if catalogRequest == request { loadingCatalog = false } }
        do {
            let reply = try await call(["operation": "catalog", "id": session.id])
            guard selection == session.id, catalogRequest == request else { return }
            models = reply.models ?? []
            var names = Set<String>()
            completions = (reply.completions ?? []).filter { names.insert($0.name).inserted }
            catalogSession = session.id
        } catch {
            guard catalogRequest == request, selection == session.id, !(error is CancellationError) else { return }
            catalogError = "Could not load this session’s models and completions. Older sessions need to be stopped and resumed after updating the computer backend. \(error.localizedDescription)"
        }
    }
    func selectModel(_ model: ModelOption, session: Session) async -> Bool {
        let escaped = model.id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await control("tell", id: session.id, message: "/model \"\(escaped)\"")
    }
    func selectEffort(_ effort: String, session: Session) async -> Bool {
        guard let current = sessions.first(where: { $0.id == session.id }),
              current.model == session.model, let command = current.commandForEffort(effort) else {
            error = "This effort is not available for the current model."
            return false
        }
        return await control("tell", id: session.id, message: command)
    }
    func control(_ operation: String, id: String, message: String? = nil) async -> Bool {
        guard !switching, !creatingSession, let command = commands.begin(id) else { return false }
        let captured = context
        defer { commands.finish(id, token: command) }
        do {
            var payload: [String: Any] = ["operation": operation, "id": id]
            if let message { payload["message"] = message }
            let reply = try await call(payload, context: captured)
            try SiriMessageReceipt.confirmed(reply.ok)
            guard isCurrent(captured), !Task.isCancelled else { return false }
            reconcileAfterCommand(id: id, context: captured)
            return true
        } catch { if isCurrent(captured) { self.error = error.localizedDescription }; return false }
    }
    func create(workspace: String, permissions: String) async -> Bool {
        guard !switching, !creatingSession else { return false }
        let captured = context
        creatingSession = true
        defer { if isCurrent(captured) { creatingSession = false } }
        do {
            let reply = try await call(["operation": "create", "workspace": workspace, "permissions": permissions], context: captured)
            guard isCurrent(captured), !Task.isCancelled else { return false }
            selection = reply.id
            await refresh()
            return isCurrent(captured) && !Task.isCancelled
        } catch { if isCurrent(captured) { self.error = error.localizedDescription }; return false }
    }
    func resume(_ session: Session) async {
        guard !switching, !creatingSession, let command = commands.begin(session.id) else { return }
        let captured = context
        defer { commands.finish(session.id, token: command) }
        do {
            let reply = try await call(["operation": "resume", "id": session.id,
                                        "workspace": session.workspace, "permissions": "ask"], context: captured)
            guard isCurrent(captured), !Task.isCancelled else { return }
            selection = reply.id
            await refresh()
        } catch { if isCurrent(captured) { self.error = error.localizedDescription } }
    }
    func delete(_ session: Session) async {
        guard !session.isRunning else { return }
        let captured = context
        if await control("delete", id: session.id), isCurrent(captured) {
            cached[session.id] = nil; sessionEpochs[session.id] = nil
            events[session.id] = nil; drafts[session.id] = nil
            fetches[session.id]?.cancel(); fetches[session.id] = nil
            sessions.removeAll { $0.id == session.id }; readQueue[session.id] = nil
            await persistCacheNow()
            guard isCurrent(captured) else { return }
            scheduleMaintenance()
            if selection == session.id { selection = nil }
        }
    }

    /// Acknowledgement releases the composer; authoritative history catches up separately.
    private func reconcileAfterCommand(id: String, context captured: ConnectionContext) {
        Task {
            guard isCurrent(captured) else { return }
            if let pending = fetches[id] { await pending.value }
            guard isCurrent(captured), !Task.isCancelled else { return }
            await loadTranscript(id)
            guard isCurrent(captured), !Task.isCancelled else { return }
            await refresh()
        }
    }
}
