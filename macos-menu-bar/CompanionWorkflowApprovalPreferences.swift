import Foundation
import CryptoKit

// MARK: - Workflow Approval Preferences

struct WorkflowApprovalPreference: Codable, Equatable {
    var toolID: String
    var risk: CompanionWorkflowToolRisk
    var approvedAt: Date
    var approvalCount: Int

    init(toolID: String, risk: CompanionWorkflowToolRisk, approvedAt: Date = Date(), approvalCount: Int = 1) {
        self.toolID = toolID
        self.risk = risk
        self.approvedAt = approvedAt
        self.approvalCount = approvalCount
    }
}

final class WorkflowApprovalPreferencesStore {
    static let fileName = "workflow-approval-prefs.json"

    private struct Payload: Codable {
        var schemaVersion: Int
        var preferences: [String: WorkflowApprovalPreference]  // toolID -> preference
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cache: [String: WorkflowApprovalPreference] = [:]
    private var cacheLoaded = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func url() -> URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    // 检查工具是否已授权
    func isApproved(toolID: String, risk: CompanionWorkflowToolRisk) -> Bool {
        ensureLoaded()

        // 高风险动作永远不可记住
        guard risk == .localWrite || risk == .localSession else {
            return false
        }

        // 检查是否在授权列表中
        guard let pref = cache[toolID] else {
            return false
        }

        // 验证风险等级匹配
        return pref.risk == risk
    }

    // 添加授权
    func approve(toolID: String, risk: CompanionWorkflowToolRisk) {
        ensureLoaded()

        // 高风险动作不可记住
        guard risk == .localWrite || risk == .localSession else {
            return
        }

        if let existing = cache[toolID] {
            cache[toolID] = WorkflowApprovalPreference(
                toolID: toolID,
                risk: risk,
                approvedAt: existing.approvedAt,
                approvalCount: existing.approvalCount + 1
            )
        } else {
            cache[toolID] = WorkflowApprovalPreference(
                toolID: toolID,
                risk: risk,
                approvedAt: Date(),
                approvalCount: 1
            )
        }

        save()
    }

    // 撤销授权
    func revoke(toolID: String) {
        ensureLoaded()
        cache.removeValue(forKey: toolID)
        save()
    }

    // 清空所有授权
    func revokeAll() {
        cache.removeAll()
        save()
    }

    // 获取所有授权
    func allPreferences() -> [WorkflowApprovalPreference] {
        ensureLoaded()
        return Array(cache.values).sorted { $0.approvedAt > $1.approvedAt }
    }

    // MARK: - Private

    private func ensureLoaded() {
        guard !cacheLoaded else { return }
        cache = loadPayload().preferences
        cacheLoaded = true
    }

    private func loadPayload() -> Payload {
        let fileURL = url()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, preferences: [:])
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try decoder.decode(Payload.self, from: data)

            // 版本检查
            guard payload.schemaVersion == 1 else {
                backupCorruptFile(fileURL)
                return Payload(schemaVersion: 1, preferences: [:])
            }

            return payload
        } catch {
            backupCorruptFile(fileURL)
            return Payload(schemaVersion: 1, preferences: [:])
        }
    }

    private func save() {
        let payload = Payload(schemaVersion: 1, preferences: cache)
        let fileURL = url()

        do {
            let data = try encoder.encode(payload)
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(Self.fileName).tmp")

            // 确保目录存在
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try data.write(to: tempURL, options: .atomic)

            // 首次写入时目标文件不存在，直接移动而非替换
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            // 写入失败，但不影响运行
            print("Failed to save workflow approval preferences: \(error)")
        }
    }

    private func backupCorruptFile(_ fileURL: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.fileName).corrupt-\(timestamp).json")

        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }
}

// MARK: - MCP Client Profiles

struct MCPClientProfile: Codable, Equatable, Identifiable {
    var id: String  // fingerprint
    var clientName: String
    var commandSummary: String
    var allowedTools: Set<String>
    var createdAt: Date
    var lastSeenAt: Date
    var approvalCount: Int

    var displayName: String {
        if !clientName.isEmpty {
            return clientName
        }
        return commandSummary.isEmpty ? "Unknown Client" : commandSummary
    }
}

final class MCPClientProfilesStore {
    static let fileName = "mcp-client-profiles.json"

    private struct Payload: Codable {
        var schemaVersion: Int
        var profiles: [String: MCPClientProfile]  // fingerprint -> profile
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cache: [String: MCPClientProfile] = [:]
    private var cacheLoaded = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func url() -> URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    // 生成 client fingerprint
    func generateFingerprint(clientName: String, commandPath: String, argv: [String]) -> String {
        let stableArgv = filterStableArgv(argv)
        let combined = "\(clientName)|\(commandPath)|\(stableArgv.joined(separator: "|"))"
        let hash = SHA256.hash(data: Data(combined.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // 检查 client 是否有权限调用工具
    func isToolAllowed(fingerprint: String, toolID: String, risk: CompanionWorkflowToolRisk) -> Bool {
        ensureLoaded()

        // 高风险动作永远不可记住
        guard risk == .localWrite || risk == .localSession else {
            return false
        }

        guard let profile = cache[fingerprint] else {
            return false
        }

        return profile.allowedTools.contains(toolID)
    }

    func isAssetUploadAllowed(
        fingerprint: String,
        profileID: String,
        profileConfigHash: String,
        selectedMaxSizeBytes: Int
    ) -> Bool {
        ensureLoaded()
        guard let profile = cache[fingerprint] else {
            return false
        }
        return profile.allowedTools.contains { token in
            guard let scope = Self.assetUploadApprovalScope(from: token) else {
                return false
            }
            return scope.profileID == profileID
                && scope.profileConfigHash == profileConfigHash
                && selectedMaxSizeBytes <= scope.maxSizeBytes
        }
    }

    // 授权 client 调用工具
    func allowTool(
        fingerprint: String,
        toolID: String,
        clientName: String,
        commandSummary: String,
        risk: CompanionWorkflowToolRisk
    ) {
        ensureLoaded()

        // 高风险动作不可记住
        guard risk == .localWrite || risk == .localSession else {
            return
        }

        let now = Date()

        if var profile = cache[fingerprint] {
            profile.allowedTools.insert(toolID)
            profile.lastSeenAt = now
            profile.approvalCount += 1
            cache[fingerprint] = profile
        } else {
            cache[fingerprint] = MCPClientProfile(
                id: fingerprint,
                clientName: clientName,
                commandSummary: commandSummary,
                allowedTools: [toolID],
                createdAt: now,
                lastSeenAt: now,
                approvalCount: 1
            )
        }

        save()
    }

    func allowAssetUpload(
        fingerprint: String,
        clientName: String,
        commandSummary: String,
        profileID: String,
        profileConfigHash: String,
        maxSizeBytes: Int
    ) {
        ensureLoaded()
        let token = Self.assetUploadApprovalToken(
            profileID: profileID,
            profileConfigHash: profileConfigHash,
            maxSizeBytes: maxSizeBytes
        )
        let now = Date()

        if var profile = cache[fingerprint] {
            profile.allowedTools = profile.allowedTools.filter { existing in
                guard let scope = Self.assetUploadApprovalScope(from: existing) else {
                    return true
                }
                return scope.profileID != profileID || scope.profileConfigHash != profileConfigHash
            }
            profile.allowedTools.insert(token)
            profile.lastSeenAt = now
            profile.approvalCount += 1
            cache[fingerprint] = profile
        } else {
            cache[fingerprint] = MCPClientProfile(
                id: fingerprint,
                clientName: clientName,
                commandSummary: commandSummary,
                allowedTools: [token],
                createdAt: now,
                lastSeenAt: now,
                approvalCount: 1
            )
        }

        save()
    }

    // 撤销 client 的所有授权
    func revokeClient(fingerprint: String) {
        ensureLoaded()
        cache.removeValue(forKey: fingerprint)
        save()
    }

    // 撤销 client 的特定工具授权
    func revokeTool(fingerprint: String, toolID: String) {
        ensureLoaded()

        guard var profile = cache[fingerprint] else {
            return
        }

        profile.allowedTools.remove(toolID)

        if profile.allowedTools.isEmpty {
            cache.removeValue(forKey: fingerprint)
        } else {
            cache[fingerprint] = profile
        }

        save()
    }

    func revokeAssetUpload(profileID: String) {
        ensureLoaded()
        for fingerprint in Array(cache.keys) {
            guard var profile = cache[fingerprint] else { continue }
            profile.allowedTools = profile.allowedTools.filter { token in
                guard let scope = Self.assetUploadApprovalScope(from: token) else {
                    return true
                }
                return scope.profileID != profileID
            }
            if profile.allowedTools.isEmpty {
                cache.removeValue(forKey: fingerprint)
            } else {
                cache[fingerprint] = profile
            }
        }
        save()
    }

    // 清空所有授权
    func revokeAll() {
        cache.removeAll()
        save()
    }

    // 更新 lastSeenAt
    func updateLastSeen(fingerprint: String) {
        ensureLoaded()

        guard var profile = cache[fingerprint] else {
            return
        }

        profile.lastSeenAt = Date()
        cache[fingerprint] = profile
        save()
    }

    // 获取所有 profiles
    func allProfiles() -> [MCPClientProfile] {
        ensureLoaded()
        return Array(cache.values).sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    // MARK: - Private

    private func ensureLoaded() {
        guard !cacheLoaded else { return }
        cache = loadPayload().profiles
        cacheLoaded = true
    }

    private func loadPayload() -> Payload {
        let fileURL = url()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, profiles: [:])
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try decoder.decode(Payload.self, from: data)

            guard payload.schemaVersion == 1 else {
                backupCorruptFile(fileURL)
                return Payload(schemaVersion: 1, profiles: [:])
            }

            return payload
        } catch {
            backupCorruptFile(fileURL)
            return Payload(schemaVersion: 1, profiles: [:])
        }
    }

    private func save() {
        let payload = Payload(schemaVersion: 1, profiles: cache)
        let fileURL = url()

        do {
            let data = try encoder.encode(payload)
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(Self.fileName).tmp")

            // 确保目录存在
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try data.write(to: tempURL, options: .atomic)

            // 首次写入时目标文件不存在，直接移动而非替换
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            print("Failed to save MCP client profiles: \(error)")
        }
    }

    private func backupCorruptFile(_ fileURL: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.fileName).corrupt-\(timestamp).json")

        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }

    // 过滤出稳定的 argv 参数
    private func filterStableArgv(_ argv: [String]) -> [String] {
        argv.filter { arg in
            // 忽略临时目录
            if arg.contains("/tmp/") || arg.contains("/var/folders/") {
                return false
            }
            // 忽略随机端口
            if arg.contains(":") && arg.split(separator: ":").last?.allSatisfy({ $0.isNumber }) == true {
                return false
            }
            // 忽略 session id / UUID 模式
            if arg.contains("-") && arg.components(separatedBy: "-").count >= 4 {
                return false
            }
            // 忽略时间戳
            if arg.allSatisfy({ $0.isNumber }) && arg.count > 8 {
                return false
            }
            return true
        }
    }

    private struct AssetUploadApprovalScope {
        var profileID: String
        var profileConfigHash: String
        var maxSizeBytes: Int
    }

    private static func assetUploadApprovalToken(
        profileID: String,
        profileConfigHash: String,
        maxSizeBytes: Int
    ) -> String {
        let escapedProfile = profileID.replacingOccurrences(of: "|", with: "_")
        let escapedHash = profileConfigHash.replacingOccurrences(of: "|", with: "_")
        return "companion.asset.upload|\(escapedProfile)|\(escapedHash)|\(max(0, maxSizeBytes))"
    }

    private static func assetUploadApprovalScope(from token: String) -> AssetUploadApprovalScope? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] == "companion.asset.upload",
              let maxSizeBytes = Int(parts[3])
        else {
            return nil
        }
        return AssetUploadApprovalScope(
            profileID: parts[1],
            profileConfigHash: parts[2],
            maxSizeBytes: maxSizeBytes
        )
    }
}
