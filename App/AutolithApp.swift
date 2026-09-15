import SwiftUI
import AppIntents
import UIKit

@main struct AutolithApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    init() { AutolithShortcuts.updateAppShortcutParameters() }
    @State private var connection = Connection(restoreCache: true)
    var body: some Scene { WindowGroup { SessionBrowser(connection: connection) } }
}

struct SessionBrowser: View {
    @Bindable var connection: Connection
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    @State private var creating = false
    @State private var search = ""
    @AppStorage("groupSessionsByProject") private var groupByProject = true
    @State private var pendingDeletion: Session?
    @State private var confirmingDeletion = false
    var body: some View {
        SessionNavigation(selection: $connection.selection) { usesListSelection in
            SessionSidebar(connection: connection, usesListSelection: usesListSelection, search: search, groupByProject: groupByProject) { session in
                pendingDeletion = session
                confirmingDeletion = true
            }
            .searchable(text: $search, prompt: "Find a session")
            .navigationTitle("Autolith")
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView(online: connection.online, refreshing: connection.refreshing, error: $connection.error)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }.keyboardShortcut(",", modifiers: .command)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("session-settings")
                }
                ToolbarItem(placement: .primaryAction) { Button("New session", systemImage: "square.and.pencil") { creating = true }.keyboardShortcut("n", modifiers: .command).disabled(!connection.online) }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Organize sessions", systemImage: "line.3.horizontal.decrease") {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await connection.refresh() } }
                            .keyboardShortcut("r", modifiers: .command).disabled(connection.refreshing)
                        Picker("Display", selection: $groupByProject) {
                            Text("By project folder").tag(true)
                            Text("All sessions").tag(false)
                        }
                    }
                }
            }
        } detail: { selectedID in
            if let id = selectedID, let session = connection.sessions.first(where: { $0.id == id }) {
                ConversationView(connection: connection, session: session).id(id)
            } else {
                ContentUnavailableView("Work from anywhere", systemImage: "ipad.and.arrow.forward", description: Text("Select a session or start a new one.\nYour work runs on your computer."))
            }
        }
        .modifier(SiriNavigation(connection: connection, search: $search))
        .onOpenURL { url in
            guard url.scheme == "autolith" else { return }
            if url.host == "session", let id = url.pathComponents.last { connection.selection = id }
        }
        .sheet(isPresented: $settings) { SettingsView(connection: connection) }
        .sheet(isPresented: $creating) { NewSessionView(connection: connection) }
        .confirmationDialog("Delete conversation permanently?", isPresented: $confirmingDeletion, titleVisibility: .visible, presenting: pendingDeletion) { session in
            Button("Delete conversation", role: .destructive) { Task { await connection.delete(session) } }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("This removes ‘\(session.title)’, its saved history, and private attachments from your computer. It cannot be undone. Workspace files are kept.")
        }
        .onChange(of: phase, initial: true) { _, value in connection.setForeground(value != .background) }
        .onDisappear { connection.setForeground(false) }
        .task(id: phase == .background) {
            guard phase != .background else { return }
            while !Task.isCancelled {
                await connection.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task(id: connection.selection) { await connection.refresh() }
    }
}

struct ConversationView: View {
    @Bindable var connection: Connection
    let session: Session
    @State private var stopping = false
    @State private var history = ConversationHistoryWindow()
    @State private var latestRequest = 0
    private var eventIDs: [String] { connection.eventIdentifiers(for: session.id) }
    private var historyStart: Int { history.startIndex(in: eventIDs) }
    private var historyRange: Range<Int> { history.range(in: eventIDs) }
    var body: some View {
        VStack(spacing: 0) {
            if !session.isRunning {
                HStack {
                    Label("Session stopped. Your conversation is saved.", systemImage: "stop.circle")
                    Spacer()
                    Button("Resume session") { Task { await connection.resume(session) } }
                        .disabled(connection.isBusy(session.id) || !connection.online)
                }.font(.callout).padding()
            }
            ConversationScrollView(content: {
                if historyStart > 0 {
                    Button("Show earlier messages (\(historyStart))") { history.showEarlier(eventIDs) }
                        .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                if connection.loadingTranscript == session.id || (connection.events[session.id] == nil && connection.refreshing) {
                    ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding()
                } else if (connection.events[session.id] ?? []).isEmpty {
                    ContentUnavailableView("Ready when you are", systemImage: "text.bubble", description: Text("Send a message to begin. Completed messages and tool activity appear here."))
                }
                ForEach((connection.events[session.id] ?? []).dropFirst(historyStart).prefix(history.pageSize)) { event in
                    ConversationEventView(event: event, presentation: connection.presentation(eventID: event.id, sessionID: session.id),
                                          retryMessage: { outboxAction("message-retry", event: event) },
                                          abandonMessage: { outboxAction("message-abandon", event: event) },
                                          controlsEnabled: connection.online && !connection.isBusy(session.id))
                        .modifier(AutolithMessageAnnotation(connection: connection, host: connection.host, sessionID: session.id, event: event))
                        .id(event.id)
                }
                if historyRange.upperBound < eventIDs.count {
                    HStack {
                        Button("Show newer messages") {
                            history.showNewer(eventIDs)
                            if history.followsLatest { latestRequest += 1 }
                        }
                        Spacer()
                        Button("Latest messages") { history.showLatest(eventIDs); latestRequest += 1 }
                    }.font(.callout)
                }
            }, followingChanged: { history.setFollowing($0, ids: eventIDs) }, latestRequest: latestRequest)
            SessionComposer(connection: connection, session: session)
        }
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: eventIDs, initial: true) { _, ids in history.update(ids) }
        .task(id: "\(session.id):\(session.isRunning)") { await connection.loadCatalog(for: session) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(session.title).font(.headline).lineLimit(1)
                    ConversationActivityBar(session: session, events: connection.visibleLiveEvents(for: session.id),
                                            online: connection.online, connected: connection.streamConnected)
                }.frame(maxWidth: 240)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Pause", systemImage: "pause") {
                        Task { _ = await connection.control("pause", id: session.id) }
                    }.disabled(connection.isBusy(session.id) || !connection.online || !session.isRunning)
                    if session.jobs > 0 { Text("\(session.jobs) jobs") }
                    if session.queued > 0 { Text("\(session.queued) queued") }
                    Text(session.workspace)
                    Text("Session \(session.id)")
                    ShareLink(item: connection.shareText(for: session.id)) {
                        Label("Share conversation", systemImage: "square.and.arrow.up")
                    }
                    Menu("Permissions: \(session.permissions)") {
                        Button("Ask on Computer") { setPermissions("ask") }
                        Button("Automatic approval") { setPermissions("auto") }
                    }.disabled(!session.isRunning)
                    Button("Stop session", systemImage: "stop.circle", role: .destructive) { stopping = true }.disabled(!session.isRunning)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Stop this session?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop session", role: .destructive) { Task { _ = await connection.control("kill", id: session.id) } }
        } message: { Text("Autolith will shut down this session on your computer. Its saved conversation remains on the computer.") }
    }
    private func outboxAction(_ operation: String, event: Event) {
        let captured = connection.context
        Task { await connection.updateOutbox(operation, event: event, sessionID: session.id, context: captured) }
    }
    private func setPermissions(_ mode: String) {
        Task { _ = await connection.control("tell", id: session.id, message: "/permissions \(mode)") }
    }
}

struct SettingsView: View {
    @Bindable var connection: Connection
    @Environment(\.dismiss) private var dismiss

    private var connectionStatus: String {
        connection.online ? "Connected" : connection.refreshing ? "Checking connection" : "Disconnected"
    }

    private var connectionStatusColor: Color {
        connection.online ? .green : .secondary
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer connection") {
                    NavigationLink {
                        ConnectionEditor(connection: connection)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(connectionStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(connectionStatus)
                                if connection.refreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.65).frame(width: 12, height: 12)
                                }
                            }
                            .font(.subheadline)

                            Text(connection.host.isEmpty ? "Not configured" : connection.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Siri") {
                    NavigationLink {
                        SiriSettingsPage(connection: connection)
                    } label: {
                        Label("Siri and Shortcuts", systemImage: "waveform")
                    }
                }

                #if !targetEnvironment(macCatalyst)
                Section("Live Activities") {
                    NavigationLink {
                        LiveActivitySettingsPage(connection: connection)
                    } label: {
                        Label("Running work on the Lock Screen", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                }
                #endif

                Section("Help") {
                    NavigationLink {
                        ConnectionSetupHelp()
                    } label: {
                        Label("Connect your computer", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !connection.refreshing else { return }
                await connection.refresh()
            }
        }
        .presentationDetents([.large])
    }
}

private struct ConnectionEditor: View {
    @Bindable var connection: Connection
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var token: String
    @State private var error: String?
    @State private var applying = false

    init(connection: Connection) {
        self.connection = connection
        _host = State(initialValue: connection.host)
        _token = State(initialValue: connection.token)
    }

    var body: some View {
        Form {
            Section("Computer connection") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Computer address").font(.caption).foregroundStyle(.secondary)
                    TextField("https://computer.your-tailnet.ts.net", text: $host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Computer address")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Companion token").font(.caption).foregroundStyle(.secondary)
                    SecureField("Token from your computer", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Companion token")
                }
            }

            Section {
                Text("Use your computer’s HTTPS address. The companion token is saved in this device’s Keychain.")
            }

            if applying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65).frame(width: 12, height: 12)
                    Text("Checking connection…")
                }
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }

            Section("Connection status") {
                LabeledContent("Computer", value: connection.online ? "Connected" : "Disconnected")
                if connection.selection != nil {
                    LabeledContent("Chat updates", value: connection.online ? (connection.streamConnected ? "Live" : "Periodic") : "Disconnected")
                    Text(connection.streamStatus).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !connection.streamConnected && connection.online {
                        Text("Chat updates are checked periodically while the live connection retries.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Computer connection")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(applying)
        .interactiveDismissDisabled(applying)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") { apply() }
                    .disabled(applying || connection.refreshing)
            }
        }
    }

    private func apply() {
        guard !applying else { return }
        applying = true
        error = nil
        let candidateHost = host, candidateToken = token
        Task {
            defer { applying = false }
            do {
                try await connection.apply(host: candidateHost, token: candidateToken)
                host = connection.host
                connection.error = nil
                await connection.refresh()
                if connection.online { dismiss() }
                else { error = connection.error ?? "Could not connect to the computer." }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct SiriSettingsPage: View {
    @Bindable var connection: Connection

    var body: some View {
        Form {
            SiriSettings(connection: connection)
        }
        .navigationTitle("Siri")
    }
}

#if !targetEnvironment(macCatalyst)
private struct LiveActivitySettingsPage: View {
    @Bindable var connection: Connection
    @AppStorage("liveActivitiesEnabled") private var liveActivities = false

    var body: some View {
        Form {
            Section("Live Activities") {
                Toggle("Show running work", isOn: $liveActivities)
                    .onChange(of: liveActivities) { _, enabled in
                        Task {
                            if enabled {
                                await connection.refresh()
                            } else {
                                await connection.activities.end()
                            }
                        }
                    }
                Text("One activity summarizes your running sessions and tasks. Without Apple push setup on the computer, updates pause when this app is suspended and the activity shows Update pending.")

                if liveActivities {
                    Text(connection.activityStatus)
                        .font(.callout)
                    Button("Show on Lock Screen") {
                        Task {
                            connection.activityError = nil
                            await connection.activities.end()
                            await connection.refresh()
                        }
                    }
                    .disabled(connection.refreshing || !connection.online)
                }

                if let message = connection.activityError {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Live Activities")
    }
}
#endif

private struct ConnectionSetupHelp: View {
    var body: some View {
        Form {
            Section("On your computer") {
                Text("Run the Autolith companion and expose port 4318 with Tailscale Serve.")
            }
            Section("On this device") {
                Text("Connect both devices to Tailscale. Then enter the computer’s HTTPS address and companion token in Computer connection.")
            }
            Section {
                Text("The token is stored in this device’s Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connect your computer")
    }
}

struct NewSessionView: View {
    @Bindable var connection: Connection
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var permissions = "ask"
    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace on your computer") {
                    NavigationLink { WorkspacePicker(connection: connection, selection: $workspace) } label: {
                        Label(workspace.isEmpty ? "Choose folder…" : workspace, systemImage: "folder")
                    }
                    DisclosureGroup("Enter path manually") {
                        TextField("/Users/you/Developer/project", text: $workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section("Command permissions") {
                    Picker("Approval", selection: $permissions) {
                        Text("Ask on Computer").tag("ask")
                        Text("Automatic").tag("auto")
                    }
                    Text(permissions == "ask" ? "Protected commands require a controlling terminal on the computer. Use Automatic for unattended work from your iPad." : "Autolith’s permission classifier decides which commands may run with your computer’s user privileges.")
                }
                if connection.busy { ProgressView("Starting session on your computer…") }
            }.navigationTitle("New session").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { if await connection.create(workspace: workspace, permissions: permissions) { dismiss() } } }.disabled(!workspace.hasPrefix("/") || connection.busy) }
                }
        }.presentationDetents([.medium])
    }
}
