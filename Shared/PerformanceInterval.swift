import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Timing labels contain no host, session ID, credentials, or conversation text.
public struct PerformanceInterval: Sendable {
    public enum Stage: String, Sendable {
        case http, decoding, reconciliation, publication, cacheWrite
        case backendWait, backendRPC, transcriptSource, transcriptRead
    }
    private let stage: Stage
    private let started = ProcessInfo.processInfo.systemUptime
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.lambda-symbolics.autolith.companion", category: "Performance")
    #endif

    public init(_ stage: Stage) { self.stage = stage }

    public func finish(bytes: Int = 0) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        #if canImport(OSLog)
        Self.logger.debug("stage=\(stage.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public) bytes=\(bytes, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
        #else
        if ProcessInfo.processInfo.environment["AUTOLITH_TRACE_PERFORMANCE"] == "1" {
            let message = "performance stage=\(stage.rawValue) ms=\(milliseconds) bytes=\(bytes)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        #endif
    }
}
