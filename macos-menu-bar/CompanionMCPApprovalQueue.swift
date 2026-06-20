import Darwin
import Foundation

enum CompanionExternalToolCallStatus: String, Codable, Equatable {
    case pending
    case prompting
    case approved
    case denied
    case expired
    case completed
    case failed

    var isTerminal: Bool {
        switch self {
        case .denied, .expired, .completed, .failed:
            return true
        case .pending, .prompting, .approved:
            return false
        }
    }
}

struct CompanionExternalToolCallRecord: Codable, Identifiable, Equatable {
    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date
    var caller: String
    var toolID: String
    var toolTitle: String
    var risk: CompanionWorkflowToolRisk
    var arguments: CompanionJSONObject
    var runID: UUID?
    var status: CompanionExternalToolCallStatus
    var result: CompanionWorkflowToolResult?
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date,
        caller: String,
        toolID: String,
        toolTitle: String,
        risk: CompanionWorkflowToolRisk,
        arguments: CompanionJSONObject,
        runID: UUID? = nil,
        status: CompanionExternalToolCallStatus = .pending,
        result: CompanionWorkflowToolResult? = nil,
        statusMessage: String? = nil
    ) {
        self.schemaVersion = 1
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.expiresAt = expiresAt
        self.caller = caller
        self.toolID = toolID
        self.toolTitle = toolTitle
        self.risk = risk
        self.arguments = arguments
        self.runID = runID
        self.status = status
        self.result = result
        self.statusMessage = statusMessage
    }
}

final class CompanionExternalToolCallQueue {
    static let didEnqueueDistributedNotification = Notification.Name("com.crazyjal.companion.mcpToolCallQueued")

    private struct Heartbeat: Codable {
        var updatedAt: Date
        var processIdentifier: Int32?
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func refreshHeartbeat(now: Date = Date(), processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) {
        do {
            try ensureDirectory()
            let data = try encoder.encode(Heartbeat(updatedAt: now, processIdentifier: processIdentifier))
            try data.write(to: heartbeatURL(), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: heartbeatURL().path)
        } catch {
            NSLog("Companion MCP heartbeat failed: \(error.localizedDescription)")
        }
    }

    func clearHeartbeat() {
        try? fileManager.removeItem(at: heartbeatURL())
    }

    func hasFreshHeartbeat(now: Date = Date(), maxAge: TimeInterval = 15) -> Bool {
        guard let data = try? Data(contentsOf: heartbeatURL()),
              let heartbeat = try? decoder.decode(Heartbeat.self, from: data)
        else {
            return false
        }
        let age = now.timeIntervalSince(heartbeat.updatedAt)
        guard age >= 0, age <= maxAge else {
            return false
        }
        guard let processIdentifier = heartbeat.processIdentifier else {
            return true
        }
        return Self.processExists(processIdentifier)
    }

    func enqueue(
        toolID: String,
        toolTitle: String,
        risk: CompanionWorkflowToolRisk,
        arguments: CompanionJSONObject,
        caller: String,
        timeout: TimeInterval,
        runID: UUID? = nil,
        now: Date = Date()
    ) throws -> CompanionExternalToolCallRecord {
        try ensureDirectory()
        let record = CompanionExternalToolCallRecord(
            createdAt: now,
            expiresAt: now.addingTimeInterval(timeout),
            caller: caller,
            toolID: toolID,
            toolTitle: toolTitle,
            risk: risk,
            arguments: arguments,
            runID: runID
        )
        try save(record)
        DistributedNotificationCenter.default().postNotificationName(
            Self.didEnqueueDistributedNotification,
            object: nil,
            userInfo: ["id": record.id.uuidString],
            deliverImmediately: true
        )
        return record
    }

    func pendingRecords(now: Date = Date()) -> [CompanionExternalToolCallRecord] {
        loadRecords()
            .filter { record in
                switch record.status {
                case .pending:
                    return record.expiresAt > now
                case .prompting, .approved:
                    return true
                case .denied, .expired, .completed, .failed:
                    return false
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func expireStalePending(now: Date = Date()) {
        for var record in loadRecords() where !record.status.isTerminal && record.expiresAt <= now {
            record.status = .expired
            record.updatedAt = now
            record.statusMessage = "The local approval request expired."
            record.result = .denied(
                code: "approval_expired",
                message: "Companion local approval expired before the request was confirmed.",
                output: [
                    "tool": .string(record.toolID),
                    "approvalExpired": .bool(true)
                ]
            )
            try? save(record)
        }
    }

    /// One-pass maintenance + load used by the main-app polling loop.
    /// - Expires stale non-terminal records (same effect as `expireStalePending`).
    /// - Prunes terminal records that have lingered on disk longer than
    ///   `retainInterval` — orphans the MCP helper never deleted (it timed out,
    ///   was killed, or the main app expired the record after the helper left).
    /// - Returns the still-actionable pending records (same filter as `pendingRecords`).
    /// Reads the queue directory only ONCE, so the timer no longer enumerates and
    /// decodes every file twice on the main thread each tick.
    func sweepAndLoadPending(now: Date = Date(), retainTerminalFor retainInterval: TimeInterval = 300) -> [CompanionExternalToolCallRecord] {
        var pending: [CompanionExternalToolCallRecord] = []
        for record in loadRecords() {
            if record.status.isTerminal {
                if now.timeIntervalSince(record.updatedAt) > retainInterval {
                    deleteRecord(id: record.id)
                }
                continue
            }

            if record.expiresAt <= now {
                var expired = record
                expired.status = .expired
                expired.updatedAt = now
                expired.statusMessage = "The local approval request expired."
                expired.result = .denied(
                    code: "approval_expired",
                    message: "Companion local approval expired before the request was confirmed.",
                    output: [
                        "tool": .string(record.toolID),
                        "approvalExpired": .bool(true)
                    ]
                )
                try? save(expired)
                continue
            }

            pending.append(record)
        }
        return pending.sorted { $0.createdAt < $1.createdAt }
    }

    func waitForTerminalRecord(
        id: UUID,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        now: () -> Date = Date.init
    ) -> CompanionExternalToolCallRecord? {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            if let record = loadRecord(id: id), record.status.isTerminal {
                return record
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        guard let record = loadRecord(id: id), record.status.isTerminal else {
            return nil
        }
        return record
    }

    func loadRecord(id: UUID) -> CompanionExternalToolCallRecord? {
        guard let data = try? Data(contentsOf: recordURL(id: id)) else { return nil }
        return try? decoder.decode(CompanionExternalToolCallRecord.self, from: data)
    }

    func save(_ record: CompanionExternalToolCallRecord) throws {
        try ensureDirectory()
        var next = record
        next.updatedAt = Date()
        let data = try encoder.encode(next)
        let url = recordURL(id: record.id)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func deleteRecord(id: UUID) {
        try? fileManager.removeItem(at: recordURL(id: id))
    }

    private func loadRecords() -> [CompanionExternalToolCallRecord] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: queueDirectory(),
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "heartbeat.json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CompanionExternalToolCallRecord.self, from: data)
            }
    }

    private func ensureDirectory() throws {
        removeLegacyDataRootQueueDirectoryIfNeeded()
        try fileManager.createDirectory(at: queueDirectory(), withIntermediateDirectories: true)
    }

    private func queueDirectory() -> URL {
        CompanionDataRoot.supportDirectory(environment: environment)
            .appendingPathComponent("mcp-tool-calls", isDirectory: true)
    }

    private func heartbeatURL() -> URL {
        queueDirectory().appendingPathComponent("heartbeat.json")
    }

    private func recordURL(id: UUID) -> URL {
        queueDirectory().appendingPathComponent("\(id.uuidString).json")
    }

    private func removeLegacyDataRootQueueDirectoryIfNeeded() {
        let runtimePath = queueDirectory().standardizedFileURL.path
        let legacyURL = CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("mcp-tool-calls", isDirectory: true)
            .standardizedFileURL
        guard legacyURL.path != runtimePath, fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }
        try? fileManager.removeItem(at: legacyURL)
    }

    private static func processExists(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if Darwin.kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
