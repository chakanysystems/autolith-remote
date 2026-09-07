import Foundation

struct ComposerContext {
    let range: NSRange
    let prefix: String
    init?(text: String, caret: Int) {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }
        // Never complete in strings or comments, and respect escaped quotes.
        var inString = false, escaped = false, comment = false
        for value in source.substring(to: caret) {
            if comment { if value == "\n" { comment = false }; continue }
            if escaped { escaped = false; continue }
            if value == "\\" { escaped = true; continue }
            if value == "\"" { inString.toggle() }
            if !inString && value == ";" { comment = true }
        }
        guard !inString, !comment else { return nil }
        var start = caret
        while start > 0 {
            let char = source.substring(with: NSRange(location: start - 1, length: 1))
            if char.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || char == ")" { break }
            start -= 1
            if char == "(" { break }
        }
        let prefix = source.substring(with: NSRange(location: start, length: caret - start))
        guard prefix.hasPrefix("(") || (start == 0 && prefix.hasPrefix("/")), prefix.count > 1 else { return nil }
        self.range = NSRange(location: start, length: caret - start)
        self.prefix = prefix
    }
}
