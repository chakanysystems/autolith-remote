import SwiftUI

struct SessionSidebar: View {
    @ObservedObject var connection: Connection
    let usesListSelection: Bool
    let search: String
    let groupByProject: Bool
    let requestDeletion: (Session) -> Void
    @State private var collapsedProjects: Set<String> = []

    @State private var sections: [SessionSection] = []
    private struct Request: Hashable, Sendable {
        let sessions: [Session]
        let search: String
        let grouped: Bool
    }

    var body: some View {
        List(selection: usesListSelection ? $connection.selection : nil) {
            ForEach(sections) { section in
                Section(isExpanded: Binding(
                    get: { !groupByProject || !search.isEmpty || !collapsedProjects.contains(section.id) },
                    set: { expanded in
                        if expanded { collapsedProjects.remove(section.id) }
                        else { collapsedProjects.insert(section.id) }
                    }
                )) {
                    ForEach(section.sessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session, showsWorkspace: !groupByProject).equatable()
                        }
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                            .contextMenu {
                                Button(session.isRunning ? "Stop session before deleting" : "Delete conversation…", systemImage: "trash", role: .destructive) {
                                    requestDeletion(session)
                                }.disabled(session.isRunning || connection.busy || !connection.online)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !session.isRunning {
                                    Button("Delete", systemImage: "trash", role: .destructive) { requestDeletion(session) }
                                        .disabled(connection.busy || !connection.online)
                                }
                            }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if groupByProject { Image(systemName: "folder") }
                            Text(groupByProject && section.id.hasPrefix("/") ? URL(fileURLWithPath: section.id).lastPathComponent : section.id)
                            Spacer()
                            Text("\(section.sessions.count)")
                        }
                        if groupByProject && section.id.hasPrefix("/") {
                            Text(section.id).font(.caption2).textCase(nil)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: Request(sessions: connection.sessions, search: search, grouped: groupByProject)) {
            let request = Request(sessions: connection.sessions, search: search, grouped: groupByProject)
            do {
                let prepared = try await BackgroundWork.run {
                    let filtered = request.sessions.filter {
                        request.search.isEmpty || $0.title.localizedCaseInsensitiveContains(request.search)
                            || $0.workspace.localizedCaseInsensitiveContains(request.search)
                    }
                    return SessionSidebarOrder.sections(filtered, grouped: request.grouped)
                }
                try Task.checkCancellation()
                withTransaction(Transaction(animation: nil)) { sections = prepared }
            } catch { /* Cancellation leaves the newest request in charge of presentation. */ }
        }
        .refreshable { await connection.refresh() }
        .overlay {
            if connection.sessions.isEmpty {
                ContentUnavailableView("Your sessions", systemImage: "sidebar.left", description: Text(connection.online ? "Create a session to start working on your computer." : "Connect your computer in Settings to see its sessions."))
            }
        }
    }
}

private struct SessionRow: View, Equatable {
    let session: Session
    let showsWorkspace: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack(spacing: 5) {
                Circle().fill(session.color).frame(width: 7, height: 7)
                Text(session.state.capitalized).lineLimit(1)
                Spacer()
                Label("\(session.jobs)", systemImage: "gearshape.2")
                    .monospacedDigit().lineLimit(1).opacity(session.jobs > 0 ? 1 : 0)
            }.font(.caption).foregroundStyle(.secondary)
            if showsWorkspace {
                Text(session.workspace).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }.padding(.vertical, 2)
    }
}
