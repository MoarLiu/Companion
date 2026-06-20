import AppKit
import Foundation
import SwiftUI

extension AppDelegate {
    @objc func showSettingsStatusCenterAction() {
        settingsStatusCenter.show()
    }

    func makeSettingsStatusActions() -> CompanionSettingsStatusActions {
        CompanionSettingsStatusActions(
            refresh: { [weak self] in
                self?.makeSettingsStatusSnapshot() ?? CompanionSettingsStatusSnapshot.empty
            },
            openAISettings: { [weak self] in self?.showCompanionAISettingsAction() },
            testAIConnection: { [weak self] in self?.testCompanionAIConnectionAction() },
            toggleClipboardAI: { [weak self] in
                guard let self else { return }
                self.toggleClipboardTranslationAction(self.clipboardTranslationItem)
            },
            toggleSelectedTextAI: { [weak self] in
                guard let self else { return }
                self.toggleSelectionTranslationAction(self.selectionTranslationItem)
            },
            requestAccessibility: { [weak self] in self?.requestAccessibilityPermissionAction() },
            toggleCompanionVisible: { [weak self] in self?.desktopPet.toggleVisibilityFromSettings() },
            toggleCompanionAutoEdge: { [weak self] in self?.desktopPet.toggleAutoEdgeBehaviorFromSettings() },
            openCompanionDataFolder: { [weak self] in self?.openCompanionDataFolderAction() },
            exportDataPackage: { [weak self] in self?.exportDataPackageAction() },
            importDataPackage: { [weak self] in self?.importDataPackageAction() },
            exportDiagnosticPackage: { [weak self] in self?.exportDiagnosticPackageAction() },
            toggleICloudStorage: { [weak self] in self?.toggleICloudStorageAction() },
            copyMCPConfig: { [weak self] in self?.copyCompanionMCPConfigAction() },
            openMCPHelperInFinder: { [weak self] in self?.openCompanionMCPHelperInFinderAction() },
            openMCPAuditLog: { [weak self] in self?.openCompanionMCPAuditLogAction() },
            clearMCPAuditLog: { [weak self] in self?.clearCompanionMCPAuditLogAction() },
            revokeMCPClient: { [weak self] fingerprint in self?.revokeMCPClientAction(fingerprint) },
            revokeMCPClientTool: { [weak self] fingerprint, toolID in self?.revokeMCPClientToolAction(fingerprint: fingerprint, toolID: toolID) },
            openWorkflowRunHistory: { [weak self] in self?.openWorkflowRunHistoryAction() },
            clearWorkflowRunHistory: { [weak self] in self?.clearWorkflowRunHistoryAction() },
            openWorkflowRunFollowUp: { [weak self] action in self?.openWorkflowRunFollowUpAction(action) },
            copyWorkflowRunSummary: { [weak self] id in self?.copyWorkflowRunSummaryAction(id) },
            clearWorkflowApprovalPrefs: { [weak self] in self?.clearWorkflowApprovalPrefsAction() },
            openAssetUploadSettings: { [weak self] in self?.showAssetUploadSettingsAction() },
            testAssetUploadProfile: { [weak self] in self?.testAssetUploadProfileAction() },
            openAssetUploadHistory: { [weak self] in self?.openAssetUploadHistoryAction() },
            copyAssetUploadResult: { [weak self] id in self?.copyAssetUploadResultAction(id) },
            clearAssetUploadHistory: { [weak self] in self?.clearAssetUploadHistoryAction() },
            deleteAssetUploadProfile: { [weak self] in self?.deleteAssetUploadProfileAction() },
            clearAssetUploadApprovals: { [weak self] in self?.clearAssetUploadApprovalsAction() }
        )
    }

    func companionMCPHelperURL() -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.deletingLastPathComponent().appendingPathComponent("CompanionMCP")
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CompanionMCP")
    }

    func copyCompanionMCPConfigAction() {
        let command = companionMCPHelperURL().path
        let jsonConfig: [String: Any] = [
            "mcpServers": [
                "companion": [
                    "command": command
                ]
            ]
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: jsonConfig, options: [.prettyPrinted, .sortedKeys])
        let jsonText = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? command
        let tomlText = """
        [mcp_servers.companion]
        command = "\(Self.tomlEscaped(command))"
        """
        let text = """
        Companion MCP JSON
        \(jsonText)

        Companion MCP TOML
        \(tomlText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusItemText.title = Self.statusTitle("Companion MCP config copied")
    }

    static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    func openCompanionMCPHelperInFinderAction() {
        let helperURL = companionMCPHelperURL()
        if FileManager.default.fileExists(atPath: helperURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([helperURL])
        } else {
            NSWorkspace.shared.open(helperURL.deletingLastPathComponent())
        }
    }

    func openCompanionMCPAuditLogAction() {
        let auditURL = mcpAuditLog.url()
        if FileManager.default.fileExists(atPath: auditURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([auditURL])
        } else {
            NSWorkspace.shared.open(CompanionDataRoot.currentURL())
        }
    }

    func clearCompanionMCPAuditLogAction() {
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Clear MCP Audit Log?"),
            informativeText: CompanionL10n.text("Companion will remove the local MCP audit summary log. Reminders, Journal, Pomodoro data, and workflow history are not changed."),
            primaryButtonTitle: CompanionL10n.text("Clear"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        mcpAuditLog.clear()
    }

    func revokeMCPClientAction(_ fingerprint: String) {
        mcpClientProfilesStore.revokeClient(fingerprint: fingerprint)
    }

    func revokeMCPClientToolAction(fingerprint: String, toolID: String) {
        mcpClientProfilesStore.revokeTool(fingerprint: fingerprint, toolID: toolID)
    }

    func configureReminderFocusJournalRoutine() {
        let routine = reminderFocusJournalRoutine
        routine.createReminder = { [weak self] title, fireDate in
            self?.desktopPet.workflowCreateTimedReminder(title: title, fireDate: fireDate)
        }
        routine.confirmStartFocus = { taskTitle in
            CompanionNonBlockingAlert.confirm(
                messageText: "提醒到了：\(taskTitle)",
                informativeText: "现在开始一个番茄钟专注吗？",
                primaryButtonTitle: "开始专注",
                cancelButtonTitle: "稍后",
                tone: .info
            )
        }
        routine.hasActiveFocusSession = { [weak self] in
            self?.desktopPet.workflowHasActiveFocus ?? false
        }
        routine.startFocus = { [weak self] taskTitle in
            self?.desktopPet.workflowStartFocus(title: taskTitle)
        }
        routine.confirmSaveJournal = { taskTitle, draft in
            CompanionNonBlockingAlert.confirm(
                messageText: "专注结束：\(taskTitle)",
                informativeText: "把这条复盘存入今日日记吗？\n\n\(draft)",
                primaryButtonTitle: "保存",
                cancelButtonTitle: "不保存",
                tone: .info
            )
        }
        routine.appendJournal = { [weak self] section, lines in
            self?.desktopPet.workflowAppendJournalSection(section, lines: lines)
        }
        routine.notify = { message, info, isError in
            CompanionNonBlockingAlert.present(
                messageText: message,
                informativeText: info,
                tone: isError ? .warning : .success
            )
        }

        desktopPet.onRemindersDueForRoutine = { [weak self] ids in
            self?.reminderFocusJournalRoutine.handleReminderDue(reminderIDs: ids)
        }
        desktopPet.onPomodoroEndedForRoutine = { [weak self] recordID, taskTitle in
            self?.reminderFocusJournalRoutine.handlePomodoroEnd(focusRecordID: recordID, fallbackTaskTitle: taskTitle)
        }
        desktopPet.onStartReminderFocusJournalRoutine = { [weak self] in
            self?.promptAndStartReminderFocusJournalRoutine()
        }

        reminderFocusJournalRoutine.recoverInterruptedRuns()
    }

    func promptAndStartReminderFocusJournalRoutine() {
        guard let input = CompanionNonBlockingAlert.promptText(
            messageText: "提醒 → 专注 → 日记",
            informativeText: "用一句话描述任务和时间，例如“明天下午3点写周报”。到点小花儿会提醒你，确认后开专注，专注结束再帮你记一条日记。",
            placeholder: "明天下午3点写周报",
            primaryButtonTitle: "创建",
            tone: .info
        ), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let parsed = PetReminderRuleParser.parse(input) else {
            CompanionNonBlockingAlert.present(
                messageText: "没识别到时间",
                informativeText: "请在描述里带上时间，例如“明天下午3点写周报”“30分钟后写周报”。",
                tone: .warning
            )
            return
        }
        reminderFocusJournalRoutine.start(taskTitle: parsed.title, fireDate: parsed.fireDate)
    }

    func startReminderFocusJournalRoutine(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PetReminderRuleParser.parse(trimmed) else {
            return "我识别到你想走“提醒 → 专注 → 日记”，但还缺明确时间。试试这样说：30分钟后写周报，提醒我专注并结束后记日记。"
        }
        reminderFocusJournalRoutine.start(taskTitle: parsed.title, fireDate: parsed.fireDate)
        let dateText = DateFormatter.localizedString(from: parsed.fireDate, dateStyle: .short, timeStyle: .short)
        return "已创建“提醒 → 专注 → 日记”计划：\(parsed.title)，\(dateText) 提醒你开始。"
    }

    func clearWorkflowApprovalPrefsAction() {
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Clear Approval Preferences?"),
            informativeText: CompanionL10n.text("Companion will require confirmation again for local actions and MCP client tools you previously chose to auto-approve."),
            primaryButtonTitle: CompanionL10n.text("Clear"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        workflowApprovalStore.revokeAll()
        mcpClientProfilesStore.revokeAll()
        finderAssetUploadApprovalStore.revokeAll()
        CompanionNonBlockingAlert.present(
            messageText: CompanionL10n.text("Approval preferences cleared"),
            informativeText: CompanionL10n.text("Local actions and MCP client approvals will ask for confirmation again."),
            tone: .success
        )
    }

    func openWorkflowRunHistoryAction() {
        let historyURL = workflowRunStore.url()
        if FileManager.default.fileExists(atPath: historyURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([historyURL])
        } else {
            NSWorkspace.shared.open(CompanionDataRoot.currentURL())
        }
    }

    func clearWorkflowRunHistoryAction() {
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Clear Workflow Run History?"),
            informativeText: CompanionL10n.text("Companion will remove local workflow run summaries. MCP audit logs and app data are not changed."),
            primaryButtonTitle: CompanionL10n.text("Clear"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        workflowRunStore.clear()
    }

    func openWorkflowRunFollowUpAction(_ action: CompanionWorkflowFollowUpAction) {
        switch action {
        case .openReminders:
            desktopPet.showReminderCenterFromWorkflowRun()
        case .openJournal:
            desktopPet.showJournalFromWorkflowRun()
        case .openPomodoro:
            desktopPet.workflowShowPomodoroCenter()
        case .copyResult:
            break
        }
    }

    func copyWorkflowRunSummaryAction(_ id: UUID) {
        guard let run = workflowRunStore.run(id: id) else { return }
        let formatter = ISO8601DateFormatter()
        let finished = run.finishedAt.map { formatter.string(from: $0) } ?? "unfinished"
        let text = [
            "Title: \(run.title)",
            "Status: \(run.status.rawValue)",
            "Tool: \(run.toolID ?? run.kind.rawValue)",
            "Started: \(formatter.string(from: run.startedAt))",
            "Finished: \(finished)",
            "Input: \(run.inputSummary)",
            "Output: \(run.outputSummary)",
            "Error: \(run.errorSummary ?? "none")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openAssetUploadHistoryAction() {
        assetUploadSettingsCoordinator.openHistory()
    }

    func copyAssetUploadResultAction(_ id: String) {
        assetUploadSettingsCoordinator.copyResult(id: id)
    }

    func clearAssetUploadHistoryAction() {
        assetUploadSettingsCoordinator.clearHistory()
    }

    func deleteAssetUploadProfileAction() {
        assetUploadSettingsCoordinator.deleteProfile()
    }

    func testAssetUploadProfileAction() {
        assetUploadSettingsCoordinator.testProfile()
    }

    func clearAssetUploadApprovalsAction() {
        assetUploadSettingsCoordinator.clearApprovals()
    }

    func makeSettingsStatusSnapshot() -> CompanionSettingsStatusSnapshot {
        let companion = desktopPet.statusSnapshot()
        let mcpHelperURL = companionMCPHelperURL()
        let mcpDescriptors = CompanionWorkflowToolRegistry.defaultRegistry().descriptors()
        let auditRecords = mcpAuditLog.records()
        let latestAudit = auditRecords.last
        let latestProblem = mcpAuditLog.latestProblemRecord()
        let mcpClientProfiles = mcpClientProfilesStore.allProfiles()
        let workflowRuns = workflowRunStore.runs(limit: 5)
        let workflowRunCount = workflowRunStore.runs(limit: 200).count
        let assetUploadDocument = try? assetUploadProfileStore.document()
        let assetUploadDefaultProfile = try? assetUploadProfileStore.defaultProfile(requireCredentials: false)
        let assetUploadRecent = assetUploadHistoryStore.recent(limit: 5)
        let assetUploadHistoryCount = assetUploadHistoryStore.recent(limit: 100).count
        let aiSnapshot = try? companionAISettingsStore.snapshot()

        return CompanionSettingsStatusSnapshot(
            aiProviderSummary: aiSnapshot?.menuSummary ?? CompanionL10n.text("AI provider not configured"),
            aiConfigured: aiSnapshot?.hasStoredAPIKey == true,
            aiClipboardEnabled: clipboardTranslation.isClipboardEnabled,
            aiSelectionEnabled: clipboardTranslation.isSelectionEnabled,
            accessibilityGranted: clipboardTranslation.accessibilityPermissionGranted,
            companionDataRootPath: CompanionDataRoot.currentURL().path,
            iCloudStorageEnabled: dataPackageController.isICloudStorageEnabled(),
            companionVisible: companion.isVisible,
            companionAutoEdgeEnabled: companion.autoEdgeEnabled,
            companionVoiceEnabled: companion.voiceEnabled,
            companionVoiceVolume: companion.voiceVolume,
            companionStatus: companion.workflowStatusTitle,
            mcpHelperPath: mcpHelperURL.path,
            mcpHelperExecutable: FileManager.default.isExecutableFile(atPath: mcpHelperURL.path),
            mcpToolCount: mcpDescriptors.count,
            mcpToolNames: mcpDescriptors.map(\.title),
            mcpLastCallStatus: latestAudit?.status.rawValue ?? "",
            mcpLastCallToolID: latestAudit?.toolID ?? "",
            mcpLastCallAt: latestAudit?.timestamp,
            mcpLastErrorSummary: latestProblem?.errorSummary ?? "",
            mcpAuditLogPath: mcpAuditLog.url().path,
            mcpAuditRecordCount: auditRecords.count,
            mcpAuditLogSizeBytes: mcpAuditLog.fileSize(),
            mcpStoredApprovalCallCount: auditRecords.filter { $0.usedStoredApproval == true }.count,
            mcpClientProfiles: mcpClientProfiles.map { profile in
                CompanionSettingsMCPClientProfileSnapshot(
                    id: profile.id,
                    clientName: profile.clientName,
                    commandSummary: profile.commandSummary,
                    allowedTools: profile.allowedTools.sorted(),
                    createdAt: profile.createdAt,
                    lastSeenAt: profile.lastSeenAt,
                    approvalCount: profile.approvalCount
                )
            },
            mcpRecentAuditCalls: auditRecords.suffix(12).reversed().map { record in
                CompanionSettingsMCPAuditCallSnapshot(
                    id: record.id,
                    caller: record.caller,
                    toolID: record.toolID,
                    status: record.status.rawValue,
                    usedStoredApproval: record.usedStoredApproval == true,
                    timestamp: record.timestamp
                )
            },
            workflowRunHistoryPath: workflowRunStore.url().path,
            workflowRunCount: workflowRunCount,
            workflowRuns: workflowRuns.map { run in
                CompanionSettingsWorkflowRunSnapshot(
                    id: run.id,
                    title: run.title,
                    toolID: run.toolID ?? "",
                    kind: run.kind.rawValue,
                    status: run.status,
                    startedAt: run.startedAt,
                    finishedAt: run.finishedAt,
                    inputSummary: run.inputSummary,
                    outputSummary: run.outputSummary,
                    errorSummary: run.errorSummary ?? "",
                    followUpActions: run.followUpActions
                )
            },
            assetUploadConfigured: assetUploadDefaultProfile != nil,
            assetUploadProfileName: assetUploadDefaultProfile?.profileSummary ?? CompanionL10n.text("Not configured"),
            assetUploadProfileType: assetUploadDefaultProfile?.type.rawValue ?? "",
            assetUploadProfileCount: assetUploadDocument?.profiles.count ?? 0,
            assetUploadDefaultFormat: assetUploadDefaultProfile?.resolvedDefaultOutputFormat ?? .url,
            assetUploadMaxSizeBytes: assetUploadDefaultProfile?.limits.maxSizeBytes ?? CompanionAssetUploadProfile.Limits.defaultMaxSizeBytes,
            assetUploadFinderApprovalCount: finderAssetUploadApprovalStore.records().count,
            assetUploadHistoryPath: assetUploadHistoryStore.url.path,
            assetUploadHistoryCount: assetUploadHistoryCount,
            assetUploadRecent: assetUploadRecent.map { record in
                CompanionSettingsAssetUploadRecordSnapshot(
                    id: record.assetID,
                    fileNameSummary: record.fileNameSummary,
                    formatted: record.formatted ?? "",
                    url: record.url ?? "",
                    format: record.format,
                    status: record.status,
                    profileSummary: record.profileSummary,
                    sizeBytes: record.sizeBytes,
                    uploadedAt: record.uploadedAt,
                    errorSummary: record.errorSummary ?? ""
                )
            }
        )
    }
}
