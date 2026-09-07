import AppKit
import CoreText

// Exact Cosmic FIGlet mark from Autolith src/startup/main.lisp.
// Colors match src/terminal/style.lisp ANSI indices 193, 157, 121, 85, 84, 83.
let rows = [
    "  :::.      :::",
    "  ;;`;;     ;;;",
    " ,[[ '[[,   [[[",
    "c$$$cc$$$c  $$'",
    " 888   888,o88oo,.__",
    " YMM   \"\"` \"\"\"\"YUMMM"
]
let colors = ["#D7FFAF", "#AFFFaf", "#87FFAF", "#5FFFAF", "#5FFF87", "#5FFF5F"]
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 62, nil)
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
for (row, text) in rows.enumerated() {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    var paths = ""
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        for index in 0..<count {
            guard let outline = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
            var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                             tx: 139 + positions[index].x, ty: 342 + CGFloat(row) * 76)
            let path = outline.copy(using: &transform)!
            var data = ""
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                func point(_ index: Int) -> String {
                    "\(number(element.points[index].x)) \(number(element.points[index].y))"
                }
                switch element.type {
                case .moveToPoint: data += "M\(point(0)) "
                case .addLineToPoint: data += "L\(point(0)) "
                case .addQuadCurveToPoint: data += "Q\(point(0)) \(point(1)) "
                case .addCurveToPoint: data += "C\(point(0)) \(point(1)) \(point(2)) "
                case .closeSubpath: data += "Z "
                @unknown default: fatalError("Unsupported glyph outline")
                }
            }
            paths += "<path d=\"\(data)\"/>\n"
        }
    }
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><g fill=\"\(colors[row])\">\n\(paths)</g></svg>\n"
    try svg.write(to: destination.appendingPathComponent("row-\(row + 1).svg"), atomically: true, encoding: .utf8)
}
