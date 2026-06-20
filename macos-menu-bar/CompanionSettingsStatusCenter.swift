import AppKit
import SwiftUI

struct CompanionSettingsWorkflowRunSnapshot: Identifiable, Equatable {
    var id: UUID
    var title: String
    var toolID: String
    var kind: String
    var status: CompanionWorkflowRunStatus
    var startedAt: Date
    var finishedAt: Date?
    var inputSummary: String
    var outputSummary: String
    var errorSummary: String
    var followUpActions: [CompanionWorkflowFollowUpAction]
}

struct CompanionSettingsAssetUploadRecordSnapshot: Identifiable, Equatable {
    var id: String
    var fileNameSummary: String
    var formatted: String
    var url: String
    var format: CompanionAssetUploadOutputFormat
    var status: CompanionAssetUploadHistoryStatus
    var profileSummary: String
    var sizeBytes: Int
    var uploadedAt: Date
    var errorSummary: String
}

struct CompanionSettingsMCPClientProfileSnapshot: Identifiable, Equatable {
    var id: String
    var clientName: String
    var commandSummary: String
    var allowedTools: [String]
    var createdAt: Date
    var lastSeenAt: Date
    var approvalCount: Int

    var displayName: String {
        let trimmed = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return commandSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompanionL10n.text("Unknown Client")
            : commandSummary
    }
}

struct CompanionSettingsMCPAuditCallSnapshot: Identifiable, Equatable {
    var id: UUID
    var caller: String
    var toolID: String
    var status: String
    var usedStoredApproval: Bool
    var timestamp: Date
}

struct CompanionSettingsStatusSnapshot {
    var aiProviderSummary: String
    var aiConfigured: Bool
    var aiClipboardEnabled: Bool
    var aiSelectionEnabled: Bool
    var accessibilityGranted: Bool
    var companionDataRootPath: String
    var iCloudStorageEnabled: Bool
    var companionVisible: Bool
    var companionAutoEdgeEnabled: Bool
    var companionVoiceEnabled: Bool
    var companionVoiceVolume: Double
    var companionStatus: String
    var mcpHelperPath: String
    var mcpHelperExecutable: Bool
    var mcpToolCount: Int
    var mcpToolNames: [String]
    var mcpLastCallStatus: String
    var mcpLastCallToolID: String
    var mcpLastCallAt: Date?
    var mcpLastErrorSummary: String
    var mcpAuditLogPath: String
    var mcpAuditRecordCount: Int
    var mcpAuditLogSizeBytes: Int64
    var mcpStoredApprovalCallCount: Int
    var mcpClientProfiles: [CompanionSettingsMCPClientProfileSnapshot]
    var mcpRecentAuditCalls: [CompanionSettingsMCPAuditCallSnapshot]
    var workflowRunHistoryPath: String
    var workflowRunCount: Int
    var workflowRuns: [CompanionSettingsWorkflowRunSnapshot]
    var assetUploadConfigured: Bool
    var assetUploadProfileName: String
    var assetUploadProfileType: String
    var assetUploadProfileCount: Int
    var assetUploadDefaultFormat: CompanionAssetUploadOutputFormat
    var assetUploadMaxSizeBytes: Int
    var assetUploadFinderApprovalCount: Int
    var assetUploadHistoryPath: String
    var assetUploadHistoryCount: Int
    var assetUploadRecent: [CompanionSettingsAssetUploadRecordSnapshot]

    static let empty = CompanionSettingsStatusSnapshot(
        aiProviderSummary: CompanionL10n.text("AI provider not configured"),
        aiConfigured: false,
        aiClipboardEnabled: false,
        aiSelectionEnabled: false,
        accessibilityGranted: false,
        companionDataRootPath: CompanionDataRoot.currentURL().path,
        iCloudStorageEnabled: false,
        companionVisible: false,
        companionAutoEdgeEnabled: false,
        companionVoiceEnabled: false,
        companionVoiceVolume: 0,
        companionStatus: CompanionL10n.text("Unknown"),
        mcpHelperPath: "",
        mcpHelperExecutable: false,
        mcpToolCount: 0,
        mcpToolNames: [],
        mcpLastCallStatus: "",
        mcpLastCallToolID: "",
        mcpLastCallAt: nil,
        mcpLastErrorSummary: "",
        mcpAuditLogPath: "",
        mcpAuditRecordCount: 0,
        mcpAuditLogSizeBytes: 0,
        mcpStoredApprovalCallCount: 0,
        mcpClientProfiles: [],
        mcpRecentAuditCalls: [],
        workflowRunHistoryPath: "",
        workflowRunCount: 0,
        workflowRuns: [],
        assetUploadConfigured: false,
        assetUploadProfileName: CompanionL10n.text("Not configured"),
        assetUploadProfileType: "",
        assetUploadProfileCount: 0,
        assetUploadDefaultFormat: .url,
        assetUploadMaxSizeBytes: CompanionAssetUploadProfile.Limits.defaultMaxSizeBytes,
        assetUploadFinderApprovalCount: 0,
        assetUploadHistoryPath: "",
        assetUploadHistoryCount: 0,
        assetUploadRecent: []
    )
}

struct CompanionSettingsStatusActions {
    var refresh: () -> CompanionSettingsStatusSnapshot
    var openAISettings: () -> Void
    var testAIConnection: () -> Void
    var toggleClipboardAI: () -> Void
    var toggleSelectedTextAI: () -> Void
    var requestAccessibility: () -> Void
    var toggleCompanionVisible: () -> Void
    var toggleCompanionAutoEdge: () -> Void
    var openCompanionDataFolder: () -> Void
    var exportDataPackage: () -> Void
    var importDataPackage: () -> Void
    var exportDiagnosticPackage: () -> Void
    var toggleICloudStorage: () -> Void
    var copyMCPConfig: () -> Void
    var openMCPHelperInFinder: () -> Void
    var openMCPAuditLog: () -> Void
    var clearMCPAuditLog: () -> Void
    var revokeMCPClient: (String) -> Void
    var revokeMCPClientTool: (String, String) -> Void
    var openWorkflowRunHistory: () -> Void
    var clearWorkflowRunHistory: () -> Void
    var openWorkflowRunFollowUp: (CompanionWorkflowFollowUpAction) -> Void
    var copyWorkflowRunSummary: (UUID) -> Void
    var clearWorkflowApprovalPrefs: () -> Void
    var openAssetUploadSettings: () -> Void
    var testAssetUploadProfile: () -> Void
    var openAssetUploadHistory: () -> Void
    var copyAssetUploadResult: (String) -> Void
    var clearAssetUploadHistory: () -> Void
    var deleteAssetUploadProfile: () -> Void
    var clearAssetUploadApprovals: () -> Void
}

final class CompanionSettingsStatusCenterController {
    static let refreshRequestedNotification = Notification.Name("CompanionSettingsStatusCenterRefreshRequested")

    private var window: NSWindow?
    private let actions: CompanionSettingsStatusActions

    init(actions: CompanionSettingsStatusActions) {
        self.actions = actions
    }

    func show() {
        let window = existingOrNewWindow()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Self.refreshRequestedNotification, object: self)
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window {
            return window
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = CompanionL10n.text("Dashboard")
        window.minSize = NSSize(width: 760, height: 500)
        window.contentView = NSHostingView(rootView: CompanionSettingsStatusView(
            initialSnapshot: actions.refresh(),
            actions: actions
        ))
        self.window = window
        return window
    }
}

private enum CompanionSettingsStatusSection: String, CaseIterable {
    case overview
    case ai
    case companion
    case data
    case mcp
    case workflows
    case assets

    var title: String {
        switch self {
        case .overview: return CompanionL10n.text("Overview")
        case .ai: return CompanionL10n.text("AI Quick Actions")
        case .companion: return CompanionL10n.text("XiaoHuaEr")
        case .data: return CompanionL10n.text("Data")
        case .mcp: return CompanionL10n.text("MCP")
        case .workflows: return CompanionL10n.text("Workflows")
        case .assets: return CompanionL10n.text("Asset Upload")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.medium"
        case .ai: return "sparkles"
        case .companion: return "face.smiling"
        case .data: return "externaldrive"
        case .mcp: return "terminal"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .assets: return "photo.on.rectangle.angled"
        }
    }
}

private struct CompanionSettingsStatusView: View {
    let actions: CompanionSettingsStatusActions

    @State private var snapshot: CompanionSettingsStatusSnapshot
    @State private var selectedSection: CompanionSettingsStatusSection = .overview

    init(initialSnapshot: CompanionSettingsStatusSnapshot, actions: CompanionSettingsStatusActions) {
        _snapshot = State(initialValue: initialSnapshot)
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: CompanionSettingsStatusCenterController.refreshRequestedNotification)) { _ in
            refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Companion")
                .font(.system(size: 18, weight: .semibold))
                .padding(.bottom, 10)
            ForEach(CompanionSettingsStatusSection.allCases, id: \.self) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(selectedSection == section ? XiaoHuaErTheme.tint.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Label(CompanionL10n.text("Refresh"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedSection.title)
                .font(.system(size: 24, weight: .semibold))
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    private var headerSubtitle: String {
        switch selectedSection {
        case .overview:
            return CompanionL10n.text("Companion status, local data, and workflow health.")
        case .ai:
            return CompanionL10n.text("Lightweight AI settings for chat, selection, clipboard, and Focus Review.")
        case .companion:
            return CompanionL10n.text("Desktop companion visibility, edge behavior, and voice state.")
        case .data:
            return CompanionL10n.text("Local data package and storage location.")
        case .mcp:
            return CompanionL10n.text("Local MCP helper, audit records, and client approvals.")
        case .workflows:
            return CompanionL10n.text("Recent local workflow runs.")
        case .assets:
            return CompanionL10n.text("Upload profiles, approvals, and recent uploaded assets.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .overview:
            overview
        case .ai:
            aiPanel
        case .companion:
            companionPanel
        case .data:
            dataPanel
        case .mcp:
            mcpPanel
        case .workflows:
            workflowsPanel
        case .assets:
            assetsPanel
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                statusTile(title: CompanionL10n.text("AI"), value: snapshot.aiConfigured ? CompanionL10n.text("Ready") : CompanionL10n.text("Needs Setup"), detail: snapshot.aiProviderSummary, ok: snapshot.aiConfigured)
                statusTile(title: CompanionL10n.text("Companion"), value: snapshot.companionVisible ? CompanionL10n.text("Visible") : CompanionL10n.text("Hidden"), detail: snapshot.companionStatus, ok: snapshot.companionVisible)
            }
            HStack(spacing: 12) {
                statusTile(title: CompanionL10n.text("MCP"), value: snapshot.mcpHelperExecutable ? CompanionL10n.text("Ready") : CompanionL10n.text("Missing"), detail: "\(snapshot.mcpToolCount) tools", ok: snapshot.mcpHelperExecutable && snapshot.mcpToolCount > 0)
                statusTile(title: CompanionL10n.text("Asset Upload"), value: snapshot.assetUploadConfigured ? CompanionL10n.text("Configured") : CompanionL10n.text("Not configured"), detail: snapshot.assetUploadProfileName, ok: snapshot.assetUploadConfigured)
            }
            sectionBox(CompanionL10n.text("Storage")) {
                keyValue(CompanionL10n.text("Data Root"), snapshot.companionDataRootPath)
                keyValue(CompanionL10n.text("iCloud"), snapshot.iCloudStorageEnabled ? CompanionL10n.text("Enabled") : CompanionL10n.text("Local"))
            }
        }
    }

    private var aiPanel: some View {
        sectionBox(CompanionL10n.text("AI Quick Actions")) {
            keyValue(CompanionL10n.text("Provider"), snapshot.aiProviderSummary)
            keyValue(CompanionL10n.text("Clipboard Popup"), snapshot.aiClipboardEnabled ? CompanionL10n.text("On") : CompanionL10n.text("Off"))
            keyValue(CompanionL10n.text("Selected Text Popup"), snapshot.aiSelectionEnabled ? CompanionL10n.text("On") : CompanionL10n.text("Off"))
            keyValue(CompanionL10n.text("Accessibility"), snapshot.accessibilityGranted ? CompanionL10n.text("Granted") : CompanionL10n.text("Needs Permission"))
            buttonRow([
                (CompanionL10n.text("AI Settings"), "gearshape", actions.openAISettings),
                (CompanionL10n.text("Test Connection"), "checkmark.seal", actions.testAIConnection),
                (snapshot.aiClipboardEnabled ? CompanionL10n.text("Disable Clipboard") : CompanionL10n.text("Enable Clipboard"), "doc.on.clipboard", actions.toggleClipboardAI)
            ])
            buttonRow([
                (snapshot.aiSelectionEnabled ? CompanionL10n.text("Disable Selected Text") : CompanionL10n.text("Enable Selected Text"), "selection.pin.in.out", actions.toggleSelectedTextAI),
                (CompanionL10n.text("Grant Accessibility"), "hand.raised", actions.requestAccessibility)
            ])
        }
    }

    private var companionPanel: some View {
        sectionBox(CompanionL10n.text("XiaoHuaEr")) {
            keyValue(CompanionL10n.text("Visible"), snapshot.companionVisible ? CompanionL10n.text("Yes") : CompanionL10n.text("No"))
            keyValue(CompanionL10n.text("Auto Edge"), snapshot.companionAutoEdgeEnabled ? CompanionL10n.text("On") : CompanionL10n.text("Off"))
            keyValue(CompanionL10n.text("Voice"), snapshot.companionVoiceEnabled ? CompanionL10n.format("%.0f%%", snapshot.companionVoiceVolume * 100) : CompanionL10n.text("Off"))
            keyValue(CompanionL10n.text("Status"), snapshot.companionStatus)
            buttonRow([
                (snapshot.companionVisible ? CompanionL10n.text("Hide XiaoHuaEr") : CompanionL10n.text("Show XiaoHuaEr"), "eye", actions.toggleCompanionVisible),
                (snapshot.companionAutoEdgeEnabled ? CompanionL10n.text("Disable Auto Edge") : CompanionL10n.text("Enable Auto Edge"), "rectangle.expand.vertical", actions.toggleCompanionAutoEdge)
            ])
        }
    }

    private var dataPanel: some View {
        sectionBox(CompanionL10n.text("Companion Data")) {
            keyValue(CompanionL10n.text("Data Root"), snapshot.companionDataRootPath)
            keyValue(CompanionL10n.text("iCloud Storage"), snapshot.iCloudStorageEnabled ? CompanionL10n.text("Enabled") : CompanionL10n.text("Local"))
            buttonRow([
                (CompanionL10n.text("Open Folder"), "folder", actions.openCompanionDataFolder),
                (CompanionL10n.text("Export Package"), "square.and.arrow.up", actions.exportDataPackage),
                (CompanionL10n.text("Import Package"), "square.and.arrow.down", actions.importDataPackage)
            ])
            buttonRow([
                (CompanionL10n.text("Export Diagnostics"), "stethoscope", actions.exportDiagnosticPackage),
                (snapshot.iCloudStorageEnabled ? CompanionL10n.text("Move to This Mac") : CompanionL10n.text("Use iCloud"), "icloud", actions.toggleICloudStorage)
            ])
        }
    }

    private var mcpPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionBox(CompanionL10n.text("MCP Helper")) {
                keyValue(CompanionL10n.text("Helper"), snapshot.mcpHelperExecutable ? CompanionL10n.text("Executable") : CompanionL10n.text("Not Found"))
                keyValue(CompanionL10n.text("Command"), snapshot.mcpHelperPath.isEmpty ? CompanionL10n.text("Unknown") : snapshot.mcpHelperPath)
                keyValue(CompanionL10n.text("Tools"), snapshot.mcpToolNames.isEmpty ? CompanionL10n.text("None") : snapshot.mcpToolNames.joined(separator: ", "))
                keyValue(CompanionL10n.text("Last Call"), snapshot.mcpLastCallToolID.isEmpty ? CompanionL10n.text("None") : "\(snapshot.mcpLastCallToolID) · \(snapshot.mcpLastCallStatus)")
                keyValue(CompanionL10n.text("Audit Log"), "\(snapshot.mcpAuditRecordCount) · \(byteCount(snapshot.mcpAuditLogSizeBytes))")
                if !snapshot.mcpLastErrorSummary.isEmpty {
                    keyValue(CompanionL10n.text("Last Error"), snapshot.mcpLastErrorSummary)
                }
                buttonRow([
                    (CompanionL10n.text("Copy Config"), "doc.on.doc", actions.copyMCPConfig),
                    (CompanionL10n.text("Show Helper"), "magnifyingglass", actions.openMCPHelperInFinder),
                    (CompanionL10n.text("Open Audit Log"), "list.bullet.rectangle", actions.openMCPAuditLog)
                ])
                buttonRow([
                    (CompanionL10n.text("Clear Audit Log"), "trash", actions.clearMCPAuditLog),
                    (CompanionL10n.text("Clear Approval Preferences"), "xmark.seal", actions.clearWorkflowApprovalPrefs)
                ])
            }

            sectionBox(CompanionL10n.text("Approved Clients")) {
                if snapshot.mcpClientProfiles.isEmpty {
                    emptyText(CompanionL10n.text("No MCP client approvals yet."))
                } else {
                    ForEach(snapshot.mcpClientProfiles) { profile in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(profile.displayName).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button(CompanionL10n.text("Revoke")) {
                                    actions.revokeMCPClient(profile.id)
                                    refresh()
                                }
                            }
                            Text(profile.commandSummary)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text(profile.allowedTools.isEmpty ? CompanionL10n.text("No remembered tools") : profile.allowedTools.joined(separator: ", "))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Divider()
                    }
                }
            }

            sectionBox(CompanionL10n.text("Recent MCP Calls")) {
                if snapshot.mcpRecentAuditCalls.isEmpty {
                    emptyText(CompanionL10n.text("No MCP calls yet."))
                } else {
                    ForEach(snapshot.mcpRecentAuditCalls) { call in
                        rowTitle(call.toolID, detail: "\(call.status) · \(dateTime(call.timestamp))")
                    }
                }
            }
        }
    }

    private var workflowsPanel: some View {
        sectionBox(CompanionL10n.text("Workflow Runs")) {
            keyValue(CompanionL10n.text("Stored Runs"), "\(snapshot.workflowRunCount)")
            keyValue(CompanionL10n.text("History File"), snapshot.workflowRunHistoryPath)
            buttonRow([
                (CompanionL10n.text("Open History"), "folder", actions.openWorkflowRunHistory),
                (CompanionL10n.text("Clear History"), "trash", actions.clearWorkflowRunHistory)
            ])
            if snapshot.workflowRuns.isEmpty {
                emptyText(CompanionL10n.text("No workflow runs yet."))
            } else {
                ForEach(snapshot.workflowRuns) { run in
                    workflowRunRow(run)
                    Divider()
                }
            }
        }
    }

    private var assetsPanel: some View {
        sectionBox(CompanionL10n.text("Asset Upload")) {
            keyValue(CompanionL10n.text("Default Profile"), snapshot.assetUploadProfileName)
            keyValue(CompanionL10n.text("Profile Count"), "\(snapshot.assetUploadProfileCount)")
            keyValue(CompanionL10n.text("Default Format"), snapshot.assetUploadDefaultFormat.rawValue)
            keyValue(CompanionL10n.text("Max Size"), byteCount(Int64(snapshot.assetUploadMaxSizeBytes)))
            keyValue(CompanionL10n.text("Finder Approvals"), "\(snapshot.assetUploadFinderApprovalCount)")
            keyValue(CompanionL10n.text("History"), "\(snapshot.assetUploadHistoryCount) · \(snapshot.assetUploadHistoryPath)")
            buttonRow([
                (CompanionL10n.text("Settings"), "gearshape", actions.openAssetUploadSettings),
                (CompanionL10n.text("Test Profile"), "checkmark.seal", actions.testAssetUploadProfile),
                (CompanionL10n.text("Open History"), "folder", actions.openAssetUploadHistory)
            ])
            buttonRow([
                (CompanionL10n.text("Clear History"), "trash", actions.clearAssetUploadHistory),
                (CompanionL10n.text("Delete Profile"), "minus.circle", actions.deleteAssetUploadProfile),
                (CompanionL10n.text("Clear Approvals"), "xmark.seal", actions.clearAssetUploadApprovals)
            ])
            if snapshot.assetUploadRecent.isEmpty {
                emptyText(CompanionL10n.text("No uploaded assets yet."))
            } else {
                ForEach(snapshot.assetUploadRecent) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record.fileNameSummary).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(CompanionL10n.text("Copy")) {
                                actions.copyAssetUploadResult(record.id)
                            }
                        }
                        Text(record.errorSummary.isEmpty ? (record.formatted.isEmpty ? record.url : record.formatted) : record.errorSummary)
                            .font(.system(size: 12))
                            .foregroundColor(record.errorSummary.isEmpty ? .secondary : XiaoHuaErTheme.coral)
                        Text("\(record.status.rawValue) · \(byteCount(Int64(record.sizeBytes))) · \(dateTime(record.uploadedAt))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    private func workflowRunRow(_ run: CompanionSettingsWorkflowRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.title.isEmpty ? (run.toolID.isEmpty ? run.kind : run.toolID) : run.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(run.status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor(run.status).opacity(0.14))
                    .clipShape(Capsule())
            }
            Text(workflowRunDetail(run))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !run.errorSummary.isEmpty {
                Text(run.errorSummary)
                    .font(.system(size: 12))
                    .foregroundColor(XiaoHuaErTheme.coral)
            }
            HStack {
                ForEach(run.followUpActions.filter { $0 != .copyResult }, id: \.self) { followUp in
                    Button(followUpTitle(followUp)) {
                        actions.openWorkflowRunFollowUp(followUp)
                    }
                }
                Button(CompanionL10n.text("Copy Summary")) {
                    actions.copyWorkflowRunSummary(run.id)
                }
            }
        }
    }

    private func statusTile(title: String, value: String, detail: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(ok ? XiaoHuaErTheme.leaf : XiaoHuaErTheme.amber)
                    .frame(width: 8, height: 8)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value.isEmpty ? CompanionL10n.text("None") : value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttonRow(_ items: [(String, String, () -> Void)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    item.2()
                    refresh()
                } label: {
                    Label(item.0, systemImage: item.1)
                }
            }
        }
    }

    private func refresh() {
        snapshot = actions.refresh()
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func workflowRunDetail(_ run: CompanionSettingsWorkflowRunSnapshot) -> String {
        let tool = run.toolID.isEmpty ? run.kind : run.toolID
        let started = dateTime(run.startedAt)
        if !run.outputSummary.isEmpty {
            return "\(tool) · \(started) · \(run.outputSummary)"
        }
        if !run.inputSummary.isEmpty {
            return "\(tool) · \(started) · \(run.inputSummary)"
        }
        return "\(tool) · \(started)"
    }

    private func statusColor(_ status: CompanionWorkflowRunStatus) -> Color {
        switch status {
        case .completed:
            return XiaoHuaErTheme.leaf
        case .running, .awaitingApproval, .awaitingInput:
            return XiaoHuaErTheme.tint
        case .blocked, .failed:
            return XiaoHuaErTheme.coral
        case .denied, .cancelled:
            return XiaoHuaErTheme.amber
        case .pending:
            return .secondary
        }
    }

    private func followUpTitle(_ action: CompanionWorkflowFollowUpAction) -> String {
        switch action {
        case .openJournal:
            return CompanionL10n.text("Open Journal")
        case .openReminders:
            return CompanionL10n.text("Open Reminders")
        case .openPomodoro:
            return CompanionL10n.text("Open Pomodoro")
        case .copyResult:
            return CompanionL10n.text("Copy Result")
        }
    }
}
