import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum CompanionAssetUploadProfileType: String, Codable, Equatable {
    case s3Compatible
    case customHTTP
}

struct CompanionAssetUploadProfilesDocument: Codable, Equatable {
    var schemaVersion: Int
    var defaultProfileID: String?
    var profiles: [CompanionAssetUploadProfile]
    var lastModified: Date

    static func empty(now: Date = Date()) -> CompanionAssetUploadProfilesDocument {
        CompanionAssetUploadProfilesDocument(
            schemaVersion: 1,
            defaultProfileID: nil,
            profiles: [],
            lastModified: now
        )
    }
}

struct CompanionAssetUploadProfile: Codable, Equatable, Identifiable {
    struct Limits: Codable, Equatable {
        var maxSizeBytes: Int
        var allowedMimeTypes: [String]?

        static let defaultMaxSizeBytes = 25 * 1024 * 1024
        static let maximumSynchronousUploadBytes = 100 * 1024 * 1024
        static let maximumSynchronousUploadMegabytes = maximumSynchronousUploadBytes / (1024 * 1024)

        static var `default`: Limits {
            Limits(maxSizeBytes: defaultMaxSizeBytes, allowedMimeTypes: nil)
        }
    }

    struct S3Config: Codable, Equatable {
        var endpoint: String
        var region: String
        var bucket: String
        var pathPrefix: String
        var publicBaseURL: String?
        var usePathStyle: Bool
        var credentialReference: String?
        // Legacy fields are decoded for local migration. New saves keep values in Companion's local data directory.
        var accessKeyID: String?
        var secretAccessKey: String?
    }

    struct CustomHTTPConfig: Codable, Equatable {
        enum Method: String, Codable {
            case post = "POST"
            case put = "PUT"
        }

        enum BodyMode: String, Codable {
            case multipart
            case rawFile
        }

        var uploadURL: String
        var method: Method
        var bodyMode: BodyMode
        var fileFieldName: String
        var additionalHeaders: [String: String]
        var sensitiveHeaderReferences: [String: String]?
        var responseURLJSONPath: String
        var publicBaseURL: String?
    }

    var id: String
    var type: CompanionAssetUploadProfileType
    var name: String
    var enabled: Bool
    var s3: S3Config?
    var customHTTP: CustomHTTPConfig?
    var limits: Limits
    var defaultOutputFormat: CompanionAssetUploadOutputFormat?
    var createdAt: Date
    var lastUsedAt: Date?

    var resolvedDefaultOutputFormat: CompanionAssetUploadOutputFormat {
        defaultOutputFormat ?? .url
    }

    var profileSummary: String {
        switch type {
        case .s3Compatible:
            let bucket = s3?.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bucket, !bucket.isEmpty {
                return "\(name) (S3: \(bucket))"
            }
            return "\(name) (S3)"
        case .customHTTP:
            return "\(name) (Custom HTTP)"
        }
    }

    var configHash: String {
        let raw: String
        switch type {
        case .s3Compatible:
            let config = s3
            raw = [
                type.rawValue,
                config?.endpoint ?? "",
                config?.region ?? "",
                config?.bucket ?? "",
                config?.pathPrefix ?? "",
                config?.publicBaseURL ?? "",
                String(config?.usePathStyle ?? false)
            ].joined(separator: "\u{001F}")
        case .customHTTP:
            let config = customHTTP
            raw = [
                type.rawValue,
                config?.uploadURL ?? "",
                config?.method.rawValue ?? "",
                config?.bodyMode.rawValue ?? "",
                config?.fileFieldName ?? "",
                config?.responseURLJSONPath ?? "",
                config?.publicBaseURL ?? ""
            ].joined(separator: "\u{001F}")
        }
        return "sha256:" + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var hasConfiguredCredentials: Bool {
        switch type {
        case .s3Compatible:
            return !(s3?.credentialReference?.isEmpty ?? true)
                || (!(s3?.accessKeyID?.isEmpty ?? true) && !(s3?.secretAccessKey?.isEmpty ?? true))
        case .customHTTP:
            return true
        }
    }
}

struct CompanionAssetUploadS3Credentials: Codable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String

    var isComplete: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum CompanionAssetUploadProfileStoreError: LocalizedError {
    case profileNotFound(String)
    case noDefaultProfile
    case profileDisabled(String)
    case profileIncomplete(String)
    case corruptProfileStore(URL)
    case credentialStoreUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "Asset upload profile not found: \(id)"
        case .noDefaultProfile:
            return "No default asset upload profile is configured."
        case .profileDisabled(let name):
            return "Asset upload profile is disabled: \(name)"
        case .profileIncomplete(let name):
            return "Asset upload profile is incomplete: \(name)"
        case .corruptProfileStore(let url):
            return "Asset upload profile store is corrupt and was backed up to \(url.lastPathComponent)."
        case .credentialStoreUnavailable(let message):
            return "Asset upload credentials are unavailable: \(message)"
        }
    }
}

protocol CompanionAssetUploadCredentialStoring {
    func credentials(reference: String) throws -> CompanionAssetUploadS3Credentials?
    func save(_ credentials: CompanionAssetUploadS3Credentials, reference: String) throws
    func secret(reference: String) throws -> String?
    func saveSecret(_ secret: String, reference: String) throws
    func delete(reference: String) throws
}

final class CompanionLocalCredentialStore: CompanionAssetUploadCredentialStoring {
    struct Document: Codable, Equatable {
        var credentials: [String: CompanionAssetUploadS3Credentials]
        var secrets: [String: String]

        static let empty = Document(credentials: [:], secrets: [:])
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let fileName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    init(
        fileName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.fileName = fileName
        self.environment = environment
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    var url: URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(fileName)
    }

    func credentials(reference: String) throws -> CompanionAssetUploadS3Credentials? {
        lock.lock()
        defer { lock.unlock() }
        return try load().credentials[reference]
    }

    func save(_ credentials: CompanionAssetUploadS3Credentials, reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try load()
        document.credentials[reference] = credentials
        try save(document)
    }

    func secret(reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try load().secrets[reference]
    }

    func saveSecret(_ secret: String, reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try load()
        document.secrets[reference] = secret
        try save(document)
    }

    func delete(reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try load()
        document.credentials[reference] = nil
        document.secrets[reference] = nil
        try save(document)
    }

    private func load() throws -> Document {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        return try decoder.decode(Document.self, from: Data(contentsOf: url))
    }

    private func save(_ document: Document) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class CompanionAssetUploadProfileStore {
    static let fileName = "asset-upload-profiles.json"

    private let environment: [String: String]
    private let fileManager: FileManager
    private let credentialStore: CompanionAssetUploadCredentialStoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        credentialStore: CompanionAssetUploadCredentialStoring? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.credentialStore = credentialStore ?? CompanionLocalCredentialStore(
            fileName: "asset-upload-credentials.json",
            environment: environment,
            fileManager: fileManager
        )
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var url: URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    func document() throws -> CompanionAssetUploadProfilesDocument {
        lock.lock()
        defer { lock.unlock() }
        return try loadDocument()
    }

    func save(_ document: CompanionAssetUploadProfilesDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveDocument(migratingCredentials(in: document, preserveExistingSensitiveHeaderReferences: false))
    }

    func migrateLegacyCredentialsIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try loadDocument()
    }

    func defaultProfile(requireCredentials: Bool = true) throws -> CompanionAssetUploadProfile {
        lock.lock()
        defer { lock.unlock() }
        let document = try loadDocument()
        guard let defaultProfileID = document.defaultProfileID else {
            throw CompanionAssetUploadProfileStoreError.noDefaultProfile
        }
        return try profile(id: defaultProfileID, in: document, requireCredentials: requireCredentials)
    }

    func profile(id: String?, requireCredentials: Bool = true) throws -> CompanionAssetUploadProfile {
        lock.lock()
        defer { lock.unlock() }
        if let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try profile(id: id, in: loadDocument(), requireCredentials: requireCredentials)
        }
        return try defaultProfile(requireCredentials: requireCredentials)
    }

    func upsert(
        _ profile: CompanionAssetUploadProfile,
        makeDefault: Bool = false,
        now: Date = Date(),
        credentials: CompanionAssetUploadS3Credentials? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try loadDocument()
        let storedProfile = try sanitizedProfile(
            profile,
            credentials: credentials,
            preserveExistingSensitiveHeaderReferences: false
        )
        if let index = document.profiles.firstIndex(where: { $0.id == profile.id }) {
            try deleteStaleCredentials(from: document.profiles[index], to: storedProfile)
            document.profiles[index] = storedProfile
        } else {
            document.profiles.append(storedProfile)
        }
        if makeDefault || document.defaultProfileID == nil {
            document.defaultProfileID = storedProfile.id
        }
        document.lastModified = now
        try saveDocument(document)
    }

    func deleteProfile(id: String, now: Date = Date()) throws -> CompanionAssetUploadProfile {
        lock.lock()
        defer { lock.unlock() }
        var document = try loadDocument()
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            throw CompanionAssetUploadProfileStoreError.profileNotFound(id)
        }
        let removed = document.profiles.remove(at: index)
        try deleteStoredCredentials(for: removed)
        if document.defaultProfileID == id {
            document.defaultProfileID = document.profiles.first?.id
        }
        document.lastModified = now
        try saveDocument(document)
        return removed
    }

    func credentials(for profile: CompanionAssetUploadProfile) throws -> CompanionAssetUploadS3Credentials? {
        lock.lock()
        defer { lock.unlock() }
        if let config = profile.s3,
           let accessKeyID = config.accessKeyID,
           let secretAccessKey = config.secretAccessKey {
            let credentials = CompanionAssetUploadS3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            if credentials.isComplete {
                return credentials
            }
        }
        guard let reference = profile.s3?.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty
        else {
            return nil
        }
        return try credentialStore.credentials(reference: reference)
    }

    func customHTTPHeaders(for profile: CompanionAssetUploadProfile) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let config = profile.customHTTP else {
            return [:]
        }

        var headers = config.additionalHeaders
        for (headerName, reference) in config.sensitiveHeaderReferences ?? [:] {
            guard let secret = try credentialStore.secret(reference: reference),
                  !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
            }
            headers[headerName] = secret
        }
        return headers
    }

    func diagnosticJSON() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let document = try? loadDocument() else { return nil }
        let redacted: [String: Any] = [
            "schemaVersion": document.schemaVersion,
            "defaultProfileID": document.defaultProfileID ?? NSNull(),
            "profiles": document.profiles.map { profile in
                [
                    "id": profile.id,
                    "type": profile.type.rawValue,
                    "name": profile.name,
                    "enabled": profile.enabled,
                    "profileSummary": profile.profileSummary,
                    "credentialsConfigured": profile.hasConfiguredCredentials,
                    "configHash": profile.configHash,
                    "defaultOutputFormat": profile.resolvedDefaultOutputFormat.rawValue,
                    "maxSizeBytes": profile.limits.maxSizeBytes
                ] as [String: Any]
            }
        ]
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func loadDocument() throws -> CompanionAssetUploadProfilesDocument {
        let fileURL = url
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty()
        }
        let document: CompanionAssetUploadProfilesDocument
        do {
            document = try decoder.decode(CompanionAssetUploadProfilesDocument.self, from: Data(contentsOf: fileURL))
        } catch {
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("asset-upload-profiles.corrupt-\(Self.timestamp()).json")
            try? fileManager.moveItem(at: fileURL, to: backupURL)
            throw CompanionAssetUploadProfileStoreError.corruptProfileStore(backupURL)
        }

        let migrated = try migratingCredentials(in: document, preserveExistingSensitiveHeaderReferences: true)
        if migrated != document {
            try saveDocument(migrated)
        }
        return migrated
    }

    private func saveDocument(_ document: CompanionAssetUploadProfilesDocument) throws {
        let fileURL = url
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func profile(
        id: String,
        in document: CompanionAssetUploadProfilesDocument,
        requireCredentials: Bool
    ) throws -> CompanionAssetUploadProfile {
        guard let profile = document.profiles.first(where: { $0.id == id }) else {
            throw CompanionAssetUploadProfileStoreError.profileNotFound(id)
        }
        try validate(profile, requireCredentials: requireCredentials)
        return profile
    }

    private func validate(_ profile: CompanionAssetUploadProfile, requireCredentials: Bool) throws {
        guard profile.enabled else {
            throw CompanionAssetUploadProfileStoreError.profileDisabled(profile.name)
        }
        switch profile.type {
        case .s3Compatible:
            guard let config = profile.s3,
                  !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !config.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !config.bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.normalizedS3PathPrefix(config.pathPrefix) != nil
            else {
                throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
            }
            if requireCredentials {
                guard try credentials(for: profile)?.isComplete == true else {
                    throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
                }
            }
        case .customHTTP:
            guard let config = profile.customHTTP,
                  URL(string: config.uploadURL) != nil,
                  !config.fileFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !config.responseURLJSONPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func migratingCredentials(
        in document: CompanionAssetUploadProfilesDocument,
        preserveExistingSensitiveHeaderReferences: Bool
    ) throws -> CompanionAssetUploadProfilesDocument {
        var migrated = document
        migrated.profiles = try migrated.profiles.map {
            try sanitizedProfile(
                $0,
                credentials: nil,
                preserveExistingSensitiveHeaderReferences: preserveExistingSensitiveHeaderReferences
            )
        }
        return migrated
    }

    private func sanitizedProfile(
        _ profile: CompanionAssetUploadProfile,
        credentials explicitCredentials: CompanionAssetUploadS3Credentials?,
        preserveExistingSensitiveHeaderReferences: Bool
    ) throws -> CompanionAssetUploadProfile {
        switch profile.type {
        case .s3Compatible:
            return try sanitizedS3Profile(profile, credentials: explicitCredentials)
        case .customHTTP:
            return try sanitizedCustomHTTPProfile(
                profile,
                preserveExistingSensitiveHeaderReferences: preserveExistingSensitiveHeaderReferences
            )
        }
    }

    private func sanitizedS3Profile(
        _ profile: CompanionAssetUploadProfile,
        credentials explicitCredentials: CompanionAssetUploadS3Credentials?
    ) throws -> CompanionAssetUploadProfile {
        guard var config = profile.s3 else {
            return profile
        }
        guard let normalizedPrefix = Self.normalizedS3PathPrefix(config.pathPrefix) else {
            throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
        }
        config.pathPrefix = normalizedPrefix

        let legacyCredentials: CompanionAssetUploadS3Credentials?
        if let accessKeyID = config.accessKeyID,
           let secretAccessKey = config.secretAccessKey {
            let credentials = CompanionAssetUploadS3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            legacyCredentials = credentials.isComplete ? credentials : nil
        } else {
            legacyCredentials = nil
        }

        let reference = Self.credentialReference(forProfileID: profile.id)
        let credentialsToSave = explicitCredentials ?? legacyCredentials
        if let credentialsToSave, credentialsToSave.isComplete {
            try credentialStore.save(credentialsToSave, reference: reference)
            config.credentialReference = reference
        }

        config.accessKeyID = nil
        config.secretAccessKey = nil

        var sanitized = profile
        sanitized.s3 = config
        return sanitized
    }

    private func sanitizedCustomHTTPProfile(
        _ profile: CompanionAssetUploadProfile,
        preserveExistingSensitiveHeaderReferences: Bool
    ) throws -> CompanionAssetUploadProfile {
        guard var config = profile.customHTTP else {
            return profile
        }

        let existingSensitiveHeaderReferences = config.sensitiveHeaderReferences ?? [:]
        var sensitiveHeaderReferences = preserveExistingSensitiveHeaderReferences ? existingSensitiveHeaderReferences : [:]
        var storedHeaders: [String: String] = [:]
        for (headerName, value) in config.additionalHeaders {
            guard Self.isSensitiveHeaderName(headerName) else {
                storedHeaders[headerName] = value
                continue
            }

            let reference = existingSensitiveHeaderReferences[headerName]
                ?? Self.sensitiveHeaderReference(forProfileID: profile.id, headerName: headerName)
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try credentialStore.saveSecret(value, reference: reference)
                sensitiveHeaderReferences[headerName] = reference
            } else if existingSensitiveHeaderReferences[headerName] != nil {
                sensitiveHeaderReferences[headerName] = reference
            }
        }

        if !preserveExistingSensitiveHeaderReferences {
            let retainedReferences = Set(sensitiveHeaderReferences.values)
            for reference in Set(existingSensitiveHeaderReferences.values) where !retainedReferences.contains(reference) {
                try credentialStore.delete(reference: reference)
            }
        }

        config.additionalHeaders = storedHeaders
        config.sensitiveHeaderReferences = sensitiveHeaderReferences.isEmpty ? nil : sensitiveHeaderReferences

        var sanitized = profile
        sanitized.customHTTP = config
        return sanitized
    }

    private func deleteStoredCredentials(for profile: CompanionAssetUploadProfile) throws {
        if let reference = profile.s3?.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            try credentialStore.delete(reference: reference)
        }
        if let references = profile.customHTTP?.sensitiveHeaderReferences?.values {
            for reference in references {
                let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    try credentialStore.delete(reference: trimmed)
                }
            }
        }
    }

    private func deleteStaleCredentials(from oldProfile: CompanionAssetUploadProfile, to newProfile: CompanionAssetUploadProfile) throws {
        let retainedReferences = Set(Self.credentialReferences(in: newProfile))
        for reference in Self.credentialReferences(in: oldProfile) where !retainedReferences.contains(reference) {
            try credentialStore.delete(reference: reference)
        }
    }

    private static func credentialReferences(in profile: CompanionAssetUploadProfile) -> [String] {
        var references: [String] = []
        if let reference = profile.s3?.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            references.append(reference)
        }
        if let sensitiveHeaderReferences = profile.customHTTP?.sensitiveHeaderReferences?.values {
            for reference in sensitiveHeaderReferences {
                let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    references.append(trimmed)
                }
            }
        }
        return references
    }

    private static func credentialReference(forProfileID id: String) -> String {
        "s3-\(id)"
    }

    private static func sensitiveHeaderReference(forProfileID id: String, headerName: String) -> String {
        let normalized = normalizedHeaderName(headerName)
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "custom-http-\(id)-header-\(digest)"
    }

    static func isSensitiveHeaderName(_ headerName: String) -> Bool {
        sensitiveHeaderNames.contains(normalizedHeaderName(headerName))
    }

    private static func normalizedHeaderName(_ headerName: String) -> String {
        headerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedS3PathPrefix(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
              segments.allSatisfy(CompanionAssetUploadService.isSafeObjectKeySegment)
        else {
            return nil
        }
        return segments.joined(separator: "/")
    }

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-amz-security-token",
        "cookie",
        "set-cookie"
    ]
}

enum CompanionAssetUploadOutputFormat: String, Codable, Equatable {
    case url
    case markdown
    case html
}

enum CompanionAssetUploadSourceType: String, Codable, Equatable {
    case filePath
    case clipboardImage
    case temporaryFile
}

struct CompanionAssetUploadRequest: Equatable {
    var sourceType: CompanionAssetUploadSourceType
    var fileURL: URL?
    var profileID: String?
    var outputFormat: CompanionAssetUploadOutputFormat
    var altText: String?
    var dryRun: Bool
    var objectKey: String? = nil
}

struct CompanionAssetUploadResult: Equatable {
    var assetID: String
    var url: String?
    var formatted: String?
    var format: CompanionAssetUploadOutputFormat
    var fileNameSummary: String
    var mimeType: String
    var sizeBytes: Int
    var profileSummary: String
    var profileID: String
    var uploadedAt: Date
    var dryRun: Bool
    var objectKey: String?
}

enum CompanionAssetUploadProfileTestCleanupStatus: String, Codable, Equatable {
    case notNeeded
    case deleted
    case warning
}

struct CompanionAssetUploadProfileTestResult: Equatable {
    var profileID: String
    var profileSummary: String
    var url: String?
    var formatted: String?
    var objectKey: String?
    var didWriteProbe: Bool
    var cleanupStatus: CompanionAssetUploadProfileTestCleanupStatus
    var cleanupWarning: String?
}

enum CompanionAssetUploadHistoryStatus: String, Codable, Equatable {
    case succeeded
    case failed
    case cancelled
    case interrupted
}

struct CompanionAssetUploadHistoryRecord: Codable, Equatable, Identifiable {
    var assetID: String
    var url: String?
    var formatted: String?
    var format: CompanionAssetUploadOutputFormat
    var fileNameSummary: String
    var mimeType: String
    var sizeBytes: Int
    var profileSummary: String
    var profileID: String
    var uploadedAt: Date
    var runID: String?
    var source: String
    var status: CompanionAssetUploadHistoryStatus
    var errorSummary: String?

    var id: String { assetID }

    static func success(
        from result: CompanionAssetUploadResult,
        runID: UUID?,
        source: String
    ) -> CompanionAssetUploadHistoryRecord {
        CompanionAssetUploadHistoryRecord(
            assetID: result.assetID,
            url: result.url,
            formatted: result.formatted,
            format: result.format,
            fileNameSummary: result.fileNameSummary,
            mimeType: result.mimeType,
            sizeBytes: result.sizeBytes,
            profileSummary: result.profileSummary,
            profileID: result.profileID,
            uploadedAt: result.uploadedAt,
            runID: runID?.uuidString,
            source: source,
            status: .succeeded,
            errorSummary: nil
        )
    }
}

final class CompanionAssetUploadHistoryStore {
    static let fileName = "asset-upload-history.json"

    private struct Payload: Codable {
        var schemaVersion: Int
        var records: [CompanionAssetUploadHistoryRecord]
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxRecords: Int
    private let lock = NSRecursiveLock()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        maxRecords: Int = 100
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.maxRecords = max(1, maxRecords)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var url: URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    func recent(limit: Int = 100) -> [CompanionAssetUploadHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadPayload().records.sorted { $0.uploadedAt > $1.uploadedAt }.prefix(max(0, limit)))
    }

    func append(_ record: CompanionAssetUploadHistoryRecord) {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        payload.records.removeAll { $0.assetID == record.assetID }
        payload.records.insert(sanitized(record), at: 0)
        payload.records = Array(payload.records.prefix(maxRecords))
        save(payload)
    }

    func appendSuccess(_ result: CompanionAssetUploadResult, runID: UUID?, source: String) {
        guard !result.dryRun else { return }
        append(.success(from: result, runID: runID, source: source))
    }

    func appendFailure(
        fileNameSummary: String,
        mimeType: String = "application/octet-stream",
        sizeBytes: Int = 0,
        profileSummary: String,
        profileID: String,
        format: CompanionAssetUploadOutputFormat,
        runID: UUID?,
        source: String,
        errorSummary: String,
        now: Date = Date()
    ) {
        append(CompanionAssetUploadHistoryRecord(
            assetID: UUID().uuidString,
            url: nil,
            formatted: nil,
            format: format,
            fileNameSummary: fileNameSummary,
            mimeType: mimeType,
            sizeBytes: max(0, sizeBytes),
            profileSummary: profileSummary,
            profileID: profileID,
            uploadedAt: now,
            runID: runID?.uuidString,
            source: source,
            status: .failed,
            errorSummary: errorSummary
        ))
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }

    func diagnosticJSON(limit: Int = 20) -> String? {
        let redacted: [[String: Any]] = recent(limit: limit).map { record in
            [
                "assetID": record.assetID,
                "fileName": record.fileNameSummary,
                "mimeType": record.mimeType,
                "sizeBytes": record.sizeBytes,
                "profileID": record.profileID,
                "profileSummary": record.profileSummary,
                "uploadedAt": ISO8601DateFormatter().string(from: record.uploadedAt),
                "success": record.status == .succeeded,
                "status": record.status.rawValue,
                "errorSummary": record.errorSummary ?? NSNull()
            ] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func sanitized(_ record: CompanionAssetUploadHistoryRecord) -> CompanionAssetUploadHistoryRecord {
        var copy = record
        copy.fileNameSummary = Self.safeSummary(URL(fileURLWithPath: copy.fileNameSummary).lastPathComponent, maxLength: 120)
        copy.profileSummary = Self.safeSummary(copy.profileSummary, maxLength: 160)
        copy.source = Self.safeSummary(copy.source, maxLength: 80)
        copy.errorSummary = copy.errorSummary.map { Self.safeSummary(Self.redactedLocalPaths(in: $0), maxLength: 240) }
        return copy
    }

    private func loadPayload() -> Payload {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            return Payload(schemaVersion: 1, records: [])
        }
        return Payload(
            schemaVersion: payload.schemaVersion,
            records: Array(payload.records.prefix(maxRecords))
        )
    }

    private func save(_ payload: Payload) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Companion asset upload history save failed: \(error.localizedDescription)")
        }
    }

    private static func safeSummary(_ raw: String, maxLength: Int) -> String {
        var value = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > maxLength {
            value = String(value.prefix(maxLength)) + "..."
        }
        return value
    }

    private static func redactedLocalPaths(in raw: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>[]{}(),;"))
        return raw
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> String in
                guard token.contains("/") else { return String(token) }
                let trimmed = String(token).trimmingCharacters(in: separators)
                guard trimmed.hasPrefix("/") else { return String(token) }
                let basename = URL(fileURLWithPath: trimmed).lastPathComponent
                guard !basename.isEmpty else { return "[local-path]" }
                return String(token).replacingOccurrences(of: trimmed, with: basename)
            }
            .joined(separator: " ")
    }
}

struct CompanionFinderAssetUploadApprovalRecord: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var id: String
    var profileID: String
    var profileConfigHash: String
    var maxSizeBytes: Int
    var grantedAt: Date
    var lastUsedAt: Date
}

final class CompanionFinderAssetUploadApprovalStore {
    static let fileName = "asset-upload-finder-approvals.json"

    private struct Payload: Codable {
        var schemaVersion: Int
        var records: [CompanionFinderAssetUploadApprovalRecord]
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var url: URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    func records() -> [CompanionFinderAssetUploadApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadPayload().records
    }

    func canUseStoredApproval(
        profile: CompanionAssetUploadProfile,
        selectedMaxSizeBytes: Int,
        now: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        let id = Self.recordID(profileID: profile.id)
        guard let index = payload.records.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let record = payload.records[index]
        guard record.profileID == profile.id,
              record.profileConfigHash == profile.configHash,
              selectedMaxSizeBytes <= record.maxSizeBytes
        else {
            return false
        }
        payload.records[index].lastUsedAt = now
        save(payload)
        return true
    }

    func remember(profile: CompanionAssetUploadProfile, maxSizeBytes: Int, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        let id = Self.recordID(profileID: profile.id)
        payload.records.removeAll { $0.id == id }
        payload.records.insert(CompanionFinderAssetUploadApprovalRecord(
            schemaVersion: 1,
            id: id,
            profileID: profile.id,
            profileConfigHash: profile.configHash,
            maxSizeBytes: max(0, maxSizeBytes),
            grantedAt: now,
            lastUsedAt: now
        ), at: 0)
        save(payload)
    }

    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }

    func revoke(profileID: String) {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        payload.records.removeAll { $0.profileID == profileID }
        save(payload)
    }

    private static func recordID(profileID: String) -> String {
        "finderAction:\(profileID)"
    }

    private func loadPayload() -> Payload {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            return Payload(schemaVersion: 1, records: [])
        }
        return Payload(schemaVersion: payload.schemaVersion, records: payload.records)
    }

    private func save(_ payload: Payload) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Companion finder asset upload approval save failed: \(error.localizedDescription)")
        }
    }
}

enum CompanionAssetUploadError: LocalizedError {
    case missingFilePath
    case clipboardImageUnavailable
    case fileNotFound(URL)
    case fileTooLarge(size: Int, limit: Int)
    case unsupportedMimeType(String)
    case unsupportedUploadType(String)
    case uploadCancelled
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFilePath:
            return "A file path is required for this upload source."
        case .clipboardImageUnavailable:
            return "The clipboard does not contain an image Companion can upload."
        case .fileNotFound(let url):
            return "File does not exist: \(url.lastPathComponent)"
        case .fileTooLarge(let size, let limit):
            return "File is too large (\(size) bytes). Limit is \(limit) bytes."
        case .unsupportedMimeType(let mime):
            return "MIME type is not allowed: \(mime)"
        case .unsupportedUploadType(let type):
            return "Real upload is not implemented for \(type) yet."
        case .uploadCancelled:
            return "Asset upload was cancelled."
        case .uploadFailed(let message):
            return message
        }
    }
}

final class CompanionAssetUploadCancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [URLSessionTask] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let activeTasks: [URLSessionTask]
        lock.lock()
        cancelled = true
        activeTasks = tasks
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CompanionAssetUploadError.uploadCancelled
        }
    }

    func register(_ task: URLSessionTask) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            throw CompanionAssetUploadError.uploadCancelled
        }
        tasks.append(task)
        lock.unlock()
    }

    func unregister(_ task: URLSessionTask) {
        lock.lock()
        tasks.removeAll { $0 === task }
        lock.unlock()
    }
}

final class CompanionAssetUploadService {
    private let profileStore: CompanionAssetUploadProfileStore
    private let fileManager: FileManager
    private let now: () -> Date
    private let cancellationToken: CompanionAssetUploadCancellationToken?
    private static let probeImageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")
        ?? Data([0x89, 0x50, 0x4E, 0x47])

    init(
        profileStore: CompanionAssetUploadProfileStore,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        cancellationToken: CompanionAssetUploadCancellationToken? = nil
    ) {
        self.profileStore = profileStore
        self.fileManager = fileManager
        self.now = now
        self.cancellationToken = cancellationToken
    }

    func upload(_ request: CompanionAssetUploadRequest) throws -> CompanionAssetUploadResult {
        try cancellationToken?.checkCancellation()
        let profile = try profileStore.profile(id: request.profileID, requireCredentials: !request.dryRun)
        let file = try resolvedFile(for: request)
        defer {
            if file.removeAfterUse {
                try? fileManager.removeItem(at: file.url)
            }
        }
        try validate(file: file, profile: profile)
        try cancellationToken?.checkCancellation()

        let uploadDate = now()
        let objectKey = try s3ObjectKey(for: file, profile: profile, requestedObjectKey: request.objectKey, date: uploadDate)
        let outputURL = request.dryRun
            ? try previewURL(for: file, profile: profile, objectKey: objectKey)
            : try performUpload(file: file, profile: profile, objectKey: objectKey, requestDate: uploadDate)
        let formatted = Self.format(
            url: outputURL,
            format: request.outputFormat,
            altText: request.altText,
            fallbackName: file.url.deletingPathExtension().lastPathComponent
        )
        return CompanionAssetUploadResult(
            assetID: UUID().uuidString,
            url: outputURL,
            formatted: formatted,
            format: request.outputFormat,
            fileNameSummary: file.url.lastPathComponent,
            mimeType: file.mimeType,
            sizeBytes: file.sizeBytes,
            profileSummary: profile.profileSummary,
            profileID: profile.id,
            uploadedAt: uploadDate,
            dryRun: request.dryRun,
            objectKey: objectKey
        )
    }

    /// Tests the selected asset upload profile.
    ///
    /// S3-compatible profiles write a small PNG probe and then make a best-effort signed DELETE.
    /// Custom HTTP profiles only run the dry-run preview path so unknown endpoints are not written.
    /// Cancellation is surfaced as `CompanionAssetUploadError.uploadCancelled`; other cleanup failures return a warning.
    func testProfile(profileID: String? = nil) throws -> CompanionAssetUploadProfileTestResult {
        let profile = try profileStore.profile(id: profileID, requireCredentials: false)
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("companion-profile-test-\(UUID().uuidString).png")
        try Self.probeImageData.write(to: tempURL, options: .atomic)
        defer { try? fileManager.removeItem(at: tempURL) }

        switch profile.type {
        case .s3Compatible:
            let result = try upload(CompanionAssetUploadRequest(
                sourceType: .temporaryFile,
                fileURL: tempURL,
                profileID: profile.id,
                outputFormat: profile.resolvedDefaultOutputFormat,
                altText: "Companion profile test",
                dryRun: false
            ))
            let cleanupWarning = try cleanupS3Probe(profile: profile, objectKey: result.objectKey, requestDate: now())
            return CompanionAssetUploadProfileTestResult(
                profileID: profile.id,
                profileSummary: profile.profileSummary,
                url: result.url,
                formatted: result.formatted,
                objectKey: result.objectKey,
                didWriteProbe: true,
                cleanupStatus: cleanupWarning == nil ? .deleted : .warning,
                cleanupWarning: cleanupWarning
            )
        case .customHTTP:
            let result = try upload(CompanionAssetUploadRequest(
                sourceType: .temporaryFile,
                fileURL: tempURL,
                profileID: profile.id,
                outputFormat: profile.resolvedDefaultOutputFormat,
                altText: "Companion profile test",
                dryRun: true
            ))
            return CompanionAssetUploadProfileTestResult(
                profileID: profile.id,
                profileSummary: profile.profileSummary,
                url: result.url,
                formatted: result.formatted,
                objectKey: result.objectKey,
                didWriteProbe: false,
                cleanupStatus: .notNeeded,
                cleanupWarning: nil
            )
        }
    }

    static func format(url: String, format: CompanionAssetUploadOutputFormat, altText: String?, fallbackName: String) -> String {
        let label = (altText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .url:
            return url
        case .markdown:
            return "![\(escapeMarkdownAlt(label))](\(url))"
        case .html:
            return "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(label))\" />"
        }
    }

    private struct ResolvedFile {
        var url: URL
        var mimeType: String
        var sizeBytes: Int
        var removeAfterUse: Bool = false
    }

    private func resolvedFile(for request: CompanionAssetUploadRequest) throws -> ResolvedFile {
        switch request.sourceType {
        case .filePath, .temporaryFile:
            guard let url = request.fileURL else {
                throw CompanionAssetUploadError.missingFilePath
            }
            return try inspect(url)
        case .clipboardImage:
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:])
            else {
                throw CompanionAssetUploadError.clipboardImageUnavailable
            }
            let tempURL = fileManager.temporaryDirectory
                .appendingPathComponent("companion-clipboard-\(UUID().uuidString).png")
            try data.write(to: tempURL, options: .atomic)
            var file = try inspect(tempURL)
            file.removeAfterUse = true
            return file
        }
    }

    private func inspect(_ url: URL) throws -> ResolvedFile {
        let standardized = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw CompanionAssetUploadError.fileNotFound(standardized)
        }
        let values = try standardized.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values.isDirectory == true {
            throw CompanionAssetUploadError.fileNotFound(standardized)
        }
        let size: Int
        if let fileSize = values.fileSize {
            size = fileSize
        } else {
            let attributes = try fileManager.attributesOfItem(atPath: standardized.path)
            size = attributes[.size] as? Int ?? 0
        }
        let contentType = values.contentType
        let mime = contentType?.preferredMIMEType ?? Self.mimeTypeFallback(for: standardized)
        return ResolvedFile(url: standardized, mimeType: mime, sizeBytes: size)
    }

    private func validate(file: ResolvedFile, profile: CompanionAssetUploadProfile) throws {
        if file.sizeBytes > profile.limits.maxSizeBytes {
            throw CompanionAssetUploadError.fileTooLarge(size: file.sizeBytes, limit: profile.limits.maxSizeBytes)
        }
        if file.sizeBytes > CompanionAssetUploadProfile.Limits.maximumSynchronousUploadBytes {
            throw CompanionAssetUploadError.fileTooLarge(
                size: file.sizeBytes,
                limit: CompanionAssetUploadProfile.Limits.maximumSynchronousUploadBytes
            )
        }
        guard let allowed = profile.limits.allowedMimeTypes, !allowed.isEmpty else {
            return
        }
        let matched = allowed.contains { pattern in
            if pattern == "*" || pattern == "*/*" {
                return true
            }
            if pattern.hasSuffix("/*") {
                return file.mimeType.hasPrefix(String(pattern.dropLast(1)))
            }
            return file.mimeType == pattern
        }
        if !matched {
            throw CompanionAssetUploadError.unsupportedMimeType(file.mimeType)
        }
    }

    private func previewURL(for file: ResolvedFile, profile: CompanionAssetUploadProfile, objectKey: String?) throws -> String {
        switch profile.type {
        case .s3Compatible:
            guard let objectKey else {
                throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
            }
            return try Self.s3PublicURL(forObjectKey: objectKey, profile: profile)
        case .customHTTP:
            if let base = profile.customHTTP?.publicBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !base.isEmpty {
                return "\(base)/\(Self.uriEncodePath(file.url.lastPathComponent))"
            }
            return "https://example.invalid/\(Self.uriEncodePath(file.url.lastPathComponent))"
        }
    }

    private func performUpload(
        file: ResolvedFile,
        profile: CompanionAssetUploadProfile,
        objectKey: String?,
        requestDate: Date
    ) throws -> String {
        switch profile.type {
        case .s3Compatible:
            guard let objectKey else {
                throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
            }
            return try performS3Upload(file: file, profile: profile, objectKey: objectKey, requestDate: requestDate)
        case .customHTTP:
            return try performCustomHTTPUpload(file: file, profile: profile)
        }
    }

    private func performS3Upload(
        file: ResolvedFile,
        profile: CompanionAssetUploadProfile,
        objectKey: String,
        requestDate: Date
    ) throws -> String {
        let payloadHash = try Self.sha256Hex(fileURL: file.url)
        let request = try signedS3Request(
            profile: profile,
            objectKey: objectKey,
            method: "PUT",
            payloadHash: payloadHash,
            contentType: file.mimeType,
            requestDate: requestDate,
            timeoutInterval: 60
        )

        _ = try Self.performSynchronousUploadRequestWithRetry(
            request,
            fromFile: file.url,
            serviceName: "S3 upload",
            cancellationToken: cancellationToken
        )
        return try Self.s3PublicURL(forObjectKey: objectKey, profile: profile)
    }

    private func cleanupS3Probe(profile: CompanionAssetUploadProfile, objectKey: String?, requestDate: Date) throws -> String? {
        guard let objectKey else {
            return CompanionL10n.text("Probe object key was not available; delete the test object manually if it was created.")
        }
        let request = try signedS3Request(
            profile: profile,
            objectKey: objectKey,
            method: "DELETE",
            payloadHash: Self.emptySHA256Hex,
            contentType: nil,
            requestDate: requestDate,
            timeoutInterval: 30
        )
        do {
            let (_, response) = try Self.performSynchronousRequest(request, cancellationToken: cancellationToken)
            guard let http = response as? HTTPURLResponse else {
                return CompanionL10n.format("Probe cleanup did not receive an HTTP response. Object key: %@", objectKey)
            }
            // PUT already succeeded; a 404 during cleanup means the probe is absent, which is clean enough.
            if (200..<300).contains(http.statusCode) || http.statusCode == 404 {
                return nil
            }
            return CompanionL10n.format("Probe upload succeeded, but cleanup returned HTTP %d. Object key: %@", http.statusCode, objectKey)
        } catch {
            if let uploadError = error as? CompanionAssetUploadError,
               case .uploadCancelled = uploadError {
                throw uploadError
            }
            return CompanionL10n.format("Probe upload succeeded, but cleanup failed: %@. Object key: %@", error.localizedDescription, objectKey)
        }
    }

    private func signedS3Request(
        profile: CompanionAssetUploadProfile,
        objectKey: String,
        method: String,
        payloadHash: String,
        contentType: String?,
        requestDate: Date,
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
        guard let config = profile.s3,
              let credentials = try profileStore.credentials(for: profile),
              credentials.isComplete
        else {
            throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
        }

        let endpoint = try Self.s3Endpoint(from: config.endpoint)
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestHost = config.usePathStyle ? endpoint.host : "\(bucket).\(endpoint.host)"
        let hostHeader = endpoint.port.map { "\(requestHost):\($0)" } ?? requestHost
        let rawPath = config.usePathStyle ? "/\(bucket)/\(objectKey)" : "/\(objectKey)"
        let canonicalURI = Self.uriEncodePath(rawPath)

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = requestHost
        components.port = endpoint.port
        components.percentEncodedPath = canonicalURI
        guard let url = components.url else {
            throw CompanionAssetUploadError.uploadFailed("S3 endpoint is invalid.")
        }

        let amzDate = Self.s3DateTime.string(from: requestDate)
        let dateStamp = Self.s3Date.string(from: requestDate)
        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        var canonicalHeaderLines: [String] = []
        var signedHeaderNames: [String] = []
        if let contentType {
            canonicalHeaderLines.append("content-type:\(contentType)")
            signedHeaderNames.append("content-type")
        }
        canonicalHeaderLines.append("host:\(hostHeader)")
        canonicalHeaderLines.append("x-amz-content-sha256:\(payloadHash)")
        canonicalHeaderLines.append("x-amz-date:\(amzDate)")
        signedHeaderNames.append(contentsOf: ["host", "x-amz-content-sha256", "x-amz-date"])
        let signedHeaders = signedHeaderNames.joined(separator: ";")
        let canonicalHeaders = canonicalHeaderLines.joined(separator: "\n") + "\n"
        let canonicalRequest = [
            method,
            canonicalURI,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signature = Self.awsSignature(
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: config.region,
            stringToSign: stringToSign
        )
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func performCustomHTTPUpload(file: ResolvedFile, profile: CompanionAssetUploadProfile) throws -> String {
        guard let config = profile.customHTTP,
              let url = URL(string: config.uploadURL)
        else {
            throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = config.method.rawValue
        for (key, value) in try profileStore.customHTTPHeaders(for: profile) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let responseData: Data
        switch config.bodyMode {
        case .rawFile:
            request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
            (responseData, _) = try Self.performSynchronousUploadRequestWithRetry(
                request,
                fromFile: file.url,
                serviceName: "Upload",
                cancellationToken: cancellationToken
            )
        case .multipart:
            let boundary = "CompanionBoundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let bodyURL = try multipartBodyFile(
                boundary: boundary,
                fieldName: config.fileFieldName,
                fileName: file.url.lastPathComponent,
                mimeType: file.mimeType,
                fileURL: file.url
            )
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            (responseData, _) = try Self.performSynchronousUploadRequestWithRetry(
                request,
                fromFile: bodyURL,
                serviceName: "Upload",
                cancellationToken: cancellationToken
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: responseData)
        else {
            throw CompanionAssetUploadError.uploadFailed("Upload response is not valid JSON.")
        }
        guard let extractedURL = Self.value(atJSONPath: config.responseURLJSONPath, in: object) as? String,
              !extractedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CompanionAssetUploadError.uploadFailed("Upload response did not contain URL at \(config.responseURLJSONPath).")
        }
        return extractedURL
    }

    private func s3ObjectKey(
        for file: ResolvedFile,
        profile: CompanionAssetUploadProfile,
        requestedObjectKey: String?,
        date: Date
    ) throws -> String? {
        guard profile.type == .s3Compatible else {
            return nil
        }
        if let requestedObjectKey = requestedObjectKey?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !requestedObjectKey.isEmpty {
            return try validatedReusableObjectKey(requestedObjectKey, for: file, profile: profile)
        }
        return objectKey(for: file, profile: profile, date: date)
    }

    private func validatedReusableObjectKey(
        _ objectKey: String,
        for file: ResolvedFile,
        profile: CompanionAssetUploadProfile
    ) throws -> String {
        let prefix = try s3PathPrefix(for: profile)
        let prefixSegments = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let keySegments = objectKey.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !prefixSegments.isEmpty,
              keySegments.count == prefixSegments.count + 4,
              Array(keySegments.prefix(prefixSegments.count)) == prefixSegments,
              (prefixSegments + keySegments.dropFirst(prefixSegments.count)).allSatisfy(Self.isSafeObjectKeySegment)
        else {
            throw CompanionAssetUploadError.uploadFailed("S3 object key must reuse a Companion-generated key under this profile's path prefix.")
        }

        let year = keySegments[prefixSegments.count]
        let month = keySegments[prefixSegments.count + 1]
        let day = keySegments[prefixSegments.count + 2]
        guard year.count == 4,
              month.count == 2,
              day.count == 2,
              let monthValue = Int(month), (1...12).contains(monthValue),
              let dayValue = Int(day), (1...31).contains(dayValue),
              year.allSatisfy(\.isNumber),
              month.allSatisfy(\.isNumber),
              day.allSatisfy(\.isNumber)
        else {
            throw CompanionAssetUploadError.uploadFailed("S3 object key must include Companion's generated date path.")
        }

        let fileSegment = keySegments[prefixSegments.count + 3]
        let uuidLength = 36
        guard fileSegment.count > uuidLength + 1 else {
            throw CompanionAssetUploadError.uploadFailed("S3 object key must include Companion's generated asset id.")
        }
        let uuidEnd = fileSegment.index(fileSegment.startIndex, offsetBy: uuidLength)
        let uuidText = String(fileSegment[..<uuidEnd])
        guard UUID(uuidString: uuidText) != nil,
              fileSegment[uuidEnd] == "-"
        else {
            throw CompanionAssetUploadError.uploadFailed("S3 object key must include Companion's generated asset id.")
        }

        let fileNameStart = fileSegment.index(after: uuidEnd)
        let fileName = String(fileSegment[fileNameStart...])
        let expectedFileName = Self.safeFileName(file.url.lastPathComponent)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !fileName.isEmpty,
              fileName == expectedFileName,
              fileName.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw CompanionAssetUploadError.uploadFailed("S3 object key must end with this file's safe Companion file name.")
        }
        return objectKey
    }

    private func objectKey(for file: ResolvedFile, profile: CompanionAssetUploadProfile, date: Date) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let prefix = (try? s3PathPrefix(for: profile)) ?? "companion"
        let fileName = Self.safeFileName(file.url.lastPathComponent)
        return "\(prefix)/\(dayFormatter.string(from: date))/\(UUID().uuidString)-\(fileName)"
    }

    private func s3PathPrefix(for profile: CompanionAssetUploadProfile) throws -> String {
        guard let rawPrefix = profile.s3?.pathPrefix,
              let prefix = CompanionAssetUploadProfileStore.normalizedS3PathPrefix(rawPrefix)
        else {
            throw CompanionAssetUploadProfileStoreError.profileIncomplete(profile.name)
        }
        return prefix
    }

    fileprivate static func isSafeObjectKeySegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else {
            return false
        }
        return !segment.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    static func s3PublicURL(forObjectKey objectKey: String, profile: CompanionAssetUploadProfile) throws -> String {
        guard let config = profile.s3 else {
            return objectKey
        }
        if let base = config.publicBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !base.isEmpty {
            return "\(base)/\(Self.uriEncodePath(objectKey))"
        }
        let endpoint = try Self.s3Endpoint(from: config.endpoint)
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = config.usePathStyle ? endpoint.host : "\(bucket).\(endpoint.host)"
        let rawPath = config.usePathStyle ? "/\(bucket)/\(objectKey)" : "/\(objectKey)"
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = host
        components.port = endpoint.port
        components.percentEncodedPath = Self.uriEncodePath(rawPath)
        guard let url = components.url else {
            throw CompanionAssetUploadError.uploadFailed("S3 public URL is invalid.")
        }
        return url.absoluteString
    }

    private func multipartBodyFile(
        boundary: String,
        fieldName: String,
        fileName: String,
        mimeType: String,
        fileURL: URL
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-multipart-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
        try output.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try output.write(contentsOf: chunk)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    private static func mimeTypeFallback(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return value.isEmpty ? "asset" : value
    }

    private static func escapeMarkdownAlt(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func value(atJSONPath path: String, in object: Any) -> Any? {
        var current: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dictionary = current as? [String: Any] {
                current = dictionary[component]
            } else {
                return nil
            }
        }
        return current
    }

    private struct S3Endpoint {
        var scheme: String
        var host: String
        var port: Int?
    }

    private static let s3DateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let s3Date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static func s3Endpoint(from raw: String) throws -> S3Endpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme,
              let host = components.host,
              components.path.isEmpty || components.path == "/"
        else {
            throw CompanionAssetUploadError.uploadFailed("S3 endpoint is invalid.")
        }
        return S3Endpoint(scheme: scheme, host: host, port: components.port)
    }

    private static func uriEncodePath(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let emptySHA256Hex = sha256Hex(Data())

    private static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, message: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }

    static func awsSignature(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        stringToSign: String
    ) -> String {
        let dateKey = hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), message: dateStamp)
        let regionKey = hmacSHA256(key: dateKey, message: region)
        let serviceKey = hmacSHA256(key: regionKey, message: "s3")
        let signingKey = hmacSHA256(key: serviceKey, message: "aws4_request")
        return hmacSHA256(key: signingKey, message: stringToSign)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let retryDelays: [TimeInterval] = [0.25, 0.75, 1.5]

    private static func performSynchronousRequestWithRetry(
        _ request: URLRequest,
        serviceName: String,
        cancellationToken: CompanionAssetUploadCancellationToken?
    ) throws -> (Data, HTTPURLResponse) {
        try performSynchronousHTTPWithRetry(serviceName: serviceName, cancellationToken: cancellationToken) {
            try performSynchronousRequest(request, cancellationToken: cancellationToken)
        }
    }

    private static func performSynchronousUploadRequestWithRetry(
        _ request: URLRequest,
        fromFile fileURL: URL,
        serviceName: String,
        cancellationToken: CompanionAssetUploadCancellationToken?
    ) throws -> (Data, HTTPURLResponse) {
        try performSynchronousHTTPWithRetry(serviceName: serviceName, cancellationToken: cancellationToken) {
            try performSynchronousUploadRequest(request, fromFile: fileURL, cancellationToken: cancellationToken)
        }
    }

    private static func performSynchronousHTTPWithRetry(
        serviceName: String,
        cancellationToken: CompanionAssetUploadCancellationToken?,
        operation: () throws -> (Data, URLResponse)
    ) throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                try cancellationToken?.checkCancellation()
                let (data, response) = try operation()
                guard let http = response as? HTTPURLResponse else {
                    throw CompanionAssetUploadError.uploadFailed("\(serviceName) failed without an HTTP response.")
                }
                if (200..<300).contains(http.statusCode) {
                    return (data, http)
                }
                if isRetryableStatusCode(http.statusCode), attempt < retryDelays.count {
                    try sleepRetryDelay(retryDelays[attempt], cancellationToken: cancellationToken)
                    attempt += 1
                    continue
                }
                throw CompanionAssetUploadError.uploadFailed(userFacingHTTPError(serviceName: serviceName, statusCode: http.statusCode))
            } catch {
                if let uploadError = error as? CompanionAssetUploadError,
                   case .uploadCancelled = uploadError {
                    throw uploadError
                }
                if isRetryableNetworkError(error), attempt < retryDelays.count {
                    try sleepRetryDelay(retryDelays[attempt], cancellationToken: cancellationToken)
                    attempt += 1
                    continue
                }
                if let uploadError = error as? CompanionAssetUploadError {
                    throw uploadError
                }
                throw CompanionAssetUploadError.uploadFailed(userFacingNetworkError(serviceName: serviceName, error: error))
            }
        }
    }

    private static func sleepRetryDelay(
        _ delay: TimeInterval,
        cancellationToken: CompanionAssetUploadCancellationToken?
    ) throws {
        let deadline = Date().addingTimeInterval(delay)
        while Date() < deadline {
            try cancellationToken?.checkCancellation()
            Thread.sleep(forTimeInterval: max(0.01, min(0.1, deadline.timeIntervalSinceNow)))
        }
        try cancellationToken?.checkCancellation()
    }

    private static func isRetryableStatusCode(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        if case CompanionAssetUploadError.uploadFailed = error {
            return false
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func userFacingHTTPError(serviceName: String, statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "\(serviceName) was rejected (HTTP 400). Check the upload URL, bucket, path prefix, and request format."
        case 401, 403:
            return "\(serviceName) was rejected (HTTP \(statusCode)). Check credentials and storage permissions."
        case 404:
            return "\(serviceName) target was not found (HTTP 404). Check the endpoint, bucket, or upload URL."
        case 408, 425, 429:
            return "\(serviceName) was rate-limited or timed out (HTTP \(statusCode)) after retrying. Try again later."
        case 413:
            return "\(serviceName) target refused the file because it is too large (HTTP 413)."
        case 500...599:
            return "\(serviceName) target is temporarily unavailable (HTTP \(statusCode)) after retrying."
        default:
            return "\(serviceName) failed with HTTP \(statusCode)."
        }
    }

    private static func userFacingNetworkError(serviceName: String, error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet:
                return "\(serviceName) failed because this Mac is offline."
            case .timedOut:
                return "\(serviceName) timed out after retrying."
            case .cannotFindHost, .dnsLookupFailed:
                return "\(serviceName) could not resolve the upload host. Check the endpoint URL."
            case .cannotConnectToHost, .networkConnectionLost:
                return "\(serviceName) could not keep a connection to the upload host after retrying."
            default:
                break
            }
        }
        return "\(serviceName) failed: \(error.localizedDescription)"
    }

    private static func performSynchronousRequest(
        _ request: URLRequest,
        cancellationToken: CompanionAssetUploadCancellationToken?
    ) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        final class ResponseBox {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = ResponseBox()
        var task: URLSessionTask!
        task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        try cancellationToken?.register(task)
        task.resume()
        semaphore.wait()
        cancellationToken?.unregister(task)
        if let error = box.error {
            if cancellationToken?.isCancelled == true,
               (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == URLError.cancelled.rawValue {
                throw CompanionAssetUploadError.uploadCancelled
            }
            throw error
        }
        guard let data = box.data, let response = box.response else {
            throw CompanionAssetUploadError.uploadFailed("Upload failed without a response.")
        }
        return (data, response)
    }

    private static func performSynchronousUploadRequest(
        _ request: URLRequest,
        fromFile fileURL: URL,
        cancellationToken: CompanionAssetUploadCancellationToken?
    ) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        final class ResponseBox {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = ResponseBox()
        var task: URLSessionTask!
        task = URLSession.shared.uploadTask(with: request, fromFile: fileURL) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        try cancellationToken?.register(task)
        task.resume()
        semaphore.wait()
        cancellationToken?.unregister(task)
        if let error = box.error {
            if cancellationToken?.isCancelled == true,
               (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == URLError.cancelled.rawValue {
                throw CompanionAssetUploadError.uploadCancelled
            }
            throw error
        }
        guard let data = box.data, let response = box.response else {
            throw CompanionAssetUploadError.uploadFailed("Upload failed without a response.")
        }
        return (data, response)
    }
}
