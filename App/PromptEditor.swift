import SwiftUI
import UIKit

struct PromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let lisp: Bool
    let editRevision: Int
    let send: (String) -> Void
    let complete: (String, NSRange) -> (String, NSRange)?

    final class TextView: UITextView {
        var send: ((String) -> Void)?
        var complete: ((String, NSRange) -> (String, NSRange)?)?
        var insertingNewline = false
        var replacingText = false
        override var keyCommands: [UIKeyCommand]? {
            [command("\r", [], #selector(submit)), command("\r", .command, #selector(submit)),
             command("\r", .shift, #selector(newline)), command("\t", [], #selector(acceptCompletion))]
        }
        private func command(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
        @objc private func submit() { if markedTextRange == nil { send?(text) } }
        @objc private func newline() {
            insertingNewline = true
            defer { insertingNewline = false }
            insertText("\n")
        }
        @objc private func acceptCompletion() {
            guard let replacement = complete?(text, selectedRange) else { return }
            replacingText = true
            text = replacement.0
            selectedRange = replacement.1
            replacingText = false
            delegate?.textViewDidChange?(self)
            delegate?.textViewDidChangeSelection?(self)
        }
    }
    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.returnKeyType = .send
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartInsertDeleteType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .none
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.accessibilityLabel = "Prompt or Lisp expression"
        view.accessibilityHint = "Return sends. Shift Return inserts a new line. Tab accepts a completion."
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.send = send; view.complete = complete
        // UIKit owns typing; replace text only for explicit draft edits from SwiftUI.
        if !context.coordinator.initialized || context.coordinator.editRevision != editRevision {
            context.coordinator.applyingUpdate = true
            let desiredSelection = selection
            view.text = text
            if NSMaxRange(desiredSelection) <= (text as NSString).length { view.selectedRange = desiredSelection }
            context.coordinator.applyingUpdate = false
            context.coordinator.initialized = true
            context.coordinator.editRevision = editRevision
        }
        view.font = lisp ? UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular)) : .preferredFont(forTextStyle: .body)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Measure wrapped text at the available width; long drafts scroll within the cap.
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(180, max(48, ceil(height))))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptEditor
        var applyingUpdate = false
        var initialized = false
        var editRevision = 0
        init(_ parent: PromptEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            guard !applyingUpdate, (textView as? TextView)?.replacingText != true else { return }
            parent.text = textView.text; parent.selection = textView.selectedRange
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applyingUpdate, (textView as? TextView)?.replacingText != true else { return }
            parent.selection = textView.selectedRange
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil,
               (textView as? TextView)?.insertingNewline != true {
                parent.send(textView.text)
                return false
            }
            return true
        }
    }
}
