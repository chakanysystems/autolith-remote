import ActivityKit
import SwiftUI
import WidgetKit

@main struct AutolithWidgets: WidgetBundle {
    var body: some Widget { AutolithActivity() }
}

struct AutolithActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Autolith", systemImage: "terminal").font(.headline)
                    Spacer()
                    Text(context.state.sessions == 0 ? "No active work" : context.isStale ? "Update pending" : "\(context.state.sessions) working")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(context.state.items) { item in
                    Link(destination: URL(string: "autolith://session/\(item.id)")!) {
                        HStack {
                            Image(systemName: context.state.sessions == 0 ? "checkmark.circle" : context.isStale ? "clock" : "circle.dotted")
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.state.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    if context.state.sessions > context.state.items.count {
                        Text("+\(context.state.sessions - context.state.items.count) more sessions")
                    }
                    Spacer()
                    if context.state.tasks > 0 { Label("\(context.state.tasks) tasks", systemImage: "gearshape.2") }
                    if context.state.queued > 0 { Label("\(context.state.queued) queued", systemImage: "tray") }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding().activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(URL(string: "autolith://sessions"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Autolith", systemImage: "terminal").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.sessions) working").font(.subheadline) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.isStale ? "Open Autolith to refresh" : context.state.items.first?.title ?? "Work finished").lineLimit(1)
                        Text("\(context.state.tasks) tasks · \(context.state.queued) queued").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: { Image(systemName: "terminal") }
              compactTrailing: { Text("\(context.state.sessions)").monospacedDigit() }
              minimal: { Text("\(context.state.sessions)").monospacedDigit() }
                .widgetURL(URL(string: "autolith://sessions"))
        }
    }
}
