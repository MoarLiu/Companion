import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let menuBarIconSize = NSSize(width: 32, height: 21)
    private static let menuBarIconItemLength: CGFloat = 38

    let companionAISettingsStore = CompanionAISettingsStore()
    lazy var aiService = CompanionAIService(
        providerResolver: { [weak self] in
            guard let self else {
                throw CompanionAIProviderError.unavailable
            }
            return try self.companionAISettingsStore.providerConfiguration()
        },
        providerDisplayNameResolver: { [weak self] in
            self?.companionAISettingsStore.displayName() ?? "Companion AI"
        }
    )
    lazy var desktopPet = DesktopPetFeature()
    lazy var petChat = PetChatWindowController(aiService: aiService)
    lazy var clipboardTranslation = ClipboardTranslationFeature(aiService: aiService)
    let dataPackageController = CompanionDataPackageController()
    let assetUploadProfileStore = CompanionAssetUploadProfileStore()
    let assetUploadHistoryStore = CompanionAssetUploadHistoryStore()
    let finderAssetUploadApprovalStore = CompanionFinderAssetUploadApprovalStore()
    lazy var assetUploadSettingsCoordinator: CompanionAssetUploadSettingsCoordinator = {
        let coordinator = CompanionAssetUploadSettingsCoordinator(
            profileStore: assetUploadProfileStore,
            historyStore: assetUploadHistoryStore,
            finderApprovalStore: finderAssetUploadApprovalStore,
            mcpClientProfilesStore: mcpClientProfilesStore
        )
        coordinator.onStatusTitleChanged = { [weak self] title in
            self?.statusItemText.title = title
        }
        coordinator.onError = { [weak self] message in
            self?.showError(message)
        }
        return coordinator
    }()
    let updateController = CompanionUpdateController()
    let mcpAuditLog = CompanionMCPAuditLog()
    let workflowRunStore = CompanionWorkflowRunStore()
    /// 本地 Hero 授权偏好 store（与 DesktopPetFeature、Dashboard 共享同一实例，保证 cache 一致）。
    let workflowApprovalStore = WorkflowApprovalPreferencesStore()
    /// 旗舰 routine 编排器（提醒 → 专注 → 日记，跨事件续接）。
    lazy var reminderFocusJournalRoutine = CompanionReminderFocusJournalRoutine(runStore: workflowRunStore)
    /// MCP per-client 授权偏好（mcp-client-profiles.json）。
    let mcpClientProfilesStore = MCPClientProfilesStore()
    /// 最近一次多选 AI 结果 workflow 的 run id（供打开 Workflow Console 用）。
    var lastAIWorkflowRunID: UUID?
    var lastAIWorkflowRequest: XiaoHuaErAIResultWorkflowRequest?
    lazy var assetUploadWorkflowCoordinator: CompanionAssetUploadWorkflowCoordinator = {
        let coordinator = CompanionAssetUploadWorkflowCoordinator(
            profileStore: assetUploadProfileStore,
            historyStore: assetUploadHistoryStore,
            mcpClientProfilesStore: mcpClientProfilesStore,
            workflowRunStore: workflowRunStore,
            auditLog: mcpAuditLog,
            statusItemText: statusItemText,
            desktopPet: desktopPet
        )
        coordinator.onError = { [weak self] message in
            self?.showError(message)
        }
        coordinator.onShowSettings = { [weak self] in
            self?.showAssetUploadSettingsAction()
        }
        coordinator.onShowS3Settings = { [weak self] in
            self?.showAssetUploadS3SettingsAction()
        }
        coordinator.onPresentWorkflowConsole = { [weak self] snapshot in
            self?.presentWorkflowConsole(snapshot)
        }
        coordinator.onRefreshWorkflowConsole = { [weak self] runID in
            self?.refreshWorkflowConsole(runID: runID)
        }
        return coordinator
    }()
    lazy var externalToolCallCoordinator: CompanionExternalToolCallCoordinator = {
        let coordinator = CompanionExternalToolCallCoordinator(
            auditLog: mcpAuditLog,
            workflowRunStore: workflowRunStore,
            mcpClientProfilesStore: mcpClientProfilesStore,
            assetUploadProfileStore: assetUploadProfileStore
        )
        coordinator.onApprovalRequested = { [weak self] duration in
            self?.desktopPet.showExternalToolApprovalRequested(duration: duration)
        }
        coordinator.onRunning = { [weak self] in
            self?.desktopPet.showExternalToolCallRunning()
        }
        coordinator.onResult = { [weak self] result, toolID in
            self?.desktopPet.showExternalToolCallResult(result, toolID: toolID)
        }
        coordinator.onStartExternalFocus = { [weak self] taskTitle, durationMinutes in
            self?.desktopPet.startExternalFocus(taskTitle: taskTitle, durationMinutes: durationMinutes)
                ?? .failed(code: "companion_unavailable", message: "Companion is unavailable.")
        }
        coordinator.onRefreshReminderWrite = { [weak self] showWindow in
            self?.desktopPet.refreshExternalReminderWrite(showWindow: showWindow)
        }
        coordinator.onRefreshJournalWrite = { [weak self] showWindow in
            self?.desktopPet.refreshExternalJournalWrite(showWindow: showWindow)
        }
        return coordinator
    }()
    lazy var settingsStatusCenter = CompanionSettingsStatusCenterController(actions: makeSettingsStatusActions())
    lazy var mainMenuCoordinator = CompanionMainMenuCoordinator(app: self)
    let statusItem = NSStatusBar.system.statusItem(withLength: AppDelegate.menuBarIconItemLength)
    let menu = NSMenu()
    let statusItemText = NSMenuItem(title: CompanionL10n.format("Status: %@", CompanionL10n.text("Ready")), action: nil, keyEquivalent: "")
    var lastMenuRefreshAt = Date.distantPast
    let menuRefreshInterval: TimeInterval = 0.75
    let translationItem = NSMenuItem(title: CompanionL10n.text("AI Quick Actions"), action: nil, keyEquivalent: "")
    let translationMenu = NSMenu(title: CompanionL10n.text("AI Quick Actions"))
    let companionAIStatusItem = NSMenuItem(title: CompanionL10n.text("AI provider not configured"), action: nil, keyEquivalent: "")
    let companionAISettingsItem = NSMenuItem(title: CompanionL10n.text("AI Settings..."), action: #selector(showCompanionAISettingsAction), keyEquivalent: "")
    let testCompanionAIConnectionItem = NSMenuItem(title: CompanionL10n.text("Test AI Connection"), action: #selector(testCompanionAIConnectionAction), keyEquivalent: "")
    let clipboardTranslationItem = NSMenuItem(title: CompanionL10n.text("Clipboard AI Popup"), action: #selector(toggleClipboardTranslationAction(_:)), keyEquivalent: "")
    let selectionTranslationItem = NSMenuItem(title: CompanionL10n.text("Selected Text AI Popup"), action: #selector(toggleSelectionTranslationAction(_:)), keyEquivalent: "")
    let accessibilityPermissionItem = NSMenuItem(title: CompanionL10n.text("Accessibility Permission"), action: #selector(requestAccessibilityPermissionAction), keyEquivalent: "")
    let translateClipboardItem = NSMenuItem(title: CompanionL10n.text("Process Clipboard"), action: #selector(translateClipboardAction), keyEquivalent: "")
    let uploadClipboardImageItem = NSMenuItem(title: CompanionL10n.text("Upload Clipboard Image"), action: #selector(uploadClipboardImageAction), keyEquivalent: "")
    let companionDataItem = NSMenuItem(title: CompanionL10n.text("Companion Data"), action: nil, keyEquivalent: "")
    let companionDataMenu = NSMenu(title: CompanionL10n.text("Companion Data"))
    let exportDataPackageItem = NSMenuItem(title: CompanionL10n.text("Export Data Package"), action: #selector(exportDataPackageAction), keyEquivalent: "")
    let importDataPackageItem = NSMenuItem(title: CompanionL10n.text("Import Data Package"), action: #selector(importDataPackageAction), keyEquivalent: "")
    let exportDiagnosticPackageItem = NSMenuItem(title: CompanionL10n.text("Export Diagnostic Package"), action: #selector(exportDiagnosticPackageAction), keyEquivalent: "")
    let assetUploadSettingsItem = NSMenuItem(title: CompanionL10n.text("Asset Upload..."), action: #selector(showAssetUploadSettingsAction), keyEquivalent: "")
    let toggleICloudStorageItem = NSMenuItem(title: CompanionL10n.text("Store Data in iCloud"), action: #selector(toggleICloudStorageAction), keyEquivalent: "")
    let openCompanionDataFolderItem = NSMenuItem(title: CompanionL10n.text("Open Companion Data Folder"), action: #selector(openCompanionDataFolderAction), keyEquivalent: "")
    let openICloudDataFolderItem = NSMenuItem(title: CompanionL10n.text("Open iCloud Data Folder"), action: #selector(openICloudDataFolderAction), keyEquivalent: "")
    let versionItem = NSMenuItem(title: "Companion", action: nil, keyEquivalent: "")
    var menuBarCountdownTitle: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        repairLegacyICloudDataSplitIfNeeded()
        translationItem.submenu = translationMenu
        desktopPet.additionalMenuItemsProvider = { [weak self] in
            guard let self else { return [] }
            self.rebuildTranslationMenu()
            return [self.translationItem]
        }
        desktopPet.focusReviewSummaryProvider = { [weak self] snapshot in
            guard let self else {
                throw CompanionAIProviderError.unavailable
            }
            return try await self.aiService.focusReviewSummary(snapshot: snapshot)
        }
        desktopPet.onChatRequested = { [weak self] anchorWindow, petName in
            DispatchQueue.main.async {
                self?.petChat.show(relativeTo: anchorWindow, title: petName)
            }
        }
        petChat.onReminderFocusJournalRequested = { [weak self] text in
            self?.startReminderFocusJournalRoutine(from: text) ?? "小花儿暂时不可用"
        }
        petChat.onAIResultWorkflowRequested = { [weak self] action in
            guard let self,
                  let request = self.clipboardTranslation.currentAIResultWorkflowRequest(action: action)
            else {
                return nil
            }
            return self.handleAIResultWorkflowRequest(request).statusMessage
        }
        petChat.hasAIResultWorkflowContext = { [weak self] in
            self?.clipboardTranslation.hasAIResultWorkflowContext() ?? false
        }
        desktopPet.onTranslationRequested = { [weak self] anchorWindow in
            DispatchQueue.main.async {
                self?.clipboardTranslation.showTranslationWindow(anchorWindow: anchorWindow)
            }
        }
        desktopPet.onJournalInsertUploadedAssetFromFile = { [weak self] in
            self?.uploadAssetsToJournalFromFilePicker()
        }
        desktopPet.onJournalInsertUploadedAssetFromClipboard = { [weak self] in
            self?.uploadClipboardImageToJournal()
        }
        clipboardTranslation.onAIActionStarted = { [weak self] in
            self?.desktopPet.setAIActionActive(true)
        }
        clipboardTranslation.onAIActionCompleted = { [weak self] in
            self?.desktopPet.handleAIActionCompleted()
        }
        clipboardTranslation.onAIActionFinished = { [weak self] in
            self?.desktopPet.setAIActionActive(false)
        }
        clipboardTranslation.onAIResultWorkflowRequested = { [weak self] request in
            self?.handleAIResultWorkflowRequest(request) ?? .cancelled("小花儿暂时不可用")
        }
        clipboardTranslation.onAssetUploadRequested = { [weak self] in
            self?.uploadFilesFromAIQuickActions()
        }
        clipboardTranslation.onChatRequested = { [weak self] text, _, _ in
            DispatchQueue.main.async {
                self?.petChat.showAndSend(text: text, relativeTo: nil, title: "Companion")
            }
        }
        desktopPet.workflowApprovalStore = workflowApprovalStore
        configureReminderFocusJournalRoutine()
        desktopPet.onMenuBarTitleChanged = { [weak self] title in
            self?.setMenuBarCountdownTitle(title)
        }
        desktopPet.start()
        if ClipboardTranslationFeature.savedClipboardEnabled {
            clipboardTranslation.start()
        }
        if ClipboardTranslationFeature.savedSelectionEnabled {
            clipboardTranslation.startSelectionPopup(requestPermission: false)
        }
        configureApplicationMenu()
        configureStatusItem()
        configureMenu()
        refreshStatus()
        externalToolCallCoordinator.start()
    }

    private func repairLegacyICloudDataSplitIfNeeded() {
        do {
            if try dataPackageController.repairLegacyICloudDataSplitIfNeeded() {
                NSLog("Companion repaired missing files from legacy iCloud .companion data root")
            }
        } catch {
            NSLog("Companion legacy iCloud data repair failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        assetUploadWorkflowCoordinator.cancelActiveRunsForTermination()
        externalToolCallCoordinator.stop()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: CompanionL10n.text("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: CompanionL10n.text("Quit Companion"), action: #selector(quitAction), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: CompanionL10n.text("Edit"))
        editMenu.addItem(NSMenuItem(title: CompanionL10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: CompanionL10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: CompanionL10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: CompanionL10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = CompanionL10n.text("Companion")
        }
        statusItem.menu = menu
        setMenuBarCountdownTitle(menuBarCountdownTitle)
    }

    private func setMenuBarCountdownTitle(_ title: String?) {
        menuBarCountdownTitle = title
        if let button = statusItem.button {
            if let title, !title.isEmpty {
                statusItem.length = NSStatusItem.variableLength
                button.image = nil
                button.title = title
            } else {
                statusItem.length = Self.menuBarIconItemLength
                button.title = ""
                button.image = Self.makeMenuBarIcon()
                button.imageScaling = .scaleProportionallyDown
            }
        }
    }

    static func versionTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let version, !version.isEmpty else {
            return "Companion"
        }

        if let build, !build.isEmpty {
            return "Companion \(version) (\(build))"
        }

        return "Companion \(version)"
    }

    static func statusTitle(_ key: String, _ arguments: CVarArg...) -> String {
        let message = String(format: CompanionL10n.text(key), arguments: arguments)
        return CompanionL10n.format("Status: %@", message)
    }

    @objc private func uploadFilesWithCompanion(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        assetUploadWorkflowCoordinator.uploadFilesWithCompanion(pasteboard, userData: userData, error: error)
    }

    private func uploadAssetsToJournalFromFilePicker() {
        assetUploadWorkflowCoordinator.uploadAssetsToJournalFromFilePicker()
    }

    private func uploadClipboardImageToJournal() {
        assetUploadWorkflowCoordinator.uploadClipboardImageToJournal()
    }

    func uploadClipboardImageToClipboard() {
        assetUploadWorkflowCoordinator.uploadClipboardImageToClipboard()
    }

    private func uploadFilesFromAIQuickActions() {
        assetUploadWorkflowCoordinator.uploadFilesFromAIQuickActions()
    }

    private static func makeMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "CompanionMenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = menuBarIconSize
            image.isTemplate = true
            image.accessibilityDescription = "Companion"
            return image
        }

        let image = NSImage(size: menuBarIconSize)
        image.lockFocus()

        NSColor.white.setStroke()
        let fallbackX = (menuBarIconSize.width - 19) / 2
        let fallbackY = (menuBarIconSize.height - 19) / 2
        let ring = NSBezierPath(ovalIn: NSRect(x: fallbackX + 1.0, y: fallbackY + 1.0, width: 17.0, height: 17.0))
        ring.lineWidth = 1.6
        ring.stroke()

        NSColor.white.setFill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: fallbackX + 9.9, y: fallbackY + 15.0))
        bolt.line(to: NSPoint(x: fallbackX + 6.8, y: fallbackY + 9.0))
        bolt.line(to: NSPoint(x: fallbackX + 9.2, y: fallbackY + 9.0))
        bolt.line(to: NSPoint(x: fallbackX + 8.0, y: fallbackY + 4.0))
        bolt.line(to: NSPoint(x: fallbackX + 12.7, y: fallbackY + 10.1))
        bolt.line(to: NSPoint(x: fallbackX + 10.2, y: fallbackY + 10.1))
        bolt.line(to: NSPoint(x: fallbackX + 11.1, y: fallbackY + 15.0))
        bolt.close()
        bolt.fill()

        image.unlockFocus()
        image.isTemplate = false
        image.size = menuBarIconSize
        image.accessibilityDescription = "Companion"
        return image
    }

}
