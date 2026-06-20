import CryptoKit
import Darwin
import Foundation

struct CompanionMCPAuditParameterSummary: Codable, Equatable {
    var key: String
    var summary: String
}

struct CompanionMCPAuditRecord: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var id: UUID
    var timestamp: Date
    var caller: String
    var toolID: String
    var risk: CompanionWorkflowToolRisk
    var dryRun: Bool
    var status: CompanionWorkflowToolResult.Status
    var parameterSummary: [CompanionMCPAuditParameterSummary]
    var resultSummary: String
    var errorSummary: String?
    var usedStoredApproval: Bool?

    init(
        schemaVersion: Int,
        id: UUID,
        timestamp: Date,
        caller: String,
        toolID: String,
        risk: CompanionWorkflowToolRisk,
        dryRun: Bool,
        status: CompanionWorkflowToolResult.Status,
        parameterSummary: [CompanionMCPAuditParameterSummary],
        resultSummary: String,
        errorSummary: String?,
        usedStoredApproval: Bool?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.caller = caller
        self.toolID = toolID
        self.risk = risk
        self.dryRun = dryRun
        self.status = status
        self.parameterSummary = parameterSummary
        self.resultSummary = resultSummary
        self.errorSummary = errorSummary
        self.usedStoredApproval = usedStoredApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        caller = try container.decode(String.self, forKey: .caller)
        toolID = try container.decode(String.self, forKey: .toolID)
        risk = try container.decode(CompanionWorkflowToolRisk.self, forKey: .risk)
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        status = try container.decode(CompanionWorkflowToolResult.Status.self, forKey: .status)
        parameterSummary = try container.decode([CompanionMCPAuditParameterSummary].self, forKey: .parameterSummary)
        resultSummary = try container.decode(String.self, forKey: .resultSummary)
        errorSummary = try container.decodeIfPresent(String.self, forKey: .errorSummary)
        usedStoredApproval = try container.decodeIfPresent(Bool.self, forKey: .usedStoredApproval)
    }
}

final class CompanionMCPAuditLog {
    static let fileName = "mcp-audit-log.jsonl"
    private static let maxLogBytes: Int64 = 5 * 1024 * 1024
    private static let maxTailReadBytes: UInt64 = 1 * 1024 * 1024
    private static let retainedRotations = 3

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
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(
        caller: String?,
        toolID: String,
        risk: CompanionWorkflowToolRisk,
        arguments: CompanionJSONObject,
        dryRun: Bool,
        result: CompanionWorkflowToolResult,
        usedStoredApproval: Bool? = nil,
        now: Date = Date()
    ) {
        let record = CompanionMCPAuditRecord(
            schemaVersion: usedStoredApproval == nil ? 1 : 2,
            id: UUID(),
            timestamp: now,
            caller: sanitizedCaller(caller),
            toolID: toolID,
            risk: risk,
            dryRun: dryRun,
            status: result.status,
            parameterSummary: Self.parameterSummary(arguments),
            resultSummary: Self.resultSummary(result),
            errorSummary: Self.errorSummary(result.error),
            usedStoredApproval: usedStoredApproval
        )
        append(record)
    }

    func append(_ record: CompanionMCPAuditRecord) {
        do {
            let targetURL = logURL()
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(record)
            data.append(10)
            try rotateIfNeeded(appendingByteCount: data.count)
            try appendAtomically(data, to: targetURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        } catch {
            NSLog("Companion MCP audit log failed: \(error.localizedDescription)")
        }
    }

    func records(limit: Int = 500) -> [CompanionMCPAuditRecord] {
        guard let text = try? tailText(maxBytes: Self.maxTailReadBytes) else {
            return []
        }
        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(CompanionMCPAuditRecord.self, from: data)
            }
    }

    func url() -> URL {
        logURL()
    }

    func fileSize() -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL().path)
        return attributes?[.size] as? Int64 ?? 0
    }

    func latestRecord() -> CompanionMCPAuditRecord? {
        records(limit: 1).last
    }

    func latestProblemRecord(limit: Int = 500) -> CompanionMCPAuditRecord? {
        records(limit: limit).reversed().first { record in
            record.status == .failed || record.status == .blocked || record.status == .denied
        }
    }

    func clear() {
        try? fileManager.removeItem(at: logURL())
    }

    func diagnosticJSONL(limit: Int = 500) -> String? {
        let records = records(limit: limit)
        guard !records.isEmpty else { return nil }
        let lines = records.compactMap { record -> String? in
            guard let data = try? encoder.encode(record) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func logURL() -> URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    private func tailText(maxBytes: UInt64) throws -> String {
        let url = logURL()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - maxBytes : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if offset > 0, let newline = data.firstIndex(of: 10) {
            data.removeSubrange(data.startIndex...newline)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func appendAtomically(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }

        let written = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, baseAddress, rawBuffer.count)
        }
        guard written == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func rotateIfNeeded(appendingByteCount: Int) throws {
        let targetURL = logURL()
        let attributes = try? fileManager.attributesOfItem(atPath: targetURL.path)
        let currentSize = attributes?[.size] as? Int64 ?? 0
        guard currentSize + Int64(appendingByteCount) > Self.maxLogBytes else {
            return
        }

        for index in stride(from: Self.retainedRotations, through: 1, by: -1) {
            let rotatedURL = rotatedLogURL(index)
            if index == Self.retainedRotations, fileManager.fileExists(atPath: rotatedURL.path) {
                try? fileManager.removeItem(at: rotatedURL)
            }
            let previousURL = index == 1 ? targetURL : rotatedLogURL(index - 1)
            guard fileManager.fileExists(atPath: previousURL.path) else {
                continue
            }
            try? fileManager.moveItem(at: previousURL, to: rotatedURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedURL.path)
        }
    }

    private func rotatedLogURL(_ index: Int) -> URL {
        logURL().deletingLastPathComponent().appendingPathComponent("\(Self.fileName).\(index)")
    }

    private func sanitizedCaller(_ caller: String?) -> String {
        let value = caller?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return "unknown" }
        return Self.safeToken(value, maxLength: 80)
    }

    private static func parameterSummary(_ arguments: CompanionJSONObject) -> [CompanionMCPAuditParameterSummary] {
        arguments
            .filter { $0.key != "dryRun" && $0.key != "dry_run" }
            .sorted { $0.key < $1.key }
            .map { key, value in
                CompanionMCPAuditParameterSummary(
                    key: safeToken(key, maxLength: 80),
                    summary: summarize(value, key: key)
                )
            }
    }

    private static func summarize(_ value: CompanionJSONValue, key: String?) -> String {
        if let key, isSensitiveKey(key) {
            return "redacted"
        }

        switch value {
        case .string(let string):
            return stringSummary(string)
        case .number(let number):
            return number.rounded() == number ? "integer" : "number"
        case .bool(let bool):
            return "bool(\(bool ? "true" : "false"))"
        case .array(let values):
            return "array(\(values.count) item\(values.count == 1 ? "" : "s"))"
        case .object(let object):
            let keys = object.keys
                .map { safeToken($0, maxLength: 40) }
                .sorted()
                .prefix(8)
                .joined(separator: ",")
            return keys.isEmpty ? "object(empty)" : "object(keys:\(keys))"
        case .null:
            return "null"
        }
    }

    private static func stringSummary(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return "string(\(normalized.count) chars, sha256:\(digest))"
    }

    private static func resultSummary(_ result: CompanionWorkflowToolResult) -> String {
        let keys = result.output.keys
            .map { safeToken($0, maxLength: 40) }
            .sorted()
            .prefix(12)
            .joined(separator: ",")
        let outputKeys = keys.isEmpty ? "none" : keys
        return "status=\(result.status.rawValue); outputKeys=\(outputKeys); summaryLength=\(result.outputSummary.count)"
    }

    private static func errorSummary(_ error: CompanionWorkflowToolError?) -> String? {
        guard let error else { return nil }
        let code = safeToken(error.code, maxLength: 80)
        return "code=\(code); messageLength=\(error.message.count)"
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
            "experimental_bearer_token",
            "key",
            "openai_api_key",
            "password",
            "providersecret",
            "refresh_token",
            "refreshtoken",
            "secret",
            "session",
            "token"
        ].contains { normalized.contains($0) }
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
