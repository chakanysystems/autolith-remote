import SwiftUI

struct SessionComposer: View {
    @ObservedObject var connection: Connection
    let session: Session
    @State private var editRevision = 0
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var pickingModel = false
    private var draft: String { connection.drafts[session.id] ?? "" }
    private var binding: Binding<String> { Binding(get: { draft }, set: { connection.drafts[session.id] = $0 }) }
    private var lisp: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(") }
    private var context: ComposerContext? { ComposerContext(text: draft, caret: selection.location) }
    private var matches: [CompletionOption] {
        guard let context else { return [] }
        return Array(connection.completions.filter { $0.name.lowercased().hasPrefix(context.prefix.lowercased()) }
            .sorted { $0.name < $1.name }.prefix(6))
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.isRunning && connection.online && !connection.isBusy(session.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !matches.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(matches) { item in
                            Button { accept(item) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.system(.callout, design: .monospaced))
                                    if !item.hint.isEmpty { Text(item.hint).font(.caption).foregroundStyle(.secondary) }
                                }.padding(8)
                            }.buttonStyle(.bordered).accessibilityHint(item.description)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            ComposerGlassGroup {
                HStack(alignment: .bottom, spacing: 8) {
                    PromptEditor(text: binding, selection: $selection, lisp: lisp, editRevision: editRevision, send: { send($0) }, complete: { text, caret in
                        guard let context = ComposerContext(text: text, caret: caret.location),
                              let item = connection.completions.filter({ $0.name.lowercased().hasPrefix(context.prefix.lowercased()) })
                                .sorted(by: { $0.name < $1.name }).first else { return nil }
                        return replacement(item, text: text, context: context)
                    })
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Message or (Lisp expression)").foregroundStyle(.secondary)
                                .lineLimit(1).padding(.horizontal, 13).padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .modifier(ComposerInputGlass())
                    ComposerSendButton(lisp: lisp, busy: connection.isBusy(session.id), enabled: canSend) { send() }
                }
            }
            HStack(spacing: 12) {
                Button { pickingModel = true } label: {
                    HStack(spacing: 4) {
                        Text(session.model).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.caption2)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Model, \(session.model)")
                .accessibilityIdentifier("composer-model")
                Spacer(minLength: 0)
                Menu {
                    ForEach(session.supportedEfforts ?? [], id: \.self) { effort in
                        Button {
                            Task { _ = await connection.selectEffort(effort, session: session) }
                        } label: {
                            if effort == session.effort { Label(effort.capitalized, systemImage: "checkmark") }
                            else { Text(effort.capitalized) }
                        }
                    }
                } label: {
                    Label(session.effort?.capitalized ?? "Effort", systemImage: "slider.horizontal.3")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(session.supportedEfforts?.isEmpty != false)
                .accessibilityLabel("Reasoning effort, \(session.effort ?? "unavailable")")
                .accessibilityIdentifier("composer-effort")
            }
            .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
            .disabled(!session.isRunning || !connection.online || connection.isBusy(session.id))
            if lisp {
                Label("Lisp runs in this session on your computer", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 900).frame(maxWidth: .infinity)
            .onAppear { selection = NSRange(location: (draft as NSString).length, length: 0) }
            .sheet(isPresented: $pickingModel) { ModelPicker(connection: connection, session: session) }
    }
    private func accept(_ item: CompletionOption) {
        guard let context else { return }
        accept(item, text: draft, context: context)
    }
    private func accept(_ item: CompletionOption, text: String, context: ComposerContext) {
        let result = replacement(item, text: text, context: context)
        binding.wrappedValue = result.0
        selection = result.1
        editRevision += 1
    }
    private func replacement(_ item: CompletionOption, text: String, context: ComposerContext) -> (String, NSRange) {
        let replacement = item.name + (item.name.hasSuffix(")") ? "" : " ")
        return ((text as NSString).replacingCharacters(in: context.range, with: replacement),
                NSRange(location: context.range.location + (replacement as NSString).length, length: 0))
    }
    private func send(_ nativeText: String? = nil) {
        let message = nativeText ?? draft
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.isRunning, connection.online, !connection.isBusy(session.id) else { return }
        let donate = !lisp && !message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
        let sequence = connection.events[session.id]?.compactMap { Int($0.id) }.max() ?? 0
        Task {
            if await connection.control("tell", id: session.id, message: message) {
                if draft == message { binding.wrappedValue = ""; selection = NSRange(location: 0, length: 0); editRevision += 1 }
                if #available(iOS 27.0, macOS 27.0, *), donate {
                    await SiriInteractionDonation.sent(text: message, session: session, connection: connection, after: sequence)
                }
            }
        }
    }
}

/// Group the two glass surfaces so the system can render them together.
private struct ComposerGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }
}

struct ComposerInputGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

struct ComposerSendButton: View {
    let lisp: Bool
    let busy: Bool
    let enabled: Bool
    let send: () -> Void

    private var label: some View {
        ZStack {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: lisp ? "play.fill" : "arrow.up").font(.system(size: 20, weight: .semibold)) }
        }
        .frame(width: 48, height: 48)
        .foregroundStyle(enabled ? Color.white : Color.secondary)
        .contentShape(Circle())
    }

    var body: some View {
        Button(action: send) {
            if #available(iOS 26.0, macOS 26.0, *) {
                label.glassEffect(.regular.tint(enabled ? .accentColor : .gray.opacity(0.15)).interactive(), in: .circle)
            } else {
                label.background(enabled ? Color.accentColor : Color.gray.opacity(0.15), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(lisp ? "Run Lisp" : "Send prompt")
        .accessibilityIdentifier("composer-send")
        .keyboardShortcut(.return, modifiers: .command)
    }
}
