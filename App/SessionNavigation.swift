import SwiftUI

/// Compact layouts push chats; wide layouts keep the selected chat beside the sidebar.
struct SessionNavigation<Sidebar: View, Detail: View>: View {
    @Binding var selection: String?
    @ViewBuilder let sidebar: (_ usesListSelection: Bool) -> Sidebar
    @ViewBuilder let detail: (String?) -> Detail
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [String]

    init(selection: Binding<String?>, @ViewBuilder sidebar: @escaping (Bool) -> Sidebar,
         @ViewBuilder detail: @escaping (String?) -> Detail) {
        _selection = selection
        self.sidebar = sidebar
        self.detail = detail
        _path = State(initialValue: selection.wrappedValue.map { [$0] } ?? [])
    }

    var body: some View {
        if horizontalSizeClass == .compact {
            NavigationStack(path: $path) {
                sidebar(false)
                    .navigationDestination(for: String.self) { id in
                        detail(id)
                    }
            }
            .onChange(of: path) { _, destination in
                if selection != destination.last { selection = destination.last }
            }
            .onChange(of: selection) { _, destination in
                guard path.last != destination else { return }
                withAnimation { path = destination.map { [$0] } ?? [] }
            }
            .onAppear {
                if path.last != selection { path = selection.map { [$0] } ?? [] }
            }
        } else {
            NavigationSplitView {
                sidebar(true)
            } detail: {
                detail(selection)
            }
        }
    }
}
