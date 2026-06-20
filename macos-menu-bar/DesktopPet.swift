import ApplicationServices
import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

private enum PetWorkflowState: String, CaseIterable, Equatable {
    case idle
    case thinking
    case focusing
    case reminding
    case resting
    case translationDone
    case happy
    case sleepy

    var title: String {
        switch self {
        case .idle:
            return "待命中"
        case .thinking:
            return "思考中"
        case .focusing:
            return "专注中"
        case .reminding:
            return "提醒中"
        case .resting:
            return "休息中"
        case .translationDone:
            return "翻译完成"
        case .happy:
            return "开心"
        case .sleepy:
            return "困倦"
        }
    }

    var animationCandidates: [String] {
        switch self {
        case .idle:
            return ["idle"]
        case .thinking:
            return ["review", "waiting", "idle"]
        case .focusing:
            return ["running", "review", "idle"]
        case .reminding:
            return ["waving", "jumping", "waiting", "idle"]
        case .resting:
            return ["waiting", "idle"]
        case .translationDone:
            return ["waving", "jumping", "idle"]
        case .happy:
            return ["jumping", "waving", "idle"]
        case .sleepy:
            return ["waiting", "idle"]
        }
    }
}

final class DesktopPetFeature: NSObject {
    struct StatusSnapshot {
        var isVisible: Bool
        var autoEdgeEnabled: Bool
        var voiceEnabled: Bool
        var voiceVolume: Double
        var workflowStatusTitle: String
    }

    let menuItem = NSMenuItem(title: CompanionL10n.text("AI Companion"), action: nil, keyEquivalent: "")
    var onChatRequested: ((NSWindow?, String) -> Void)?
    var onTranslationRequested: ((NSWindow?) -> Void)?
    var additionalMenuItemsProvider: (() -> [NSMenuItem])?
    var focusReviewSummaryProvider: CompanionFocusReviewWindowController.SummaryProvider?
    var onJournalInsertUploadedAssetFromFile: (() -> Void)? {
        didSet {
            journalFeature.onInsertUploadedAssetFromFile = onJournalInsertUploadedAssetFromFile
        }
    }
    var onJournalInsertUploadedAssetFromClipboard: (() -> Void)? {
        didSet {
            journalFeature.onInsertUploadedAssetFromClipboard = onJournalInsertUploadedAssetFromClipboard
        }
    }

    private let skinStore = PetSkinStore()
    private let reminderFeature = DesktopPetReminderFeature()
    private let pomodoroFeature = DesktopPetPomodoroFeature()
    private let journalFeature = DesktopPetJournalFeature()
    private let musicFeature = DesktopPetMusicFeature()
    private let musicMiniPlayerController = DesktopPetMusicMiniPlayerController()
    private let behaviorSettings = DesktopPetBehaviorSettingsStore()
    private lazy var voiceFeature = DesktopPetVoiceFeature(settingsStore: behaviorSettings)
    private let quickMenuController = PetQuickMenuController()
    private lazy var focusReviewWindow = CompanionFocusReviewWindowController(
        snapshotProvider: { [weak self] in
            self?.makeFocusReviewSnapshot() ?? CompanionFocusReviewSnapshot.make(
                focusRecords: [],
                reminders: [],
                journal: .empty
            )
        },
        summaryProvider: { [weak self] snapshot in
            guard let provider = self?.focusReviewSummaryProvider else {
                throw CompanionAIProviderError.unavailable
            }
            return try await provider(snapshot)
        },
        journalAppender: { [weak self] section, lines in
            self?.journalFeature.appendToToday(section: section, lines: lines)
        }
    )
    private lazy var skinPanelController = PetSkinPanelController(
        skinStore: skinStore,
        selectedSkinIDProvider: { [weak self] in
            self?.petController.selectedSkinID
        },
        selectSkinAction: { [weak self] skinID in
            self?.selectPetSkinFromPanel(id: skinID)
        },
        reloadAction: { [weak self] in
            self?.reloadPetSkinsFromPanel()
        },
        openUserSkinFolderAction: { [weak self] in
            guard let self else {
                throw NSError(
                    domain: "CompanionPetSkinPanel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Companion is unavailable."]
                )
            }
            return try self.skinStore.createUserSkinDirectoryIfNeeded()
        }
    )
    private lazy var petController = PetController(skinStore: skinStore)
    private let petMenu = NSMenu(title: CompanionL10n.text("AI Companion"))
    private var petWindow: NSPanel?
    private var focusQuietModeActive = false
    private var activePomodoroMode: PetPomodoroMode = .focus
    private var activePomodoroState: PetPomodoroRunState = .idle
    private var aiActionActive = false
    private var restPromptWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        menuItem.submenu = petMenu
        petMenu.delegate = self

        skinStore.reload()
        petController.onLayoutChanged = { [weak self] in
            self?.resizePetWindow()
        }
        petController.onError = { [weak self] message in
            self?.showAlert(message: "小花儿", informativeText: message)
        }
        petController.onChatRequested = { [weak self] anchorWindow in
            self?.onChatRequested?(anchorWindow, self?.petController.displayName ?? PetSkinStore.xiaoHuaErSkinID)
        }
        petController.onQuickMenuRequested = { [weak self] anchorWindow in
            self?.showQuickMenu(anchorWindow: anchorWindow)
        }
        petController.reminderContextMenuProvider = { [weak self] in
            self?.reminderFeature.makeMenuItems() ?? []
        }
        petController.pomodoroContextMenuProvider = { [weak self] in
            self?.pomodoroFeature.makeMenuItems() ?? []
        }
        reminderFeature.onMenuNeedsUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        reminderFeature.onRemindersDue = { [weak self] delivery in
            self?.handleReminderDue(delivery)
            self?.onRemindersDueForRoutine?(delivery.reminders.map { $0.id })
        }
        reminderFeature.onStartFocusRequested = { [weak self] title in
            self?.pomodoroFeature.startFocus(taskTitle: title)
        }
        pomodoroFeature.onMenuNeedsUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        pomodoroFeature.onPomodoroStateChanged = { [weak self] mode, state in
            self?.handlePomodoroStateChanged(mode: mode, state: state)
        }
        pomodoroFeature.onFocusActiveChanged = { [weak self] active in
            self?.petController.suppressEdgeBehaviorForFocus = active
            self?.petController.setQuietFocusMode(active)
            self?.focusQuietModeActive = active
            self?.scheduleOrCancelRestPrompt(focusActive: active)
            self?.rebuildMenu()
        }
        pomodoroFeature.onFocusStarted = { [weak self] in
            self?.playWorkflowVoice(.focusStart, duringFocusAllowed: true)
        }
        pomodoroFeature.onFocusEnded = { [weak self] in
            self?.petController.showWorkflowMoment(.happy, duration: 4)
            self?.playWorkflowVoice(.focusEnd, duringFocusAllowed: true)
        }
        pomodoroFeature.onBreakStarted = { [weak self] in
            self?.playWorkflowVoice(.breakStart)
        }
        pomodoroFeature.onFocusRecordCompleted = { [weak self] record in
            self?.onPomodoroEndedForRoutine?(record.id, record.taskTitle)
        }
        pomodoroFeature.onFocusRecordSaveRequested = { [weak self] record in
            self?.journalFeature.appendFocusRecord(record, showWindow: true)
        }
        journalFeature.onConvertToReminder = { [weak self] draft in
            self?.reminderFeature.addReminder(from: draft)
        }
        pomodoroFeature.onMenuBarCountdownChanged = { [weak self] title in
            self?.onMenuBarTitleChanged?(title)
        }
        behaviorSettings.onChange = { [weak self] in
            guard let self else { return }
            self.petController.presenceIntensity = self.behaviorSettings.presenceIntensity
            self.rebuildMenu()
        }
        petController.presenceIntensity = behaviorSettings.presenceIntensity
        voiceFeature.onMenuNeedsUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        musicFeature.onPlaybackFailed = { [weak self] track, message in
            self?.petController.showWorkflowMoment(.sleepy, duration: 4)
            let title = track.map { "曲目 \($0.id)" } ?? "当前曲目"
            CompanionNonBlockingAlert.present(
                messageText: "小花儿音乐播放失败",
                informativeText: "\(title)：\(message)",
                tone: .warning
            )
        }
        musicFeature.onPlaybackStarted = { [weak self] _ in
            self?.petController.showWorkflowMoment(.happy, duration: 4)
        }
        petController.loadInitialSkin()
        petController.startAnimation()

        createPetWindow()
        voiceFeature.playLaunchWelcomeIfNeeded(isPetVisible: isXiaoHuaErVisible)
        reminderFeature.start { [weak self] in
            self?.petWindow
        }
        pomodoroFeature.start { [weak self] in
            self?.petWindow
        }
        bindMenuUpdates()
        rebuildMenu()
    }

    func rebuildMenu() {
        menuItem.title = CompanionL10n.text("AI Companion")
        petMenu.title = CompanionL10n.text("AI Companion")
        petMenu.removeAllItems()

        for item in reminderFeature.makeMenuItems() {
            petMenu.addItem(item)
        }
        petMenu.addItem(.separator())

        for item in pomodoroFeature.makeMenuItems() {
            petMenu.addItem(item)
        }
        petMenu.addItem(.separator())

        for item in journalFeature.makeMenuItems() {
            petMenu.addItem(item)
        }
        petMenu.addItem(menuItem(title: "专注复盘", action: #selector(showFocusReviewAction)))
        petMenu.addItem(menuItem(title: "提醒 → 专注 → 日记", action: #selector(startReminderFocusJournalRoutineAction)))
        petMenu.addItem(.separator())

        for item in behaviorSettings.makeMenuItems() {
            petMenu.addItem(item)
        }
        petMenu.addItem(.separator())

        for item in voiceFeature.makeMenuItems() {
            petMenu.addItem(item)
        }
        petMenu.addItem(.separator())

        petMenu.addItem(menuItem(title: "皮肤...", action: #selector(showPetSkinPanelAction)))
        petMenu.addItem(.separator())

        let visibilityTitle = petController.isVisible ? "隐藏\(petController.displayName)" : "显示\(petController.displayName)"
        petMenu.addItem(menuItem(title: visibilityTitle, action: #selector(togglePetVisibility), keyEquivalent: "h"))
        let autoEdgeState = petController.isAutoEdgeBehaviorEnabled ? "开" : "关"
        let autoEdgeItem = menuItem(title: "自动靠边爬墙：\(autoEdgeState)", action: #selector(toggleAutoEdgeBehavior))
        autoEdgeItem.state = petController.isAutoEdgeBehaviorEnabled ? .on : .off
        petMenu.addItem(autoEdgeItem)
        let statusItem = NSMenuItem(title: "\(petController.displayName)状态：\(petController.workflowStatusTitle)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        petMenu.addItem(statusItem)
        if behaviorSettings.isQuietTime() {
            let quietItem = NSMenuItem(title: "勿扰时段中", action: nil, keyEquivalent: "")
            quietItem.isEnabled = false
            petMenu.addItem(quietItem)
        }
        if focusQuietModeActive {
            let quietItem = NSMenuItem(title: "专注安静模式中", action: nil, keyEquivalent: "")
            quietItem.isEnabled = false
            petMenu.addItem(quietItem)
        }
    }

    func appendMenuItems(to menu: NSMenu) {
        menu.addItem(submenuItem(title: "提醒事项", items: reminderMenuItems()))
        menu.addItem(submenuItem(title: "番茄闹钟", items: pomodoroFeature.makeMainMenuItems()))
        menu.addItem(submenuItem(title: "日记", items: journalFeature.makeMainMenuItems()))
        menu.addItem(submenuItem(title: "专注", items: [
            menuItem(title: "专注复盘", action: #selector(showFocusReviewAction)),
            menuItem(title: "提醒 → 专注 → 日记", action: #selector(startReminderFocusJournalRoutineAction))
        ]))
        menu.addItem(menuItem(title: "宠物皮肤...", action: #selector(showPetSkinPanelAction)))

        if let additionalItems = additionalMenuItemsProvider?(), !additionalItems.isEmpty {
            for item in additionalItems {
                menu.addItem(item)
            }
        }
    }

    private func reminderMenuItems() -> [NSMenuItem] {
        let sourceItems = reminderFeature.makeMenuItems()
        guard sourceItems.count >= 2 else {
            return sourceItems
        }

        sourceItems[1].title = "查看记录"
        return Array(sourceItems.prefix(2))
    }

    private func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for child in items {
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    var onMenuBarTitleChanged: ((String?) -> Void)?

    func statusSnapshot() -> StatusSnapshot {
        StatusSnapshot(
            isVisible: petController.isVisible,
            autoEdgeEnabled: petController.isAutoEdgeBehaviorEnabled,
            voiceEnabled: voiceFeature.isEnabled,
            voiceVolume: voiceFeature.volume,
            workflowStatusTitle: petController.workflowStatusTitle
        )
    }

    func toggleVisibilityFromSettings() {
        togglePetVisibility()
    }

    func toggleAutoEdgeBehaviorFromSettings() {
        toggleAutoEdgeBehavior()
    }

    func showReminderCenterFromWorkflowRun() {
        reminderFeature.showReminderCenter()
    }

    func showJournalFromWorkflowRun() {
        journalFeature.showJournalWindow()
    }

    func showPomodoroFromWorkflowRun() {
        pomodoroFeature.showPomodoroCenter()
    }

    func saveAIActionToJournal(_ entry: PetJournalAIActionEntry) {
        journalFeature.appendAIAction(entry, showWindow: true)
    }

    func handleAIResultWorkflow(_ request: XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome {
        switch request.action {
        case .saveToJournal:
            guard confirmWorkflowActionIfNeeded(
                toolID: "companion.journal.appendToday",
                risk: .localWrite,
                messageText: "存到日记？",
                informativeText: "Companion 会把这条 \(request.resultTitle) 追加到今日记录。"
            ) else {
                petController.showWorkflowMoment(.resting, duration: 3)
                return .cancelled("已取消存日记")
            }

            saveAIActionToJournal(PetJournalAIActionEntry(
                actionTitle: request.actionTitle,
                resultTitle: request.resultTitle,
                providerName: request.providerName,
                sourceText: request.sourceText,
                resultText: request.resultText,
                createdAt: request.createdAt
            ))
            petController.showWorkflowMoment(.translationDone, duration: 4)
            playWorkflowVoice(.translationDone, duringFocusAllowed: true)
            CompanionNonBlockingAlert.present(
                messageText: "已存到日记",
                informativeText: "这条 \(request.resultTitle) 已追加到今日记录。",
                tone: .success
            )
            return .accepted(request.action.statusTitle)
        case .createReminder:
            let title = request.reminderTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? request.reminderTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
                : Self.workflowTaskTitle(from: request.resultText, fallback: request.resultTitle, maxLength: 60)

            // 快捷补问已经给出明确时间：直接创建真实提醒。
            if let reminderTime = request.reminderTime {
                if reminderFeature.createTimedReminder(title: title, fireDate: reminderTime) != nil {
                    petController.showWorkflowMoment(.reminding, duration: 5)
                    playWorkflowVoice(.reminderDue, duringFocusAllowed: true)
                    CompanionNonBlockingAlert.present(
                        messageText: "已创建提醒",
                        informativeText: "提醒「\(title)」将在 \(DateFormatter.localizedString(from: reminderTime, dateStyle: .short, timeStyle: .short)) 提醒你。",
                        tone: .success
                    )
                    return .accepted(request.action.statusTitle)
                }
                petController.showWorkflowMoment(.resting, duration: 3)
                CompanionNonBlockingAlert.present(
                    messageText: "创建提醒失败",
                    informativeText: "无法创建提醒，请稍后重试。",
                    tone: .warning
                )
                return .cancelled("创建失败")
            } else if let parsed = PetReminderRuleParser.parse(title, now: Date(), calendar: .current) {
                // 有时间：真正创建提醒
                if reminderFeature.createTimedReminder(title: parsed.title, fireDate: parsed.fireDate) != nil {
                    petController.showWorkflowMoment(.reminding, duration: 5)
                    playWorkflowVoice(.reminderDue, duringFocusAllowed: true)
                    CompanionNonBlockingAlert.present(
                        messageText: "已创建提醒",
                        informativeText: "提醒「\(parsed.title)」将在 \(DateFormatter.localizedString(from: parsed.fireDate, dateStyle: .short, timeStyle: .short)) 提醒你。",
                        tone: .success
                    )
                    return .accepted(request.action.statusTitle)
                } else {
                    petController.showWorkflowMoment(.resting, duration: 3)
                    CompanionNonBlockingAlert.present(
                        messageText: "创建提醒失败",
                        informativeText: "无法创建提醒，请稍后重试。",
                        tone: .warning
                    )
                    return .cancelled("创建失败")
                }
            } else {
                // 无时间：打开草稿
                let acceptedReminderDraft = reminderFeature.showQuickAddReminder(prefillTitle: title)
                guard acceptedReminderDraft else {
                    petController.showWorkflowMoment(.resting, duration: 3)
                    return .cancelled("已有提醒草稿")
                }
                petController.showWorkflowMoment(.reminding, duration: 5)
                CompanionNonBlockingAlert.present(
                    messageText: "准备创建提醒",
                    informativeText: "已把 AI 结果整理成提醒草稿，请补充时间后保存。",
                    tone: .info
                )
                return .accepted(request.action.statusTitle)
            }
        case .startFocus:
            let title = Self.workflowTaskTitle(from: request.resultText, fallback: request.resultTitle, maxLength: 40)
            guard !pomodoroFeature.hasActiveSession else {
                pomodoroFeature.showPomodoroCenter()
                petController.showWorkflowMoment(.reminding, duration: 5)
                CompanionNonBlockingAlert.present(
                    messageText: "已有番茄钟正在运行",
                    informativeText: "Companion 已打开番茄闹钟给你查看，不会静默替换当前计时。",
                    tone: .warning
                )
                return .cancelled("已有专注正在运行")
            }

            guard confirmWorkflowActionIfNeeded(
                toolID: "companion.pomodoro.startFocus",
                risk: .localSession,
                messageText: "开始专注？",
                informativeText: "Companion 会用「\(title)」作为任务名开始当前设置的番茄钟。"
            ) else {
                petController.showWorkflowMoment(.resting, duration: 3)
                return .cancelled("已取消开始专注")
            }

            pomodoroFeature.startFocus(taskTitle: title)
            petController.showWorkflowMoment(.focusing, duration: 5)
            CompanionNonBlockingAlert.present(
                messageText: "已开始专注",
                informativeText: "任务：\(title)",
                tone: .success
            )
            return .accepted(request.action.statusTitle)
        }
    }

    // MARK: - 多选 workflow step helpers
    // 供 CompanionAIResultDispatcher 编排多选组合时调用；在 DesktopPetFeature 内部封装对
    // private 子 feature（reminderFeature / pomodoroFeature）的访问，避免外部直接触碰私有状态。

    func workflowAppendToJournal(_ context: AIResultWorkflowContext) {
        saveAIActionToJournal(PetJournalAIActionEntry(
            actionTitle: context.actionTitle,
            resultTitle: context.resultTitle,
            providerName: context.providerName,
            sourceText: context.sourceText,
            resultText: context.resultText,
            createdAt: context.createdAt
        ))
    }

    func workflowCreateReminderDraft(title: String) -> Bool {
        reminderFeature.showQuickAddReminder(prefillTitle: title)
    }

    var workflowHasActiveFocus: Bool {
        pomodoroFeature.hasActiveSession
    }

    func workflowShowPomodoroCenter() {
        pomodoroFeature.showPomodoroCenter()
    }

    func workflowStartFocus(title: String) {
        pomodoroFeature.startFocus(taskTitle: title)
    }

    func workflowCreateTimedReminder(title: String, fireDate: Date) -> UUID? {
        reminderFeature.createTimedReminder(title: title, fireDate: fireDate)
    }

    func workflowAppendJournalSection(_ section: String, lines: [String]) {
        journalFeature.appendToToday(section: section, lines: lines)
    }

    func startExternalFocus(taskTitle: String, durationMinutes: Int?) -> CompanionWorkflowToolResult {
        let title = Self.workflowTaskTitle(from: taskTitle, fallback: "Companion MCP", maxLength: 40)
        let minutes = durationMinutes.map { min(max($0, 1), 180) } ?? pomodoroFeature.focusMinutes
        guard !pomodoroFeature.hasActiveSession else {
            pomodoroFeature.showPomodoroCenter()
            petController.showWorkflowMoment(.reminding, duration: 5)
            return .blocked(
                code: "pomodoro_active",
                message: "A Pomodoro session is already active.",
                output: [
                    "taskTitle": .string(title),
                    "durationMinutes": .number(Double(minutes)),
                    "started": .bool(false),
                    "blockedReason": .string("pomodoro_active"),
                    "dryRun": .bool(false)
                ]
            )
        }

        pomodoroFeature.startFocus(taskTitle: title, durationMinutes: minutes)
        petController.showWorkflowMoment(.focusing, duration: 5)
        playWorkflowVoice(.focusStart, duringFocusAllowed: true)
        return .succeeded(
            output: [
                "taskTitle": .string(title),
                "durationMinutes": .number(Double(minutes)),
                "started": .bool(true),
                "blockedReason": .null,
                "dryRun": .bool(false)
            ],
            outputSummary: "Started focus session for \"\(title)\"."
        )
    }

    func showExternalToolApprovalRequested(duration: TimeInterval) {
        petController.showWorkflowMoment(.reminding, duration: duration)
    }

    func showExternalToolCallRunning() {
        petController.showWorkflowMoment(.thinking, duration: 4)
    }

    func showExternalToolCallResult(_ result: CompanionWorkflowToolResult, toolID: String) {
        switch result.status {
        case .succeeded:
            if toolID != "companion.pomodoro.startFocus" {
                petController.showWorkflowMoment(.happy, duration: 4)
            }
        case .failed:
            petController.showWorkflowMoment(.sleepy, duration: 4)
        case .needsInput, .blocked:
            petController.showWorkflowMoment(.reminding, duration: 4)
        case .denied:
            petController.showWorkflowMoment(.resting, duration: 3)
        }
    }

    func refreshExternalReminderWrite(showWindow: Bool) {
        reminderFeature.reloadFromDataRoot(showWindow: showWindow)
    }

    func refreshExternalJournalWrite(showWindow: Bool) {
        journalFeature.reloadFromDataRoot(showWindow: showWindow)
    }

    func showFocusReviewWindow() {
        focusReviewWindow.show()
    }

    func setAIActionActive(_ active: Bool) {
        guard aiActionActive != active else { return }
        aiActionActive = active
        syncWorkflowState()
    }

    func handleAIActionCompleted() {
        let wasActive = aiActionActive
        aiActionActive = false
        syncWorkflowState()
        guard wasActive else { return }
        petController.showWorkflowMoment(.translationDone, duration: 4)
        playWorkflowVoice(.translationDone, duringFocusAllowed: true)
    }

    func playVoice(_ event: PetVoiceEvent) {
        voiceFeature.play(event)
    }

    private func createPetWindow() {
        let size = petController.displaySize
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(
            x: visibleFrame.maxX - size.width - 80,
            y: visibleFrame.minY + 80
        )

        let panel = PetPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.petController = petController
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.level = .floating
        panel.title = "小花儿"

        let contentView = PetContainerView(controller: petController)
        contentView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = contentView

        petWindow = panel
        petController.window = panel

        if petController.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func resizePetWindow() {
        guard let petWindow else { return }

        let currentFrame = petWindow.frame
        let newSize = petController.displaySize
        let newOrigin = CGPoint(
            x: currentFrame.origin.x,
            y: currentFrame.maxY - newSize.height
        )

        petWindow.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
    }

    private func bindMenuUpdates() {
        skinStore.$skins
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        petController.$selectedSkinID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.skinPanelController.updateSelectedSkinID(self?.petController.selectedSkinID)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private var isXiaoHuaErVisible: Bool {
        petController.isVisible && petController.displayName == "小花儿"
    }

    @objc private func togglePetVisibility() {
        petController.toggleVisibility()
        voiceFeature.playLaunchWelcomeIfNeeded(isPetVisible: isXiaoHuaErVisible)
        rebuildMenu()
    }

    @objc private func toggleAutoEdgeBehavior() {
        petController.toggleAutoEdgeBehavior()
        rebuildMenu()
    }

    @objc private func showFocusReviewAction() {
        showFocusReviewWindow()
    }

    @objc private func showPetSkinPanelAction() {
        skinPanelController.show()
    }

    @objc private func startReminderFocusJournalRoutineAction() {
        onStartReminderFocusJournalRoutine?()
    }

    private func selectPetSkinFromPanel(id: String) {
        petController.selectSkin(id: id)
        skinPanelController.updateSelectedSkinID(petController.selectedSkinID)
        rebuildMenu()
    }

    private func reloadPetSkinsFromPanel() {
        skinStore.reload()
        petController.reloadSelectedSkin()
        skinPanelController.updateSelectedSkinID(petController.selectedSkinID)
        rebuildMenu()
    }

    private func showAlert(message: String, informativeText: String) {
        CompanionNonBlockingAlert.present(messageText: message, informativeText: informativeText)
    }

    /// 本地 Hero 授权偏好（workflow-approval-prefs.json），由 Companion 注入共享实例。
    /// nil 时退回每次确认（绝不静默放行）。
    var workflowApprovalStore: WorkflowApprovalPreferencesStore?

    /// 旗舰 routine 事件 passthrough（由 Companion 接到 CompanionReminderFocusJournalRoutine）。
    var onRemindersDueForRoutine: (([UUID]) -> Void)?
    var onPomodoroEndedForRoutine: ((UUID, String) -> Void)?
    var onStartReminderFocusJournalRoutine: (() -> Void)?

    private func confirmWorkflowActionIfNeeded(
        toolID: String,
        risk: CompanionWorkflowToolRisk,
        messageText: String,
        informativeText: String
    ) -> Bool {
        if let store = workflowApprovalStore, store.isApproved(toolID: toolID, risk: risk) {
            return true
        }

        let choice = CompanionNonBlockingAlert.choose(
            messageText: messageText,
            informativeText: "\(informativeText)\n\n你可以只执行这一次，也可以让小花儿以后直接执行这类动作。",
            primaryButtonTitle: "执行一次",
            secondaryButtonTitle: "以后直接执行",
            tone: .info
        )

        if choice == .secondary {
            // 仅 localWrite/localSession 可记住；store 内部已对高风险动作拒绝记住。
            workflowApprovalStore?.approve(toolID: toolID, risk: risk)
        }
        return choice == .primary || choice == .secondary
    }

    private static func workflowTaskTitle(from text: String, fallback: String, maxLength: Int) -> String {
        let candidates = text
            .components(separatedBy: .newlines)
            .map(Self.strippingWorkflowListPrefix)
            .filter { !$0.isEmpty }

        let rawTitle = candidates.first ?? fallback
        let collapsed = rawTitle
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed.isEmpty ? fallback : collapsed
        }

        let index = collapsed.index(collapsed.startIndex, offsetBy: max(1, maxLength - 1))
        return String(collapsed[..<index]) + "…"
    }

    private static func strippingWorkflowListPrefix(from line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^\s*(?:[-*•]\s+|\d+[.)、）]\s+)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showQuickMenu(anchorWindow: NSWindow?) {
        petController.setQuickMenuOpen(true)
        quickMenuController.show(anchorWindow: anchorWindow, anchorPoint: petController.spriteCenterInScreen, onClose: { [weak self] in
            self?.petController.setQuickMenuOpen(false)
        }) { [weak self] action in
            self?.handleQuickAction(action)
        }
    }

    private func handleQuickAction(_ action: PetQuickAction) {
        switch action {
        case .chat:
            petController.requestChat()
        case .translation:
            onTranslationRequested?(petWindow)
        case .reminders:
            reminderFeature.showReminderCenter()
        case .pomodoro:
            pomodoroFeature.showPomodoroCenter()
        case .journal:
            journalFeature.showJournalWindow()
        case .mood:
            showPetMusicMiniPlayer()
        }
    }

    private func showPetMusicMiniPlayer() {
        musicMiniPlayerController.show(anchorWindow: petWindow, musicFeature: musicFeature)
        petController.showWorkflowMoment(.happy, duration: 3)
    }

    private func cycleWorkflowMoodForFutureUse() {
        petController.advanceRoleMoodState()
        rebuildMenu()
    }

    private func handleReminderDue(_ delivery: PetReminderDelivery) {
        guard !delivery.reminders.isEmpty else { return }
        petController.showWorkflowMoment(.reminding, duration: 5)
        playWorkflowVoice(.reminderDue, duringFocusAllowed: true)
    }

    private func makeFocusReviewSnapshot(now: Date = Date(), calendar: Calendar = .current) -> CompanionFocusReviewSnapshot {
        CompanionFocusReviewSnapshot.make(
            focusRecords: pomodoroFeature.focusRecordsSnapshot(),
            reminders: reminderFeature.remindersSnapshot(),
            journal: journalFeature.focusReviewSnapshot(now: now),
            now: now,
            calendar: calendar
        )
    }

    private func handlePomodoroStateChanged(mode: PetPomodoroMode, state: PetPomodoroRunState) {
        guard activePomodoroMode != mode || activePomodoroState != state else { return }
        activePomodoroMode = mode
        activePomodoroState = state
        syncWorkflowState()
    }

    private func syncWorkflowState() {
        if activePomodoroState == .running {
            petController.setBaseWorkflowState(activePomodoroMode == .focus ? .focusing : .resting)
        } else if activePomodoroState == .paused, activePomodoroMode == .focus {
            petController.setBaseWorkflowState(.thinking)
        } else if aiActionActive {
            petController.setBaseWorkflowState(.thinking)
        } else {
            petController.setBaseWorkflowState(.idle)
        }
        rebuildMenu()
    }

    private func playWorkflowVoice(_ event: PetVoiceEvent, duringFocusAllowed: Bool = false) {
        guard duringFocusAllowed || !focusQuietModeActive else { return }
        voiceFeature.play(event)
    }

    private func scheduleOrCancelRestPrompt(focusActive: Bool) {
        restPromptWorkItem?.cancel()
        restPromptWorkItem = nil
        guard focusActive, behaviorSettings.restPromptEnabled else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activePomodoroMode == .focus,
                  self.activePomodoroState == .running,
                  self.behaviorSettings.restPromptEnabled,
                  !self.behaviorSettings.isQuietTime()
            else {
                return
            }
            self.petController.showWorkflowMoment(.resting, duration: 5)
            CompanionNonBlockingAlert.present(
                messageText: "小花儿提醒你休息一下",
                informativeText: "你已经连续专注了一段时间。站起来活动一下，回来再继续。",
                tone: .info
            )
        }
        restPromptWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 90 * 60, execute: workItem)
    }

}

extension DesktopPetFeature: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === petMenu else { return }
        rebuildMenu()
    }
}

private final class PetController: ObservableObject {
    @Published private(set) var loadedSkin: LoadedSkin?
    @Published private(set) var selectedSkinID: String?
    @Published private(set) var animationStateID = "idle"
    @Published private(set) var frameIndex = 0
    @Published private(set) var isVisible: Bool
    @Published var displayScale: Double {
        didSet {
            displayScale = min(max(displayScale, 0.5), 1.8)
            UserDefaults.standard.set(displayScale, forKey: Self.displayScaleDefaultsKey)
            onLayoutChanged?()
        }
    }

    weak var window: NSWindow?
    var onLayoutChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var onChatRequested: ((NSWindow?) -> Void)?
    var onQuickMenuRequested: ((NSWindow?) -> Void)?
    var reminderContextMenuProvider: (() -> [NSMenuItem])?
    var pomodoroContextMenuProvider: (() -> [NSMenuItem])?

    private static let selectedSkinDefaultsKey = "CompanionDesktopPetSelectedSkinID"
    private static let displayScaleDefaultsKey = "CompanionDesktopPetDisplayScale"
    private static let isVisibleDefaultsKey = "CompanionDesktopPetIsVisible"
    private static let autoEdgeBehaviorDefaultsKey = "CompanionDesktopPetAutoEdgeBehaviorEnabled"
    private static let roleMoodStates: [PetWorkflowState] = [.idle, .happy, .thinking, .sleepy]
    private static let edgeTopRestDuration: TimeInterval = 10
    private static let edgeSeekSpeed: CGFloat = 140
    private static let edgeClimbSpeed: CGFloat = 34
    private static let edgeBarWalkSpeed: CGFloat = 130
    private static let edgeReturnSpeed: CGFloat = 170
    private static let edgeSnapTolerance: CGFloat = 2
    private static let immersiveWindowWidthRatio: CGFloat = 0.88
    private static let immersiveWindowHeightRatio: CGFloat = 0.82
    private static let immersiveWindowAreaRatio: CGFloat = 0.78
    private static let immersiveWindowCheckInterval: TimeInterval = 1.0
    private let skinStore: PetSkinStore
    private var timer: Timer?
    private var currentTimerInterval: TimeInterval?
    private var lastFrameDate = Date()
    private var lastUserInteractionDate = Date()
    private var lastEdgeBehaviorUpdateDate = Date()
    private var lastImmersiveWindowCheckDate = Date.distantPast
    private var cachedForegroundHasImmersiveWindow = false
    private var dragStartMouseLocation: CGPoint?
    private var dragDirectionReferenceLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var isDraggingPet = false
    private var isQuickMenuOpen = false
    private var autoEdgeBehaviorEnabled: Bool
    // 由外部（番茄钟专注）置位：为 true 时暂停"开始新的"自动靠边爬墙，专注/演示时不打扰。
    var suppressEdgeBehaviorForFocus = false
    var presenceIntensity: DesktopPetPresenceIntensity = .standard {
        didSet {
            if oldValue != presenceIntensity {
                cancelEdgeBehavior(restoreAnimation: true)
            }
        }
    }
    private(set) var workflowState: PetWorkflowState = .idle
    private var baseWorkflowState: PetWorkflowState = .idle
    private var roleMoodState: PetWorkflowState = .idle
    private var transientWorkflowState: PetWorkflowState?
    private var transientWorkflowWorkItem: DispatchWorkItem?
    private var edgeBehaviorMode: EdgeBehaviorMode = .normal
    private var edgeReturnOrigin: CGPoint?
    private var edgeTopRestStartDate: Date?
    private let dragThreshold: CGFloat = 5

    private enum EdgeBehaviorMode: Equatable {
        case normal
        case seeking(PetEdgeSide)
        case climbing(PetEdgeSide)
        case barWalking(PetEdgeSide)
        case resting(PetEdgeSide)
        case returning(CGPoint)
    }

    private enum PetEdgeSide: Equatable {
        case left
        case right
    }

    init(skinStore: PetSkinStore) {
        self.skinStore = skinStore
        let savedScale = UserDefaults.standard.double(forKey: Self.displayScaleDefaultsKey)
        self.displayScale = savedScale == 0 ? 0.85 : savedScale
        self.isVisible = UserDefaults.standard.object(forKey: Self.isVisibleDefaultsKey) as? Bool ?? true
        self.autoEdgeBehaviorEnabled = UserDefaults.standard.object(forKey: Self.autoEdgeBehaviorDefaultsKey) as? Bool ?? true
    }

    deinit {
        timer?.invalidate()
    }

    var currentFrame: NSImage? {
        let frames = loadedSkin?.framesByState[animationStateID]
            ?? loadedSkin?.framesByState["idle"]
        guard let frames, !frames.isEmpty else { return nil }
        return frames[frameIndex % frames.count]
    }

    var displaySize: CGSize {
        let width = Double(loadedSkin?.manifest.cellWidth ?? 192) * displayScale
        let height = Double(loadedSkin?.manifest.cellHeight ?? 208) * displayScale
        return CGSize(width: width, height: height)
    }

    var displayName: String {
        loadedSkin?.manifest.name ?? PetSkinStore.xiaoHuaErSkinID
    }

    var isAutoEdgeBehaviorEnabled: Bool {
        autoEdgeBehaviorEnabled
    }

    var workflowStatusTitle: String {
        workflowState.title
    }

    var spriteCenterInScreen: CGPoint? {
        guard let window else { return nil }

        return CGPoint(
            x: window.frame.midX,
            y: window.frame.minY + displaySize.height * 0.62
        )
    }

    func loadInitialSkin() {
        let targetSkinID = UserDefaults.standard.string(forKey: Self.selectedSkinDefaultsKey)
            ?? PetSkinStore.xiaoHuaErSkinID
        selectSkin(id: targetSkinID)
    }

    func selectSkin(id: String) {
        guard let summary = skinStore.summary(id: id) ?? skinStore.summary(id: PetSkinStore.xiaoHuaErSkinID) else {
            onError?("Skin not found: \(id)")
            return
        }

        do {
            applyLoadedSkin(try PetSpriteLoader.load(summary), id: summary.id)
        } catch {
            loadFallbackSkin(after: error, requestedID: id, attemptedID: summary.id)
        }
    }

    func reloadSelectedSkin() {
        selectSkin(id: selectedSkinID
            ?? UserDefaults.standard.string(forKey: Self.selectedSkinDefaultsKey)
            ?? PetSkinStore.xiaoHuaErSkinID)
    }

    private func loadFallbackSkin(after error: Error, requestedID: String, attemptedID: String) {
        guard attemptedID != PetSkinStore.xiaoHuaErSkinID,
              let fallbackSummary = skinStore.summary(id: PetSkinStore.xiaoHuaErSkinID) else {
            onError?(error.localizedDescription)
            return
        }

        do {
            applyLoadedSkin(try PetSpriteLoader.load(fallbackSummary), id: fallbackSummary.id)
            onError?("Could not load skin \(requestedID). Reverted to \(fallbackSummary.manifest.name).")
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func applyLoadedSkin(_ skin: LoadedSkin, id: String) {
        loadedSkin = skin
        selectedSkinID = id
        UserDefaults.standard.set(id, forKey: Self.selectedSkinDefaultsKey)
        transientWorkflowWorkItem?.cancel()
        transientWorkflowWorkItem = nil
        transientWorkflowState = nil
        baseWorkflowState = .idle
        roleMoodState = .idle
        workflowState = .idle
        cancelEdgeBehavior(restoreAnimation: false)
        setAnimationState("idle")
        onLayoutChanged?()
    }

    func startAnimation() {
        guard isVisible else {
            stopAnimation()
            return
        }

        configureAnimationTimer(interval: desiredTimerInterval())
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        currentTimerInterval = nil
    }

    func toggleVisibility() {
        guard let window else { return }

        noteUserInteraction()
        if isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }

        isVisible.toggle()
        UserDefaults.standard.set(isVisible, forKey: Self.isVisibleDefaultsKey)
        if isVisible {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    func beginNativeDrag(at screenLocation: CGPoint) {
        guard !isQuickMenuOpen else { return }
        guard let window else { return }

        noteUserInteraction()
        dragStartMouseLocation = screenLocation
        dragDirectionReferenceLocation = screenLocation
        dragStartWindowOrigin = window.frame.origin
        isDraggingPet = false
    }

    func updateNativeDrag(to screenLocation: CGPoint) {
        guard !isQuickMenuOpen else { return }
        guard let window, let startMouse = dragStartMouseLocation, let startOrigin = dragStartWindowOrigin else {
            return
        }

        let delta = CGSize(
            width: screenLocation.x - startMouse.x,
            height: screenLocation.y - startMouse.y
        )

        if !isDraggingPet {
            guard hypot(delta.width, delta.height) >= dragThreshold else {
                return
            }
            isDraggingPet = true
            cancelEdgeBehavior(restoreAnimation: false)
            setAnimationState("running")
        }

        let newOrigin = CGPoint(
            x: startOrigin.x + delta.width,
            y: startOrigin.y + delta.height
        )
        window.setFrameOrigin(clampedOrigin(newOrigin, size: window.frame.size))

        let directionReference = dragDirectionReferenceLocation ?? startMouse
        let directionDeltaX = screenLocation.x - directionReference.x
        if abs(directionDeltaX) > 3 {
            setAnimationState(directionDeltaX >= 0 ? "running-right" : "running-left")
            dragDirectionReferenceLocation = screenLocation
        }
    }

    func endDrag() {
        noteUserInteraction()
        guard !isQuickMenuOpen else {
            dragStartMouseLocation = nil
            dragDirectionReferenceLocation = nil
            dragStartWindowOrigin = nil
            isDraggingPet = false
            return
        }

        let shouldOpenQuickMenu = dragStartMouseLocation != nil && !isDraggingPet
        dragStartMouseLocation = nil
        dragDirectionReferenceLocation = nil
        dragStartWindowOrigin = nil
        isDraggingPet = false
        restoreLockedOrIdleState()

        if shouldOpenQuickMenu {
            requestQuickMenu()
        }
    }

    func requestChat() {
        noteUserInteraction()
        onChatRequested?(window)
    }

    func requestQuickMenu() {
        noteUserInteraction()
        onQuickMenuRequested?(window)
    }

    func setQuickMenuOpen(_ isOpen: Bool) {
        noteUserInteraction()
        isQuickMenuOpen = isOpen
        if isOpen {
            dragStartMouseLocation = nil
            dragDirectionReferenceLocation = nil
            dragStartWindowOrigin = nil
            isDraggingPet = false
        }
    }

    func toggleAutoEdgeBehavior() {
        autoEdgeBehaviorEnabled.toggle()
        UserDefaults.standard.set(autoEdgeBehaviorEnabled, forKey: Self.autoEdgeBehaviorDefaultsKey)
        noteUserInteraction()
        if !autoEdgeBehaviorEnabled {
            cancelEdgeBehavior(restoreAnimation: true)
        }
    }

    @discardableResult
    func advanceRoleMoodState() -> PetWorkflowState {
        noteUserInteraction()
        cancelEdgeBehavior(restoreAnimation: false)
        let availableStates = Self.roleMoodStates.filter(hasUsableAnimation)
        let states = availableStates.isEmpty ? [.idle] : availableStates
        let currentIndex = states.firstIndex(of: roleMoodState) ?? 0
        let nextIndex = states.index(after: currentIndex)
        roleMoodState = states[nextIndex == states.endIndex ? states.startIndex : nextIndex]
        applyWorkflowState()
        return roleMoodState
    }

    func setBaseWorkflowState(_ state: PetWorkflowState) {
        guard baseWorkflowState != state else {
            applyWorkflowState()
            return
        }

        baseWorkflowState = state
        if state != .idle {
            cancelEdgeBehavior(restoreAnimation: false)
        }
        applyWorkflowState()
    }

    func showWorkflowMoment(_ state: PetWorkflowState, duration: TimeInterval) {
        noteUserInteraction()
        cancelEdgeBehavior(restoreAnimation: false)
        transientWorkflowWorkItem?.cancel()
        transientWorkflowState = state
        applyWorkflowState()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.transientWorkflowState == state else { return }
            self.transientWorkflowState = nil
            self.transientWorkflowWorkItem = nil
            self.applyWorkflowState()
        }
        transientWorkflowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.2), execute: workItem)
    }

    func setQuietFocusMode(_ active: Bool) {
        suppressEdgeBehaviorForFocus = active
        if active {
            cancelEdgeBehavior(restoreAnimation: false)
        } else {
            restoreLockedOrIdleState()
        }
    }

    func reminderContextMenuItems() -> [NSMenuItem] {
        reminderContextMenuProvider?() ?? []
    }

    func pomodoroContextMenuItems() -> [NSMenuItem] {
        pomodoroContextMenuProvider?() ?? []
    }

    private func tick() {
        let now = Date()
        updateEdgeBehavior(now: now)
        defer { rescheduleAnimationTimerIfNeeded() }

        guard let state = currentAnimationState else { return }

        let fps = max(state.fps ?? 8, 1)
        guard now.timeIntervalSince(lastFrameDate) >= 1.0 / fps else { return }

        frameIndex += 1
        lastFrameDate = now
    }

    private func configureAnimationTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentTimerInterval = interval
    }

    private func rescheduleAnimationTimerIfNeeded() {
        guard isVisible, timer != nil else { return }
        let nextInterval = desiredTimerInterval()
        guard let currentTimerInterval,
              abs(currentTimerInterval - nextInterval) > 0.002 else {
            return
        }
        configureAnimationTimer(interval: nextInterval)
    }

    private func desiredTimerInterval() -> TimeInterval {
        let fps = max(currentAnimationState?.fps ?? 8, 1)
        let animationInterval = 1.0 / Double(fps)
        let edgeInterval = edgeBehaviorNeedsHighFrequencyTicks ? (1.0 / 30.0) : .greatestFiniteMagnitude
        return min(max(min(animationInterval, edgeInterval), 1.0 / 30.0), 0.25)
    }

    private var edgeBehaviorNeedsHighFrequencyTicks: Bool {
        switch edgeBehaviorMode {
        case .seeking, .climbing, .barWalking, .returning:
            return true
        case .normal, .resting:
            return false
        }
    }

    private var currentAnimationState: PetAnimationState? {
        loadedSkin?.manifest.states.first(where: { $0.id == animationStateID })
            ?? loadedSkin?.manifest.states.first(where: { $0.id == "idle" })
    }

    private func restoreLockedOrIdleState() {
        applyWorkflowState()
    }

    private var allowsAutoEdgeBehavior: Bool {
        guard transientWorkflowState == nil, roleMoodState == .idle else {
            return false
        }
        switch baseWorkflowState {
        case .idle, .thinking, .sleepy:
            return true
        case .focusing, .reminding, .resting, .translationDone, .happy:
            return false
        }
    }

    private func applyWorkflowState() {
        let statusState = transientWorkflowState ?? (baseWorkflowState == .idle ? roleMoodState : baseWorkflowState)
        let animationState = transientWorkflowState ?? (roleMoodState == .idle ? baseWorkflowState : roleMoodState)
        workflowState = statusState
        setAnimationState(firstAvailableState(animationState.animationCandidates))
    }

    private func hasUsableAnimation(for state: PetWorkflowState) -> Bool {
        guard let framesByState = loadedSkin?.framesByState else {
            return state == .idle
        }

        return state.animationCandidates.contains { framesByState[$0]?.isEmpty == false }
    }

    private func noteUserInteraction() {
        lastUserInteractionDate = Date()
    }

    private func cancelEdgeBehavior(restoreAnimation: Bool) {
        edgeBehaviorMode = .normal
        edgeReturnOrigin = nil
        edgeTopRestStartDate = nil
        lastEdgeBehaviorUpdateDate = Date()
        if restoreAnimation {
            restoreLockedOrIdleState()
        }
    }

    private func updateEdgeBehavior(now: Date) {
        guard let window, isVisible else {
            lastEdgeBehaviorUpdateDate = now
            return
        }

        guard autoEdgeBehaviorEnabled else {
            lastEdgeBehaviorUpdateDate = now
            return
        }

        guard !isQuickMenuOpen, !isDraggingPet, dragStartMouseLocation == nil else {
            lastEdgeBehaviorUpdateDate = now
            return
        }

        let deltaTime = min(max(now.timeIntervalSince(lastEdgeBehaviorUpdateDate), 0), 0.2)
        lastEdgeBehaviorUpdateDate = now

        switch edgeBehaviorMode {
        case .normal:
            guard allowsAutoEdgeBehavior else { return }
            guard !suppressEdgeBehaviorForFocus else { return }
            guard now.timeIntervalSince(lastUserInteractionDate) >= presenceIntensity.edgeIdleDelay else { return }
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            beginEdgeSeeking(for: window)
        case .seeking(let side):
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            updateEdgeSeeking(side: side, window: window, deltaTime: deltaTime)
        case .climbing(let side):
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            updateEdgeClimbing(side: side, window: window, deltaTime: deltaTime, now: now)
        case .barWalking(let side):
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            updateEdgeBarWalking(from: side, window: window, deltaTime: deltaTime, now: now)
        case .resting(let side):
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            updateEdgeResting(side: side, window: window, now: now)
        case .returning(let origin):
            if foregroundAppHasImmersiveWindow(near: window, now: now) {
                cancelEdgeBehavior(restoreAnimation: true)
                lastUserInteractionDate = now
                return
            }
            updateEdgeReturning(to: origin, window: window, deltaTime: deltaTime)
        }
    }

    private func beginEdgeSeeking(for window: NSWindow) {
        let visibleFrame = visibleFrame(for: window)
        let frame = window.frame
        edgeReturnOrigin = clampedOrigin(frame.origin, size: frame.size)
        edgeTopRestStartDate = nil
        let leftDistance = abs(frame.minX - visibleFrame.minX)
        let rightDistance = abs(visibleFrame.maxX - frame.maxX)
        let side: PetEdgeSide = leftDistance <= rightDistance ? .left : .right

        edgeBehaviorMode = .seeking(side)
        setEdgeSeekingAnimation(for: side)
    }

    private func updateEdgeSeeking(side: PetEdgeSide, window: NSWindow, deltaTime: TimeInterval) {
        let visibleFrame = visibleFrame(for: window)
        let frame = window.frame
        let targetX = edgeX(for: side, windowSize: frame.size, visibleFrame: visibleFrame)
        let step = Self.edgeSeekSpeed * CGFloat(deltaTime)
        let nextX = steppedValue(from: frame.origin.x, to: targetX, step: step)
        let nextY = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)

        window.setFrameOrigin(CGPoint(x: nextX, y: nextY))

        if abs(nextX - targetX) <= Self.edgeSnapTolerance {
            window.setFrameOrigin(CGPoint(x: targetX, y: nextY))
            edgeBehaviorMode = .climbing(side)
            setEdgeClimbingAnimation(for: side)
        }
    }

    private func updateEdgeClimbing(side: PetEdgeSide, window: NSWindow, deltaTime: TimeInterval, now: Date) {
        let visibleFrame = visibleFrame(for: window)
        let frame = window.frame
        let targetX = edgeX(for: side, windowSize: frame.size, visibleFrame: visibleFrame)
        let targetY = visibleFrame.maxY - frame.height
        let step = Self.edgeClimbSpeed * CGFloat(deltaTime)
        let nextY = steppedValue(from: frame.origin.y, to: targetY, step: step)

        window.setFrameOrigin(CGPoint(x: targetX, y: nextY))

        if abs(nextY - targetY) <= Self.edgeSnapTolerance {
            window.setFrameOrigin(CGPoint(x: targetX, y: targetY))
            beginEdgeBarWalking(from: side)
        }
    }

    private func beginEdgeBarWalking(from side: PetEdgeSide) {
        edgeBehaviorMode = .barWalking(side)
        edgeTopRestStartDate = nil
        setEdgeBarWalkingAnimation(from: side)
    }

    private func updateEdgeBarWalking(from side: PetEdgeSide, window: NSWindow, deltaTime: TimeInterval, now: Date) {
        let visibleFrame = visibleFrame(for: window)
        let frame = window.frame
        let targetSide = oppositeEdgeSide(side)
        let targetX = edgeX(for: targetSide, windowSize: frame.size, visibleFrame: visibleFrame)
        let targetY = visibleFrame.maxY - frame.height
        let step = Self.edgeBarWalkSpeed * CGFloat(deltaTime)
        let nextX = steppedValue(from: frame.origin.x, to: targetX, step: step)

        window.setFrameOrigin(CGPoint(x: nextX, y: targetY))
        setEdgeBarWalkingAnimation(from: side)

        if abs(nextX - targetX) <= Self.edgeSnapTolerance {
            window.setFrameOrigin(CGPoint(x: targetX, y: targetY))
            edgeBehaviorMode = .resting(targetSide)
            edgeTopRestStartDate = now
            setEdgeRestingAnimation(for: targetSide)
        }
    }

    private func updateEdgeResting(side: PetEdgeSide, window: NSWindow, now: Date) {
        pin(window: window, to: side)

        if edgeTopRestStartDate == nil {
            edgeTopRestStartDate = now
        }

        guard let edgeTopRestStartDate,
              now.timeIntervalSince(edgeTopRestStartDate) >= Self.edgeTopRestDuration else {
            return
        }

        beginEdgeReturning(window: window)
    }

    private func beginEdgeReturning(window: NSWindow) {
        guard let edgeReturnOrigin else {
            cancelEdgeBehavior(restoreAnimation: true)
            noteUserInteraction()
            return
        }

        let targetOrigin = clampedOrigin(edgeReturnOrigin, size: window.frame.size)
        edgeBehaviorMode = .returning(targetOrigin)
        edgeTopRestStartDate = nil
        setEdgeReturningAnimation()
    }

    private func updateEdgeReturning(to origin: CGPoint, window: NSWindow, deltaTime: TimeInterval) {
        let targetOrigin = clampedOrigin(origin, size: window.frame.size)
        let currentOrigin = window.frame.origin
        let step = Self.edgeReturnSpeed * CGFloat(deltaTime)
        let nextOrigin = steppedPoint(from: currentOrigin, to: targetOrigin, step: step)

        window.setFrameOrigin(nextOrigin)
        setEdgeReturningAnimation()

        let remainingDistance = hypot(nextOrigin.x - targetOrigin.x, nextOrigin.y - targetOrigin.y)
        if remainingDistance <= Self.edgeSnapTolerance {
            window.setFrameOrigin(targetOrigin)
            edgeBehaviorMode = .normal
            edgeReturnOrigin = nil
            edgeTopRestStartDate = nil
            lastUserInteractionDate = Date()
            restoreLockedOrIdleState()
        }
    }

    private func pin(window: NSWindow, to side: PetEdgeSide) {
        let visibleFrame = visibleFrame(for: window)
        let frame = window.frame
        let targetX = edgeX(for: side, windowSize: frame.size, visibleFrame: visibleFrame)
        let targetY = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        if abs(frame.origin.x - targetX) > Self.edgeSnapTolerance || frame.origin.y != targetY {
            window.setFrameOrigin(CGPoint(x: targetX, y: targetY))
        }
    }

    private func setEdgeSeekingAnimation(for side: PetEdgeSide) {
        switch side {
        case .left:
            setAnimationState("running-left")
        case .right:
            setAnimationState("running-right")
        }
    }

    private func setEdgeClimbingAnimation(for side: PetEdgeSide) {
        setAnimationState(firstAvailableState(edgeClimbingStateCandidates(for: side)))
    }

    private func setEdgeRestingAnimation(for side: PetEdgeSide) {
        setAnimationState(firstAvailableState(edgeRestingStateCandidates(for: side)))
    }

    private func setEdgeBarWalkingAnimation(from side: PetEdgeSide) {
        setAnimationState(firstAvailableState(edgeBarWalkingStateCandidates(from: side)))
    }

    private func setEdgeReturningAnimation() {
        setAnimationState(firstAvailableState(["parachute", "jumping", "running", "idle"]))
    }

    private func firstAvailableState(_ candidates: [String]) -> String {
        guard let framesByState = loadedSkin?.framesByState else {
            return "idle"
        }

        return candidates.first { framesByState[$0]?.isEmpty == false } ?? "idle"
    }

    private func edgeClimbingStateCandidates(for side: PetEdgeSide) -> [String] {
        switch side {
        case .left:
            return ["climb-left", "climbing-left", "edge-climb-left", "wall-climb-left", "climbing", "climb", "running"]
        case .right:
            return ["climb-right", "climbing-right", "edge-climb-right", "wall-climb-right", "climbing", "climb", "running"]
        }
    }

    private func edgeRestingStateCandidates(for side: PetEdgeSide) -> [String] {
        switch side {
        case .left:
            return ["edge-idle-left", "wall-idle-left", "climb-idle-left", "waiting", "idle"]
        case .right:
            return ["edge-idle-right", "wall-idle-right", "climb-idle-right", "waiting", "idle"]
        }
    }

    private func edgeBarWalkingStateCandidates(from side: PetEdgeSide) -> [String] {
        switch side {
        case .left:
            return ["bar-walk-right", "bar-walk", "running-right", "running"]
        case .right:
            return ["bar-walk-left", "bar-walk", "running-left", "running"]
        }
    }

    private func oppositeEdgeSide(_ side: PetEdgeSide) -> PetEdgeSide {
        switch side {
        case .left:
            return .right
        case .right:
            return .left
        }
    }

    private func edgeX(for side: PetEdgeSide, windowSize: CGSize, visibleFrame: NSRect) -> CGFloat {
        switch side {
        case .left:
            return visibleFrame.minX
        case .right:
            return visibleFrame.maxX - windowSize.width
        }
    }

    private func steppedValue(from current: CGFloat, to target: CGFloat, step: CGFloat) -> CGFloat {
        guard abs(target - current) > step else {
            return target
        }

        return current + (target > current ? step : -step)
    }

    private func steppedPoint(from current: CGPoint, to target: CGPoint, step: CGFloat) -> CGPoint {
        let deltaX = target.x - current.x
        let deltaY = target.y - current.y
        let distance = hypot(deltaX, deltaY)
        guard distance > step, distance > 0 else {
            return target
        }

        let ratio = step / distance
        return CGPoint(
            x: current.x + deltaX * ratio,
            y: current.y + deltaY * ratio
        )
    }

    private func setAnimationState(_ stateID: String) {
        let nextState = resolvedStateID(for: stateID)

        if animationStateID != nextState {
            animationStateID = nextState
            frameIndex = 0
            lastFrameDate = Date()
        }
    }

    private func resolvedStateID(for requestedStateID: String) -> String {
        guard let framesByState = loadedSkin?.framesByState else {
            return "idle"
        }

        if framesByState[requestedStateID]?.isEmpty == false {
            return requestedStateID
        }

        if ["running-left", "running-right"].contains(requestedStateID),
           framesByState["running"]?.isEmpty == false {
            return "running"
        }

        return "idle"
    }

    private func clampedOrigin(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame

        guard let frame = visibleFrame else { return origin }

        return CGPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private func visibleFrame(for window: NSWindow) -> NSRect {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func foregroundAppHasImmersiveWindow(near window: NSWindow, now: Date) -> Bool {
        guard now.timeIntervalSince(lastImmersiveWindowCheckDate) >= Self.immersiveWindowCheckInterval else {
            return cachedForegroundHasImmersiveWindow
        }

        lastImmersiveWindowCheckDate = now
        cachedForegroundHasImmersiveWindow = computeForegroundAppHasImmersiveWindow(near: window)
        return cachedForegroundHasImmersiveWindow
    }

    private func computeForegroundAppHasImmersiveWindow(near window: NSWindow) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.activationPolicy == .regular,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let screen = window.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let minWidth = screenFrame.width * Self.immersiveWindowWidthRatio
        let minHeight: CGFloat
        if visibleFrame.height < screenFrame.height * 0.96 {
            minHeight = max(screenFrame.height * Self.immersiveWindowHeightRatio, visibleFrame.height + 16)
        } else {
            minHeight = screenFrame.height * 0.96
        }
        let minArea = screenFrame.width * screenFrame.height * Self.immersiveWindowAreaRatio
        let pid = application.processIdentifier

        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
                return false
            }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return false }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { return false }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return false
            }

            return bounds.width >= minWidth
                && bounds.height >= minHeight
                && bounds.width * bounds.height >= minArea
        }
    }
}

private final class PetPanel: NSPanel {
    weak var petController: PetController?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }
}

private enum PetQuickAction: CaseIterable, Identifiable {
    case chat
    case translation
    case reminders
    case pomodoro
    case journal
    case mood

    var id: String {
        switch self {
        case .chat:
            return "chat"
        case .translation:
            return "translation"
        case .reminders:
            return "reminders"
        case .pomodoro:
            return "pomodoro"
        case .journal:
            return "journal"
        case .mood:
            return "mood"
        }
    }

    var title: String {
        switch self {
        case .chat:
            return "对话"
        case .translation:
            return "翻译"
        case .reminders:
            return "提醒"
        case .pomodoro:
            return "专注"
        case .journal:
            return "日记"
        case .mood:
            return "心情"
        }
    }

    var iconName: String {
        switch self {
        case .chat:
            return "bubble.left.and.bubble.right"
        case .translation:
            return "text.bubble"
        case .reminders:
            return "checklist"
        case .pomodoro:
            return "timer"
        case .journal:
            return "note.text"
        case .mood:
            return "sparkles"
        }
    }

    var accentColor: Color {
        let index = Self.allCases.firstIndex { $0 == self } ?? 0
        return XiaoHuaErTheme.actionAccent(index: index)
    }

    func position(in layout: PetQuickMenuLayout) -> CGPoint {
        layout.position(for: self)
    }
}

private struct PetQuickMenuLayout {
    let size: NSSize
    let petSize: CGSize
    let tileSize: CGFloat
    let symbolSize: CGFloat
    let labelFontSize: CGFloat
    let buttonSize: CGSize
    let cornerRadius: CGFloat

    var center: CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    var petTopY: CGFloat {
        center.y - petSize.height * 0.62
    }

    var connectorStart: CGPoint {
        CGPoint(x: center.x, y: petTopY + petSize.height * 0.18)
    }

    static func make(anchorSize: CGSize?) -> PetQuickMenuLayout {
        let rawPetSize = anchorSize ?? CGSize(width: 150, height: 170)
        let petSize = CGSize(
            width: min(max(rawPetSize.width, 96), 260),
            height: min(max(rawPetSize.height, 112), 300)
        )
        let petMinSide = min(petSize.width, petSize.height)
        let tileSize = min(max(petMinSide * 0.29, 38), 50)
        let buttonSize = CGSize(width: max(tileSize + 26, 74), height: tileSize + 28)
        let width = min(max(buttonSize.width * 6.12 + 44, 500), 620)
        let height = min(max(petSize.height + buttonSize.height * 1.72 + 78, 320), 430)

        return PetQuickMenuLayout(
            size: NSSize(width: width, height: height),
            petSize: petSize,
            tileSize: tileSize,
            symbolSize: tileSize * 0.48,
            labelFontSize: 11.5,
            buttonSize: buttonSize,
            cornerRadius: tileSize * 0.25
        )
    }

    func position(for action: PetQuickAction) -> CGPoint {
        let slot = slotIndex(for: action)
        let horizontalStep = buttonSize.width * 0.86
        let arcDip = abs(slot) * buttonSize.height * 0.14
        let topSafeCenterY = buttonSize.height / 2 + 14

        return CGPoint(
            x: center.x + slot * horizontalStep,
            y: max(topSafeCenterY, petTopY - buttonSize.height * 0.16 + arcDip)
        )
    }

    private func slotIndex(for action: PetQuickAction) -> CGFloat {
        switch action {
        case .translation:
            return -2.5
        case .reminders:
            return -1.5
        case .pomodoro:
            return -0.5
        case .chat:
            return 0.5
        case .journal:
            return 1.5
        case .mood:
            return 2.5
        }
    }
}

private final class PetQuickMenuController {
    private var panel: PetQuickMenuPanel?
    private var onClose: (() -> Void)?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    deinit {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
    }

    func show(anchorWindow: NSWindow?, anchorPoint: CGPoint?, onClose: @escaping () -> Void, actionHandler: @escaping (PetQuickAction) -> Void) {
        close()

        self.onClose = onClose

        let layout = PetQuickMenuLayout.make(anchorSize: anchorWindow?.frame.size)
        let size = layout.size
        let panel = PetQuickMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.title = "Pet Quick Menu"
        panel.onDismiss = { [weak self] in
            self?.finishClose()
        }

        let view = PetQuickMenuView(layout: layout) { [weak self] action in
            self?.close()
            if let action {
                actionHandler(action)
            }
        }
        let contentView = TransparentPanelContentView(frame: NSRect(origin: .zero, size: size))
        let hostingView = TransparentHostingView(rootView: view)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        panel.contentView = contentView
        panel.setFrameOrigin(Self.origin(for: size, anchorWindow: anchorWindow, anchorPoint: anchorPoint))
        installOutsideClickMonitor(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.dismiss()
    }

    private func finishClose() {
        removeOutsideClickMonitor()
        panel = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
    }

    private func installOutsideClickMonitor(for panel: PetQuickMenuPanel) {
        removeOutsideClickMonitor()
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            guard !panel.frame.contains(NSEvent.mouseLocation) else { return event }

            self.close()
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] _ in
            DispatchQueue.main.async {
                guard let self, let panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.close()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private static func origin(for size: NSSize, anchorWindow: NSWindow?, anchorPoint: CGPoint?) -> CGPoint {
        let visibleFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        guard let anchorWindow, anchorWindow.isVisible else {
            return CGPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        }

        let anchor = anchorWindow.frame
        let anchorCenter = anchorPoint ?? CGPoint(x: anchor.midX, y: anchor.midY)
        let proposed = CGPoint(
            x: anchorCenter.x - size.width / 2,
            y: anchorCenter.y - size.height / 2
        )

        return CGPoint(
            x: min(max(proposed.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
            y: min(max(proposed.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        )
    }
}

private final class PetQuickMenuPanel: NSPanel {
    var onDismiss: (() -> Void)?
    private var isDismissing = false

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
            return
        }

        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        orderOut(nil)
        onDismiss?()
        onDismiss = nil
    }
}

private final class TransparentPanelContentView: NSView {
    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
    }
}

private final class TransparentHostingView<Content: View>: CompanionInteractiveHostingView<Content> {
    override var isOpaque: Bool {
        false
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        enclosingScrollView?.drawsBackground = false
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

private struct PetQuickMenuView: View {
    let layout: PetQuickMenuLayout
    let action: (PetQuickAction?) -> Void

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    action(nil)
                }

            PetQuickMenuConnectorView(layout: layout)
                .allowsHitTesting(false)

            ForEach(PetQuickAction.allCases) { item in
                PetQuickMenuButton(item: item, layout: layout) {
                    action(item)
                }
                .position(item.position(in: layout))
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(Color.clear)
    }
}

private struct PetQuickMenuButton: View {
    let item: PetQuickAction
    let layout: PetQuickMenuLayout
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.28), radius: 10, x: 0, y: 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                                .stroke(item.accentColor.opacity(isHovering ? 0.55 : 0.30), lineWidth: 1)
                        )

                    Image(systemName: item.iconName)
                        .font(.system(size: layout.symbolSize, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.accentColor)
                }
                .frame(width: layout.tileSize, height: layout.tileSize)
                .scaleEffect(isHovering ? 1.06 : 1.0)

                Text(item.title)
                    .font(.system(size: layout.labelFontSize, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: layout.buttonSize.width, height: layout.buttonSize.height)
            .contentShape(RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous))
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .shadow(color: item.accentColor.opacity(isHovering ? 0.28 : 0.0), radius: isHovering ? 10 : 0, x: 0, y: isHovering ? 5 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovering)
    }
}

private struct PetQuickMenuConnectorView: View {
    let layout: PetQuickMenuLayout

    var body: some View {
        ZStack {
            ForEach(PetQuickAction.allCases) { item in
                PetQuickMenuCurve(layout: layout, end: item.position(in: layout))
                    .stroke(
                        item.accentColor.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 7])
                    )
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }
}

private struct PetQuickMenuCurve: Shape {
    let layout: PetQuickMenuLayout
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        let start = layout.connectorStart
        let target = CGPoint(x: end.x, y: end.y + layout.tileSize * 0.58)
        let direction = target.x < start.x ? -1.0 : 1.0
        let control1 = CGPoint(x: start.x + CGFloat(direction * 28), y: start.y - layout.petSize.height * 0.10)
        let control2 = CGPoint(x: target.x - CGFloat(direction * 30), y: target.y + layout.petSize.height * 0.06)

        var path = Path()
        path.move(to: start)
        path.addCurve(to: target, control1: control1, control2: control2)
        return path
    }
}

private final class PetContainerView: NSView {
    weak var controller: PetController?

    private let hostingView: NSHostingView<PetView>

    init(controller: PetController) {
        self.controller = controller
        self.hostingView = NSHostingView(rootView: PetView(controller: controller))

        super.init(frame: NSRect(origin: .zero, size: controller.displaySize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        controller?.beginNativeDrag(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.updateNativeDrag(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endDrag()
    }
}

private struct PetView: View {
    @ObservedObject var controller: PetController

    var body: some View {
        ZStack {
            if let image = controller.currentFrame {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .allowsHitTesting(false)
            }
        }
        .frame(width: controller.displaySize.width, height: controller.displaySize.height)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}
