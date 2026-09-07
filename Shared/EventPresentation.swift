import Foundation

/// Constructed on the transcript worker before a message reaches SwiftUI.
struct EventPresentation: Sendable {
    var startsResponse = false
    let markdown: AttributedString?
    let preview: String
    let hasLongOutput: Bool

    init(_ event: Event) {
        markdown = event.activityKind == nil
            ? (try? AttributedString(markdown: event.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(event.text)
            : nil
        preview = String(event.text.prefix(600))
        hasLongOutput = event.hasLongOutput
    }
}
