import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

enum XiaoHuaErAIResultWorkflowAction: String, Equatable, Hashable, Codable {
    case saveToJournal
    case createReminder
    case startFocus

    var statusTitle: String {
        switch self {
        case .saveToJournal:
            return "已存到日记"
        case .createReminder:
            return "已创建提醒"
        case .startFocus:
            return "已开始专注"
        }
    }

    var displayName: String {
        switch self {
        case .saveToJournal:
            return "存到日记"
        case .createReminder:
            return "创建提醒"
        case .startFocus:
            return "开始专注"
        }
    }
}

enum XiaoHuaErAIResultWorkflowOutcome: Equatable {
    case accepted(String)
    case cancelled(String)

    var statusMessage: String {
        switch self {
        case .accepted(let message), .cancelled(let message):
            return message
        }
    }
}

struct XiaoHuaErAIResultWorkflowRequest {
    var action: XiaoHuaErAIResultWorkflowAction  // 保留单选字段以兼容现有代码
    var actions: Set<XiaoHuaErAIResultWorkflowAction>  // 新增多选字段
    var actionTitle: String
    var resultTitle: String
    var providerName: String
    var sourceText: String
    var resultText: String
    var createdAt: Date = Date()
    var reminderTitle: String?
    var reminderTime: Date?

    // 单选构造器（兼容现有代码）
    init(
        action: XiaoHuaErAIResultWorkflowAction,
        actionTitle: String,
        resultTitle: String,
        providerName: String,
        sourceText: String,
        resultText: String,
        createdAt: Date = Date(),
        reminderTitle: String? = nil,
        reminderTime: Date? = nil
    ) {
        self.action = action
        self.actions = [action]
        self.actionTitle = actionTitle
        self.resultTitle = resultTitle
        self.providerName = providerName
        self.sourceText = sourceText
        self.resultText = resultText
        self.createdAt = createdAt
        self.reminderTitle = reminderTitle
        self.reminderTime = reminderTime
    }

    // 多选构造器
    init(
        actions: Set<XiaoHuaErAIResultWorkflowAction>,
        actionTitle: String,
        resultTitle: String,
        providerName: String,
        sourceText: String,
        resultText: String,
        createdAt: Date = Date(),
        reminderTitle: String? = nil,
        reminderTime: Date? = nil
    ) {
        self.action = actions.first ?? .saveToJournal
        self.actions = actions
        self.actionTitle = actionTitle
        self.resultTitle = resultTitle
        self.providerName = providerName
        self.sourceText = sourceText
        self.resultText = resultText
        self.createdAt = createdAt
        self.reminderTitle = reminderTitle
        self.reminderTime = reminderTime
    }
}

final class ClipboardTranslationFeature {
    var onAIActionStarted: (() -> Void)? {
        didSet {
            translationController.onAIActionStarted = onAIActionStarted
        }
    }

    var onAIActionCompleted: (() -> Void)? {
        didSet {
            translationController.onAIActionCompleted = onAIActionCompleted
        }
    }

    var onAIActionFinished: (() -> Void)? {
        didSet {
            translationController.onAIActionFinished = onAIActionFinished
        }
    }

    var onAIResultWorkflowRequested: ((XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome)? {
        didSet {
            translationController.onAIResultWorkflowRequested = onAIResultWorkflowRequested
        }
    }

    var onAssetUploadRequested: (() -> Void)? {
        didSet {
            translationController.onAssetUploadRequested = onAssetUploadRequested
        }
    }

    var onChatRequested: ((String, CGPoint, CompanionAIInputSource) -> Void)?

    func currentAIResultWorkflowRequest(action: XiaoHuaErAIResultWorkflowAction) -> XiaoHuaErAIResultWorkflowRequest? {
        translationController.currentAIResultWorkflowRequest(action: action)
    }

    func hasAIResultWorkflowContext() -> Bool {
        translationController.hasAIResultWorkflowContext()
    }

    private let aiService: CompanionAIService
    private let buttonController = TranslationButtonPanelController()
    private let selectionMonitor = CompanionSelectionMonitor()
    private lazy var translationController = TranslationWindowController(aiService: aiService)
    private var timer: Timer?
    private var permissionRetryTimer: Timer?
    private var permissionRetryExpiresAt: Date?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastButtonPresentation: (text: String, date: Date)?
    private let duplicatePresentationInterval: TimeInterval = 0.45
    private let permissionRetryInterval: TimeInterval = 1.25
    private let permissionRetryWindow: TimeInterval = 90
    private static let clipboardEnabledDefaultsKey = "CompanionClipboardTranslationEnabled"
    private static let selectionEnabledDefaultsKey = "CompanionSelectionTranslationEnabled"
    private static var suppressedPasteboardChangeCounts: Set<Int> = []

    var isClipboardEnabled: Bool {
        timer != nil
    }

    var isSelectionEnabled: Bool {
        CompanionAccessibilityPermission.isTrusted && selectionMonitor.isRunning
    }

    var accessibilityPermissionGranted: Bool {
        CompanionAccessibilityPermission.isTrusted
    }

    var isEnabled: Bool {
        isClipboardEnabled || isSelectionEnabled
    }

    static var savedClipboardEnabled: Bool {
        if UserDefaults.standard.object(forKey: clipboardEnabledDefaultsKey) == nil {
            return true
        }

        return UserDefaults.standard.bool(forKey: clipboardEnabledDefaultsKey)
    }

    static var savedSelectionEnabled: Bool {
        if UserDefaults.standard.object(forKey: selectionEnabledDefaultsKey) == nil {
            return true
        }

        return UserDefaults.standard.bool(forKey: selectionEnabledDefaultsKey)
    }

    static func suppressPasteboardChange(_ changeCount: Int) {
        suppressedPasteboardChangeCounts.insert(changeCount)
        if suppressedPasteboardChangeCounts.count > 8 {
            suppressedPasteboardChangeCounts.remove(suppressedPasteboardChangeCounts.min() ?? changeCount)
        }
    }

    init(aiService: CompanionAIService) {
        self.aiService = aiService
        buttonController.onQuickAction = { [weak self] text, anchor, source, action, preselectedWorkflowActions in
            self?.showTranslation(
                for: text,
                anchor: anchor,
                source: source,
                initialAction: action,
                preselectedWorkflowActions: preselectedWorkflowActions
            )
        }
        buttonController.onChatAction = { [weak self] text, anchor, source in
            self?.showChat(for: text, anchor: anchor, source: source)
        }
        selectionMonitor.onSelectionChanged = { [weak self] snapshot in
            self?.handleSelection(snapshot)
        }
        selectionMonitor.shouldIgnoreMouseDown = { [weak self] location in
            self?.buttonController.contains(screenLocation: location) ?? false
        }
    }

    func start() {
        guard timer == nil else {
            return
        }

        UserDefaults.standard.set(true, forKey: Self.clipboardEnabledDefaultsKey)
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: Self.clipboardEnabledDefaultsKey)
        timer?.invalidate()
        timer = nil
        buttonController.hide()
    }

    func startSelectionPopup(requestPermission: Bool = true) {
        UserDefaults.standard.set(true, forKey: Self.selectionEnabledDefaultsKey)
        guard CompanionAccessibilityPermission.isTrusted else {
            selectionMonitor.stop()
            if requestPermission {
                CompanionAccessibilityPermission.request()
                openAccessibilitySettings()
            }
            startPermissionRetry()
            return
        }

        stopPermissionRetry()
        selectionMonitor.start()
    }

    func stopSelectionPopup() {
        UserDefaults.standard.set(false, forKey: Self.selectionEnabledDefaultsKey)
        stopPermissionRetry()
        selectionMonitor.stop()
        buttonController.hide()
    }

    func requestAccessibilityPermission() {
        CompanionAccessibilityPermission.request()
        openAccessibilitySettings()
        if Self.savedSelectionEnabled {
            startPermissionRetry()
        }
    }

    func refreshSelectionPopupState() {
        guard Self.savedSelectionEnabled else {
            stopPermissionRetry()
            selectionMonitor.stop()
            return
        }

        guard CompanionAccessibilityPermission.isTrusted else {
            selectionMonitor.stop()
            startPermissionRetry()
            return
        }

        stopPermissionRetry()
        selectionMonitor.start()
    }

    func translateClipboardNow() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }

        showTranslation(for: text, anchor: NSEvent.mouseLocation, source: .clipboard)
    }

    func showTranslationWindow(anchorWindow: NSWindow?) {
        let anchor = anchorWindow.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            ?? NSEvent.mouseLocation
        guard let text = NSPasteboard.general.string(forType: .string) else {
            showEmptyTranslation(anchor: anchor)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showEmptyTranslation(anchor: anchor)
            return
        }

        showTranslation(for: text, anchor: anchor, source: .clipboard)
    }

    private func handleSelection(_ snapshot: CompanionSelectionSnapshot?) {
        guard let snapshot else {
            buttonController.hide()
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        presentTranslationButton(text: snapshot.text, anchor: snapshot.anchor, source: .selectedText)
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        if Self.suppressedPasteboardChangeCounts.remove(pasteboard.changeCount) != nil {
            return
        }

        guard
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier,
            let text = pasteboard.string(forType: .string)
        else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard Self.looksLikeTranslatableClipboardText(trimmed) else {
            return
        }

        presentTranslationButton(text: text, anchor: NSEvent.mouseLocation, source: .clipboard)
    }

    /// 启发式判断：剪贴板触发时是否值得弹"翻译"按钮。
    /// 选中触发不走这里，那种是用户主动行为意图很明确。
    /// 设计原则：宁可漏弹，也不要在用户复制代码/URL/路径时打扰。
    static func looksLikeTranslatableClipboardText(_ text: String) -> Bool {
        // 必弹：含汉字
        if containsCJK(text) {
            return true
        }

        // 跳过：太短
        guard text.count >= 2 else {
            return false
        }

        // 跳过：纯数字 / 纯标点 / 纯空白
        let alphanumericOrCJK = text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar)
        }
        guard alphanumericOrCJK else {
            return false
        }

        // 跳过：明显是 URL
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#, options: .regularExpression) != nil {
            return false
        }

        // 跳过：明显是文件路径（Unix / Windows）
        if text.hasPrefix("/") || text.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil {
            return false
        }

        // 跳过：单个 token 且全是 ASCII 标识符样式（变量名、文件名等技术片段）
        // 例如 "getUserName"、"snake_case"、"some.dotted.path"
        if !text.contains(" "),
           !text.contains("\n"),
           text.range(of: #"^[A-Za-z0-9_.\-/]+$"#, options: .regularExpression) != nil {
            return false
        }

        // 通过：至少 4 个连续字母（普通自然语言单词的基本特征）
        return text.range(of: #"[A-Za-z]{4,}"#, options: .regularExpression) != nil
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            // CJK 统一表意 + 扩展 A + 兼容表意 + 假名 + 谚文（覆盖中日韩）
            return (0x3040...0x30FF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
                || (0xF900...0xFAFF).contains(v)
        }
    }

    private func presentTranslationButton(text: String, anchor: CGPoint, source: CompanionAIInputSource) {
        guard shouldPresentButton(for: text) else {
            return
        }

        buttonController.show(text: text, anchor: anchor, source: source)
    }

    private func shouldPresentButton(for text: String) -> Bool {
        let now = Date()
        if let lastButtonPresentation,
           lastButtonPresentation.text == text,
           now.timeIntervalSince(lastButtonPresentation.date) < duplicatePresentationInterval {
            return false
        }

        lastButtonPresentation = (text, now)
        return true
    }

    private func showTranslation(
        for text: String,
        anchor: CGPoint,
        source: CompanionAIInputSource,
        initialAction: CompanionAIQuickAction = .translate,
        preselectedWorkflowActions: Set<XiaoHuaErAIResultWorkflowAction> = []
    ) {
        buttonController.hide()
        translationController.show(
            sourceText: text,
            anchor: anchor,
            source: source,
            initialAction: initialAction,
            preselectedWorkflowActions: preselectedWorkflowActions
        )
    }

    private func showChat(for text: String, anchor: CGPoint, source: CompanionAIInputSource) {
        buttonController.hide()
        onChatRequested?(text, anchor, source)
    }

    private func showEmptyTranslation(anchor: CGPoint) {
        buttonController.hide()
        translationController.showEmpty(anchor: anchor)
    }

    private func startPermissionRetry() {
        guard Self.savedSelectionEnabled else {
            return
        }

        permissionRetryExpiresAt = Date().addingTimeInterval(permissionRetryWindow)
        guard permissionRetryTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: permissionRetryInterval, repeats: true) { [weak self] _ in
            self?.retryStartSelectionPopupIfPossible()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionRetryTimer = timer
        retryStartSelectionPopupIfPossible()
    }

    private func stopPermissionRetry() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        permissionRetryExpiresAt = nil
    }

    private func retryStartSelectionPopupIfPossible() {
        guard Self.savedSelectionEnabled else {
            stopPermissionRetry()
            selectionMonitor.stop()
            return
        }

        if CompanionAccessibilityPermission.isTrusted {
            stopPermissionRetry()
            selectionMonitor.start()
            return
        }

        selectionMonitor.stop()
        if let permissionRetryExpiresAt, Date() >= permissionRetryExpiresAt {
            stopPermissionRetry()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class TranslationButtonPanelController {
    var onQuickAction: ((String, CGPoint, CompanionAIInputSource, CompanionAIQuickAction, Set<XiaoHuaErAIResultWorkflowAction>) -> Void)?
    var onChatAction: ((String, CGPoint, CompanionAIInputSource) -> Void)?

    private var panel: NSPanel?
    private var currentText = ""
    private var currentAnchor = CGPoint.zero
    private var currentSource: CompanionAIInputSource = .manual
    private var hideWorkItem: DispatchWorkItem?
    private var isHovered = false
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?

    deinit {
        removeOutsideClickMonitor()
    }

    func show(text: String, anchor: CGPoint, source: CompanionAIInputSource) {
        currentText = text
        currentAnchor = anchor
        currentSource = source
        hideWorkItem?.cancel()

        let content = TranslationButtonView(
            translateAction: { [weak self] in
                self?.performQuickAction(.translate, preselectedWorkflowActions: [])
            },
            polishAction: { [weak self] in
                self?.performQuickAction(.polish, preselectedWorkflowActions: [])
            },
            summarizeAction: { [weak self] in
                self?.performQuickAction(.summarize, preselectedWorkflowActions: [])
            },
            rewriteAction: { [weak self] in
                self?.performQuickAction(.friendlyRewrite, preselectedWorkflowActions: [])
            },
            chatAction: { [weak self] in
                self?.performChatAction()
            },
            hoverChanged: { [weak self] isHovered in
                self?.setHovered(isHovered)
            }
        )

        let hostingView = CompanionInteractiveHostingView(rootView: content)
        let fittingSize = hostingView.fittingSize
        let contentSize = CGSize(
            width: max(fittingSize.width, 410),
            height: max(fittingSize.height, 50)
        )

        let panel = existingOrNewPanel(contentSize: contentSize)
        panel.contentView = hostingView
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(origin(for: contentSize, anchor: anchor))
        installOutsideClickMonitor(for: panel)
        panel.orderFrontRegardless()
        scheduleAutoHide(after: 9)
    }

    private func performQuickAction(
        _ action: CompanionAIQuickAction,
        preselectedWorkflowActions: Set<XiaoHuaErAIResultWorkflowAction>
    ) {
        onQuickAction?(currentText, currentAnchor, currentSource, action, preselectedWorkflowActions)
    }

    private func performChatAction() {
        hide()
        onChatAction?(currentText, currentAnchor, currentSource)
    }

    func contains(screenLocation: CGPoint) -> Bool {
        panel?.isVisible == true && panel?.frame.contains(screenLocation) == true
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isHovered = false
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
    }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        if hovered {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            scheduleAutoHide(after: 9)
        }
    }

    private func scheduleAutoHide(after delay: TimeInterval = 7) {
        hideWorkItem?.cancel()
        guard !isHovered else {
            hideWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func existingOrNewPanel(contentSize: CGSize) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        self.panel = panel
        return panel
    }

    private func installOutsideClickMonitor(for panel: NSPanel) {
        removeOutsideClickMonitor()
        let monitoredEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            guard !panel.frame.contains(NSEvent.mouseLocation) else { return event }

            self.hide()
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitoredEvents) { [weak self, weak panel] _ in
            DispatchQueue.main.async {
                guard let self, let panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
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

    private func origin(for size: CGSize, anchor: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rawOrigin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y + 16)
        return CGPoint(
            x: min(max(rawOrigin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
            y: min(max(rawOrigin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        )
    }
}

private struct TranslationButtonView: View {
    let translateAction: () -> Void
    let polishAction: () -> Void
    let summarizeAction: () -> Void
    let rewriteAction: () -> Void
    let chatAction: () -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            toolbarButton(title: "翻译", systemImage: "globe", tint: XiaoHuaErTheme.tint, action: translateAction)
            divider
            toolbarButton(title: "润色", systemImage: "wand.and.stars", tint: XiaoHuaErTheme.amber, action: polishAction)
            divider
            toolbarButton(title: "总结", systemImage: "text.alignleft", tint: XiaoHuaErTheme.leaf, action: summarizeAction)
            divider
            toolbarButton(title: "改写", systemImage: "arrow.triangle.2.circlepath", tint: XiaoHuaErTheme.sky, action: rewriteAction)
            divider
            toolbarButton(title: "聊天", systemImage: "bubble.left.and.bubble.right", tint: XiaoHuaErTheme.plum, action: chatAction)
            divider
            appLogo
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 1)
        )
        .accessibilityLabel(Text("AI Actions"))
        .help("AI Actions")
        .onHover(perform: hoverChanged)
    }

    private var divider: some View {
        Rectangle()
            .fill(XiaoHuaErTheme.subtleBorder)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    private var appLogo: some View {
        CompanionTranslationButtonIcon(size: 18)
            .frame(width: 32, height: 32)
            .background(XiaoHuaErTheme.plum.opacity(0.12), in: Circle())
            .accessibilityLabel(Text("Companion"))
            .help("Companion")
    }

    private func toolbarButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        TranslationToolbarActionButton(
            title: title,
            systemImage: systemImage,
            tint: tint,
            action: action
        )
    }
}

private struct TranslationToolbarActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 15, height: 15)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 32)
            .padding(.horizontal, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? tint.opacity(0.10) : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .help(title)
        .onHover { isHovering = $0 }
    }
}

private struct CompanionTranslationButtonIcon: View {
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let image = Self.iconImage(size: size) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: max(12, size * 0.72), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(XiaoHuaErTheme.plum)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func iconImage(size: CGFloat) -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: size, height: size)
            image.accessibilityDescription = "Companion"
            return image
        }

        if let url = Bundle.main.url(forResource: "CompanionMenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: size, height: size)
            image.isTemplate = true
            image.accessibilityDescription = "Companion"
            return image
        }

        return nil
    }
}

private enum TranslationPanelLayout {
    static let width: CGFloat = 460
    static let minHeight: CGFloat = 480

    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 18
    private static let titleHeight: CGFloat = 52
    private static let titleContentSpacing: CGFloat = 12
    private static let languageBarHeight: CGFloat = 46
    private static let sourceStatusHeight: CGFloat = 22
    private static let currentViewSpacing: CGFloat = 12
    private static let sourceMinHeight: CGFloat = 104
    private static let sourceMaxHeight: CGFloat = 184
    private static let resultMinHeight: CGFloat = 162
    private static let screenVerticalInset: CGFloat = 24
    private static let resultPaneChromeHeight: CGFloat = 74
    private static let maxMeasuredTextCharacters = 12_000

    private static var currentPaneChromeHeight: CGFloat {
        verticalPadding * 2
            + titleHeight
            + titleContentSpacing
            + languageBarHeight
            + sourceStatusHeight
            + currentViewSpacing * 3
    }

    static func desiredPanelHeight(
        sourceText: String,
        translatedText: String,
        isLoading: Bool,
        isShowingHistory: Bool,
        visibleFrame: CGRect
    ) -> CGFloat {
        guard !isShowingHistory else {
            return minHeight
        }

        let desiredHeight = currentPaneChromeHeight
            + sourcePaneHeight(for: sourceText)
            + resultPaneHeight(for: translatedText, isLoading: isLoading)
        let maximumHeight = max(minHeight, visibleFrame.height - screenVerticalInset)
        return clamp(desiredHeight, min: minHeight, max: maximumHeight)
    }

    static func paneHeights(
        sourceText: String,
        translatedText: String,
        isLoading: Bool,
        panelHeight: CGFloat
    ) -> (source: CGFloat, result: CGFloat) {
        let sourceDesired = sourcePaneHeight(for: sourceText)
        let resultDesired = resultPaneHeight(for: translatedText, isLoading: isLoading)
        let availableHeight = max(
            sourceMinHeight + resultMinHeight,
            panelHeight - currentPaneChromeHeight
        )

        guard sourceDesired + resultDesired > availableHeight else {
            return (sourceDesired, resultDesired)
        }

        let sourceHeight = min(
            sourceDesired,
            max(sourceMinHeight, availableHeight - resultMinHeight)
        )
        let resultHeight = max(resultMinHeight, availableHeight - sourceHeight)
        return (sourceHeight, resultHeight)
    }

    private static func sourcePaneHeight(for text: String) -> CGFloat {
        let textWidth = width - horizontalPadding * 2 - 24
        let textHeight = measuredTextHeight(
            text,
            font: .systemFont(ofSize: 14, weight: .regular),
            lineSpacing: 2,
            width: textWidth
        )
        return clamp(textHeight + 40, min: sourceMinHeight, max: sourceMaxHeight)
    }

    private static func resultPaneHeight(for text: String, isLoading: Bool) -> CGFloat {
        guard !isLoading else {
            return resultMinHeight
        }

        let textWidth = width - horizontalPadding * 2 - 22
        let textHeight = measuredTextHeight(
            text,
            font: .systemFont(ofSize: 13, weight: .regular),
            lineSpacing: 2,
            width: textWidth
        )
        return max(resultMinHeight, textHeight + resultPaneChromeHeight)
    }

    private static func measuredTextHeight(
        _ text: String,
        font: NSFont,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        guard text.count <= maxMeasuredTextCharacters else {
            return 1_200
        }
        let measuredText = text.isEmpty ? " " : text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let rect = (measuredText as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }

    private static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        min(max(value, minValue), maxValue)
    }
}

private final class TranslationWindowController {
    var onAIActionStarted: (() -> Void)? {
        didSet {
            viewModel.onAIActionStarted = onAIActionStarted
        }
    }

    var onAIActionCompleted: (() -> Void)? {
        didSet {
            viewModel.onAIActionCompleted = onAIActionCompleted
        }
    }

    var onAIActionFinished: (() -> Void)? {
        didSet {
            viewModel.onAIActionFinished = onAIActionFinished
        }
    }

    var onAIResultWorkflowRequested: ((XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome)? {
        didSet {
            viewModel.onAIResultWorkflowRequested = onAIResultWorkflowRequested
        }
    }

    var onAssetUploadRequested: (() -> Void)? {
        didSet {
            viewModel.onAssetUploadRequested = onAssetUploadRequested
        }
    }

    func currentAIResultWorkflowRequest(action: XiaoHuaErAIResultWorkflowAction) -> XiaoHuaErAIResultWorkflowRequest? {
        viewModel.currentWorkflowRequest(action: action)
    }

    func hasAIResultWorkflowContext() -> Bool {
        viewModel.hasWorkflowContext
    }

    private let viewModel: TranslationViewModel
    private var panel: NSPanel?
    private var sizingCancellables: Set<AnyCancellable> = []
    private var actionStoreCancellable: AnyCancellable?
    private var lastAnchor: CGPoint?

    init(aiService: CompanionAIService) {
        let actionStore = CompanionAIQuickActionStore()
        self.viewModel = TranslationViewModel(
            aiService: aiService,
            historyStore: TranslationHistoryStore(),
            actionStore: actionStore
        )
        installDynamicSizing()
        actionStoreCancellable = actionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.viewModel.refreshAvailableActions()
            }
    }

    func show(sourceText: String, anchor: CGPoint, source: CompanionAIInputSource) {
        show(sourceText: sourceText, anchor: anchor, source: source, initialAction: .translate)
    }

    func show(
        sourceText: String,
        anchor: CGPoint,
        source: CompanionAIInputSource,
        initialAction: CompanionAIQuickAction,
        preselectedWorkflowActions: Set<XiaoHuaErAIResultWorkflowAction> = []
    ) {
        let panel = existingOrNewPanel()
        let visibleFrame = Self.visibleFrame(containing: anchor)
        lastAnchor = anchor
        viewModel.selectedWorkflowActions = preselectedWorkflowActions
        viewModel.runAction(initialAction, text: sourceText, source: source)
        resizePanelToFitContent(visibleFrame: visibleFrame, animated: false)
        position(panel, visibleFrame: visibleFrame)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func showEmpty(anchor: CGPoint) {
        let panel = existingOrNewPanel()
        let visibleFrame = Self.visibleFrame(containing: anchor)
        lastAnchor = anchor
        viewModel.showEmptyMessage(CompanionL10n.text("Copy the content you want to process, then click AI actions again."))
        resizePanelToFitContent(visibleFrame: visibleFrame, animated: false)
        position(panel, visibleFrame: visibleFrame)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = TranslationPanel(
            contentRect: NSRect(
                origin: .zero,
                size: CGSize(width: TranslationPanelLayout.width, height: TranslationPanelLayout.minHeight)
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.onOrderOut = { [weak self] in
            self?.viewModel.cancelCurrentAction()
        }
        let hostingView = CompanionInteractiveHostingView(rootView: TranslationPanelView(
            viewModel: viewModel,
            closeAction: { [weak panel] in
                panel?.orderOut(nil)
            }
        ))
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func installDynamicSizing() {
        Publishers.CombineLatest4(
            viewModel.$sourceText,
            viewModel.$translatedText,
            viewModel.$isLoading,
            viewModel.$isShowingHistory
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] sourceText, translatedText, isLoading, isShowingHistory in
            self?.resizePanelToFitContent(
                animated: true,
                sourceText: sourceText,
                translatedText: translatedText,
                isLoading: isLoading,
                isShowingHistory: isShowingHistory
            )
        }
        .store(in: &sizingCancellables)
    }

    private func resizePanelToFitContent(
        visibleFrame explicitVisibleFrame: CGRect? = nil,
        animated: Bool,
        sourceText: String? = nil,
        translatedText: String? = nil,
        isLoading: Bool? = nil,
        isShowingHistory: Bool? = nil
    ) {
        guard let panel else {
            return
        }

        let visibleFrame = explicitVisibleFrame
            ?? panel.screen?.visibleFrame
            ?? lastAnchor.map(Self.visibleFrame(containing:))
            ?? Self.visibleFrame(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        let targetHeight = TranslationPanelLayout.desiredPanelHeight(
            sourceText: sourceText ?? viewModel.sourceText,
            translatedText: translatedText ?? viewModel.translatedText,
            isLoading: isLoading ?? viewModel.isLoading,
            isShowingHistory: isShowingHistory ?? viewModel.isShowingHistory,
            visibleFrame: visibleFrame
        )
        viewModel.panelContentHeight = targetHeight

        var nextFrame = panel.frame
        nextFrame.size = panel.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: CGSize(width: TranslationPanelLayout.width, height: targetHeight)
            )
        ).size

        if panel.isVisible {
            nextFrame.origin.y = panel.frame.maxY - nextFrame.height
        }

        nextFrame.origin.x = min(max(nextFrame.origin.x, visibleFrame.minX + 12), visibleFrame.maxX - nextFrame.width - 12)
        nextFrame.origin.y = min(max(nextFrame.origin.y, visibleFrame.minY + 12), visibleFrame.maxY - nextFrame.height - 12)
        panel.setFrame(nextFrame, display: true, animate: animated && panel.isVisible)
    }

    private func position(_ panel: NSPanel, visibleFrame: CGRect) {
        let size = panel.frame.size
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private static func visibleFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

private final class TranslationPanel: NSPanel {
    var onOrderOut: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            orderOut(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }

    override func orderOut(_ sender: Any?) {
        onOrderOut?()
        super.orderOut(sender)
    }
}

private final class TranslationViewModel: ObservableObject {
    var onAIActionStarted: (() -> Void)?
    var onAIActionCompleted: (() -> Void)?
    var onAIActionFinished: (() -> Void)?
    var onAIResultWorkflowRequested: ((XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome)?
    var onAssetUploadRequested: (() -> Void)?

    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var isLoading = false
    @Published var providerName = "Companion"
    @Published var sourceLanguageLabel = CompanionL10n.text("Auto Detect")
    @Published var inputSource: CompanionAIInputSource = .manual
    @Published var autoCopyResult: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyResult, forKey: Self.autoCopyDefaultsKey)
        }
    }
    @Published var isShowingHistory = false
    @Published var panelContentHeight = TranslationPanelLayout.minHeight
    @Published var selectedAction: CompanionAIQuickAction = .translate
    @Published var availableActions: [CompanionAIQuickAction]
    @Published var history: [TranslationHistoryRecord]
    @Published var workflowStatusMessage = ""
    @Published var hasSuccessfulResult = false
    @Published var selectedWorkflowActions: Set<XiaoHuaErAIResultWorkflowAction> = []
    @Published var showingPlanPreview = false
    @Published var showingReminderTimeInput = false

    private let maxHistoryRecords = 300
    private let maxHistoryTextCharacters = 12_000
    private let maxQuickActionInputCharacters = 120_000
    private let aiService: CompanionAIService
    private let historyStore: TranslationHistoryStore
    private let actionStore: CompanionAIQuickActionStore
    private var task: Task<Void, Never>?
    private var currentRequestID: UUID?
    /// 标记异步 load 是否已经把磁盘历史合并进来。
    /// 在合并完成前不直接 historyStore.save，避免用一条新记录覆盖整盘历史。
    private var didLoadStoredHistory = false
    /// 异步 load 完成前，用户已经做出的新翻译先缓存在这里，等 load 完成后跟磁盘历史合并。
    private var pendingNewRecords: [TranslationHistoryRecord] = []
    private static let autoCopyDefaultsKey = "Companion.AIQuickActionsAutoCopyResult"
    private static let legacyAutoCopyDefaultsKey = "CompanionAIQuickActionsAutoCopyResult"

    init(aiService: CompanionAIService, historyStore: TranslationHistoryStore, actionStore: CompanionAIQuickActionStore) {
        self.aiService = aiService
        self.historyStore = historyStore
        self.actionStore = actionStore
        self.availableActions = actionStore.allActions
        self.history = []
        if UserDefaults.standard.object(forKey: Self.autoCopyDefaultsKey) == nil,
           let legacyValue = UserDefaults.standard.object(forKey: Self.legacyAutoCopyDefaultsKey) as? Bool
        {
            UserDefaults.standard.set(legacyValue, forKey: Self.autoCopyDefaultsKey)
        }
        self.autoCopyResult = UserDefaults.standard.bool(forKey: Self.autoCopyDefaultsKey)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let storedRecords = historyStore.load()

            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.mergeStoredHistory(storedRecords)
            }
        }
    }

    func translate(_ text: String, source: CompanionAIInputSource = .manual) {
        run(text, action: .translate, source: source)
    }

    func runAction(_ action: CompanionAIQuickAction, text: String, source: CompanionAIInputSource = .manual) {
        run(text, action: action, source: source)
    }

    var hasWorkflowContext: Bool {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasSuccessfulResult && !isLoading && !trimmedSource.isEmpty && !trimmedResult.isEmpty
    }

    func runSelectedAction(_ action: CompanionAIQuickAction) {
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectedAction = action
            return
        }

        run(text, action: action, source: inputSource)
    }

    func rerunCurrentAction() {
        let text = sourceText
        guard !isLoading, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        run(text, action: selectedAction, source: inputSource)
    }

    func rerun(record: TranslationHistoryRecord) {
        guard !isLoading else { return }
        let action = record.replayAction
            ?? actionStore.action(for: record.actionID)
            ?? .translate
        isShowingHistory = false
        run(record.sourceText, action: action, source: record.inputSource)
    }

    func dispatchHistoryRecord(_ record: TranslationHistoryRecord, action: XiaoHuaErAIResultWorkflowAction) {
        let trimmedSource = record.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = record.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedResult.isEmpty else {
            return
        }

        guard let outcome = onAIResultWorkflowRequested?(XiaoHuaErAIResultWorkflowRequest(
            action: action,
            actionTitle: record.displayActionTitle,
            resultTitle: record.displayResultTitle,
            providerName: record.providerName,
            sourceText: record.sourceText,
            resultText: record.translatedText,
            createdAt: record.createdAt
        )) else {
            workflowStatusMessage = "操作暂时不可用"
            return
        }
        workflowStatusMessage = outcome.statusMessage
    }

    func addCustomAction(title: String, prompt: String) {
        actionStore.addCustomAction(title: title, prompt: prompt)
    }

    func updateCustomAction(_ action: CompanionAIQuickAction, title: String, prompt: String) {
        actionStore.updateCustomAction(id: action.id, title: title, prompt: prompt)
        if selectedAction.id == action.id,
           let updated = actionStore.action(for: action.id)
        {
            selectedAction = updated
        }
    }

    func deleteCustomAction(_ action: CompanionAIQuickAction) {
        guard action.isCustom else { return }
        actionStore.deleteCustomAction(id: action.id)
        if selectedAction.id == action.id {
            selectedAction = .translate
        }
    }

    func togglePinned(_ action: CompanionAIQuickAction) {
        guard action.isCustom else { return }
        actionStore.togglePinned(id: action.id)
        if selectedAction.id == action.id,
           let updated = actionStore.action(for: action.id)
        {
            selectedAction = updated
        }
    }

    func moveCustomAction(_ action: CompanionAIQuickAction, direction: Int) {
        guard action.isCustom else { return }
        actionStore.moveCustomAction(id: action.id, direction: direction)
    }

    func exportCustomActions() throws -> Data {
        try actionStore.exportCustomActions()
    }

    @discardableResult
    func importCustomActions(from data: Data) throws -> Int {
        try actionStore.importCustomActions(from: data)
    }

    func refreshAvailableActions() {
        availableActions = actionStore.allActions
    }

    private func run(_ text: String, action: CompanionAIQuickAction, source: CompanionAIInputSource) {
        guard text.count <= maxQuickActionInputCharacters else {
            task?.cancel()
            currentRequestID = nil
            sourceText = String(text.prefix(maxHistoryTextCharacters))
            translatedText = CompanionL10n.text("The selected text is too large for a quick action. Please shorten it and try again.")
            workflowStatusMessage = ""
            hasSuccessfulResult = false
            inputSource = source
            isLoading = false
            isShowingHistory = false
            selectedAction = action
            return
        }

        let requestID = UUID()
        sourceText = text
        translatedText = ""
        workflowStatusMessage = ""
        hasSuccessfulResult = false
        inputSource = source
        isLoading = true
        isShowingHistory = false
        selectedAction = action
        selectedWorkflowActions = []
        showingPlanPreview = false
        showingReminderTimeInput = false
        providerName = aiService.providerDisplayName()
        sourceLanguageLabel = action == .translate ? Self.languageLabel(for: text) : action.title
        task?.cancel()
        currentRequestID = requestID
        onAIActionStarted?()
        let service = aiService

        task = Task {
            do {
                let result = try await service.performQuickAction(action, text: text)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentRequestID == requestID, !Task.isCancelled else {
                        return
                    }
                    self.translatedText = result
                    self.hasSuccessfulResult = !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    self.isLoading = false
                    if self.autoCopyResult {
                        self.copyText(result, suppressClipboardPopup: true)
                    }
                    self.saveHistoryRecord(action: action, sourceText: text, translatedText: result, inputSource: source)
                    self.onAIActionCompleted?()
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentRequestID == requestID, !Task.isCancelled else {
                        return
                    }
                    self.translatedText = error.localizedDescription
                    self.hasSuccessfulResult = false
                    self.isLoading = false
                    self.onAIActionFinished?()
                }
            }
        }
    }

    func showEmptyMessage(_ message: String) {
        task?.cancel()
        task = nil
        currentRequestID = nil
        onAIActionFinished?()
        sourceText = ""
        translatedText = message
        isLoading = false
        isShowingHistory = false
        selectedAction = .translate
        workflowStatusMessage = ""
        hasSuccessfulResult = false
        providerName = aiService.providerDisplayName()
        sourceLanguageLabel = CompanionL10n.text("Auto Detect")
        inputSource = .manual
    }

    func cancelCurrentAction() {
        task?.cancel()
        task = nil
        currentRequestID = nil
        if isLoading {
            isLoading = false
            onAIActionFinished?()
        }
    }

    func copySource() {
        copy(sourceText)
    }

    func copyTranslation() {
        copy(translatedText)
    }

    func requestAssetUpload() {
        onAssetUploadRequested?()
    }

    func dispatchCurrentResult(_ action: XiaoHuaErAIResultWorkflowAction) {
        // 单选快路径（兼容现有调用）
        if action == .createReminder, reminderNeedsTimeInput() {
            showingReminderTimeInput = true
            return
        }
        dispatchWorkflow(with: [action])
    }

    func currentWorkflowRequest(action: XiaoHuaErAIResultWorkflowAction) -> XiaoHuaErAIResultWorkflowRequest? {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSuccessfulResult, !isLoading, !trimmedSource.isEmpty, !trimmedResult.isEmpty else {
            return nil
        }
        return XiaoHuaErAIResultWorkflowRequest(
            action: action,
            actionTitle: selectedAction.title,
            resultTitle: selectedAction.resultTitle,
            providerName: providerName,
            sourceText: sourceText,
            resultText: translatedText
        )
    }

    func dispatchSelectedWorkflowActions() {
        // 多选路径
        guard !selectedWorkflowActions.isEmpty else {
            return
        }
        dispatchWorkflow(with: selectedWorkflowActions)
    }

    private func dispatchWorkflow(with actions: Set<XiaoHuaErAIResultWorkflowAction>) {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSuccessfulResult, !isLoading, !trimmedSource.isEmpty, !trimmedResult.isEmpty else {
            return
        }

        // 如果是多选，显示计划预览
        if actions.count > 1 {
            showingPlanPreview = true
            return
        }

        // 单选直接执行
        guard let action = actions.first else {
            return
        }

        guard let outcome = onAIResultWorkflowRequested?(XiaoHuaErAIResultWorkflowRequest(
            action: action,
            actionTitle: selectedAction.title,
            resultTitle: selectedAction.resultTitle,
            providerName: providerName,
            sourceText: sourceText,
            resultText: translatedText
        )) else {
            workflowStatusMessage = "小花儿暂时不可用"
            return
        }
        workflowStatusMessage = outcome.statusMessage
    }

    func confirmPlanAndExecute() {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSuccessfulResult, !isLoading, !trimmedSource.isEmpty, !trimmedResult.isEmpty else {
            return
        }

        showingPlanPreview = false

        guard let outcome = onAIResultWorkflowRequested?(XiaoHuaErAIResultWorkflowRequest(
            actions: selectedWorkflowActions,
            actionTitle: selectedAction.title,
            resultTitle: selectedAction.resultTitle,
            providerName: providerName,
            sourceText: sourceText,
            resultText: translatedText
        )) else {
            workflowStatusMessage = "小花儿暂时不可用"
            return
        }
        workflowStatusMessage = outcome.statusMessage
    }

    func cancelPlan() {
        showingPlanPreview = false
    }

    func reminderTaskTitle(maxLength: Int = 60) -> String {
        let candidates = translatedText
            .components(separatedBy: .newlines)
            .map(Self.strippingWorkflowListPrefix)
            .filter { !$0.isEmpty }
        let rawTitle = candidates.first ?? selectedAction.resultTitle
        let collapsed = rawTitle
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed.isEmpty ? selectedAction.resultTitle : collapsed
        }
        let index = collapsed.index(collapsed.startIndex, offsetBy: max(1, maxLength - 1))
        return String(collapsed[..<index]) + "..."
    }

    func dispatchReminderWithTime(_ fireDate: Date) {
        showingReminderTimeInput = false
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSuccessfulResult, !isLoading, !trimmedSource.isEmpty, !trimmedResult.isEmpty else {
            return
        }
        let title = reminderTaskTitle()
        guard let outcome = onAIResultWorkflowRequested?(XiaoHuaErAIResultWorkflowRequest(
            action: .createReminder,
            actionTitle: selectedAction.title,
            resultTitle: selectedAction.resultTitle,
            providerName: providerName,
            sourceText: sourceText,
            resultText: translatedText,
            reminderTitle: title,
            reminderTime: fireDate
        )) else {
            workflowStatusMessage = "小花儿暂时不可用"
            return
        }
        workflowStatusMessage = outcome.statusMessage
    }

    func cancelReminderTimeInput() {
        showingReminderTimeInput = false
    }

    func openReminderDraftFromTimeInput() {
        showingReminderTimeInput = false
        dispatchWorkflow(with: [.createReminder])
    }

    func copy(record: TranslationHistoryRecord) {
        copy("""
        \(CompanionL10n.text("Source")):
        \(record.sourceText)

        \(record.displayResultTitle):
        \(record.translatedText)
        """)
    }

    private func copy(_ text: String) {
        copyText(text, suppressClipboardPopup: false)
    }

    private func copyText(_ text: String, suppressClipboardPopup: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if suppressClipboardPopup {
            ClipboardTranslationFeature.suppressPasteboardChange(NSPasteboard.general.changeCount)
        }
    }

    private func reminderNeedsTimeInput() -> Bool {
        let title = reminderTaskTitle()
        return PetReminderRuleParser.parse(title, now: Date(), calendar: .current) == nil
    }

    private static func strippingWorkflowListPrefix(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[\.)、]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveHistoryRecord(action: CompanionAIQuickAction, sourceText: String, translatedText: String, inputSource: CompanionAIInputSource) {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTranslation.isEmpty else {
            return
        }

        let record = TranslationHistoryRecord(
            action: action,
            sourceText: boundedHistoryText(sourceText),
            translatedText: boundedHistoryText(translatedText),
            providerName: providerName,
            sourceLanguageLabel: sourceLanguageLabel,
            inputSource: inputSource
        )

        // 内存里立即可见（UI 不卡）
        history.insert(record, at: 0)
        history = Array(history.prefix(maxHistoryRecords))

        if didLoadStoredHistory {
            // 磁盘历史已合并，可以安全地全量保存
            historyStore.save(history)
        } else {
            // 还没把磁盘历史读进来；先缓存等合并，避免覆盖磁盘
            pendingNewRecords.insert(record, at: 0)
        }
    }

    private func mergeStoredHistory(_ storedRecords: [TranslationHistoryRecord]) {
        // 已有 pending 的新记录放最前；与磁盘历史按 id 去重后拼接。
        let pendingIDs = Set(pendingNewRecords.map(\.id))
        let dedupedStored = storedRecords.filter { !pendingIDs.contains($0.id) }
        let merged = (pendingNewRecords + dedupedStored).prefix(maxHistoryRecords)
        history = Array(merged)
        didLoadStoredHistory = true

        // 用户在 load 完成前确实有新增 → 现在合并后写一次磁盘
        if !pendingNewRecords.isEmpty {
            historyStore.save(history)
            pendingNewRecords.removeAll()
        }
    }

    private func boundedHistoryText(_ text: String) -> String {
        guard text.count > maxHistoryTextCharacters else {
            return text
        }
        return String(text.prefix(maxHistoryTextCharacters)) + "\n[truncated]"
    }

    private static func languageLabel(for text: String) -> String {
        if text.unicodeScalars.contains(where: { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }) {
            return CompanionL10n.text("Detected Chinese")
        }

        if text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            return CompanionL10n.text("Detected English")
        }

        return CompanionL10n.text("Auto Detect")
    }
}

private struct TranslationPanelView: View {
    @ObservedObject var viewModel: TranslationViewModel
    let closeAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TranslationPanelTitle(
                isShowingHistory: viewModel.isShowingHistory,
                historyAction: {
                    viewModel.isShowingHistory.toggle()
                },
                closeAction: closeAction
            )

            if viewModel.isShowingHistory {
                TranslationHistoryView(viewModel: viewModel)
            } else {
                TranslationCurrentView(viewModel: viewModel)
            }
        }
        .padding(18)
        .frame(width: TranslationPanelLayout.width, height: viewModel.panelContentHeight)
        .companionGlassPanel(radius: 34, liquidOpacity: 0.18, shadowRadius: 30, shadowOpacity: 0.35)
    }
}

enum TranslationStyle {
    static let sectionBackground = Color.white
    static let fieldBorder = Color.gray.opacity(0.46)
    static let fieldText = Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1))
    static let fieldSecondaryText = Color(nsColor: NSColor(calibratedWhite: 0.38, alpha: 1))
    static let sectionRadius: CGFloat = 12
}

private struct TranslationPanelTitle: View {
    let isShowingHistory: Bool
    let historyAction: () -> Void
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            WindowDragRegion()
            Text(CompanionL10n.text("Translate"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)

            HStack {
                TranslationCloseButton(action: closeAction)
                    .padding(.leading, 4)

                Spacer()

                Button(isShowingHistory ? CompanionL10n.text("Back") : CompanionL10n.text("History"), action: historyAction)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 82, height: 30))
                    .padding(.trailing, 1)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 52)
    }
}

private struct TranslationCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(XiaoHuaErTheme.coral)
                    .overlay(
                        Circle()
                            .stroke(XiaoHuaErTheme.border, lineWidth: 0.8)
                    )

                Image(systemName: "xmark")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .opacity(isHovered ? 1 : 0)
            }
            .frame(width: 11, height: 11)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 34)
        .help(CompanionL10n.text("Close"))
        .accessibilityLabel(Text(CompanionL10n.text("Close AI Actions Window")))
        .onHover { isHovered = $0 }
    }
}

private struct TranslationCurrentView: View {
    @ObservedObject var viewModel: TranslationViewModel

    private var paneHeights: (source: CGFloat, result: CGFloat) {
        TranslationPanelLayout.paneHeights(
            sourceText: viewModel.sourceText,
            translatedText: viewModel.translatedText,
            isLoading: viewModel.isLoading,
            panelHeight: viewModel.panelContentHeight
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            TranslationSourcePane(
                text: $viewModel.sourceText,
                onSubmit: viewModel.rerunCurrentAction
            )
            .frame(height: paneHeights.source)

            HStack(spacing: 8) {
                CompanionStatusTag(title: CompanionL10n.format("Source: %@", viewModel.inputSource.title), tint: XiaoHuaErTheme.sky)
                Spacer()
                Toggle(CompanionL10n.text("Auto Copy Result"), isOn: $viewModel.autoCopyResult)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .disabled(viewModel.isLoading)
            }
            .frame(height: 22)
            .padding(.horizontal, 2)

            AIQuickActionBar(
                actions: viewModel.availableActions,
                selectedAction: viewModel.selectedAction,
                isLoading: viewModel.isLoading,
                selectAction: viewModel.runSelectedAction,
                addAction: viewModel.addCustomAction,
                updateAction: viewModel.updateCustomAction,
                deleteAction: viewModel.deleteCustomAction,
                moveAction: viewModel.moveCustomAction,
                togglePinAction: viewModel.togglePinned,
                exportTemplates: viewModel.exportCustomActions,
                importTemplates: viewModel.importCustomActions
            )

            TranslationResultPane(
                action: viewModel.selectedAction,
                providerName: viewModel.providerName,
                translatedText: viewModel.translatedText,
                isLoading: viewModel.isLoading,
                workflowStatusMessage: viewModel.workflowStatusMessage,
                hasSuccessfulResult: viewModel.hasSuccessfulResult,
                copyAction: viewModel.copyTranslation,
                rerunAction: viewModel.rerunCurrentAction,
                saveToJournalAction: {
                    viewModel.dispatchCurrentResult(.saveToJournal)
                },
                uploadAssetAction: viewModel.requestAssetUpload
            )
            .frame(height: paneHeights.result)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TranslationSourcePane: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            TranslationInputTextView(
                text: $text,
                placeholder: "输入或粘贴要处理的内容",
                onSubmit: onSubmit
            )
        }
        .background(TranslationStyle.sectionBackground, in: RoundedRectangle(cornerRadius: TranslationStyle.sectionRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TranslationStyle.sectionRadius, style: .continuous)
                .stroke(TranslationStyle.fieldBorder, lineWidth: 1)
        )
    }
}

private struct TranslationInputTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> TranslationInputContainerView {
        let container = TranslationInputContainerView(placeholder: placeholder)
        container.textView.delegate = context.coordinator
        container.textView.onSubmit = {
            context.coordinator.submit()
        }
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: TranslationInputContainerView, context: Context) {
        if container.textView.string != text, !container.textView.hasMarkedText() {
            container.textView.string = text
        }
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        container.updatePlaceholder()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        weak var container: TranslationInputContainerView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
            container?.updatePlaceholder()
        }

        func submit() {
            text.wrappedValue = container?.textView.string ?? text.wrappedValue
            onSubmit()
        }
    }
}

private final class TranslationInputContainerView: NSView {
    let textView = TranslationInputNSTextView()
    private let scrollView = NSScrollView()
    private let placeholderLabel: NSTextField

    init(placeholder: String) {
        placeholderLabel = NSTextField(labelWithString: placeholder)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        if #available(macOS 10.12.2, *) {
            textView.isAutomaticTextCompletionEnabled = false
        }

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = NSColor(calibratedWhite: 0.46, alpha: 1)
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.isSelectable = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        textView.frame = scrollView.contentView.bounds
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollView.contentView.bounds.width - 24),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
    }
}

private final class TranslationInputNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,
           !hasMarkedText(),
           event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }
}

private struct TranslationResultPane: View {
    let action: CompanionAIQuickAction
    let providerName: String
    let translatedText: String
    let isLoading: Bool
    let workflowStatusMessage: String
    let hasSuccessfulResult: Bool
    let copyAction: () -> Void
    let rerunAction: () -> Void
    let saveToJournalAction: () -> Void
    let uploadAssetAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(action == .translate ? XiaoHuaErTheme.tint : XiaoHuaErTheme.plum)
                    .frame(width: 16, height: 16)
                    .background(
                        XiaoHuaErTheme.actionFill(action == .translate ? XiaoHuaErTheme.tint : XiaoHuaErTheme.plum),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                Text("\(providerName) \(action.resultTitle)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(TranslationStyle.fieldText)

                Spacer()
            }
            .layoutPriority(2)

            resultContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(0)

            if !workflowStatusMessage.isEmpty {
                Text(workflowStatusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(XiaoHuaErTheme.tint)
                    .lineLimit(1)
                    .padding(.leading, 2)
                    .layoutPriority(2)
            }

            HStack(spacing: 14) {
                Spacer()
                Button(action: {}) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 14, weight: .regular))
                }
                .disabled(true)
                .help(CompanionL10n.text("Read Aloud"))

                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .regular))
                }
                .disabled(translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(CompanionL10n.text("Copy"))

                Button(action: rerunAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .regular))
                }
                .disabled(isLoading)
                .help(CompanionL10n.text("Run Again"))

                Button(action: saveToJournalAction) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .regular))
                }
                .disabled(isLoading || !hasSuccessfulResult)
                .help(CompanionL10n.text("Save to Journal"))

                Button(action: uploadAssetAction) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 14, weight: .regular))
                }
                .disabled(isLoading)
                .help(CompanionL10n.text("Upload Image"))
                Spacer()
            }
            .frame(height: 34)
            .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 30))
            .foregroundStyle(Color.secondary)
            .layoutPriority(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TranslationStyle.sectionBackground, in: RoundedRectangle(cornerRadius: TranslationStyle.sectionRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TranslationStyle.sectionRadius, style: .continuous)
                .stroke(TranslationStyle.fieldBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var resultContent: some View {
        if isLoading {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(CompanionL10n.format("Running %@...", action.title))
                    .font(.system(size: 13))
                    .foregroundStyle(TranslationStyle.fieldSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                Text(translatedText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(TranslationStyle.fieldText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(CompanionL10n.text("Copy"), action: copyAction)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TranslationHistoryView: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        Group {
            if viewModel.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.secondary)
                    Text(CompanionL10n.text("No AI action history yet"))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TranslationStyle.sectionBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.history) { record in
                            TranslationHistoryRow(
                                record: record,
                                copyAction: {
                                    viewModel.copy(record: record)
                                },
                                rerunAction: {
                                    viewModel.rerun(record: record)
                                },
                                aiAction: { action in
                                    viewModel.dispatchHistoryRecord(record, action: action)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .background(TranslationStyle.sectionBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranslationHistoryRow: View {
    let record: TranslationHistoryRecord
    let copyAction: () -> Void
    let rerunAction: () -> Void
    let aiAction: (XiaoHuaErAIResultWorkflowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.displayActionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.tint)
                Text(record.providerName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.primary)
                Text(Self.dateString(for: record.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Menu {
                    Button(XiaoHuaErAIResultWorkflowAction.saveToJournal.displayName) {
                        aiAction(.saveToJournal)
                    }
                    Button(XiaoHuaErAIResultWorkflowAction.createReminder.displayName) {
                        aiAction(.createReminder)
                    }
                    Button(XiaoHuaErAIResultWorkflowAction.startFocus.displayName) {
                        aiAction(.startFocus)
                    }
                } label: {
                    Text("AI Actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(TranslationStyle.fieldBorder, lineWidth: 1)
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("AI Actions")

                Button(action: rerunAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help(CompanionL10n.text("Run Again"))
                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help(CompanionL10n.text("Copy This Record"))
            }

            Text(record.sourceText)
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(record.translatedText)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(9)
        .background(XiaoHuaErTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 1)
        )
    }

    private static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableWindowRegionView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableWindowRegionView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
