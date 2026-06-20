import CryptoKit
import Darwin
import Foundation

enum CompanionWorkflowRunKind: String, Codable, Equatable {
    case mcpToolCall
    case aiResultWorkflow
    case internalWorkflow
}

enum CompanionWorkflowRunStatus: String, Codable, Equatable {
    case pending
    case awaitingApproval
    case awaitingInput
    case running
    case completed
    case blocked
    case denied
    case failed
    case cancelled

    static func fromToolResult(_ result: CompanionWorkflowToolResult) -> CompanionWorkflowRunStatus {
        switch result.status {
        case .succeeded:
            return .completed
        case .needsInput:
            return .awaitingInput
        case .blocked:
            return .blocked
        case .denied:
            return .denied
        case .failed:
            return .failed
        }
    }
}

enum CompanionWorkflowStepStatus: String, Codable, Equatable {
    case pending
    case awaitingInput
    case awaitingApproval
    case running
    case succeeded
    case skipped
    case failed
    case cancelled

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let status = CompanionWorkflowStepStatus(rawValue: raw) {
            self = status
            return
        }
        if let runStatus = CompanionWorkflowRunStatus(rawValue: raw) {
            self = .fromRunStatus(runStatus)
            return
        }
        self = .failed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func fromRunStatus(_ status: CompanionWorkflowRunStatus) -> CompanionWorkflowStepStatus {
        switch status {
        case .pending:
            return .pending
        case .awaitingApproval:
            return .awaitingApproval
        case .awaitingInput:
            return .awaitingInput
        case .running:
            return .running
        case .completed:
            return .succeeded
        case .blocked, .failed:
            return .failed
        case .denied, .cancelled:
            return .cancelled
        }
    }

    static func fromToolResult(_ result: CompanionWorkflowToolResult) -> CompanionWorkflowStepStatus {
        switch result.status {
        case .succeeded:
            return .succeeded
        case .needsInput:
            return .awaitingInput
        case .blocked, .failed:
            return .failed
        case .denied:
            return .cancelled
        }
    }
}

enum CompanionWorkflowFollowUpAction: String, Codable, Equatable {
    case openReminders
    case openJournal
    case openPomodoro
    case copyResult
}

struct CompanionWorkflowStepRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var templateStepID: String?
    var toolID: String?
    var title: String
    var status: CompanionWorkflowStepStatus
    var required: Bool?
    var inputSummary: String
    var outputSummary: String
    var errorSummary: String?
    var startedAt: Date?
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        templateStepID: String? = nil,
        toolID: String? = nil,
        title: String,
        status: CompanionWorkflowStepStatus,
        required: Bool? = nil,
        inputSummary: String = "",
        outputSummary: String = "",
        errorSummary: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.templateStepID = templateStepID
        self.toolID = toolID
        self.title = title
        self.status = status
        self.required = required
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.errorSummary = errorSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

struct CompanionWorkflowRunRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: CompanionWorkflowRunKind
    var source: String
    var templateID: String?
    var toolID: String?
    var title: String
    var status: CompanionWorkflowRunStatus
    var risk: CompanionWorkflowToolRisk?
    var inputSummary: String
    var outputSummary: String
    var errorSummary: String?
    var followUpActions: [CompanionWorkflowFollowUpAction]
    var startedAt: Date
    var finishedAt: Date?
    var steps: [CompanionWorkflowStepRecord]
    // 跨事件续接字段（reminder-focus-journal routine 用）。
    // 旧 workflow-runs.json 无这些 key → Swift 合成 Codable 对缺失的 Optional 字段解码为 nil，向后兼容，无需升 schemaVersion。
    var reminderID: UUID? = nil
    var pomodoroSessionID: UUID? = nil
    var continuationToken: String? = nil
    var waitingReason: String? = nil
    var lastEventAt: Date? = nil
}

final class CompanionWorkflowRunStore {
    static let fileName = "workflow-runs.json"
    private static let processLock = NSLock()

    private struct Payload: Codable {
        var schemaVersion: Int
        var runs: [CompanionWorkflowRunRecord]
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxRuns: Int
    private var loadFailed = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        maxRuns: Int = 200
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.maxRuns = max(1, maxRuns)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func url() -> URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    func runs(limit: Int = 200) -> [CompanionWorkflowRunRecord] {
        withFileLock {
            Array(loadPayload().runs.sorted { $0.startedAt > $1.startedAt }.prefix(max(0, limit)))
        }
    }

    func run(id: UUID) -> CompanionWorkflowRunRecord? {
        withFileLock {
            loadPayload().runs.first { $0.id == id }
        }
    }

    func append(_ run: CompanionWorkflowRunRecord) {
        withFileLock {
            var payload = loadPayload()
            payload.runs.removeAll { $0.id == run.id }
            payload.runs.insert(run, at: 0)
            save(payload)
        }
    }

    @discardableResult
    func startMCPToolRun(
        caller: String,
        toolID: String,
        toolTitle: String,
        risk: CompanionWorkflowToolRisk,
        arguments: CompanionJSONObject,
        status: CompanionWorkflowRunStatus = .awaitingApproval,
        now: Date = Date()
    ) -> UUID {
        let id = UUID()
        append(CompanionWorkflowRunRecord(
            id: id,
            kind: .mcpToolCall,
            source: Self.safeToken(caller, maxLength: 80),
            templateID: nil,
            toolID: Self.safeToken(toolID, maxLength: 120),
            title: Self.safeHumanTitle(toolTitle, fallback: toolID),
            status: status,
            risk: risk,
            inputSummary: Self.argumentSummary(arguments),
            outputSummary: "",
            errorSummary: nil,
            followUpActions: [],
            startedAt: now,
            finishedAt: nil,
            steps: [
                CompanionWorkflowStepRecord(
                    toolID: toolID,
                    title: Self.safeHumanTitle(toolTitle, fallback: toolID),
                    status: .fromRunStatus(status),
                    required: Self.defaultRequiredFlag(toolID: toolID, title: toolTitle),
                    inputSummary: Self.argumentSummary(arguments),
                    startedAt: now
                )
            ]
        ))
        return id
    }

    @discardableResult
    func startWorkflowRun(
        kind: CompanionWorkflowRunKind,
        source: String,
        templateID: String?,
        templateStepID: String? = nil,
        toolID: String?,
        title: String,
        risk: CompanionWorkflowToolRisk?,
        inputSummary: String,
        status: CompanionWorkflowRunStatus = .running,
        now: Date = Date()
    ) -> UUID {
        let id = UUID()
        append(CompanionWorkflowRunRecord(
            id: id,
            kind: kind,
            source: Self.safeToken(source, maxLength: 80),
            templateID: templateID.map { Self.safeToken($0, maxLength: 120) },
            toolID: toolID.map { Self.safeToken($0, maxLength: 120) },
            title: Self.safeHumanTitle(title, fallback: templateID ?? toolID ?? kind.rawValue),
            status: status,
            risk: risk,
            inputSummary: Self.safeSummary(inputSummary, maxLength: 180),
            outputSummary: "",
            errorSummary: nil,
            followUpActions: [],
            startedAt: now,
            finishedAt: nil,
            steps: [
                CompanionWorkflowStepRecord(
                    templateStepID: templateStepID.map { Self.safeToken($0, maxLength: 120) },
                    toolID: toolID,
                    title: Self.safeHumanTitle(title, fallback: templateID ?? toolID ?? kind.rawValue),
                    status: .fromRunStatus(status),
                    required: Self.defaultRequiredFlag(toolID: toolID, title: title),
                    inputSummary: Self.safeSummary(inputSummary, maxLength: 180),
                    startedAt: now
                )
            ]
        ))
        return id
    }

    func markRunning(id: UUID, now: Date = Date()) {
        mutate(id: id) { run in
            run.status = .running
            run.steps = run.steps.map { step in
                var next = step
                if next.finishedAt == nil {
                    next.status = .running
                    next.startedAt = next.startedAt ?? now
                }
                return next
            }
        }
    }

    func setStatus(id: UUID, status: CompanionWorkflowRunStatus, message: String? = nil, now: Date = Date()) {
        mutate(id: id) { run in
            run.status = status
            if let message {
                run.outputSummary = Self.safeSummary(message)
            }
            run.finishedAt = nil
            run.steps = run.steps.map { step in
                var next = step
                if next.finishedAt == nil {
                    next.status = .fromRunStatus(status)
                    if let message {
                        next.outputSummary = Self.safeSummary(message)
                    }
                    next.startedAt = next.startedAt ?? now
                }
                return next
            }
        }
    }

    func finish(id: UUID, result: CompanionWorkflowToolResult, now: Date = Date()) {
        mutate(id: id) { run in
            guard run.status != .cancelled else {
                return
            }
            let status = CompanionWorkflowRunStatus.fromToolResult(result)
            run.status = status
            run.outputSummary = Self.toolResultSummary(result)
            run.errorSummary = result.error.map(Self.errorSummary)
            run.followUpActions = Self.followUpActions(toolID: run.toolID, result: result)
            run.finishedAt = now
            run.steps = run.steps.map { step in
                var next = step
                if next.finishedAt == nil {
                    next.status = .fromToolResult(result)
                    next.outputSummary = Self.toolResultSummary(result)
                    next.errorSummary = result.error.map(Self.errorSummary)
                    next.finishedAt = now
                }
                return next
            }
        }
    }

    func cancel(id: UUID, status: CompanionWorkflowRunStatus, message: String, now: Date = Date()) {
        mutate(id: id) { run in
            run.status = status
            run.outputSummary = Self.safeSummary(message)
            run.errorSummary = Self.safeSummary(message)
            run.finishedAt = now
            run.steps = run.steps.map { step in
                var next = step
                if next.finishedAt == nil {
                    next.status = .fromRunStatus(status)
                    next.outputSummary = Self.safeSummary(message)
                    next.errorSummary = Self.safeSummary(message)
                    next.finishedAt = now
                }
                return next
            }
        }
    }

    func cancelInteractively(id: UUID, message: String = "Workflow cancelled by user.", now: Date = Date()) {
        mutate(id: id) { run in
            run.status = .cancelled
            run.outputSummary = Self.safeSummary(message)
            run.errorSummary = Self.safeSummary(message)
            run.finishedAt = now
            run.steps = run.steps.map { step in
                var next = step
                switch next.status {
                case .pending, .running, .awaitingInput, .awaitingApproval:
                    next.status = .cancelled
                    next.outputSummary = Self.safeSummary(message)
                    next.errorSummary = Self.safeSummary(message)
                    next.finishedAt = now
                default:
                    break
                }
                return next
            }
        }
    }

    @discardableResult
    func skipStep(id: UUID, stepID: UUID, now: Date = Date()) -> Bool {
        var didSkip = false
        mutate(id: id) { run in
            guard let index = run.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            guard !Self.requiredFlag(for: run.steps[index]) else {
                return
            }
            run.steps[index].status = .skipped
            run.steps[index].outputSummary = "Skipped by user."
            run.steps[index].errorSummary = nil
            run.steps[index].finishedAt = now
            didSkip = true
            Self.refreshRunStatusAfterInteractiveStepChange(&run, now: now)
        }
        return didSkip
    }

    func markStepRetryStarted(id: UUID, stepID: UUID, now: Date = Date()) {
        mutate(id: id) { run in
            guard let index = run.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            run.status = .running
            run.finishedAt = nil
            run.errorSummary = nil
            run.steps[index].status = .running
            run.steps[index].outputSummary = "Retrying..."
            run.steps[index].errorSummary = nil
            run.steps[index].startedAt = now
            run.steps[index].finishedAt = nil
        }
    }

    func markStepRetryFinished(id: UUID, stepID: UUID, result: CompanionWorkflowToolResult, now: Date = Date()) {
        mutate(id: id) { run in
            guard run.status != .cancelled else {
                return
            }
            guard let index = run.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            run.steps[index].status = .fromToolResult(result)
            run.steps[index].outputSummary = Self.toolResultSummary(result)
            run.steps[index].errorSummary = result.error.map(Self.errorSummary)
            run.steps[index].finishedAt = now
            Self.refreshRunStatusAfterInteractiveStepChange(&run, now: now)
        }
    }

    func markStepRetryUnavailable(id: UUID, stepID: UUID, message: String, now: Date = Date()) {
        mutate(id: id) { run in
            guard let index = run.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            run.steps[index].status = .failed
            run.steps[index].outputSummary = ""
            run.steps[index].errorSummary = Self.safeSummary(message)
            run.steps[index].finishedAt = now
            run.status = .failed
            run.errorSummary = Self.safeSummary(message)
            run.finishedAt = now
        }
    }

    func clear() {
        withFileLock {
            try? fileManager.removeItem(at: url())
        }
    }

    func diagnosticJSON(limit: Int = 200) -> String? {
        let records = runs(limit: limit).map(redactedForDiagnostics)
        guard !records.isEmpty else { return nil }
        let payload = Payload(schemaVersion: 1, runs: records)
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mutate(id: UUID, _ transform: (inout CompanionWorkflowRunRecord) -> Void) {
        withFileLock {
            var payload = loadPayload()
            guard let index = payload.runs.firstIndex(where: { $0.id == id }) else { return }
            transform(&payload.runs[index])
            save(payload)
        }
    }

    private func loadPayload() -> Payload {
        let targetURL = url()
        guard fileManager.fileExists(atPath: targetURL.path) else {
            loadFailed = false
            return Payload(schemaVersion: 1, runs: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: targetURL)
        } catch {
            markLoadFailure(error)
            return Payload(schemaVersion: 1, runs: [])
        }

        guard !data.isEmpty else {
            markLoadFailure(Self.persistenceError("workflow-runs.json is empty."))
            return Payload(schemaVersion: 1, runs: [])
        }

        do {
            let payload = try decoder.decode(Payload.self, from: data)
            loadFailed = false
            return Payload(schemaVersion: payload.schemaVersion, runs: payload.runs)
        } catch {
            markLoadFailure(error)
            return Payload(schemaVersion: 1, runs: [])
        }
    }

    private func save(_ payload: Payload) {
        guard !loadFailed else {
            CompanionPersistenceAlert.reportSaveBlocked(context: "工作流记录")
            return
        }

        do {
            try fileManager.createDirectory(at: url().deletingLastPathComponent(), withIntermediateDirectories: true)
            let sorted = payload.runs
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(maxRuns)
            let next = Payload(schemaVersion: 1, runs: Array(sorted))
            let data = try encoder.encode(next)
            try data.write(to: url(), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url().path)
        } catch {
            NSLog("Companion workflow run history failed: \(error.localizedDescription)")
        }
    }

    private func lockURL() -> URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(".workflow-runs.lock")
    }

    private func withFileLock<T>(_ body: () -> T) -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try? fileManager.createDirectory(at: url().deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(lockURL().path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return body()
        }
        Darwin.lockf(fd, F_LOCK, 0)
        defer {
            Darwin.lockf(fd, F_ULOCK, 0)
            Darwin.close(fd)
        }
        return body()
    }

    private func markLoadFailure(_ error: Error) {
        loadFailed = true
        CompanionDataBackup.backupUnreadableFile(at: url(), fileManager: fileManager)
        CompanionPersistenceAlert.reportLoadFailure(context: "工作流记录", error: error)
    }

    private static func persistenceError(_ message: String) -> Error {
        NSError(domain: "CompanionPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func redactedForDiagnostics(_ run: CompanionWorkflowRunRecord) -> CompanionWorkflowRunRecord {
        var next = run
        next.inputSummary = run.inputSummary.isEmpty ? "" : "summaryLength=\(run.inputSummary.count)"
        next.outputSummary = run.outputSummary.isEmpty ? "" : "summaryLength=\(run.outputSummary.count)"
        next.errorSummary = run.errorSummary.map { "summaryLength=\($0.count)" }
        next.steps = run.steps.map { step in
            var redacted = step
            redacted.inputSummary = step.inputSummary.isEmpty ? "" : "summaryLength=\(step.inputSummary.count)"
            redacted.outputSummary = step.outputSummary.isEmpty ? "" : "summaryLength=\(step.outputSummary.count)"
            redacted.errorSummary = step.errorSummary.map { "summaryLength=\($0.count)" }
            return redacted
        }
        return next
    }

    private static func requiredFlag(for step: CompanionWorkflowStepRecord) -> Bool {
        if let required = step.required {
            return required
        }
        return defaultRequiredFlag(toolID: step.toolID, title: step.title)
    }

    private static func defaultRequiredFlag(toolID: String?, title: String) -> Bool {
        switch toolID {
        case "companion.journal.appendToday",
             "companion.reminder.create",
             "companion.reminder.createBatch",
             "companion.pomodoro.startFocus",
             "companion.asset.upload":
            return true
        case "companion.reminder.parseDraft",
             "companion.focusReview.generate":
            return false
        case nil:
            let normalizedTitle = title.lowercased()
            return !normalizedTitle.contains("present")
                && !normalizedTitle.contains("clipboard")
                && !normalizedTitle.contains("preview")
                && !normalizedTitle.contains("展示")
                && !normalizedTitle.contains("复制")
        default:
            return true
        }
    }

    private static func refreshRunStatusAfterInteractiveStepChange(_ run: inout CompanionWorkflowRunRecord, now: Date) {
        let requiredFailures = run.steps.filter { step in
            requiredFlag(for: step) && step.status == .failed
        }
        if !requiredFailures.isEmpty {
            run.status = .failed
            run.errorSummary = requiredFailures.first?.errorSummary
            run.finishedAt = now
            return
        }

        let terminalStatuses: Set<CompanionWorkflowStepStatus> = [.succeeded, .skipped, .cancelled]
        if run.steps.allSatisfy({ terminalStatuses.contains($0.status) }) {
            run.status = run.steps.contains(where: { $0.status == .cancelled }) ? .cancelled : .completed
            run.errorSummary = nil
            run.outputSummary = run.steps
                .filter { $0.status == .succeeded && !$0.outputSummary.isEmpty }
                .map(\.outputSummary)
                .joined(separator: "; ")
            run.finishedAt = now
        } else {
            run.status = .blocked
            run.errorSummary = "Workflow recovery requires retry or cancellation."
            run.finishedAt = nil
        }
    }

    static func argumentSummary(_ arguments: CompanionJSONObject) -> String {
        let parts = arguments
            .filter { $0.key != "dryRun" && $0.key != "dry_run" }
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(safeToken(key, maxLength: 40)):\(valueSummary(value, key: key))"
            }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    static func outputSummary(_ output: CompanionJSONObject) -> String {
        var parts = [String]()

        if let items = output["itemResults"]?.arrayValue, !items.isEmpty {
            let statuses = items.compactMap { item -> String? in
                guard let obj = item.objectValue,
                      let index = obj["index"]?.intValue,
                      let status = obj["status"]?.stringValue else { return nil }
                return "i\(index)=\(safeToken(status, maxLength: 24))"
            }
            if !statuses.isEmpty {
                parts.append("items:[\(statuses.joined(separator: ", "))]")
            }
        }

        let keys = output.keys.map { safeToken($0, maxLength: 40) }.sorted().joined(separator: ",")
        parts.append(keys.isEmpty ? "output:none" : "outputKeys:\(keys)")

        return parts.joined(separator: "; ")
    }

    static func toolResultSummary(_ result: CompanionWorkflowToolResult) -> String {
        if let batchSummary = reminderBatchOutputSummary(result.output) {
            return "status=\(result.status.rawValue); \(batchSummary)"
        }
        return "status=\(result.status.rawValue); \(outputSummary(result.output))"
    }

    private static func reminderBatchOutputSummary(_ output: CompanionJSONObject) -> String? {
        guard let itemResults = output["itemResults"]?.arrayValue else { return nil }
        let requested = output["requestedCount"]?.intValue ?? itemResults.count
        let valid = output["validCount"]?.intValue ?? 0
        let invalid = output["invalidCount"]?.intValue ?? 0
        let created = output["createdCount"]?.intValue ?? 0
        let skipped = output["skippedCount"]?.intValue ?? 0
        let failed = output["failedCount"]?.intValue ?? 0
        let itemStatuses = itemResults
            .prefix(20)
            .compactMap(batchItemStatusSummary)
            .joined(separator: ",")
        let suffix = itemResults.count > 20 ? ",..." : ""
        return [
            "reminderBatch requested=\(requested)",
            "valid=\(valid)",
            "invalid=\(invalid)",
            "created=\(created)",
            "skipped=\(skipped)",
            "failed=\(failed)",
            "items=\(itemStatuses)\(suffix)"
        ].joined(separator: "; ")
    }

    private static func batchItemStatusSummary(_ value: CompanionJSONValue) -> String? {
        guard let object = value.objectValue,
              let index = object["index"]?.intValue
        else {
            return nil
        }
        let status = safeToken(object["status"]?.stringValue ?? "unknown", maxLength: 24)
        return "\(index):\(status)"
    }

    static func safeSummary(_ value: String, maxLength: Int = 160) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "..."
    }

    static func errorSummary(_ error: CompanionWorkflowToolError) -> String {
        let code = safeToken(error.code, maxLength: 80)
        return "code=\(code); messageLength=\(error.message.count)"
    }

    private static func valueSummary(_ value: CompanionJSONValue, key: String?) -> String {
        if let key, isSensitiveKey(key) {
            return "redacted"
        }
        switch value {
        case .string(let string):
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if key?.lowercased().contains("date") == true || key?.lowercased().contains("time") == true {
                return safeSummary(normalized, maxLength: 48)
            }
            let digest = SHA256.hash(data: Data(normalized.utf8))
                .compactMap { String(format: "%02x", $0) }
                .joined()
                .prefix(10)
            return "string(\(normalized.count) chars, sha256:\(digest))"
        case .number(let value):
            return value.rounded() == value ? "integer" : "number"
        case .bool(let value):
            return "bool(\(value ? "true" : "false"))"
        case .array(let values):
            return "array(\(values.count))"
        case .object(let object):
            let keys = object.keys.map { safeToken($0, maxLength: 24) }.sorted().prefix(6).joined(separator: ",")
            return keys.isEmpty ? "object(empty)" : "object(keys:\(keys))"
        case .null:
            return "null"
        }
    }

    private static func followUpActions(toolID: String?, result: CompanionWorkflowToolResult) -> [CompanionWorkflowFollowUpAction] {
        guard result.status == .succeeded else {
            return result.status == .blocked && toolID == "companion.pomodoro.startFocus" ? [.openPomodoro] : []
        }
        switch toolID {
        case "companion.reminder.create", "companion.reminder.createBatch":
            return [.openReminders, .copyResult]
        case "companion.journal.appendToday":
            return [.openJournal, .copyResult]
        case "companion.pomodoro.startFocus":
            return [.openPomodoro, .copyResult]
        default:
            return [.copyResult]
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return [
            "api_key",
            "apikey",
            "auth",
            "authorization",
            "bearer",
            "cookie",
            "key",
            "password",
            "providersecret",
            "refresh_token",
            "secret",
            "session",
            "token"
        ].contains { normalized.contains($0) }
    }

    private static func safeHumanTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return safeSummary(trimmed.isEmpty ? fallback : trimmed, maxLength: 80)
    }

    private static func safeToken(_ value: String, maxLength: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars)
        guard sanitized.count > maxLength else { return sanitized }
        return String(sanitized.prefix(maxLength))
    }
}
