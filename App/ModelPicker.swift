import SwiftUI

struct ModelPicker: View {
    @ObservedObject var connection: Connection
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if connection.loadingCatalog { ProgressView("Loading models…") }
                if let error = connection.catalogError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await connection.loadCatalog(for: session, force: true) } }
                }
                ForEach(Array(Set(connection.models.map(\.provider))).sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(connection.models.filter { $0.provider == provider && (search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)) }) { model in
                            Button {
                                Task { if await connection.selectModel(model, session: session) { dismiss() } }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.id).foregroundStyle(.primary)
                                        if !model.description.isEmpty { Text(model.description).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if model.id == session.model { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                                }
                            }.disabled(connection.busy)
                        }
                    }
                }
            }.searchable(text: $search, prompt: "Find a model")
                .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    if connection.busy { ProgressView("Changing model…").padding().frame(maxWidth: .infinity).background(.bar) }
                }
        }.task { await connection.loadCatalog(for: session) }
    }
}
