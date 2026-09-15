import Foundation

// Generate XCTest's portable entry point from compiler symbols, not source text.
// Nixpkgs' Swift 5.10 omits libIndexStore, so SwiftPM's index-based discovery
// cannot run. Symbol graphs preserve active #if branches and async signatures.
struct Graph: Decodable {
    struct Symbol: Decodable {
        struct Kind: Decodable { let identifier: String }
        struct Identifier: Decodable { let precise: String }
        struct Fragment: Decodable { let kind: String; let spelling: String }
        struct Signature: Decodable {
            let parameters: [Parameter]?
            let returns: [Fragment]
            struct Parameter: Decodable { let name: String }
        }
        let kind: Kind
        let identifier: Identifier
        let pathComponents: [String]
        let declarationFragments: [Fragment]
        let functionSignature: Signature?
    }
    struct Relationship: Decodable {
        let kind: String
        let source: String
        let target: String
        let targetFallback: String?
    }
    let symbols: [Symbol]
    let relationships: [Relationship]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("test discovery: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else { fail("expected symbol directory, output path, and test modules") }
let directory = arguments[0]
let output = arguments[1]
let modules = arguments.dropFirst(2).sorted()
var lines = ["import XCTest"]
var entries: [String] = []
var total = 0
var classNames: Set<String> = []

for module in modules {
    let path = "\(directory)/\(module).symbols.json"
    let graph = try JSONDecoder().decode(Graph.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let symbols = Dictionary(uniqueKeysWithValues: graph.symbols.map { ($0.identifier.precise, $0) })
    let testClasses = Set(graph.relationships.filter {
        $0.kind == "inheritsFrom" && $0.targetFallback == "XCTest.XCTestCase"
    }.map(\.source))
    // Reject indirect inheritance rather than silently dropping inherited tests.
    for relation in graph.relationships where relation.kind == "inheritsFrom" && testClasses.contains(relation.target) {
        fail("\(module): indirect XCTest inheritance requires extending discovery")
    }
    let owners = Dictionary(uniqueKeysWithValues: graph.relationships.filter {
        $0.kind == "memberOf"
    }.map { ($0.source, $0.target) })
    let subclasses = Set(graph.relationships.filter { $0.kind == "inheritsFrom" }.map(\.source))
    for method in graph.symbols where method.kind.identifier == "swift.method" {
        if let owner = owners[method.identifier.precise], subclasses.contains(owner),
           !testClasses.contains(owner), method.pathComponents.last?.hasPrefix("test") == true {
            fail("\(module): test method on unsupported superclass: \(method.pathComponents.joined(separator: "."))")
        }
    }
    var moduleCount = 0
    lines.append("@testable import \(module)")
    for classID in testClasses.sorted() {
        guard let type = symbols[classID] else { fail("missing test class \(classID)") }
        // A class can shadow its module name in Swift 5.10, so module-qualified
        // references are not usable here. Reject ambiguous names explicitly.
        let name = type.pathComponents.joined(separator: ".")
        guard classNames.insert(name).inserted else { fail("ambiguous test class: \(name)") }
        var tests: [String] = []
        for method in graph.symbols.sorted(by: { $0.identifier.precise < $1.identifier.precise }) {
            guard owners[method.identifier.precise] == classID,
                  method.kind.identifier == "swift.method",
                  let title = method.pathComponents.last,
                  title.hasPrefix("test"),
                  let signature = method.functionSignature,
                  (signature.parameters ?? []).isEmpty,
                  ["()", "Void"].contains(signature.returns.map(\.spelling).joined()) else { continue }
            guard title.hasSuffix("()") else { fail("unsupported test name: \(title)") }
            let methodName = String(title.dropLast(2))
            let reference = "\(name).\(methodName)"
            let isAsync = method.declarationFragments.contains { $0.kind == "keyword" && $0.spelling == "async" }
            let isMainActor = (type.declarationFragments + method.declarationFragments)
                .map(\.spelling).joined().contains("@MainActor")
            let invocation: String
            if isMainActor && !isAsync {
                // Invoke synchronous actor-isolated tests on their actor instead
                // of coercing an isolated method to XCTest's nonisolated closure.
                invocation = "asyncTest { (instance: \(name)) in { @MainActor in try instance.\(methodName)() } }"
            } else {
                invocation = isAsync ? "asyncTest(\(reference))" : reference
            }
            tests.append("(\"\(methodName)\", \(invocation))")
        }
        if !tests.isEmpty {
            entries.append("testCase([\n        " + tests.joined(separator: ",\n        ") + "\n    ])")
            moduleCount += tests.count
        }
    }
    guard moduleCount > 0 else { fail("no tests discovered in \(module)") }
    print("Discovered \(moduleCount) tests in \(module)")
    total += moduleCount
}
guard total > 0 else { fail("no tests discovered") }
lines.append("XCTMain([\n    " + entries.joined(separator: ",\n    ") + "\n])")
try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
print("Discovered \(total) tests in \(modules.count) modules")
