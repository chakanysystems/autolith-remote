import Foundation

/// Index maintenance follows an authoritative mutation. Its failure must not undo the result.
@MainActor enum SiriIndexMaintenance {
    static func run(update: () async throws -> Void, failed: (Error) -> Void) async {
        do { try await update() }
        catch { failed(error) }
    }
}
