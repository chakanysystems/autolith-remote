import SwiftUI

struct WorkspacePicker: View {
    @Bindable var connection: Connection
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Section { Text(error).foregroundStyle(.red); Button("Retry") { Task { await load(directory.isEmpty ? nil : directory) } } } }
            if !directory.isEmpty {
                Section {
                    Text(directory).font(.caption).textSelection(.enabled)
                    Button("Choose this folder", systemImage: "checkmark") { selection = directory; dismiss() }
                    if directory != "/" {
                        Button("Enclosing folder", systemImage: "arrow.up") { Task { await load(URL(fileURLWithPath: directory).deletingLastPathComponent().path) } }
                    }
                }
            }
            Section("Folders on your computer") {
                ForEach(folders, id: \.self) { path in
                    Button { Task { await load(path) } } label: {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                    }
                }
            }
        }
        .disabled(loading)
        .overlay { if loading { ProgressView("Loading folders…") } }
        .navigationTitle("Choose workspace")
        .task { await load(nil) }
    }

    private func load(_ path: String?) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            var request: [String: Any] = ["operation": "browse"]
            if let path { request["path"] = path }
            let reply = try await connection.call(request)
            guard let current = reply.directory, let children = reply.directories else {
                throw connection.failure("Update the computer companion to browse folders.")
            }
            directory = current; folders = children
        } catch { self.error = error.localizedDescription }
    }
}
