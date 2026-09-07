import SwiftUI

/// Keep connection changes and error details out of the sidebar's layout.
struct ConnectionStatusView: View {
    let online: Bool
    let refreshing: Bool
    @Binding var error: String?
    @State private var showingDetails = false

    private var status: String {
        online ? "Mac connected" : refreshing ? "Connecting…" : "Disconnected"
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if refreshing && !online {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(online ? .green : .gray).frame(width: 7, height: 7)
                }
            }.frame(width: 14, height: 14)
            Text(status).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Button {
                showingDetails = true
            } label: {
                Image(systemName: error == nil ? "info.circle" : "exclamationmark.circle")
                    .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(error == nil ? "Connection details" : "Connection details, error reported")
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(status).font(.headline)
                    if let error {
                        ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 240)
                        Button("Clear error") { self.error = nil; showingDetails = false }
                    }
                    Button("Done") { showingDetails = false }
                }
                .padding().frame(idealWidth: 320, maxWidth: 400)
                .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(.bar)
    }
}
