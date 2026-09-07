#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct WorkActivityAttributes: ActivityAttributes {
    typealias ContentState = WorkSummary
    let host: String
}
#endif
