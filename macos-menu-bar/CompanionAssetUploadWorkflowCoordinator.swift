import AppKit
import Foundation
import UniformTypeIdentifiers

final class CompanionAssetUploadWorkflowCoordinator {
    var onError: ((String) -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowS3Settings: (() -> Void)?
    var onPresentWorkflowConsole: ((CompanionWorkflowRunSnapshot) -> Void)?
    var onRefreshWorkflowConsole: ((UUID) -> Void)?

    private let assetUploadProfileStore: CompanionAssetUploadProfileStore
    private let assetUploadHistoryStore: CompanionAssetUploadHistoryStore
    private let mcpClientProfilesStore: MCPClientProfilesStore
    private let workflowRunStore: CompanionWorkflowRunStore
    private let mcpAuditLog: CompanionMCPAuditLog
    private let statusItemText: NSMenuItem
    private let desktopPet: DesktopPetFeature

    private var activeAssetUploadRunIDs = Set<UUID>()
    private var assetUploadCancellationTokens: [UUID: CompanionAssetUploadCancellationToken] = [:]
    private var assetUploadRetryContexts: [UUID: AssetUploadRetryContext] = [:]
    private var assetUploadRetryContextOrder: [UUID] = []
    private let maxAssetUploadRetryContexts = 20

    init(
        profileStore: CompanionAssetUploadProfileStore,
        historyStore: CompanionAssetUploadHistoryStore,
        mcpClientProfilesStore: MCPClientProfilesStore,
        workflowRunStore: CompanionWorkflowRunStore,
        auditLog: CompanionMCPAuditLog,
        statusItemText: NSMenuItem,
        desktopPet: DesktopPetFeature
    ) {
        self.assetUploadProfileStore = profileStore
        self.assetUploadHistoryStore = historyStore
        self.mcpClientProfilesStore = mcpClientProfilesStore
        self.workflowRunStore = workflowRunStore
        self.mcpAuditLog = auditLog
        self.statusItemText = statusItemText
        self.desktopPet = desktopPet
    }

    func cancelActiveRunsForTermination() {
        for token in assetUploadCancellationTokens.values {
            token.cancel()
        }
        for runID in activeAssetUploadRunIDs {
            workflowRunStore.cancel(
                id: runID,
                status: .blocked,
                message: "Asset upload was interrupted because Companion terminated before completion."
            )
        }
        activeAssetUploadRunIDs.removeAll()
        assetUploadCancellationTokens.removeAll()
    }

    func cancelRun(_ runID: UUID) {
        assetUploadCancellationTokens[runID]?.cancel()
    }

    private func showError(_ message: String) {
        onError?(message)
    }

    private func showAssetUploadSettingsAction() {
        onShowSettings?()
    }

    private func showAssetUploadS3SettingsAction() {
        NSApp.activate(ignoringOtherApps: true)
        (onShowS3Settings ?? onShowSettings)?()
    }

    private func presentWorkflowConsole(_ snapshot: CompanionWorkflowRunSnapshot) {
        onPresentWorkflowConsole?(snapshot)
    }

    private func refreshWorkflowConsole(runID: UUID) {
        onRefreshWorkflowConsole?(runID)
    }

    private static func statusTitle(_ key: String, _ arguments: CVarArg...) -> String {
        let message = String(format: CompanionL10n.text(key), arguments: arguments)
        return CompanionL10n.format("Status: %@", message)
    }

    func retryAssetUploadStep(runID: UUID, stepID: UUID, run: CompanionWorkflowRunRecord) -> Bool {
        guard run.toolID == "companion.asset.upload",
              let context = assetUploadRetryContexts[runID],
              !context.failedItems.isEmpty
        else {
            return false
        }

        let cancellationToken = CompanionAssetUploadCancellationToken()
        activeAssetUploadRunIDs.insert(runID)
        assetUploadCancellationTokens[runID] = cancellationToken
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.performAssetUploadRetry(
                context: context,
                runID: runID,
                cancellationToken: cancellationToken
            )
            DispatchQueue.main.async {
                self.noteAssetUploadRunFinished(runID)
                if result.remainingItems.isEmpty {
                    self.assetUploadRetryContexts.removeValue(forKey: runID)
                } else {
                    var next = context
                    next.failedItems = result.remainingItems
                    self.assetUploadRetryContexts[runID] = next
                }

                self.workflowRunStore.markStepRetryFinished(id: runID, stepID: stepID, result: result.toolResult)
                if !result.formattedLinks.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.formattedLinks.joined(separator: "\n"), forType: .string)
                    ClipboardTranslationFeature.suppressPasteboardChange(NSPasteboard.general.changeCount)
                }
                self.refreshWorkflowConsole(runID: runID)
            }
        }
        return true
    }

    private func performAssetUploadRetry(
        context: AssetUploadRetryContext,
        runID: UUID,
        cancellationToken: CompanionAssetUploadCancellationToken
    ) -> AssetUploadRetryAttemptResult {
        let profile: CompanionAssetUploadProfile
        do {
            profile = try assetUploadProfileStore.profile(id: context.profileID, requireCredentials: true)
        } catch {
            return AssetUploadRetryAttemptResult(
                formattedLinks: [],
                remainingItems: context.failedItems,
                toolResult: .failed(
                    code: "asset_upload_profile_unavailable",
                    message: error.localizedDescription
                )
            )
        }

        guard profile.configHash == context.profileConfigHash else {
            let message = "Asset upload profile changed after this run. Start a new upload so Companion can ask for approval again."
            return AssetUploadRetryAttemptResult(
                formattedLinks: [],
                remainingItems: context.failedItems,
                toolResult: .failed(code: "asset_upload_profile_changed", message: message)
            )
        }

        let service = CompanionAssetUploadService(
            profileStore: assetUploadProfileStore,
            cancellationToken: cancellationToken
        )
        var formattedLinks: [String] = []
        var remainingItems: [AssetUploadRetryItem] = []
        var failures: [FinderAssetUploadFailure] = []

        for item in context.failedItems {
            do {
                let upload = try service.upload(item.request)
                assetUploadHistoryStore.appendSuccess(upload, runID: runID, source: "\(context.sourceName)-retry")
                if let formatted = upload.formatted?.trimmingCharacters(in: .whitespacesAndNewlines), !formatted.isEmpty {
                    formattedLinks.append(formatted)
                } else if let url = upload.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                    formattedLinks.append(url)
                }
            } catch {
                assetUploadHistoryStore.appendFailure(
                    fileNameSummary: item.name,
                    sizeBytes: item.sizeBytes,
                    profileSummary: context.profileSummary,
                    profileID: context.profileID,
                    format: context.outputFormat,
                    runID: runID,
                    source: "\(context.sourceName)-retry",
                    errorSummary: error.localizedDescription
                )
                remainingItems.append(item)
                failures.append(FinderAssetUploadFailure(fileName: item.name, message: error.localizedDescription))
            }
        }

        if remainingItems.isEmpty {
            return AssetUploadRetryAttemptResult(
                formattedLinks: formattedLinks,
                remainingItems: [],
                toolResult: .succeeded(
                    output: [
                        "uploadedCount": .number(Double(formattedLinks.count)),
                        "failedCount": .number(0),
                        "links": .array(formattedLinks.map { .string($0) }),
                        "profileSummary": .string(context.profileSummary),
                        "format": .string(context.outputFormat.rawValue)
                    ],
                    outputSummary: "Retried \(formattedLinks.count) asset upload(s)."
                )
            )
        }

        let summary = failures.prefix(3).map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
        let message = formattedLinks.isEmpty
            ? "Retry failed for \(remainingItems.count) asset(s): \(summary)"
            : "Retry uploaded \(formattedLinks.count) asset(s), failed \(remainingItems.count): \(summary)"
        return AssetUploadRetryAttemptResult(
            formattedLinks: formattedLinks,
            remainingItems: remainingItems,
            toolResult: CompanionWorkflowToolResult(
                status: .failed,
                output: [
                    "uploadedCount": .number(Double(formattedLinks.count)),
                    "failedCount": .number(Double(remainingItems.count)),
                    "failedFileNames": .array(remainingItems.prefix(10).map { .string($0.name) }),
                    "profileSummary": .string(context.profileSummary),
                    "format": .string(context.outputFormat.rawValue)
                ],
                outputSummary: message,
                userMessage: message,
                missingInputs: [],
                error: CompanionWorkflowToolError(
                    code: formattedLinks.isEmpty ? "asset_upload_retry_failed" : "asset_upload_retry_partial_failed",
                    message: message,
                    recoverySuggestion: nil
                )
            )
        )
    }

    func uploadFilesWithCompanion(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let fileURLs = serviceFileURLs(from: pasteboard)
        guard !fileURLs.isEmpty else {
            error.pointee = CompanionL10n.text("No files were provided to Companion.") as NSString
            return
        }
        uploadFinderFileURLs(fileURLs, sourceName: "finder-service") { validationError in
            error.pointee = validationError as NSString
            self.showError(validationError)
        }
    }

    private func uploadFinderFileURLs(
        _ fileURLs: [URL],
        sourceName: String,
        onValidationError: @escaping (String) -> Void
    ) {
        let standardizedFileURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedFileURLs.isEmpty else {
            onValidationError(CompanionL10n.text("No files were provided to Companion."))
            return
        }
        let defaultProfile: CompanionAssetUploadProfile
        do {
            defaultProfile = try assetUploadProfileStore.defaultProfile(requireCredentials: true)
        } catch {
            statusItemText.title = Self.statusTitle("Asset upload not configured")
            showAssetUploadS3SettingsAction()
            return
        }

        guard defaultProfile.type == .s3Compatible else {
            statusItemText.title = Self.statusTitle("Asset upload needs S3-compatible target")
            showAssetUploadS3SettingsAction()
            return
        }

        if let validationError = finderUploadValidationError(fileURLs: standardizedFileURLs, profile: defaultProfile) {
            onValidationError(validationError)
            return
        }

        statusItemText.title = Self.statusTitle("Uploading %d file(s)...", standardizedFileURLs.count)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.uploadServiceFiles(
                standardizedFileURLs,
                defaultProfile: defaultProfile,
                sourceName: sourceName,
                usedStoredApproval: nil
            )
            DispatchQueue.main.async {
                if !result.formattedLinks.isEmpty {
                    let text = result.formattedLinks.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }

                if result.failedCount == 0 {
                    self.statusItemText.title = Self.statusTitle("Uploaded %d file(s) · Link copied", result.uploadedCount)
                } else if result.uploadedCount > 0 {
                    self.statusItemText.title = Self.statusTitle("Uploaded %d/%d file(s) · Link copied", result.uploadedCount, result.requestedCount)
                    CompanionNonBlockingAlert.present(
                        messageText: CompanionL10n.text("Upload partially complete"),
                        informativeText: CompanionL10n.format(
                            "Uploaded %d file(s), failed %d. Successful link(s) copied to clipboard.\n%@",
                            result.uploadedCount,
                            result.failedCount,
                            result.failureSummary
                        ),
                        tone: .warning
                    )
                } else {
                    self.statusItemText.title = Self.statusTitle("Upload failed")
                    self.showError(result.failureSummary)
                }
            }
        }
    }

    private struct FinderAssetUploadFailure {
        var fileName: String
        var message: String
    }

    private struct FinderAssetUploadBatchResult {
        var formattedLinks: [String]
        var failures: [FinderAssetUploadFailure]

        var requestedCount: Int {
            formattedLinks.count + failures.count
        }

        var uploadedCount: Int {
            formattedLinks.count
        }

        var failedCount: Int {
            failures.count
        }

        var failureSummary: String {
            let rows = failures.prefix(3).map { "\($0.fileName): \($0.message)" }
            let suffix = failures.count > 3 ? "\n..." : ""
            let value = rows.joined(separator: "\n") + suffix
            return value.isEmpty ? CompanionL10n.text("Upload failed.") : value
        }
    }

    private enum AssetUploadWorkflowSource {
        case files([URL])
        case clipboardImage

        var sourceType: CompanionAssetUploadSourceType {
            switch self {
            case .files:
                return .filePath
            case .clipboardImage:
                return .clipboardImage
            }
        }

        var sourceLabel: String {
            switch self {
            case .files:
                return "file"
            case .clipboardImage:
                return "clipboard-image"
            }
        }

        var requestedCount: Int {
            switch self {
            case .files(let urls):
                return urls.count
            case .clipboardImage:
                return 1
            }
        }

        var displayNames: [String] {
            switch self {
            case .files(let urls):
                return urls.map(\.lastPathComponent)
            case .clipboardImage:
                return ["clipboard-image.png"]
            }
        }
    }

    private struct AssetUploadWorkflowOptions {
        var insertIntoJournal: Bool
        var copyToClipboard: Bool
        var outputFormat: CompanionAssetUploadOutputFormat
        var sourceName: String
        var alertTitle: String
    }

    private struct AssetUploadWorkflowResult {
        var runID: UUID
        var formattedLinks: [String]
        var failures: [FinderAssetUploadFailure]

        var uploadedCount: Int { formattedLinks.count }
        var failedCount: Int { failures.count }
        var failureSummary: String {
            let rows = failures.prefix(3).map { "\($0.fileName): \($0.message)" }
            let suffix = failures.count > 3 ? "\n..." : ""
            let value = rows.joined(separator: "\n") + suffix
            return value.isEmpty ? CompanionL10n.text("Upload failed.") : value
        }
    }

    private struct AssetUploadRetryItem {
        var name: String
        var sizeBytes: Int
        var request: CompanionAssetUploadRequest
    }

    private struct AssetUploadRetryContext {
        var sourceName: String
        var profileID: String
        var profileSummary: String
        var profileConfigHash: String
        var outputFormat: CompanionAssetUploadOutputFormat
        var failedItems: [AssetUploadRetryItem]
    }

    private struct AssetUploadRetryAttemptResult {
        var formattedLinks: [String]
        var remainingItems: [AssetUploadRetryItem]
        var toolResult: CompanionWorkflowToolResult
    }

    private func noteAssetUploadRunStarted(
        _ runID: UUID,
        cancellationToken: CompanionAssetUploadCancellationToken? = nil
    ) {
        DispatchQueue.main.async {
            self.activeAssetUploadRunIDs.insert(runID)
            if let cancellationToken {
                self.assetUploadCancellationTokens[runID] = cancellationToken
            }
        }
    }

    private func noteAssetUploadRunFinished(_ runID: UUID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.noteAssetUploadRunFinished(runID)
            }
            return
        }
        activeAssetUploadRunIDs.remove(runID)
        assetUploadCancellationTokens.removeValue(forKey: runID)
    }

    private func storeAssetUploadRetryContext(_ context: AssetUploadRetryContext?, runID: UUID) {
        DispatchQueue.main.async {
            if let context, !context.failedItems.isEmpty {
                self.assetUploadRetryContexts[runID] = context
                self.assetUploadRetryContextOrder.removeAll { $0 == runID }
                self.assetUploadRetryContextOrder.append(runID)
                while self.assetUploadRetryContextOrder.count > self.maxAssetUploadRetryContexts {
                    let expiredID = self.assetUploadRetryContextOrder.removeFirst()
                    self.assetUploadRetryContexts.removeValue(forKey: expiredID)
                }
            } else {
                self.assetUploadRetryContexts.removeValue(forKey: runID)
                self.assetUploadRetryContextOrder.removeAll { $0 == runID }
            }
        }
    }

    func uploadAssetsToJournalFromFilePicker() {
        let panel = NSOpenPanel()
        panel.title = CompanionL10n.text("Insert Uploaded Image")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = CompanionL10n.text("Upload")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        runAssetUploadWorkflow(
            source: .files(panel.urls.map(\.standardizedFileURL)),
            options: AssetUploadWorkflowOptions(
                insertIntoJournal: true,
                copyToClipboard: false,
                outputFormat: .markdown,
                sourceName: "journal-file-picker",
                alertTitle: CompanionL10n.text("Upload Image to Journal")
            )
        )
    }

    func uploadClipboardImageToJournal() {
        runAssetUploadWorkflow(
            source: .clipboardImage,
            options: AssetUploadWorkflowOptions(
                insertIntoJournal: true,
                copyToClipboard: false,
                outputFormat: .markdown,
                sourceName: "journal-clipboard-image",
                alertTitle: CompanionL10n.text("Upload Clipboard Image to Journal")
            )
        )
    }

    func uploadClipboardImageToClipboard() {
        let format = (try? assetUploadProfileStore.defaultProfile(requireCredentials: false).resolvedDefaultOutputFormat) ?? .markdown
        runAssetUploadWorkflow(
            source: .clipboardImage,
            options: AssetUploadWorkflowOptions(
                insertIntoJournal: false,
                copyToClipboard: true,
                outputFormat: format,
                sourceName: "clipboard-image",
                alertTitle: CompanionL10n.text("Upload Clipboard Image")
            )
        )
    }

    func uploadFilesFromAIQuickActions() {
        let panel = NSOpenPanel()
        panel.title = CompanionL10n.text("Upload Asset")
        panel.allowedContentTypes = [.image, .pdf, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = CompanionL10n.text("Upload")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        runAssetUploadWorkflow(
            source: .files(panel.urls.map(\.standardizedFileURL)),
            options: AssetUploadWorkflowOptions(
                insertIntoJournal: false,
                copyToClipboard: true,
                outputFormat: .markdown,
                sourceName: "ai-quick-actions",
                alertTitle: CompanionL10n.text("Upload Asset")
            )
        )
    }

    private func runAssetUploadWorkflow(source: AssetUploadWorkflowSource, options: AssetUploadWorkflowOptions) {
        let profile: CompanionAssetUploadProfile
        do {
            profile = try assetUploadProfileStore.defaultProfile(requireCredentials: true)
        } catch {
            statusItemText.title = Self.statusTitle("Asset upload not configured")
            showError(error.localizedDescription)
            showAssetUploadSettingsAction()
            return
        }

        if case .files(let urls) = source, !validateUploadSelection(urls, profile: profile) {
            return
        }

        guard confirmAssetUploadWorkflow(source: source, profile: profile, options: options) else {
            recordCancelledAssetUploadWorkflow(source: source, profile: profile, options: options)
            return
        }

        statusItemText.title = Self.statusTitle("Uploading %d asset(s)...", source.requestedCount)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.performAssetUploadWorkflow(source: source, profile: profile, options: options)
            DispatchQueue.main.async {
                self.finishAssetUploadWorkflow(result, source: source, profile: profile, options: options)
            }
        }
    }

    private func validateUploadSelection(_ fileURLs: [URL], profile: CompanionAssetUploadProfile) -> Bool {
        guard !fileURLs.isEmpty else {
            showError(CompanionL10n.text("No files were selected."))
            return false
        }
        let maxPerFile = profile.limits.maxSizeBytes
        if let tooLarge = fileURLs.first(where: { fileSizeBytes($0) > maxPerFile }) {
            showError(CompanionL10n.format(
                "%@ is larger than this profile's limit of %@.",
                tooLarge.lastPathComponent,
                Self.byteCount(maxPerFile)
            ))
            return false
        }
        return true
    }

    private func confirmAssetUploadWorkflow(
        source: AssetUploadWorkflowSource,
        profile: CompanionAssetUploadProfile,
        options: AssetUploadWorkflowOptions
    ) -> Bool {
        let names = source.displayNames.prefix(6).joined(separator: "\n")
        let more = source.displayNames.count > 6 ? "\n..." : ""
        let totalSize = {
            if case .files(let urls) = source {
                return totalSizeBytes(urls)
            }
            return nil
        }()
        let sizeLine = totalSize.map { CompanionL10n.format("Total size: %@", Self.byteCount($0)) }
            ?? CompanionL10n.text("Total size: clipboard image")
        let actions = [
            options.insertIntoJournal ? CompanionL10n.text("Insert into Journal") : nil,
            options.copyToClipboard ? CompanionL10n.text("Copy link") : nil
        ].compactMap { $0 }.joined(separator: " · ")
        return CompanionNonBlockingAlert.confirm(
            messageText: options.alertTitle,
            informativeText: [
                CompanionL10n.format("Files: %d", source.requestedCount),
                sizeLine,
                CompanionL10n.format("Target: %@", profile.profileSummary),
                CompanionL10n.format("Output: %@", options.outputFormat.rawValue),
                actions.isEmpty ? "" : CompanionL10n.format("After upload: %@", actions),
                "",
                names + more
            ].filter { !$0.isEmpty }.joined(separator: "\n"),
            primaryButtonTitle: CompanionL10n.text("Upload"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        )
    }

    private func performAssetUploadWorkflow(
        source: AssetUploadWorkflowSource,
        profile: CompanionAssetUploadProfile,
        options: AssetUploadWorkflowOptions
    ) -> AssetUploadWorkflowResult {
        let runID = workflowRunStore.startWorkflowRun(
            kind: .internalWorkflow,
            source: options.sourceName,
            templateID: "asset-upload-dispatch",
            templateStepID: "asset.upload",
            toolID: "companion.asset.upload",
            title: "Asset Upload",
            risk: .externalWrite,
            inputSummary: "source=\(source.sourceLabel), files=\(source.requestedCount), names=\(source.displayNames.prefix(5).joined(separator: ","))"
        )
        let cancellationToken = CompanionAssetUploadCancellationToken()
        noteAssetUploadRunStarted(runID, cancellationToken: cancellationToken)
        let service = CompanionAssetUploadService(
            profileStore: assetUploadProfileStore,
            cancellationToken: cancellationToken
        )
        var formattedLinks: [String] = []
        var failures: [FinderAssetUploadFailure] = []
        var retryItems: [AssetUploadRetryItem] = []

        let requests: [(name: String, request: CompanionAssetUploadRequest)] = {
            switch source {
            case .files(let urls):
                return urls.map { url in
                    (
                        url.lastPathComponent,
                        CompanionAssetUploadRequest(
                            sourceType: .filePath,
                            fileURL: url,
                            profileID: profile.id,
                            outputFormat: options.outputFormat,
                            altText: nil,
                            dryRun: false
                        )
                    )
                }
            case .clipboardImage:
                return [
                    (
                        "clipboard-image.png",
                        CompanionAssetUploadRequest(
                            sourceType: .clipboardImage,
                            fileURL: nil,
                            profileID: profile.id,
                            outputFormat: options.outputFormat,
                            altText: "Clipboard image",
                            dryRun: false
                        )
                    )
                ]
            }
        }()

        for item in requests {
            do {
                let result = try service.upload(item.request)
                assetUploadHistoryStore.appendSuccess(result, runID: runID, source: options.sourceName)
                formattedLinks.append(result.formatted ?? result.url ?? "")
            } catch {
                assetUploadHistoryStore.appendFailure(
                    fileNameSummary: item.name,
                    sizeBytes: item.request.fileURL.map(fileSizeBytes) ?? 0,
                    profileSummary: profile.profileSummary,
                    profileID: profile.id,
                    format: options.outputFormat,
                    runID: runID,
                    source: options.sourceName,
                    errorSummary: error.localizedDescription
                )
                failures.append(FinderAssetUploadFailure(fileName: item.name, message: error.localizedDescription))
                retryItems.append(AssetUploadRetryItem(
                    name: item.name,
                    sizeBytes: item.request.fileURL.map(fileSizeBytes) ?? 0,
                    request: item.request
                ))
            }
        }

        storeAssetUploadRetryContext(AssetUploadRetryContext(
            sourceName: options.sourceName,
            profileID: profile.id,
            profileSummary: profile.profileSummary,
            profileConfigHash: profile.configHash,
            outputFormat: options.outputFormat,
            failedItems: retryItems
        ), runID: runID)

        let filteredLinks = formattedLinks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let result = AssetUploadWorkflowResult(runID: runID, formattedLinks: filteredLinks, failures: failures)
        finishAssetUploadRunRecord(result, profile: profile, options: options)
        return result
    }

    private func finishAssetUploadRunRecord(
        _ result: AssetUploadWorkflowResult,
        profile: CompanionAssetUploadProfile,
        options: AssetUploadWorkflowOptions
    ) {
        let statusMessage = result.failedCount == 0
            ? "Uploaded \(result.uploadedCount) asset(s)."
            : result.uploadedCount > 0
                ? "Uploaded \(result.uploadedCount) asset(s), failed \(result.failedCount): \(result.failureSummary)"
                : "Asset upload failed: \(result.failureSummary)"
        let toolResult: CompanionWorkflowToolResult
        if result.failedCount == 0 {
            toolResult = .succeeded(
                output: [
                    "uploadedCount": .number(Double(result.uploadedCount)),
                    "failedCount": .number(0),
                    "links": .array(result.formattedLinks.map { .string($0) }),
                    "profileSummary": .string(profile.profileSummary),
                    "format": .string(options.outputFormat.rawValue)
                ],
                outputSummary: statusMessage
            )
        } else {
            toolResult = CompanionWorkflowToolResult(
                status: result.uploadedCount > 0 ? .failed : .failed,
                output: [
                    "uploadedCount": .number(Double(result.uploadedCount)),
                    "failedCount": .number(Double(result.failedCount)),
                    "failedFileNames": .array(result.failures.prefix(10).map { .string($0.fileName) }),
                    "profileSummary": .string(profile.profileSummary),
                    "format": .string(options.outputFormat.rawValue)
                ],
                outputSummary: statusMessage,
                userMessage: statusMessage,
                missingInputs: [],
                error: CompanionWorkflowToolError(
                    code: result.uploadedCount > 0 ? "asset_upload_partial_failed" : "asset_upload_failed",
                    message: statusMessage,
                    recoverySuggestion: nil
                )
            )
        }
        workflowRunStore.finish(id: result.runID, result: toolResult)
        mcpAuditLog.append(
            caller: options.sourceName,
            toolID: "companion.asset.upload",
            risk: .externalWrite,
            arguments: [
                "sourceType": .string(options.sourceName),
                "fileCount": .number(Double(result.uploadedCount + result.failedCount)),
                "profileID": .string(profile.id),
                "profileConfigHash": .string(profile.configHash),
                "outputFormat": .string(options.outputFormat.rawValue)
            ],
            dryRun: false,
            result: toolResult,
            usedStoredApproval: false
        )
    }

    private func finishAssetUploadWorkflow(
        _ result: AssetUploadWorkflowResult,
        source: AssetUploadWorkflowSource,
        profile: CompanionAssetUploadProfile,
        options: AssetUploadWorkflowOptions
    ) {
        noteAssetUploadRunFinished(result.runID)
        if !result.formattedLinks.isEmpty {
            if options.insertIntoJournal {
                desktopPet.workflowAppendJournalSection("上传资产", lines: result.formattedLinks)
                desktopPet.showJournalFromWorkflowRun()
            }
            if options.copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.formattedLinks.joined(separator: "\n"), forType: .string)
                ClipboardTranslationFeature.suppressPasteboardChange(NSPasteboard.general.changeCount)
            }
        }

        if let run = workflowRunStore.run(id: result.runID) {
            presentWorkflowConsole(run.workflowSnapshot(template: CompanionWorkflowTemplates.assetUploadDispatch))
        }

        if result.failedCount == 0 {
            statusItemText.title = Self.statusTitle("Uploaded %d asset(s)", result.uploadedCount)
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Upload complete"),
                informativeText: options.insertIntoJournal
                    ? CompanionL10n.text("Uploaded link(s) inserted into Journal.")
                    : CompanionL10n.text("Uploaded link(s) copied to clipboard."),
                tone: .success
            )
        } else if result.uploadedCount > 0 {
            statusItemText.title = Self.statusTitle("Uploaded %d/%d asset(s)", result.uploadedCount, source.requestedCount)
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Upload partially complete"),
                informativeText: result.failureSummary,
                tone: .warning
            )
        } else {
            statusItemText.title = Self.statusTitle("Upload failed")
            showError(result.failureSummary)
        }
    }

    private func recordCancelledAssetUploadWorkflow(
        source: AssetUploadWorkflowSource,
        profile: CompanionAssetUploadProfile,
        options: AssetUploadWorkflowOptions
    ) {
        let runID = workflowRunStore.startWorkflowRun(
            kind: .internalWorkflow,
            source: options.sourceName,
            templateID: "asset-upload-dispatch",
            templateStepID: "workflow.approval.request",
            toolID: "companion.asset.upload",
            title: "Asset Upload",
            risk: .externalWrite,
            inputSummary: "cancelled before upload, source=\(source.sourceLabel), files=\(source.requestedCount)"
        )
        workflowRunStore.cancel(id: runID, status: .cancelled, message: "User cancelled asset upload before network write.")
        mcpAuditLog.append(
            caller: options.sourceName,
            toolID: "companion.asset.upload",
            risk: .externalWrite,
            arguments: [
                "sourceType": .string(source.sourceLabel),
                "fileCount": .number(Double(source.requestedCount)),
                "profileID": .string(profile.id),
                "profileConfigHash": .string(profile.configHash),
                "outputFormat": .string(options.outputFormat.rawValue)
            ],
            dryRun: false,
            result: .failed(code: "asset_upload_cancelled", message: "User cancelled asset upload."),
            usedStoredApproval: false
        )
    }

    private func uploadServiceFiles(
        _ fileURLs: [URL],
        defaultProfile: CompanionAssetUploadProfile,
        sourceName: String,
        usedStoredApproval: Bool?
    ) -> FinderAssetUploadBatchResult {
        let outputFormat = defaultProfile.resolvedDefaultOutputFormat
        let runID = workflowRunStore.startWorkflowRun(
            kind: .internalWorkflow,
            source: sourceName,
            templateID: "finder-asset-upload",
            templateStepID: "asset.upload",
            toolID: "companion.asset.upload",
            title: "Finder Upload",
            risk: .externalWrite,
            inputSummary: "files=\(fileURLs.count), names=\(fileURLs.prefix(5).map(\.lastPathComponent).joined(separator: ","))"
        )
        let cancellationToken = CompanionAssetUploadCancellationToken()
        noteAssetUploadRunStarted(runID, cancellationToken: cancellationToken)

        let service = CompanionAssetUploadService(
            profileStore: assetUploadProfileStore,
            cancellationToken: cancellationToken
        )
        var formattedLinks: [String] = []
        var failures: [FinderAssetUploadFailure] = []
        var retryItems: [AssetUploadRetryItem] = []

        for url in fileURLs {
            let request = CompanionAssetUploadRequest(
                sourceType: .filePath,
                fileURL: url,
                profileID: defaultProfile.id,
                outputFormat: outputFormat,
                altText: nil,
                dryRun: false
            )
            do {
                let result = try service.upload(request)
                assetUploadHistoryStore.appendSuccess(result, runID: runID, source: sourceName)
                if let formatted = result.formatted {
                    formattedLinks.append(formatted)
                }
            } catch {
                assetUploadHistoryStore.appendFailure(
                    fileNameSummary: url.lastPathComponent,
                    sizeBytes: fileSizeBytes(url),
                    profileSummary: defaultProfile.profileSummary,
                    profileID: defaultProfile.id,
                    format: outputFormat,
                    runID: runID,
                    source: sourceName,
                    errorSummary: error.localizedDescription
                )
                failures.append(FinderAssetUploadFailure(
                    fileName: url.lastPathComponent,
                    message: error.localizedDescription
                ))
                retryItems.append(AssetUploadRetryItem(
                    name: url.lastPathComponent,
                    sizeBytes: fileSizeBytes(url),
                    request: request
                ))
            }
        }

        storeAssetUploadRetryContext(AssetUploadRetryContext(
            sourceName: sourceName,
            profileID: defaultProfile.id,
            profileSummary: defaultProfile.profileSummary,
            profileConfigHash: defaultProfile.configHash,
            outputFormat: outputFormat,
            failedItems: retryItems
        ), runID: runID)

        let batchResult = FinderAssetUploadBatchResult(formattedLinks: formattedLinks, failures: failures)
        if failures.isEmpty {
            let toolResult = CompanionWorkflowToolResult.succeeded(
                output: [
                    "uploadedCount": .number(Double(formattedLinks.count)),
                    "failedCount": .number(0),
                    "profileSummary": .string(defaultProfile.profileSummary),
                    "format": .string(outputFormat.rawValue)
                ],
                outputSummary: "Uploaded \(formattedLinks.count) file(s) from Finder."
            )
            workflowRunStore.finish(
                id: runID,
                result: toolResult
            )
            auditFinderUpload(
                fileURLs: fileURLs,
                profile: defaultProfile,
                result: toolResult,
                sourceName: sourceName,
                usedStoredApproval: usedStoredApproval
            )
            noteAssetUploadRunFinished(runID)
        } else {
            let message = formattedLinks.isEmpty
                ? "Finder upload failed for \(failures.count) file(s): \(batchResult.failureSummary)"
                : "Finder upload partially failed after \(formattedLinks.count) success(es): \(batchResult.failureSummary)"
            let toolResult = CompanionWorkflowToolResult(
                status: .failed,
                output: [
                    "uploadedCount": .number(Double(formattedLinks.count)),
                    "failedCount": .number(Double(failures.count)),
                    "failedFileNames": .array(failures.prefix(10).map { .string($0.fileName) }),
                    "profileSummary": .string(defaultProfile.profileSummary),
                    "format": .string(outputFormat.rawValue)
                ],
                outputSummary: message,
                userMessage: message,
                missingInputs: [],
                error: CompanionWorkflowToolError(
                    code: formattedLinks.isEmpty ? "finder_asset_upload_failed" : "finder_asset_upload_partial_failed",
                    message: message,
                    recoverySuggestion: nil
                )
            )
            workflowRunStore.finish(id: runID, result: toolResult)
            auditFinderUpload(
                fileURLs: fileURLs,
                profile: defaultProfile,
                result: toolResult,
                sourceName: sourceName,
                usedStoredApproval: usedStoredApproval
            )
            noteAssetUploadRunFinished(runID)
        }
        return batchResult
    }

    private func finderUploadValidationError(fileURLs: [URL], profile: CompanionAssetUploadProfile) -> String? {
        let maxPerFile = profile.limits.maxSizeBytes
        if let tooLarge = fileURLs.first(where: { fileSizeBytes($0) > maxPerFile }) {
            return CompanionL10n.format(
                "%@ is larger than this profile's limit of %@.",
                tooLarge.lastPathComponent,
                Self.byteCount(maxPerFile)
            )
        }
        if let totalSize = totalSizeBytes(fileURLs),
           totalSize > CompanionAssetUploadProfile.Limits.maximumSynchronousUploadBytes {
            return CompanionL10n.format(
                "Selected files total %@. Finder upload is currently limited to %@ per batch.",
                Self.byteCount(totalSize),
                Self.byteCount(CompanionAssetUploadProfile.Limits.maximumSynchronousUploadBytes)
            )
        }
        return nil
    }

    private func auditFinderUpload(
        fileURLs: [URL],
        profile: CompanionAssetUploadProfile,
        result: CompanionWorkflowToolResult,
        sourceName: String,
        usedStoredApproval: Bool?
    ) {
        mcpAuditLog.append(
            caller: sourceName,
            toolID: "companion.asset.upload",
            risk: .externalWrite,
            arguments: [
                "sourceType": .string(sourceName),
                "fileCount": .number(Double(fileURLs.count)),
                "fileNames": .array(fileURLs.prefix(10).map { .string($0.lastPathComponent) }),
                "profileID": .string(profile.id),
                "profileConfigHash": .string(profile.configHash),
                "outputFormat": .string(profile.resolvedDefaultOutputFormat.rawValue)
            ],
            dryRun: false,
            result: result,
            usedStoredApproval: usedStoredApproval
        )
    }

    private func serviceFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }
        if let fileNames = pasteboard.propertyList(forType: .fileURL) as? [String] {
            return fileNames.compactMap(Self.fileURLFromPasteboardString)
        }
        if let fileName = pasteboard.string(forType: .fileURL) {
            return Self.fileURLFromPasteboardString(fileName).map { [$0] } ?? []
        }
        if let fileNames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return fileNames.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        return []
    }

    private static func fileURLFromPasteboardString(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    private func totalSizeBytes(_ urls: [URL]) -> Int? {
        var total = 0
        for url in urls {
            let size = fileSizeBytes(url)
            if size <= 0 {
                return nil
            }
            total += size
        }
        return total
    }

    private func fileSizeBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func mimeTypeSummary(for url: URL) -> String {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let mimeType = contentType.preferredMIMEType {
            return mimeType
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private func publicLinkDisclosure(for profile: CompanionAssetUploadProfile) -> String {
        switch profile.type {
        case .s3Compatible:
            let hasPublicBase = profile.s3?.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return hasPublicBase
                ? CompanionL10n.text("Link visibility: public base URL is configured")
                : CompanionL10n.text("Link visibility: depends on bucket policy")
        case .customHTTP:
            let hasPublicBase = profile.customHTTP?.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return hasPublicBase
                ? CompanionL10n.text("Link visibility: public base URL is configured")
                : CompanionL10n.text("Link visibility: depends on upload service response")
        }
    }

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

}
