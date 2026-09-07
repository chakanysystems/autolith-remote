import SwiftUI
import AppIntents

// Store action names only, never dictated content or workspace paths.
@MainActor enum SiriInvocation {
    static func record(_ action: String) {
        UserDefaults.standard.set(action, forKey: "siriLastAction")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "siriLastActionDate")
        SiriTrace.record(action)
    }
}

struct SiriSettings: View {
    @ObservedObject var connection: Connection
    @AppStorage("siriLastAction") private var lastAction = ""
    @AppStorage("siriLastActionDate") private var lastDate = 0.0
    @AppStorage("siriContextError") private var contextError = ""
    var body: some View {
        Section("Siri") {
            Text("Say “Ask Autolith a question”, then dictate your request. Name a workspace in the request or set a default below.")
            NavigationLink("Workspaces and nicknames") { SiriWorkspaceSettings(connection: connection) }
            Text("Say “Follow up with Autolith” to send another question to the same conversation. On iOS 27, conversations and responses also provide context for Siri through Apple’s conversation schema.")
            Text("Say “Read my latest Autolith answer” to check the result. You can also say “Check Autolith progress” or “Stop my Autolith task”.")
            if !lastAction.isEmpty {
                LabeledContent("Last action", value: lastAction)
                Text(Date(timeIntervalSince1970: lastDate), style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            if !contextError.isEmpty {
                Text("Siri could not index conversation context: \(contextError)").foregroundStyle(.red)
            }
            Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
            NavigationLink("Siri diagnostics") { SiriDiagnosticsView() }
            MessageNotificationSettings()
        }
    }
}

private struct SiriDiagnosticsView: View {
    @State private var entries: [SiriTrace.Entry] = []
    var body: some View {
        List {
            Section {
                Text("Records action stages, session IDs, counts, and error codes. Prompts and responses are not recorded. A prepared result does not prove Siri used it.")
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.stage)
                    Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    if let id = entry.sessionID { Text("Session: \(id)").font(.caption.monospaced()) }
                    if let id = entry.eventID { Text("Message: \(id)").font(.caption.monospaced()) }
                    if let count = entry.count { Text("Count: \(count)").font(.caption) }
                    if let hasResponse = entry.hasResponse { Text(hasResponse ? "Response present" : "No response in result").font(.caption) }
                    if let code = entry.errorCode { Text("Error code: \(code)").font(.caption) }
                }
            }
        }
        .navigationTitle("Siri diagnostics")
        .task { entries = SiriTrace.entries() }
        .refreshable { entries = SiriTrace.entries() }
    }
}
