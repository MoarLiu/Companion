import AppKit
import Foundation
import UniformTypeIdentifiers

final class CompanionExternalToolCallCoordinator: NSObject {
    var onApprovalRequested: ((TimeInterval) -> Void)?
    var onRunning: (() -> Void)?
    var onResult: ((CompanionWorkflowToolResult, String) -> Void)?
    var onStartExternalFocus: ((String, Int?) -> CompanionWorkflowToolResult)?
    var onRefreshReminderWrite: ((Bool) -> Void)?
    var onRefreshJournalWrite: ((Bool) -> Void)?

    private let queue: CompanionExternalToolCallQueue
    private let auditLog: CompanionMCPAuditLog
    private let workflowRunStore: CompanionWorkflowRunStore
    private let mcpClientProfilesStore: MCPClientProfilesStore
    private let assetUploadProfileStore: CompanionAssetUploadProfileStore
    private let queueIO = DispatchQueue(label: "com.crazyjal.companion.mcp-queue-io", qos: .utility)
    private let executionQueue = DispatchQueue(label: "com.crazyjal.companion.mcp-tool-execution", qos: .userInitiated)

    private var timer: Timer?
    private var processingIDs = Set<UUID>()
    private var isStarted = false

    init(
        queue: CompanionExternalToolCallQueue = CompanionExternalToolCallQueue(),
        auditLog: CompanionMCPAuditLog,
        workflowRunStore: CompanionWorkflowRunStore,
        mcpClientProfilesStore: MCPClientProfilesStore,
        assetUploadProfileStore: CompanionAssetUploadProfileStore
    ) {
        self.queue = queue
        self.auditLog = auditLog
        self.workflowRunStore = workflowRunStore
        self.mcpClientProfilesStore = mcpClientProfilesStore
        self.assetUploadProfileStore = assetUploadProfileStore
        super.init()
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(externalToolCallQueuedNotification(_:)),
            name: CompanionExternalToolCallQueue.didEnqueueDistributedNotification,
            object: nil
        )
        // The queue is primarily driven by the distributed enqueue notification above.
        // This timer is a low-frequency fallback for heartbeat refresh + stale sweep.
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        timer?.tolerance = 1.0
        pump()
    }

    func stop() {
        guard isStarted || timer != nil else {
            queue.clearHeartbeat()
            return
        }
        isStarted = false
        timer?.invalidate()
        timer = nil
        queue.clearHeartbeat()
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: CompanionExternalToolCallQueue.didEnqueueDistributedNotification,
            object: nil
        )
    }

    @objc private func externalToolCallQueuedNotification(_ notification: Notification) {
        pump()
    }

    /// Runs queue maintenance + load off the main thread, then hands actionable
    /// pending records back to the main thread for approval UI.
    private func pump() {
        queueIO.async { [weak self] in
            guard let self else { return }
            self.queue.refreshHeartbeat()
            let pending = self.queue.sweepAndLoadPending()
            DispatchQueue.main.async {
                self.consume(pending)
            }
        }
    }

    private func consume(_ pending: [CompanionExternalToolCallRecord]) {
        guard let record = pending.first(where: { !processingIDs.contains($0.id) }) else {
            return
        }
        processingIDs.insert(record.id)
        handle(record)
    }

    /// Records stay in processing until they reach a terminal state. While async
    /// execution is running, the on-disk status is .approved and can still be swept.
    private func finishProcessing(_ id: UUID) {
        processingIDs.remove(id)
        pump()
    }

    private func handle(_ record: CompanionExternalToolCallRecord) {
        var promptingRecord = record
        promptingRecord.status = .prompting
        promptingRecord.statusMessage = "Waiting for local user approval."
        _ = save(promptingRecord, failureContext: "Failed to persist the tool approval prompt.")
        if let runID = record.runID {
            workflowRunStore.setStatus(id: runID, status: .awaitingApproval, message: "Waiting for local user approval.")
        }
        onApprovalRequested?(min(max(record.expiresAt.timeIntervalSinceNow, 5), 120))

        let approval = approval(for: record)

        var completed = queue.loadRecord(id: record.id) ?? promptingRecord
        completed.updatedAt = Date()

        guard completed.expiresAt > Date() else {
            completed.status = .expired
            completed.statusMessage = "Companion local approval expired before the request was confirmed."
            completed.result = .denied(
                code: "approval_expired",
                message: "Companion local approval expired before the request was confirmed.",
                output: [
                    "tool": .string(record.toolID),
                    "approvalExpired": .bool(true)
                ]
            )
            audit(completed, result: completed.result, usedStoredApproval: false)
            _ = save(completed, failureContext: "Failed to persist the expired tool call result.")
            finishProcessing(record.id)
            return
        }

        guard approval.approved else {
            completed.status = .denied
            completed.statusMessage = "Companion local approval was denied."
            completed.result = .denied(
                code: "approval_denied",
                message: "Companion local approval was denied.",
                output: [
                    "tool": .string(record.toolID),
                    "approved": .bool(false)
                ]
            )
            audit(completed, result: completed.result, usedStoredApproval: approval.usedStoredApproval)
            _ = save(completed, failureContext: "Failed to persist the denied tool call result.")
            finishProcessing(record.id)
            return
        }

        completed.arguments = approval.arguments
        completed.status = .approved
        completed.statusMessage = "Approved by local user."
        guard save(completed, failureContext: "Failed to persist the approved tool call before execution.") else {
            finishProcessing(record.id)
            return
        }
        if let runID = completed.runID {
            workflowRunStore.markRunning(id: runID)
        }
        onRunning?()

        if completed.toolID == "companion.pomodoro.startFocus" {
            let result = invoke(completed)
            finishApproved(completed, result: result, usedStoredApproval: approval.usedStoredApproval)
            return
        }

        let approvedRecord = completed
        let usedStoredApproval = approval.usedStoredApproval
        executionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.invoke(approvedRecord)
            DispatchQueue.main.async {
                self.finishApproved(approvedRecord, result: result, usedStoredApproval: usedStoredApproval)
            }
        }
    }

    private func finishApproved(
        _ record: CompanionExternalToolCallRecord,
        result: CompanionWorkflowToolResult,
        usedStoredApproval: Bool
    ) {
        defer { finishProcessing(record.id) }
        var completed = queue.loadRecord(id: record.id) ?? record
        completed.result = result
        completed.status = result.status == .succeeded ? .completed : (result.status == .denied ? .denied : .failed)
        completed.statusMessage = result.outputSummary
        guard save(completed, failureContext: "Failed to persist the completed tool call result.") else {
            audit(completed, result: result, usedStoredApproval: usedStoredApproval)
            return
        }
        refreshAfter(completed, result: result)
        audit(completed, result: result, usedStoredApproval: usedStoredApproval)
    }

    @discardableResult
    private func save(_ record: CompanionExternalToolCallRecord, failureContext: String) -> Bool {
        do {
            try queue.save(record)
            return true
        } catch {
            let message = "\(failureContext) \(error.localizedDescription)"
            NSLog("Companion external tool queue save failed: \(message)")
            if let runID = record.runID {
                workflowRunStore.setStatus(id: runID, status: .failed, message: message)
            }
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Tool result could not be saved"),
                informativeText: message,
                tone: .warning
            )
            return false
        }
    }

    private func refreshAfter(_ record: CompanionExternalToolCallRecord, result: CompanionWorkflowToolResult) {
        guard result.status == .succeeded || result.status == .blocked else { return }
        let showWindow = record.arguments["showWindow"]?.boolValue ?? false
        if record.toolID == "companion.reminder.create" || record.toolID == "companion.reminder.createBatch" {
            onRefreshReminderWrite?(showWindow)
        } else if record.toolID == "companion.journal.appendToday" {
            onRefreshJournalWrite?(showWindow)
        }
    }

    private func audit(
        _ record: CompanionExternalToolCallRecord,
        result: CompanionWorkflowToolResult?,
        usedStoredApproval: Bool? = nil
    ) {
        guard let result else { return }
        auditLog.append(
            caller: record.caller,
            toolID: record.toolID,
            risk: record.risk,
            arguments: record.arguments,
            dryRun: false,
            result: result,
            usedStoredApproval: usedStoredApproval
        )
        if let runID = record.runID {
            workflowRunStore.finish(id: runID, result: result)
        }
        onResult?(result, record.toolID)
    }

    private func invoke(_ record: CompanionExternalToolCallRecord) -> CompanionWorkflowToolResult {
        if record.toolID == "companion.pomodoro.startFocus" {
            let taskTitle = record.arguments["taskTitle"]?.stringValue ?? CompanionL10n.text("Focus")
            let durationMinutes = record.arguments["durationMinutes"]?.intValue
            return onStartExternalFocus?(taskTitle, durationMinutes)
                ?? .failed(code: "companion_unavailable", message: "Companion is unavailable.")
        }

        var arguments = record.arguments
        arguments["dryRun"] = .bool(false)
        arguments["__companionApproved"] = .bool(true)
        let registry = CompanionWorkflowToolRegistry.defaultRegistry()
        return registry.invoke(CompanionWorkflowToolInvocation(
            toolID: record.toolID,
            arguments: arguments,
            dryRun: false,
            caller: record.caller
        ))
    }

    private func approval(for record: CompanionExternalToolCallRecord) -> (approved: Bool, arguments: CompanionJSONObject, usedStoredApproval: Bool) {
        if record.toolID == "companion.reminder.createBatch" {
            let prompter = CompanionReminderBatchApprovalClosurePrompter(
                previewProvider: { [self] arguments in
                    var updatedRecord = record
                    updatedRecord.arguments = arguments
                    let preview = externalReminderBatchPreview(updatedRecord)
                    return CompanionReminderBatchApprovalPreview(prompt: preview.prompt, invalidCount: preview.invalidCount)
                },
                invalidIndexProvider: { [self] arguments in
                    var updatedRecord = record
                    updatedRecord.arguments = arguments
                    return reminderBatchInvalidIndexes(updatedRecord)
                },
                initialActionProvider: { preview in
                    let hasInvalidItems = preview.invalidCount > 0
                    let choice = CompanionNonBlockingAlert.choose(
                        messageText: CompanionL10n.text("Allow Reminder Batch?"),
                        informativeText: preview.prompt,
                        primaryButtonTitle: hasInvalidItems ? CompanionL10n.text("Edit Items") : CompanionL10n.text("Allow Batch"),
                        secondaryButtonTitle: hasInvalidItems ? CompanionL10n.text("Create Valid") : nil,
                        cancelButtonTitle: CompanionL10n.text("Deny"),
                        tone: hasInvalidItems ? .warning : .info
                    )
                    switch choice {
                    case .primary:
                        return hasInvalidItems ? .editItems : .allowBatch
                    case .secondary:
                        return hasInvalidItems ? .createValid : .deny
                    case .cancel:
                        return .deny
                    }
                },
                itemActionProvider: { [self] item, index in
                    let choice = CompanionNonBlockingAlert.choose(
                        messageText: CompanionL10n.format("Edit Reminder %d?", index + 1),
                        informativeText: reminderBatchEditPrompt(item, index: index),
                        primaryButtonTitle: CompanionL10n.text("Edit"),
                        secondaryButtonTitle: CompanionL10n.text("Skip Item"),
                        cancelButtonTitle: CompanionL10n.text("Deny Batch"),
                        tone: .warning
                    )
                    switch choice {
                    case .primary:
                        return .edit
                    case .secondary:
                        return .skip
                    case .cancel:
                        return .denyBatch
                    }
                },
                editedItemProvider: { [self] item, index in
                    promptEditedReminderBatchItem(item, index: index)
                },
                createValidConfirmationProvider: { preview in
                    let choice = CompanionNonBlockingAlert.choose(
                        messageText: CompanionL10n.text("Create Valid Reminders?"),
                        informativeText: preview.prompt,
                        primaryButtonTitle: CompanionL10n.text("Create Valid"),
                        secondaryButtonTitle: nil,
                        cancelButtonTitle: CompanionL10n.text("Deny"),
                        tone: .warning
                    )
                    return choice == .primary
                }
            )
            let decision = CompanionReminderBatchApprovalResolver(prompter: prompter).resolve(arguments: record.arguments)
            return (decision.approved, decision.arguments, false)
        }

        // Per-client remembered approvals use caller as the stable identity because
        // external queue records do not carry command/argv.
        let fingerprint = mcpClientProfilesStore.generateFingerprint(
            clientName: record.caller,
            commandPath: "",
            argv: []
        )

        if let uploadScope = mcpAssetUploadApprovalScope(for: record) {
            if mcpClientProfilesStore.isAssetUploadAllowed(
                fingerprint: fingerprint,
                profileID: uploadScope.profile.id,
                profileConfigHash: uploadScope.profile.configHash,
                selectedMaxSizeBytes: uploadScope.selectedMaxSizeBytes
            ) {
                mcpClientProfilesStore.updateLastSeen(fingerprint: fingerprint)
                return (true, record.arguments, true)
            }

            let choice = CompanionNonBlockingAlert.choose(
                messageText: CompanionL10n.format("Allow MCP Tool: %@", record.toolTitle),
                informativeText: mcpAssetUploadApprovalPrompt(record, scope: uploadScope),
                primaryButtonTitle: CompanionL10n.text("Allow Once"),
                secondaryButtonTitle: CompanionL10n.text("Allow & Remember"),
                cancelButtonTitle: CompanionL10n.text("Deny"),
                tone: .warning
            )
            switch choice {
            case .primary:
                return (true, record.arguments, false)
            case .secondary:
                mcpClientProfilesStore.allowAssetUpload(
                    fingerprint: fingerprint,
                    clientName: record.caller,
                    commandSummary: record.caller,
                    profileID: uploadScope.profile.id,
                    profileConfigHash: uploadScope.profile.configHash,
                    maxSizeBytes: max(uploadScope.selectedMaxSizeBytes, uploadScope.profile.limits.maxSizeBytes)
                )
                return (true, record.arguments, false)
            case .cancel:
                return (false, record.arguments, false)
            }
        }

        let canRemember = (record.risk == .localWrite || record.risk == .localSession)

        if canRemember, mcpClientProfilesStore.isToolAllowed(fingerprint: fingerprint, toolID: record.toolID, risk: record.risk) {
            mcpClientProfilesStore.updateLastSeen(fingerprint: fingerprint)
            return (true, record.arguments, true)
        }

        if canRemember {
            let choice = CompanionNonBlockingAlert.choose(
                messageText: CompanionL10n.format("Allow MCP Tool: %@", record.toolTitle),
                informativeText: externalToolCallPrompt(record),
                primaryButtonTitle: CompanionL10n.text("Allow Once"),
                secondaryButtonTitle: CompanionL10n.text("Always Allow for This Client"),
                cancelButtonTitle: CompanionL10n.text("Deny"),
                tone: .warning
            )
            switch choice {
            case .primary:
                return (true, record.arguments, false)
            case .secondary:
                mcpClientProfilesStore.allowTool(
                    fingerprint: fingerprint,
                    toolID: record.toolID,
                    clientName: record.caller,
                    commandSummary: record.caller,
                    risk: record.risk
                )
                return (true, record.arguments, false)
            case .cancel:
                return (false, record.arguments, false)
            }
        }

        let approved = CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.format("Allow MCP Tool: %@", record.toolTitle),
            informativeText: externalToolCallPrompt(record),
            primaryButtonTitle: CompanionL10n.text("Allow Once"),
            cancelButtonTitle: CompanionL10n.text("Deny"),
            tone: .warning
        )
        return (approved, record.arguments, false)
    }

    private struct MCPAssetUploadApprovalScope {
        var profile: CompanionAssetUploadProfile
        var selectedMaxSizeBytes: Int
        var fileName: String
        var mimeType: String
    }

    private func mcpAssetUploadApprovalScope(for record: CompanionExternalToolCallRecord) -> MCPAssetUploadApprovalScope? {
        guard record.toolID == "companion.asset.upload",
              record.arguments["dryRun"]?.boolValue != true,
              record.arguments["dry_run"]?.boolValue != true
        else {
            return nil
        }
        let sourceType = record.arguments["sourceType"]?.stringValue ?? ""
        guard sourceType == CompanionAssetUploadSourceType.filePath.rawValue
                || sourceType == CompanionAssetUploadSourceType.temporaryFile.rawValue,
              let rawPath = record.arguments["filePath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else {
            return nil
        }
        let url = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL
        let profileID = record.arguments["profileID"]?.stringValue
        guard let profile = try? assetUploadProfileStore.profile(id: profileID, requireCredentials: false) else {
            return nil
        }
        return MCPAssetUploadApprovalScope(
            profile: profile,
            selectedMaxSizeBytes: fileSizeBytes(url),
            fileName: url.lastPathComponent,
            mimeType: mimeTypeSummary(for: url)
        )
    }

    private func mcpAssetUploadApprovalPrompt(
        _ record: CompanionExternalToolCallRecord,
        scope: MCPAssetUploadApprovalScope
    ) -> String {
        [
            externalToolCallPrompt(record),
            "",
            CompanionL10n.format("File: %@ · %@ · %@", scope.fileName, Self.byteCount(scope.selectedMaxSizeBytes), scope.mimeType),
            CompanionL10n.format("Target: %@", scope.profile.profileSummary),
            publicLinkDisclosure(for: scope.profile),
            CompanionL10n.format("Remembered limit: %@", Self.byteCount(scope.profile.limits.maxSizeBytes))
        ].joined(separator: "\n")
    }

    private func reminderBatchInvalidIndexes(_ record: CompanionExternalToolCallRecord) -> [Int] {
        var previewArguments = record.arguments
        previewArguments["dryRun"] = .bool(true)
        let preview = CompanionWorkflowToolRegistry.defaultRegistry().invoke(CompanionWorkflowToolInvocation(
            toolID: record.toolID,
            arguments: previewArguments,
            dryRun: true,
            caller: record.caller
        ))
        return (preview.output["itemResults"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            guard value.objectValue?["status"]?.stringValue == "invalid" else { return nil }
            return index
        }
    }

    private func reminderBatchEditPrompt(_ item: CompanionJSONValue, index: Int) -> String {
        let object = item.objectValue ?? [:]
        let title = CompanionWorkflowRunStore.safeSummary(object["title"]?.stringValue ?? CompanionL10n.text("Untitled"), maxLength: 80)
        let fireDate = object["fireDate"]?.stringValue ?? CompanionL10n.text("Missing")
        return [
            CompanionL10n.format("Item %d needs a valid title and time.", index + 1),
            CompanionL10n.format("Title: %@", title),
            CompanionL10n.format("Time: %@", fireDate),
            "",
            CompanionL10n.text("Choose Edit to enter: title | ISO-8601 time | recurrence(optional). Choose Skip Item to leave it out of this run.")
        ].joined(separator: "\n")
    }

    private func promptEditedReminderBatchItem(_ item: CompanionJSONValue, index: Int) -> CompanionJSONValue? {
        let object = item.objectValue ?? [:]
        let initial = [
            object["title"]?.stringValue ?? "",
            object["fireDate"]?.stringValue ?? "",
            object["recurrence"]?.stringValue ?? ""
        ].joined(separator: " | ")
        guard let text = CompanionNonBlockingAlert.promptText(
            messageText: CompanionL10n.format("Reminder %d", index + 1),
            informativeText: CompanionL10n.text("Use: title | ISO-8601 time | recurrence(optional). Supported recurrence: daily, weekdays, weekly."),
            initialValue: initial,
            placeholder: "Task title | 2026-06-04T15:00:00+08:00 | daily",
            primaryButtonTitle: CompanionL10n.text("Use Item"),
            cancelButtonTitle: CompanionL10n.text("Skip"),
            tone: .info
        ) else {
            return nil
        }
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2 else {
            return item
        }
        var edited = object
        edited["title"] = .string(parts[0])
        edited["fireDate"] = .string(parts[1])
        if parts.count >= 3, !parts[2].isEmpty {
            edited["recurrence"] = .string(parts[2])
        }
        return .object(edited)
    }

    private func externalToolCallPrompt(_ record: CompanionExternalToolCallRecord) -> String {
        [
            CompanionL10n.format("Caller: %@", record.caller),
            CompanionL10n.format("Tool: %@", record.toolID),
            CompanionL10n.format("Risk: %@", record.risk.rawValue),
            "",
            Self.externalToolArgumentSummary(record.arguments),
            "",
            CompanionL10n.text("Companion will only run this local write once after you allow it.")
        ].joined(separator: "\n")
    }

    private func externalReminderBatchPreview(_ record: CompanionExternalToolCallRecord) -> (prompt: String, invalidCount: Int) {
        var previewArguments = record.arguments
        previewArguments["dryRun"] = .bool(true)
        let preview = CompanionWorkflowToolRegistry.defaultRegistry().invoke(CompanionWorkflowToolInvocation(
            toolID: record.toolID,
            arguments: previewArguments,
            dryRun: true,
            caller: record.caller
        ))

        let requestedCount = preview.output["requestedCount"]?.intValue ?? reminderBatchItemCount(record.arguments)
        let validCount = preview.output["validCount"]?.intValue ?? 0
        let invalidCount = preview.output["invalidCount"]?.intValue ?? 0
        var lines: [String] = [
            CompanionL10n.format("Caller: %@", record.caller),
            CompanionL10n.format("Tool: %@", record.toolID),
            CompanionL10n.format("Risk: %@", record.risk.rawValue),
            "",
            CompanionL10n.format("Batch: %d total · %d valid · %d need edits", requestedCount, validCount, invalidCount)
        ]

        if let itemResults = preview.output["itemResults"]?.arrayValue {
            lines.append("")
            for (index, item) in itemResults.prefix(20).enumerated() {
                guard let object = item.objectValue else { continue }
                let title = CompanionWorkflowRunStore.safeSummary(
                    object["title"]?.stringValue ?? CompanionL10n.text("Untitled"),
                    maxLength: 48
                )
                let fireDate = object["fireDate"]?.stringValue ?? ""
                let status = object["status"]?.stringValue ?? "unknown"
                let error = object["error"]?.stringValue
                var row = "\(index + 1). [\(status)] \(title)"
                if !fireDate.isEmpty {
                    row += " · \(fireDate)"
                }
                lines.append(row)
                if let error, !error.isEmpty {
                    lines.append("   \(CompanionWorkflowRunStore.safeSummary(error, maxLength: 90))")
                }
            }
        }

        lines.append("")
        if invalidCount > 0 {
            lines.append(CompanionL10n.text("Companion will create only valid reminders if you continue. Invalid items are skipped and reported in the result."))
        } else {
            lines.append(CompanionL10n.text("Companion will create these reminders once after you allow it."))
        }
        return (lines.joined(separator: "\n"), invalidCount)
    }

    private func reminderBatchItemCount(_ arguments: CompanionJSONObject) -> Int {
        arguments["items"]?.arrayValue?.count ?? 0
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

    private static func externalToolArgumentSummary(_ arguments: CompanionJSONObject) -> String {
        let rows = arguments
            .filter { $0.key != "dryRun" && $0.key != "dry_run" }
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key): \(externalToolDisplayValue(value))"
            }
        return rows.isEmpty ? "Arguments: none" : rows.joined(separator: "\n")
    }

    private static func externalToolDisplayValue(_ value: CompanionJSONValue) -> String {
        let raw: String
        switch value {
        case .string(let string):
            raw = string
        case .number(let number):
            raw = number.rounded() == number ? "\(Int(number))" : "\(number)"
        case .bool(let bool):
            raw = bool ? "true" : "false"
        case .array(let values):
            raw = values.map(externalToolDisplayValue).joined(separator: ", ")
        case .object:
            raw = "{...}"
        case .null:
            raw = "null"
        }
        if raw.count <= 180 {
            return raw
        }
        let index = raw.index(raw.startIndex, offsetBy: 180)
        return "\(raw[..<index])..."
    }
}
