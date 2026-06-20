import CryptoKit
import Foundation

enum CompanionDataRoot {
    private static let iCloudStorageStateFileName = "icloud-data-root-enabled"
    private static let legacyICloudSyncStateFileName = "icloud-sync-enabled"

    /// 数据根切换（导入数据包 / 切 iCloud / 移回本机）后广播，让能安全 reload 的 store 重新从当前数据根读取。
    static let didChangeNotification = Notification.Name("CompanionDataRootDidChange")

    /// 数据根切换“之前”广播：让有延迟落盘的 store（如日记）先把待写内容刷到旧数据根，避免最后几百毫秒的编辑丢失。
    /// 须在主线程同步 post（在真正搬移数据之前），观察者同步 flush。
    static let willChangeNotification = Notification.Name("CompanionDataRootWillChange")

    static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
    }

    static func localURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment)
            .appendingPathComponent(".companion", isDirectory: true)
            .standardizedFileURL
    }

    static func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Companion", isDirectory: true)
            .standardizedFileURL
    }

    static func iCloudStorageStateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        supportDirectory(environment: environment).appendingPathComponent(iCloudStorageStateFileName)
    }

    static func legacyICloudSyncStateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        supportDirectory(environment: environment).appendingPathComponent(legacyICloudSyncStateFileName)
    }

    static func iCloudDriveRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .standardizedFileURL
    }

    static func iCloudURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        iCloudDriveRoot(environment: environment)
            .appendingPathComponent("Companion", isDirectory: true)
            .standardizedFileURL
    }

    static func legacyNestedICloudURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        iCloudURL(environment: environment)
            .appendingPathComponent(".companion", isDirectory: true)
            .standardizedFileURL
    }

    static func currentURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        isICloudStorageEnabled(environment: environment)
            ? iCloudURL(environment: environment)
            : localURL(environment: environment)
    }

    static func isICloudStorageEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: iCloudStorageStateURL(environment: environment).path)
            || fileManager.fileExists(atPath: legacyICloudSyncStateURL(environment: environment).path) {
            return true
        }
        return legacyICloudSymlinkDestination(environment: environment) != nil
    }

    static func legacyICloudSymlinkDestination(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        let local = localURL(environment: environment)
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: local.path) else {
            return nil
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: local.deletingLastPathComponent())
            .standardizedFileURL
        let supportedDestinations = [
            iCloudURL(environment: environment).standardizedFileURL.path,
            legacyNestedICloudURL(environment: environment).standardizedFileURL.path
        ]
        return supportedDestinations.contains(resolved.path) ? resolved : nil
    }

    static func recoveryURLs(forFileNamed fileName: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let roots = [
            currentURL(environment: environment),
            iCloudURL(environment: environment),
            legacyNestedICloudURL(environment: environment),
            localURL(environment: environment)
        ]
        var seen = Set<String>()
        return roots.compactMap { root in
            let url = root.appendingPathComponent(fileName).standardizedFileURL
            guard seen.insert(url.path).inserted else {
                return nil
            }
            return url
        }
    }
}

struct CompanionDataPackageManifest: Codable {
    struct FileEntry: Codable {
        var path: String
        var size: Int64
        var sha256: String?
    }

    var schemaVersion: Int
    var exportedAt: String
    var appVersion: String
    var appBuild: String
    var dataRootName: String
    var files: [FileEntry]
}

enum CompanionDataPackageError: LocalizedError {
    case companionHomeMissing(URL)
    case invalidPackage
    case iCloudDriveUnavailable(URL)
    case iCloudDataRootConflict(URL)
    case iCloudAlreadyDisabled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .companionHomeMissing(let url):
            return CompanionL10n.format("Companion data folder does not exist: %@", url.path)
        case .invalidPackage:
            return CompanionL10n.text("The selected zip is not a valid Companion data package.")
        case .iCloudDriveUnavailable(let url):
            return CompanionL10n.format("iCloud Drive is not available at %@. Make sure iCloud Drive is enabled for this Mac.", url.path)
        case .iCloudDataRootConflict(let url):
            return CompanionL10n.format("The iCloud Companion data path already exists but is not a folder: %@", url.path)
        case .iCloudAlreadyDisabled:
            return CompanionL10n.text("iCloud storage is not enabled for Companion data.")
        case .commandFailed(let message):
            return message
        }
    }
}

final class CompanionDataPackageController {
    private static let runtimeOnlyDirectoryNames: Set<String> = [
        "mcp-tool-calls"
    ]

    private let fileManager = FileManager.default
    private let operationLock = NSRecursiveLock()
    private let environment: [String: String]
    private let home: URL
    private let appVersion: String
    private let appBuild: String
    private let assetUploadCredentialStore: CompanionAssetUploadCredentialStoring?

    private var companionHome: URL {
        CompanionDataRoot.localURL(environment: environment)
    }

    private var currentCompanionHome: URL {
        CompanionDataRoot.currentURL(environment: environment)
    }

    private var downloadsDirectory: URL {
        home.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var supportDirectory: URL {
        CompanionDataRoot.supportDirectory(environment: environment)
    }

    private var iCloudStorageStateURL: URL {
        CompanionDataRoot.iCloudStorageStateURL(environment: environment)
    }

    private var legacyICloudSyncStateURL: URL {
        CompanionDataRoot.legacyICloudSyncStateURL(environment: environment)
    }

    var iCloudDriveRoot: URL {
        CompanionDataRoot.iCloudDriveRoot(environment: environment)
    }

    var iCloudCompanionHome: URL {
        CompanionDataRoot.iCloudURL(environment: environment)
    }

    private var legacyNestedICloudCompanionHome: URL {
        CompanionDataRoot.legacyNestedICloudURL(environment: environment)
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        assetUploadCredentialStore: CompanionAssetUploadCredentialStoring? = nil
    ) {
        self.environment = environment
        self.assetUploadCredentialStore = assetUploadCredentialStore
        home = CompanionDataRoot.homeDirectory(environment: environment)
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    func isICloudStorageEnabled() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return CompanionDataRoot.isICloudStorageEnabled(environment: environment)
    }

    @discardableResult
    func repairLegacyICloudDataSplitIfNeeded() throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard isICloudStorageEnabled() else {
            return false
        }
        let migrated = try migrateLegacyNestedICloudDataIfNeeded()
        let materialized = try materializeLegacyICloudSymlinkIfNeeded()
        return migrated || materialized
    }

    func defaultDataPackageURL(prefix: String = "Companion-Data-Backup") -> URL {
        downloadsDirectory.appendingPathComponent("\(prefix)-\(Self.timestamp()).zip")
    }

    func defaultDiagnosticPackageURL() -> URL {
        downloadsDirectory.appendingPathComponent("Companion-Diagnostics-\(Self.timestamp()).zip")
    }

    @discardableResult
    func exportDataPackage(to destination: URL) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        try migrateSensitiveStoresBeforeExport()
        let source = try resolvedCompanionHome()
        let packageRoot = try temporaryDirectory(prefix: "CompanionDataPackage")
            .appendingPathComponent("CompanionDataPackage", isDirectory: true)
        try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        let copiedCompanionHome = packageRoot.appendingPathComponent(".companion", isDirectory: true)
        try runDitto(["--noextattr", "--noacl", source.path, copiedCompanionHome.path])
        try removeRuntimeOnlyData(from: copiedCompanionHome)

        let manifest = CompanionDataPackageManifest(
            schemaVersion: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            appBuild: appBuild,
            dataRootName: ".companion",
            files: fileEntries(under: source)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: packageRoot.appendingPathComponent("CompanionDataPackageManifest.json"), options: .atomic)

        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", packageRoot.path, destination.path])
        return destination
    }

    @discardableResult
    func importDataPackage(from packageURL: URL) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        let extractRoot = try temporaryDirectory(prefix: "CompanionDataImport")
        try runDitto(["-x", "-k", packageURL.path, extractRoot.path])
        let importedCompanionHome = try validatedImportedCompanionHome(in: extractRoot)

        let destination = currentCompanionHome
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let rollbackURL = defaultDataPackageURL(prefix: "Companion-Data-Rollback")
        try exportDataPackage(to: rollbackURL)

        try replaceCompanionHome(at: destination, with: importedCompanionHome)
        return rollbackURL
    }

    @discardableResult
    func exportDiagnosticPackage(to destination: URL) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        let source = try resolvedCompanionHome()
        let diagnosticRoot = try temporaryDirectory(prefix: "CompanionDiagnostics")
            .appendingPathComponent("CompanionDiagnostics", isDirectory: true)
        try fileManager.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)

        let summary: [String: Any] = [
            "schemaVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "appBuild": appBuild,
            "companionHome": diagnosticPathSummary(companionHome),
            "resolvedCompanionHome": diagnosticPathSummary(source),
            "iCloudStorageEnabled": isICloudStorageEnabled(),
            "files": fileEntries(under: source).map { ["path": $0.path, "size": $0.size] }
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try summaryData.write(to: diagnosticRoot.appendingPathComponent("diagnostic-summary.json"), options: .atomic)

        let redactedDirectory = diagnosticRoot.appendingPathComponent("redacted", isDirectory: true)
        try fileManager.createDirectory(at: redactedDirectory, withIntermediateDirectories: true)
        for name in ["ai-settings.json", "ai-credentials.json", "asset-upload-credentials.json"] {
            let url = source.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                continue
            }
            try redactedText(text).write(
                to: redactedDirectory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        if let assetUploadProfilesJSON = CompanionAssetUploadProfileStore(
            environment: environment,
            fileManager: fileManager
        ).diagnosticJSON() {
            try assetUploadProfilesJSON.write(
                to: redactedDirectory.appendingPathComponent(CompanionAssetUploadProfileStore.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        if let assetUploadHistoryJSON = CompanionAssetUploadHistoryStore(
            environment: environment,
            fileManager: fileManager
        ).diagnosticJSON() {
            try assetUploadHistoryJSON.write(
                to: redactedDirectory.appendingPathComponent(CompanionAssetUploadHistoryStore.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        if let auditJSONL = CompanionMCPAuditLog(environment: environment, fileManager: fileManager).diagnosticJSONL() {
            try auditJSONL.write(
                to: redactedDirectory.appendingPathComponent(CompanionMCPAuditLog.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        if let workflowRunsJSON = CompanionWorkflowRunStore(environment: environment, fileManager: fileManager).diagnosticJSON() {
            try workflowRunsJSON.write(
                to: redactedDirectory.appendingPathComponent(CompanionWorkflowRunStore.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", diagnosticRoot.path, destination.path])
        return destination
    }

    @discardableResult
    func enableICloudStorage() throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard fileManager.fileExists(atPath: iCloudDriveRoot.path) else {
            throw CompanionDataPackageError.iCloudDriveUnavailable(iCloudDriveRoot)
        }

        try materializeLegacyICloudSymlinkIfNeeded()
        _ = try migrateLegacyNestedICloudDataIfNeeded()
        if !fileManager.fileExists(atPath: companionHome.path) {
            try fileManager.createDirectory(at: companionHome, withIntermediateDirectories: true)
        }

        let rollbackURL = defaultDataPackageURL(prefix: "Companion-Data-Before-iCloud")
        try exportDataPackage(to: rollbackURL)
        let source = companionHome
        try fileManager.createDirectory(at: iCloudDriveRoot, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        let iCloudDataExists = fileManager.fileExists(atPath: iCloudCompanionHome.path, isDirectory: &isDirectory)
        if iCloudDataExists, !isDirectory.boolValue {
            throw CompanionDataPackageError.iCloudDataRootConflict(iCloudCompanionHome)
        }

        let localHasUserData = containsCompanionUserData(under: source)
        let cloudHasUserData = iCloudDataExists && containsCompanionUserData(under: iCloudCompanionHome)
        // Existing iCloud data may have come from another Mac. Treat it as authoritative
        // so a new device with empty/default local files cannot erase the shared data root.
        if !cloudHasUserData, localHasUserData {
            try mirrorDirectory(from: source, to: iCloudCompanionHome)
        } else if !cloudHasUserData, !iCloudDataExists {
            try fileManager.createDirectory(at: iCloudCompanionHome, withIntermediateDirectories: true)
        }

        try setICloudStorageEnabled(true)
        return rollbackURL
    }

    @discardableResult
    func disableICloudStorage() throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard isICloudStorageEnabled() else {
            throw CompanionDataPackageError.iCloudAlreadyDisabled
        }
        guard fileManager.fileExists(atPath: iCloudDriveRoot.path) else {
            throw CompanionDataPackageError.iCloudDriveUnavailable(iCloudDriveRoot)
        }

        try materializeLegacyICloudSymlinkIfNeeded()
        _ = try migrateLegacyNestedICloudDataIfNeeded()
        let rollbackURL = defaultDataPackageURL(prefix: "Companion-Data-Before-iCloud-Off")
        try exportDataPackage(to: rollbackURL)
        if fileManager.fileExists(atPath: iCloudCompanionHome.path) {
            try replaceDirectory(at: companionHome, with: iCloudCompanionHome)
        } else {
            try fileManager.createDirectory(at: companionHome, withIntermediateDirectories: true)
        }
        try setICloudStorageEnabled(false)
        return rollbackURL
    }

    func openCompanionHome() {
        operationLock.lock()
        defer { operationLock.unlock() }
        let root = currentCompanionHome
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        _ = runProcess("/usr/bin/open", [root.path])
    }

    func openICloudCompanionHome() {
        operationLock.lock()
        defer { operationLock.unlock() }
        try? fileManager.createDirectory(at: iCloudCompanionHome, withIntermediateDirectories: true)
        _ = runProcess("/usr/bin/open", [iCloudCompanionHome.path])
    }

    private func resolvedCompanionHome() throws -> URL {
        let root = currentCompanionHome
        guard fileManager.fileExists(atPath: root.path) else {
            throw CompanionDataPackageError.companionHomeMissing(root)
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func migrateSensitiveStoresBeforeExport() throws {
        try CompanionAssetUploadProfileStore(
            environment: environment,
            fileManager: fileManager,
            credentialStore: assetUploadCredentialStore
        ).migrateLegacyCredentialsIfNeeded()
    }

    private func replaceCompanionHome(at destination: URL, with importedCompanionHome: URL) throws {
        try materializeLegacyICloudSymlinkIfNeeded()
        try replaceDirectory(at: destination, with: importedCompanionHome)
    }

    private func replaceDirectory(at destination: URL, with source: URL) throws {
        let previousURL = try temporaryDirectory(prefix: "CompanionImportPrevious")
            .appendingPathComponent(".companion-previous", isDirectory: true)
        var movedExisting = false

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: previousURL)
                movedExisting = true
            }
            try runDitto(["--noextattr", "--noacl", source.path, destination.path])
        } catch {
            try? fileManager.removeItem(at: destination)
            if movedExisting, fileManager.fileExists(atPath: previousURL.path) {
                try? fileManager.moveItem(at: previousURL, to: destination)
            }
            throw error
        }
    }

    private func mirrorDirectory(from source: URL, to destination: URL) throws {
        try replaceDirectory(at: destination, with: source)
    }

    private func setICloudStorageEnabled(_ enabled: Bool) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if enabled {
            try "enabled\n".write(to: iCloudStorageStateURL, atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: legacyICloudSyncStateURL.path) {
                try fileManager.removeItem(at: legacyICloudSyncStateURL)
            }
        } else {
            if fileManager.fileExists(atPath: iCloudStorageStateURL.path) {
                try fileManager.removeItem(at: iCloudStorageStateURL)
            }
            if fileManager.fileExists(atPath: legacyICloudSyncStateURL.path) {
                try fileManager.removeItem(at: legacyICloudSyncStateURL)
            }
        }
    }

    @discardableResult
    private func materializeLegacyICloudSymlinkIfNeeded() throws -> Bool {
        guard let destination = CompanionDataRoot.legacyICloudSymlinkDestination(environment: environment) else {
            return false
        }
        let temporaryLocal = try temporaryDirectory(prefix: "CompanionICloudSymlinkMaterialize")
            .appendingPathComponent(".companion", isDirectory: true)
        let source = fileManager.fileExists(atPath: destination.path)
            ? destination
            : (fileManager.fileExists(atPath: iCloudCompanionHome.path) ? iCloudCompanionHome : nil)
        if let source {
            try runDitto(["--noextattr", "--noacl", source.path, temporaryLocal.path])
        } else {
            try fileManager.createDirectory(at: temporaryLocal, withIntermediateDirectories: true)
        }
        try fileManager.removeItem(at: companionHome)
        try fileManager.moveItem(at: temporaryLocal, to: companionHome)
        return true
    }

    private func migrateLegacyNestedICloudDataIfNeeded() throws -> Bool {
        guard fileManager.fileExists(atPath: legacyNestedICloudCompanionHome.path),
              containsCompanionUserData(under: legacyNestedICloudCompanionHome)
        else {
            return false
        }

        if containsCompanionUserDataOutsideLegacyNested(under: iCloudCompanionHome) {
            return try copyMissingLegacyNestedFiles()
        }

        let migrated = try temporaryDirectory(prefix: "CompanionLegacyICloudData")
            .appendingPathComponent("Companion", isDirectory: true)
        try runDitto(["--noextattr", "--noacl", legacyNestedICloudCompanionHome.path, migrated.path])

        if fileManager.fileExists(atPath: iCloudCompanionHome.path) {
            try fileManager.removeItem(at: iCloudCompanionHome)
        }
        try fileManager.moveItem(at: migrated, to: iCloudCompanionHome)
        return true
    }

    private func copyMissingLegacyNestedFiles() throws -> Bool {
        try fileManager.createDirectory(at: iCloudCompanionHome, withIntermediateDirectories: true)
        var copied = false

        let topLevelURLs = try fileManager.contentsOfDirectory(
            at: legacyNestedICloudCompanionHome,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        )
        for source in topLevelURLs {
            let relativePath = source.lastPathComponent
            guard !isIgnorableCloudMetadata(relativePath) else {
                continue
            }
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                continue
            }
            let destination = iCloudCompanionHome.appendingPathComponent(relativePath)
            guard !fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            try fileManager.copyItem(at: source, to: destination)
            copied = true
        }

        return copied
    }

    private func validatedImportedCompanionHome(in extractRoot: URL) throws -> URL {
        guard let packageRoot = try findDataPackageRoot(in: extractRoot) else {
            throw CompanionDataPackageError.invalidPackage
        }
        let manifestURL = packageRoot.appendingPathComponent("CompanionDataPackageManifest.json")
        let manifest = try JSONDecoder().decode(CompanionDataPackageManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.dataRootName == ".companion" else {
            throw CompanionDataPackageError.invalidPackage
        }
        let importedCompanionHome = packageRoot.appendingPathComponent(".companion", isDirectory: true)
        var isDirectory: ObjCBool = false
        let extractPath = extractRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let importedPath = importedCompanionHome.resolvingSymlinksInPath().standardizedFileURL.path
        guard fileManager.fileExists(atPath: importedCompanionHome.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              importedPath.hasPrefix(extractPath + "/")
        else {
            throw CompanionDataPackageError.invalidPackage
        }
        try validateImportTree(under: importedCompanionHome)
        try validateManifest(manifest, against: importedCompanionHome)
        try removeRuntimeOnlyData(from: importedCompanionHome)
        return importedCompanionHome
    }

    private func findDataPackageRoot(in extractRoot: URL) throws -> URL? {
        let direct = extractRoot.appendingPathComponent("CompanionDataPackage", isDirectory: true)
        if fileManager.fileExists(atPath: direct.appendingPathComponent("CompanionDataPackageManifest.json").path),
           fileManager.fileExists(atPath: direct.appendingPathComponent(".companion", isDirectory: true).path) {
            return direct
        }
        if fileManager.fileExists(atPath: extractRoot.appendingPathComponent("CompanionDataPackageManifest.json").path),
           fileManager.fileExists(atPath: extractRoot.appendingPathComponent(".companion", isDirectory: true).path) {
            return extractRoot
        }
        guard let enumerator = fileManager.enumerator(at: extractRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw CompanionDataPackageError.invalidPackage
        }
        for case let url as URL in enumerator where url.lastPathComponent == "CompanionDataPackageManifest.json" {
            let candidate = url.deletingLastPathComponent()
            let companion = candidate.appendingPathComponent(".companion", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: companion.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func validateManifest(_ manifest: CompanionDataPackageManifest, against root: URL) throws {
        var manifestEntries: [String: CompanionDataPackageManifest.FileEntry] = [:]
        for entry in manifest.files {
            guard isSafeRelativePath(entry.path), manifestEntries[entry.path] == nil else {
                throw CompanionDataPackageError.invalidPackage
            }
            manifestEntries[entry.path] = entry
        }

        let actualEntries = Dictionary(uniqueKeysWithValues: fileEntries(under: root).map { ($0.path, $0) })
        guard Set(manifestEntries.keys) == Set(actualEntries.keys) else {
            throw CompanionDataPackageError.invalidPackage
        }

        for (path, expected) in manifestEntries {
            guard let actual = actualEntries[path],
                  actual.size == expected.size
            else {
                throw CompanionDataPackageError.invalidPackage
            }
            if let expectedHash = expected.sha256, let actualHash = actual.sha256,
               expectedHash.lowercased() != actualHash.lowercased() {
                throw CompanionDataPackageError.invalidPackage
            }
        }
    }

    private func validateImportTree(under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
            options: []
        ) else {
            throw CompanionDataPackageError.invalidPackage
        }

        for case let url as URL in enumerator {
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                throw CompanionDataPackageError.invalidPackage
            }

            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            guard isSafeRelativePath(relativePath) else {
                throw CompanionDataPackageError.invalidPackage
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isSymbolicLink != true, values.isPackage != true else {
                throw CompanionDataPackageError.invalidPackage
            }
            if values.isDirectory == true || values.isRegularFile == true {
                continue
            }
            throw CompanionDataPackageError.invalidPackage
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return false
        }
        return !path.split(separator: "/").contains("..")
    }

    private func containsCompanionUserData(under root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return false
        }

        for case let url as URL in enumerator {
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                continue
            }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            if isIgnorableCloudMetadata(relativePath) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true || values?.isSymbolicLink == true {
                return true
            }
        }

        return false
    }

    private func containsCompanionUserDataOutsideLegacyNested(under root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return false
        }

        for case let url as URL in enumerator {
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                continue
            }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            if relativePath == ".companion" || relativePath.hasPrefix(".companion/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isIgnorableCloudMetadata(relativePath) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true || values?.isSymbolicLink == true {
                return true
            }
        }

        return false
    }

    private func isIgnorableCloudMetadata(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            return true
        }
        return fileName == ".DS_Store"
            || fileName == ".localized"
            || components.contains(".TemporaryItems")
    }

    private func fileEntries(under root: URL) -> [CompanionDataPackageManifest.FileEntry] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants])
        else {
            return []
        }

        var entries: [CompanionDataPackageManifest.FileEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else {
                if shouldSkipDataPackagePath(url, rootPath: rootPath),
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                continue
            }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            guard !isRuntimeOnlyRelativePath(relative) else {
                continue
            }
            let sha256 = fileSHA256(url)
            entries.append(CompanionDataPackageManifest.FileEntry(path: relative, size: Int64(values.fileSize ?? 0), sha256: sha256))
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func shouldSkipDataPackagePath(_ url: URL, rootPath: String) -> Bool {
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return false
        }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        return isRuntimeOnlyRelativePath(relative)
    }

    private func isRuntimeOnlyRelativePath(_ relativePath: String) -> Bool {
        let first = relativePath.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
        guard let first else {
            return false
        }
        return Self.runtimeOnlyDirectoryNames.contains(first)
    }

    private func removeRuntimeOnlyData(from companionHome: URL) throws {
        for name in Self.runtimeOnlyDirectoryNames {
            let url = companionHome.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func fileSHA256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func redactedText(_ text: String) -> String {
        if let json = redactedJSONText(text) {
            return json
        }
        return redactedKeyValueText(text)
    }

    private func diagnosticPathSummary(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let localPath = companionHome.resolvingSymlinksInPath().standardizedFileURL.path
        let iCloudPath = iCloudCompanionHome.resolvingSymlinksInPath().standardizedFileURL.path

        if path == localPath {
            return "~/.companion"
        }
        if path == iCloudPath {
            return "iCloud Drive/Companion"
        }

        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[redacted-path]" : "[redacted-path]/\(name)"
    }

    private func redactedJSONText(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        let redacted = redactedJSONValue(object, key: nil)
        guard JSONSerialization.isValidJSONObject(redacted),
              let redactedData = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }
        return String(data: redactedData, encoding: .utf8)
    }

    private func redactedJSONValue(_ value: Any, key: String?) -> Any {
        if let key, isSensitiveDiagnosticKey(key) {
            return "[REDACTED]"
        }

        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                output[childKey] = redactedJSONValue(childValue, key: childKey)
            }
            return output
        }

        if let array = value as? [Any] {
            return array.map { redactedJSONValue($0, key: nil) }
        }

        return value
    }

    private func redactedKeyValueText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { redactedKeyValueLine(String($0)) }
            .joined(separator: "\n")
    }

    private func redactedKeyValueLine(_ line: String) -> String {
        guard let separator = keyValueSeparatorIndex(in: line) else {
            return line
        }

        let key = diagnosticKey(from: String(line[..<separator]))
        guard isSensitiveDiagnosticKey(key) else {
            return line
        }

        var valueStart = line.index(after: separator)
        while valueStart < line.endIndex, line[valueStart].isWhitespace {
            valueStart = line.index(after: valueStart)
        }

        let prefix = String(line[..<valueStart])
        guard valueStart < line.endIndex else {
            return prefix + "\"[REDACTED]\""
        }

        let firstValueCharacter = line[valueStart]
        if firstValueCharacter == "\"" || firstValueCharacter == "'" {
            var index = line.index(after: valueStart)
            var previousWasEscape = false
            while index < line.endIndex {
                let character = line[index]
                if character == firstValueCharacter && !previousWasEscape {
                    let afterValue = line.index(after: index)
                    return prefix + "\(firstValueCharacter)[REDACTED]\(firstValueCharacter)" + String(line[afterValue...])
                }
                previousWasEscape = character == "\\" && !previousWasEscape
                if character != "\\" {
                    previousWasEscape = false
                }
                index = line.index(after: index)
            }
            return prefix + "\(firstValueCharacter)[REDACTED]\(firstValueCharacter)"
        }

        var valueEnd = valueStart
        while valueEnd < line.endIndex {
            let character = line[valueEnd]
            if character.isWhitespace || character == "," || character == "}" || character == "]" {
                break
            }
            valueEnd = line.index(after: valueEnd)
        }
        return prefix + "\"[REDACTED]\"" + String(line[valueEnd...])
    }

    private func keyValueSeparatorIndex(in line: String) -> String.Index? {
        var quote: Character?
        var previousWasEscape = false

        for index in line.indices {
            let character = line[index]

            if let currentQuote = quote {
                if character == currentQuote && !previousWasEscape {
                    quote = nil
                }
                previousWasEscape = character == "\\" && !previousWasEscape
                if character != "\\" {
                    previousWasEscape = false
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                previousWasEscape = false
                continue
            }

            if character == ":" || character == "=" {
                return index
            }
        }

        return nil
    }

    private func diagnosticKey(from raw: String) -> String {
        var key = raw
        if let delimiter = key.lastIndex(where: { $0 == "{" || $0 == "," }) {
            key = String(key[key.index(after: delimiter)...])
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 2,
           let first = key.first,
           let last = key.last,
           (first == "\"" || first == "'"),
           first == last {
            key.removeFirst()
            key.removeLast()
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSensitiveDiagnosticKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let compact = normalized.replacingOccurrences(of: "_", with: "")

        return normalized.contains("api_key")
            || compact.contains("apikey")
            || normalized.contains("access_token")
            || compact.contains("accesstoken")
            || normalized.contains("refresh_token")
            || compact.contains("refreshtoken")
            || normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("authorization")
            || normalized.contains("auth")
            || normalized.contains("password")
    }

    private func runDitto(_ arguments: [String]) throws {
        let status = runProcess("/usr/bin/ditto", arguments)
        guard status == 0 else {
            throw CompanionDataPackageError.commandFailed("ditto failed with status \(status): \(arguments.joined(separator: " "))")
        }
    }

    @discardableResult
    private func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
