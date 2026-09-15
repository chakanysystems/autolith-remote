import SwiftUI
import AppIntents

struct SiriWorkspaceSettings: View {
    @Bindable var connection: Connection
    @State private var configuration = SiriWorkspaceConfiguration()
    @State private var defaultPath = ""
    @State private var paths: [String] = []
    @State private var error: String?
    private var visiblePaths: [String] {
        var all = Set(paths)
        all.formUnion(configuration.nicknames.keys)
        if !defaultPath.isEmpty { all.insert(defaultPath) }
        return all.sorted()
    }
    var body: some View {
        Form {
            Section("Default workspace") {
                NavigationLink { WorkspacePicker(connection: connection, selection: $defaultPath) } label: {
                    Label(defaultPath.isEmpty ? "Ask each time" : defaultPath, systemImage: "folder")
                }
                if !defaultPath.isEmpty { Button("Ask each time") { defaultPath = "" } }
                Text("When your request does not name a workspace, Siri uses this folder on the connected computer.")
            }
            Section("Workspace nicknames") {
                ForEach(visiblePaths, id: \.self) { path in
                    VStack(alignment: .leading) {
                        Text(path).font(.caption).foregroundStyle(.secondary)
                        TextField("For example, backend", text: Binding(
                            get: { configuration.nicknames[path] ?? "" },
                            set: { configuration.nicknames[path] = $0; save() }
                        )).autocorrectionDisabled()
                    }
                }
                Text("Use a nickname or folder name in Siri’s workspace picker, or say “In the backend workspace, investigate the failing tests.” Duplicate names require clarification.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Siri workspaces")
        .task {
            configuration = .load(host: connection.host)
            defaultPath = configuration.defaultPath ?? ""
            do { paths = try await AutolithWorkspaceQuery().suggestedEntities().map(\.path) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: defaultPath) { _, value in
            configuration.defaultPath = value.isEmpty ? nil : value
            save()
        }
        .onDisappear { AutolithShortcuts.updateAppShortcutParameters() }
    }
    private func save() {
        do { try configuration.save(host: connection.host); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
