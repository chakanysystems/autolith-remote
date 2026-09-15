import Foundation

/// Constructed on the transcript worker before a message reaches SwiftUI.
struct EventPresentation: Sendable {
    var startsResponse = false
    let markdown: AttributedString?
    let preview: String
    let hasLongOutput: Bool

    init(_ event: Event) {
        #if canImport(Darwin)
        markdown = event.activityKind == nil
            ? (try? AttributedString(markdown: event.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(event.text)
            : nil
        #else
        // Linux stores a plain-text presentation; Markdown rendering is client-side.
        markdown = event.activityKind == nil ? AttributedString(event.text) : nil
        #endif
        preview = String(event.text.prefix(600))
        hasLongOutput = event.hasLongOutput
    }
}
