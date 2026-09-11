import SwiftUI

struct ConversationEventView: View {
    let event: Event
    let presentation: EventPresentation?
    var retryMessage: (() -> Void)? = nil
    var abandonMessage: (() -> Void)? = nil
    var controlsEnabled = true
    @State private var confirmingAbandon = false
    @State private var expanded = false
    @State private var thinkingVisible = true

    private var tint: Color {
        switch event.activityKind {
        case .thinking: .secondary
        case .rlm: .purple
        case .job: .orange
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if presentation?.startsResponse == true {
                Divider().padding(.bottom, 6).accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(event.activityTitle, systemImage: event.activityKind?.symbol ?? (event.role == "user" ? "person.crop.circle" : "sparkle"))
                    .font(.caption.weight(.semibold))
                if let phase = event.activityPhase { Text(phase).font(.caption) }
                Spacer(minLength: 0)
                if let timestamp = event.timestamp {
                    Text(Date(timeIntervalSince1970: timestamp), style: .time).font(.caption2).monospacedDigit()
                }
            }.foregroundStyle(tint)

            if event.deliveryState == "uncertain" {
                Text("Delivery unconfirmed. Check the conversation before sending again.").font(.caption).foregroundStyle(.orange)
            } else if event.deliveryState == "queued", let dispatchAt = event.dispatchAt {
                Text("Queued for \(Date(timeIntervalSince1970: dispatchAt), format: .dateTime.hour().minute().second())").font(.caption).foregroundStyle(.secondary)
            } else if event.deliveryState == "failed" {
                Text("Not delivered. Preparation failed after repeated attempts.").font(.caption).foregroundStyle(.orange)
            } else if event.deliveryState == "preparing" {
                ProgressView("Preparing to send…").font(.caption)
            } else if event.deliveryState == "dispatching" {
                ProgressView("Sending…").font(.caption)
            }
            if event.canRetryDelivery || event.canAbandonDelivery {
                HStack {
                    if event.canRetryDelivery, let retryMessage {
                        Button("Retry delivery", action: retryMessage)
                    }
                    if event.canAbandonDelivery, abandonMessage != nil {
                        Button("Abandon message", role: .destructive) { confirmingAbandon = true }
                    }
                }.font(.caption).disabled(!controlsEnabled)
            }

            if event.activityKind == .thinking {
                if thinkingVisible {
                    Text(event.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(thinkingVisible ? "Hide thinking" : "Show thinking") { thinkingVisible.toggle() }
                    .font(.caption).accessibilityLabel(thinkingVisible ? "Hide thinking trace" : "Show thinking trace")
            } else if event.activityKind == nil {
                if let markdown = presentation?.markdown {
                    Text(markdown).textSelection(.enabled)
                } else {
                    Text(verbatim: event.text).textSelection(.enabled)
                }
            } else {
                Text(expanded || presentation?.hasLongOutput != true ? event.text : presentation?.preview ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(expanded ? nil : 8)
                    .textSelection(.enabled)
                if presentation?.hasLongOutput == true {
                    Button(expanded ? "Show less" : "Show full output") { expanded.toggle() }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(event.role == "user" || event.activityKind != nil ? 14 : 0)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if event.activityKind != nil {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.5)).frame(width: 2).padding(.vertical, 12)
            }
        }
        .confirmationDialog("Abandon this message?", isPresented: $confirmingAbandon, titleVisibility: .visible) {
            Button("Abandon message", role: .destructive) { abandonMessage?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(event.deliveryState == "uncertain"
                 ? "Check the conversation first. Abandoning removes the pending payload and retains its receipt; it cannot undo a message already sent."
                 : "Remove the pending payload and retain its receipt to prevent duplicate delivery.")
        }
    }

    private var background: Color {
        if event.role == "user" { return Color.accentColor.opacity(0.07) }
        return event.activityKind == nil ? .clear : tint.opacity(0.05)
    }
}

/// One line of current worker state, separate from the conversation.
struct ConversationActivityBar: View {
    let session: Session
    let events: [Event]
    let online: Bool
    let connected: Bool

    var body: some View {
        let status = ConversationWorkerStatus(session: session, events: events, online: online, connected: connected)
        HStack(spacing: 5) {
            if status.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
            } else {
                Image(systemName: online ? (session.isRunning ? "checkmark.circle" : "stop.circle") : "wifi.slash")
            }
            Text(([status.text] + (status.usesPolling ? ["Periodic updates"] : status.workers)).joined(separator: " · "))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation-worker-status")
    }
}
