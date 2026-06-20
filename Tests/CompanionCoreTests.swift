import Darwin
import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestError.failure(message)
    }
}

@main
enum CompanionCoreTests {
    private static var temporaryHomes: [URL] = []

    static func main() throws {
        defer { cleanupTemporaryHomes() }

        let tests: [(name: String, run: () throws -> Void)] = [
            ("testAISettingsStoreSavesProviderConfiguration", testAISettingsStoreSavesProviderConfiguration),
            ("testMCPRegistryContainsCompanionToolsOnly", testMCPRegistryContainsCompanionToolsOnly),
            ("testReminderParseDraftTool", testReminderParseDraftTool),
            ("testFocusReviewGenerateUsesCompanionData", testFocusReviewGenerateUsesCompanionData),
            ("testDataPackageImportRejectsSymlink", testDataPackageImportRejectsSymlink),
            ("testAssetUploadProfileStorePersistsCustomHTTPProfile", testAssetUploadProfileStorePersistsCustomHTTPProfile)
        ]

        var failures: [(String, Error)] = []
        for test in tests {
            do {
                try test.run()
                print("✓ \(test.name)")
            } catch {
                failures.append((test.name, error))
                fputs("✗ \(test.name): \(error)\n", stderr)
            }
        }

        if !failures.isEmpty {
            fputs("\n\(failures.count) test(s) failed.\n", stderr)
            exit(1)
        }

        print("\n\(tests.count) tests passed.")
    }

    private static func testAISettingsStoreSavesProviderConfiguration() throws {
        let environment = try testEnvironment()
        let store = CompanionAISettingsStore(environment: environment)

        let initial = try store.snapshot()
        try expect(!initial.hasStoredAPIKey, "new AI settings should start without a stored API key")

        try store.save(CompanionAISettingsInput(
            providerName: "Local Companion AI",
            baseURL: "https://api.example.com/v1",
            model: "example-model",
            apiKey: "sk-test"
        ))

        let snapshot = try store.snapshot()
        let configuration = try store.providerConfiguration()
        try expect(snapshot.hasStoredAPIKey, "saved AI settings should report a stored API key")
        try expect(snapshot.menuSummary == "Local Companion AI · example-model", "menu summary should use lightweight AI settings")
        try expect(configuration.name == "Local Companion AI", "provider name should round-trip")
        try expect(configuration.baseURL == "https://api.example.com/v1", "base URL should round-trip")
        try expect(configuration.model == "example-model", "model should round-trip")
        try expect(configuration.apiKey == "sk-test", "API key should load from Companion credential storage")
    }

    private static func testMCPRegistryContainsCompanionToolsOnly() throws {
        let registry = CompanionWorkflowToolRegistry.defaultRegistry(environment: try testEnvironment())
        let ids = Set(registry.descriptors().map(\.id))
        let expected = Set([
            "companion.asset.upload",
            "companion.focusReview.generate",
            "companion.journal.appendToday",
            "companion.pomodoro.startFocus",
            "companion.reminder.create",
            "companion.reminder.createBatch",
            "companion.reminder.parseDraft"
        ])
        try expect(ids == expected, "MCP registry should expose only Companion-owned tools")
    }

    private static func testReminderParseDraftTool() throws {
        let registry = CompanionWorkflowToolRegistry.defaultRegistry(environment: try testEnvironment())
        let result = registry.invoke(CompanionWorkflowToolInvocation(
            toolID: "companion.reminder.parseDraft",
            arguments: ["text": .string("30分钟后 喝水")],
            dryRun: true,
            caller: "test"
        ))

        try expect(result.status == .succeeded, "reminder parser should parse relative Chinese time")
        try expect(result.output["title"]?.stringValue == "喝水", "reminder parser should extract the reminder title")
        try expect(result.output["fireDate"]?.stringValue?.isEmpty == false, "reminder parser should return a fire date")
    }

    private static func testFocusReviewGenerateUsesCompanionData() throws {
        let registry = CompanionWorkflowToolRegistry.defaultRegistry(environment: try testEnvironment())
        let result = registry.invoke(CompanionWorkflowToolInvocation(
            toolID: "companion.focusReview.generate",
            arguments: ["format": .string("markdown")],
            dryRun: true,
            caller: "test"
        ))

        try expect(result.status == .succeeded, "focus review should generate from local Companion data")
        try expect(result.output["markdown"]?.stringValue?.contains("Focus Review") == true, "markdown output should be present when requested")
        try expect(result.output["todayFocusMinutes"]?.intValue == 0, "empty test home should have zero focus minutes")
    }

    private static func testAssetUploadProfileStorePersistsCustomHTTPProfile() throws {
        let environment = try testEnvironment()
        let store = CompanionAssetUploadProfileStore(environment: environment)
        let profile = CompanionAssetUploadProfile(
            id: "custom-http",
            type: .customHTTP,
            name: "Companion Upload",
            enabled: true,
            s3: nil,
            customHTTP: CompanionAssetUploadProfile.CustomHTTPConfig(
                uploadURL: "https://upload.example.com/files",
                method: .post,
                bodyMode: .multipart,
                fileFieldName: "file",
                additionalHeaders: ["X-Companion": "1"],
                sensitiveHeaderReferences: nil,
                responseURLJSONPath: "url",
                publicBaseURL: "https://cdn.example.com"
            ),
            limits: CompanionAssetUploadProfile.Limits(maxSizeBytes: 2 * 1024 * 1024, allowedMimeTypes: nil),
            defaultOutputFormat: .markdown,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastUsedAt: nil
        )

        try store.upsert(profile, makeDefault: true)
        let loaded = try store.defaultProfile(requireCredentials: false)
        try expect(loaded.id == profile.id, "default asset upload profile should persist")
        try expect(loaded.profileSummary == "Companion Upload (Custom HTTP)", "profile summary should identify custom HTTP upload")
        try expect(loaded.resolvedDefaultOutputFormat == .markdown, "default output format should persist")
    }

    private static func testDataPackageImportRejectsSymlink() throws {
        let environment = try testEnvironment()
        let home = URL(fileURLWithPath: environment["HOME"]!, isDirectory: true)
        let stagingRoot = home.appendingPathComponent("malicious-package", isDirectory: true)
        let packageRoot = stagingRoot.appendingPathComponent("CompanionDataPackage", isDirectory: true)
        let companionHome = packageRoot.appendingPathComponent(".companion", isDirectory: true)
        try FileManager.default.createDirectory(at: companionHome, withIntermediateDirectories: true)

        let journalURL = companionHome.appendingPathComponent("journal.json")
        try #"{"entries":[]}"#.write(to: journalURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: companionHome.appendingPathComponent("outside-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        let manifest = CompanionDataPackageManifest(
            schemaVersion: 1,
            exportedAt: "2026-06-19T00:00:00Z",
            appVersion: "0.1.0",
            appBuild: "1",
            dataRootName: ".companion",
            files: [
                CompanionDataPackageManifest.FileEntry(
                    path: "journal.json",
                    size: Int64((try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                    sha256: nil
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageRoot.appendingPathComponent("CompanionDataPackageManifest.json"),
            options: .atomic
        )

        let packageURL = home.appendingPathComponent("malicious.companion.zip")
        let status = runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", packageRoot.path, packageURL.path])
        try expect(status == 0, "test package should be created")

        do {
            _ = try CompanionDataPackageController(environment: environment).importDataPackage(from: packageURL)
            try expect(false, "data package import should reject symbolic links")
        } catch CompanionDataPackageError.invalidPackage {
            return
        }
    }

    private static func testEnvironment() throws -> [String: String] {
        let home = try temporaryHome()
        return ["HOME": home.path]
    }

    private static func temporaryHome() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("companion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryHomes.append(root)
        return root
    }

    private static func cleanupTemporaryHomes() {
        for url in temporaryHomes {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private static func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
