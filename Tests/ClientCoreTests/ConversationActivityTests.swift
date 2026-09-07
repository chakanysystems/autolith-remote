import XCTest
@testable import ClientCore

final class ConversationActivityTests: XCTestCase {
    private func event(_ role: String, tool: String = "", text: String = "") -> Event {
        Event(id: "1", role: role, tool: tool, text: text)
    }

    func testReasoningIsSeparateFromAnswersAndTools() {
        XCTAssertEqual(event("reasoning").activityKind, .thinking)
        XCTAssertEqual(event("thinking").activityKind, .thinking)
        XCTAssertNil(event("assistant").activityKind)
        XCTAssertNil(event("user", text: "rlm.infer").activityKind)
        XCTAssertEqual(event("user-operation").activityKind, .tool)
    }

    func testToolNamespacesClassifyCallsAndResults() {
        for role in ["tool-call", "tool-result"] {
            for tool in ["rlm.infer", "RLM-MAP", "functions.t_3_rlm__complete"] {
                XCTAssertEqual(event(role, tool: tool).activityKind, .rlm)
            }
            for tool in ["task.run", "job.wait", "JOB-GET", "functions.t_4_task__run"] {
                XCTAssertEqual(event(role, tool: tool).activityKind, .job)
            }
            XCTAssertEqual(event(role, tool: "shell.run", text: "rlm.infer job.wait").activityKind, .tool)
            XCTAssertEqual(event(role, tool: "taskmaster.run").activityKind, .tool)
        }
        XCTAssertEqual(event("tool-call", tool: "rlm.infer").activityPhase, "Call")
        XCTAssertEqual(event("tool-result", tool: "rlm.infer").activityPhase, "Result")
        XCTAssertNil(event("reasoning").activityPhase)
        XCTAssertEqual(event("turn-aborted").activityKind, .other)
    }

    func testOutputPreviewBoundsUnicodeAndLines() {
        let short = event("tool-result", text: "first\nsecond")
        XCTAssertFalse(short.hasLongOutput)
        XCTAssertEqual(short.activityPreview, "first second")
        let long = event("tool-result", text: String(repeating: "🧠", count: 601))
        XCTAssertTrue(long.hasLongOutput)
        XCTAssertEqual(long.activityPreview.count, 240)
        XCTAssertTrue(event("tool-result", text: Array(repeating: "line", count: 9).joined(separator: "\n")).hasLongOutput)
        XCTAssertFalse(event("tool-result", text: "").hasLongOutput)
    }

    func testExistingTranscriptPayloadSupportsActivityWithoutNewBackendFields() throws {
        let data = Data(#"{"id":"4","role":"reasoning","tool":"","text":"Inspecting the source","timestamp":1789000000}"#.utf8)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertEqual(decoded.activityKind, .thinking)
        XCTAssertEqual(decoded.text, "Inspecting the source")
    }

    private func status(_ events: [Event], state: String = "working", jobs: Int = 0,
                        connected: Bool = true, online: Bool = true) -> ConversationWorkerStatus {
        let session = Session(id: "s", title: "Test", state: state, workspace: "/test", model: "test",
                              permissions: "ask", queued: 0, jobs: jobs, updatedAt: nil)
        return ConversationWorkerStatus(session: session, events: events, online: online, connected: connected)
    }

    private func toolStatus(_ phase: String, _ tool: String) -> Event {
        Event(id: "live-1-tool-call-\(phase)-\(tool)", role: "status", tool: tool, text: "tool-call-\(phase)")
    }

    func testPendingToolClearsOnCompletionAndCanStartAgain() {
        let start = toolStatus("started", "rlm.infer")
        let end = toolStatus("completed", "rlm.infer")
        XCTAssertEqual(status([start]).text, "Waiting for RLM")
        XCTAssertEqual(status([start, end]).text, "Working")
        XCTAssertEqual(status([end, start]).text, "Waiting for RLM")
        XCTAssertEqual(status([toolStatus("started", "job.wait")]).text, "Waiting for jobs")
        XCTAssertEqual(status([toolStatus("started", "shell.run")]).text, "Running shell.run")
    }

    func testInternalEventsDoNotBecomeWorkerText() {
        let bookkeeping = Event(id: "live-1-user-message-persisted-", role: "status", tool: "", text: "user-message-persisted")
        XCTAssertEqual(status([bookkeeping]).text, "Working")
        let pending = toolStatus("started", "rlm.map")
        XCTAssertEqual(status([pending], state: "idle").text, "Ready")
    }

    func testPollingWorkKeepsProgressWithoutUsingStaleLiveEvents() {
        let staleTool = toolStatus("started", "rlm.map")
        let staleWorker = Event(id: "job-task:1", role: "status", tool: "job.list", text: "task:1 scout running")
        let result = status([staleTool, staleWorker], connected: false)
        XCTAssertTrue(result.isWorking)
        XCTAssertTrue(result.usesPolling)
        XCTAssertTrue(result.workers.isEmpty)
        XCTAssertEqual(result.text, status([], connected: false).text)
        XCTAssertFalse(status([], state: "idle", connected: false).isWorking)
        XCTAssertTrue(status([], state: "idle", connected: false).usesPolling)
    }

    func testProgressTracksWorkRatherThanTransportConnection() {
        XCTAssertTrue(status([]).isWorking)
        XCTAssertFalse(status([]).usesPolling)
        XCTAssertFalse(status([], state: "stopped", connected: false).isWorking)
        XCTAssertFalse(status([], state: "stopped", connected: false).usesPolling)
        XCTAssertFalse(status([], connected: false, online: false).isWorking)
        XCTAssertFalse(status([], connected: false, online: false).usesPolling)
    }

    func testWorkerNamesAndBackgroundWaitUseActiveJobsOnly() {
        let running = Event(id: "job-task:1", role: "status", tool: "job.list", text: "task:1 scout running")
        let done = Event(id: "job-task:2", role: "status", tool: "job.list", text: "task:2 reviewer completed")
        let result = status([running, done], state: "idle", jobs: 1)
        XCTAssertEqual(result.workers, ["scout"])
        XCTAssertEqual(result.text, "Waiting for jobs")
        XCTAssertEqual(status([running], state: "idle").workers, [])
        let rlm = Event(id: "job-exec:1", role: "status", tool: "job.list", text: "exec:1 rlm.infer running")
        XCTAssertEqual(status([rlm], state: "idle", jobs: 1).text, "Waiting for RLM")
    }
}
