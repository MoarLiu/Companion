import AppKit
import Combine
import Foundation
import SwiftUI

final class PetChatWindowController {
    private let viewModel: PetChatViewModel
    private let inputFocusBridge = ChatInputFocusBridge()
    private var window: NSWindow?
    private var didBecomeKeyObserver: NSObjectProtocol?
    private var willCloseObserver: NSObjectProtocol?
    var onReminderFocusJournalRequested: ((String) -> String)? {
        didSet {
            viewModel.onReminderFocusJournalRequested = onReminderFocusJournalRequested
        }
    }
    var onAIResultWorkflowRequested: ((XiaoHuaErAIResultWorkflowAction) -> String?)? {
        didSet {
            viewModel.onAIResultWorkflowRequested = onAIResultWorkflowRequested
        }
    }
    var hasAIResultWorkflowContext: (() -> Bool)? {
        didSet {
            viewModel.hasAIResultWorkflowContext = hasAIResultWorkflowContext
        }
    }

    init(aiService: CompanionAIService) {
        self.viewModel = PetChatViewModel(aiService: aiService, historyStore: PetChatHistoryStore())
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
        }
    }

    func show(relativeTo anchorWindow: NSWindow?, title: String) {
        let window = existingOrNewWindow()
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Companion" : title
        window.title = displayTitle
        viewModel.companionName = displayTitle

        if let anchorWindow, !window.isVisible {
            position(window, near: anchorWindow)
        } else if !window.isVisible {
            window.center()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if window.isKeyWindow {
            focusInput(in: window)
        }
    }

    func showAndSend(text: String, relativeTo anchorWindow: NSWindow?, title: String) {
        show(relativeTo: anchorWindow, title: title)
        viewModel.send(text: text)
    }

    private func focusInput(in window: NSWindow) {
        if !inputFocusBridge.focus(in: window) {
            window.initialFirstResponder = nil
        }
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window {
            return window
        }

        let view = PetChatView(viewModel: viewModel, inputFocusBridge: inputFocusBridge)
        let window = PetChatWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Companion"
        window.minSize = NSSize(width: 640, height: 500)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = CompanionInteractiveHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        self.window = window
        installWindowObservers(for: window)
        return window
    }

    private func installWindowObservers(for window: NSWindow) {
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.focusInput(in: window)
        }

        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func position(_ window: NSWindow, near anchorWindow: NSWindow) {
        let size = window.frame.size
        let anchor = anchorWindow.frame
        let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let rawOrigin = CGPoint(
            x: anchor.maxX + 18,
            y: anchor.midY - size.height / 2
        )
        let fallbackX = anchor.minX - size.width - 18
        let x = rawOrigin.x + size.width <= visibleFrame.maxX ? rawOrigin.x : fallbackX
        let origin = CGPoint(
            x: min(max(x, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12),
            y: min(max(rawOrigin.y, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
        )
        window.setFrameOrigin(origin)
    }
}

private final class PetChatWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            performClose(nil)
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            performClose(nil)
            return
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

private final class PetChatViewModel: ObservableObject {
    @Published var companionName = "Companion"
    @Published var messages: [CompanionAIChatMessage]
    @Published var draft = ""
    @Published var isSending = false

    private let aiService: CompanionAIService
    private let historyStore: PetChatHistoryStore
    private var didLoadStoredHistory = false
    private var pendingNewMessages: [CompanionAIChatMessage] = []
    private var transientMessageIDs = Set<UUID>()
    private let initialGreetingID: UUID
    private let maxModelContextMessages = 40
    var onReminderFocusJournalRequested: ((String) -> String)?
    var onAIResultWorkflowRequested: ((XiaoHuaErAIResultWorkflowAction) -> String?)?
    var hasAIResultWorkflowContext: (() -> Bool)?

    init(aiService: CompanionAIService, historyStore: PetChatHistoryStore) {
        self.aiService = aiService
        self.historyStore = historyStore
        let greeting = CompanionAIChatMessage(role: .assistant, text: "你好，我在。想聊点什么？")
        self.initialGreetingID = greeting.id
        self.messages = [greeting]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let storedMessages = historyStore.load()
            DispatchQueue.main.async {
                self?.mergeStoredHistory(storedMessages)
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }

        draft = ""
        messages.append(CompanionAIChatMessage(role: .user, text: text))
        saveHistory()

        if let reply = localRestrictedReply(for: text) {
            messages.append(CompanionAIChatMessage(role: .assistant, text: reply, companionName: companionName))
            saveHistory()
            return
        }

        isSending = true
        let conversation = modelContextMessages()
        let service = aiService
        let currentCompanionName = companionName

        Task {
            do {
                let reply = try await service.chat(messages: conversation)
                await MainActor.run {
                    self.messages.append(CompanionAIChatMessage(role: .assistant, text: reply, companionName: currentCompanionName))
                    self.isSending = false
                    self.saveHistory()
                }
            } catch {
                await MainActor.run {
                    let errorMessage = CompanionAIChatMessage(role: .assistant, text: error.localizedDescription, companionName: currentCompanionName)
                    self.transientMessageIDs.insert(errorMessage.id)
                    self.messages.append(errorMessage)
                    self.isSending = false
                }
            }
        }
    }

    func send(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        draft = text
        send()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveHistory() {
        let persistableMessages = messages.filter { !transientMessageIDs.contains($0.id) }
        if didLoadStoredHistory {
            historyStore.save(persistableMessages)
            return
        }

        var pendingIDs = Set(pendingNewMessages.map(\.id))
        for message in persistableMessages where message.id != initialGreetingID && !pendingIDs.contains(message.id) {
            pendingNewMessages.append(message)
            pendingIDs.insert(message.id)
        }
    }

    private func mergeStoredHistory(_ storedMessages: [CompanionAIChatMessage]) {
        didLoadStoredHistory = true
        guard !pendingNewMessages.isEmpty else {
            if !storedMessages.isEmpty {
                messages = storedMessages
            }
            return
        }

        let pendingIDs = Set(pendingNewMessages.map(\.id))
        let dedupedStored = storedMessages.filter { !pendingIDs.contains($0.id) }
        if dedupedStored.isEmpty {
            messages = [messages.first { $0.id == initialGreetingID }].compactMap { $0 } + pendingNewMessages
        } else {
            messages = Array((dedupedStored + pendingNewMessages).suffix(200))
        }
        pendingNewMessages.removeAll()
        historyStore.save(messages)
    }

    private func modelContextMessages() -> [CompanionAIChatMessage] {
        Array(messages.filter { !transientMessageIDs.contains($0.id) }.suffix(maxModelContextMessages))
    }

    private func localRestrictedReply(for text: String) -> String? {
        let resolution = CompanionRestrictedNLRouteResolver().resolve(
            text,
            context: CompanionRestrictedNLRouteContext(hasAIResult: hasAIResultWorkflowContext?() ?? false)
        )
        switch resolution {
        case .command(let command):
            return execute(command, originalText: text)
        case .clarification(_, let message), .supportedRoutines(_, let message):
            return message
        case .noRoute:
            return nil
        }
    }

    private func execute(_ command: CompanionRestrictedNLCommand, originalText: String) -> String {
        switch command.templateID {
        case "reminder-focus-journal":
            return onReminderFocusJournalRequested?(originalText)
                ?? "我能识别“提醒 → 专注 → 日记”，但当前 routine 入口暂时不可用。"
        case "ai-result-dispatch":
            guard let action = command.action?.workflowAction else {
                return CompanionRestrictedNLRouteResolver.supportedRoutineMessage
            }
            return onAIResultWorkflowRequested?(action) ?? CompanionRestrictedNLRouteResolver.missingAIResultMessage
        default:
            return CompanionRestrictedNLRouteResolver.supportedRoutineMessage
        }
    }
}

private extension CompanionRestrictedNLRouteAction {
    var workflowAction: XiaoHuaErAIResultWorkflowAction {
        switch self {
        case .saveToJournal:
            return .saveToJournal
        case .createReminder:
            return .createReminder
        case .startFocus:
            return .startFocus
        }
    }
}

private final class PetChatHistoryStore {
    private struct Payload: Codable {
        var messages: [CompanionAIChatMessage]
    }

    private let maxStoredMessages = 200
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "companion.chat-history", qos: .utility)

    private var historyURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("chat_history.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [CompanionAIChatMessage] {
        guard
            fileManager.fileExists(atPath: historyURL.path),
            let data = try? Data(contentsOf: historyURL),
            !data.isEmpty
        else {
            return []
        }

        if let payload = try? decoder.decode(Payload.self, from: data) {
            return Array(payload.messages.suffix(maxStoredMessages))
        }

        if let messages = try? decoder.decode([CompanionAIChatMessage].self, from: data) {
            return Array(messages.suffix(maxStoredMessages))
        }

        return []
    }

    func save(_ messages: [CompanionAIChatMessage]) {
        let snapshot = Array(messages.suffix(maxStoredMessages))
        saveQueue.async { [weak self] in
            guard let self else { return }
            do {
                try fileManager.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try encoder.encode(Payload(messages: snapshot))
                try data.write(to: historyURL, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
            } catch {
                NSLog("Companion chat history save failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct PetChatView: View {
    @ObservedObject var viewModel: PetChatViewModel
    let inputFocusBridge: ChatInputFocusBridge
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 24) {
            toolbar

            VStack(alignment: .leading, spacing: 22) {
                Text("对话")
                    .font(.system(size: 22, weight: .semibold))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                ChatMessageBubble(
                                    message: message,
                                    companionName: viewModel.companionName,
                                    copyAction: { viewModel.copy(message.text) }
                                )
                                .id(message.id)
                            }

                            if viewModel.isSending {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在回复...")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onReceive(viewModel.$messages.map(\.count).removeDuplicates()) { _ in
                        if let lastID = viewModel.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack(spacing: 14) {
                    ChatInputField(
                        text: $viewModel.draft,
                        focusBridge: inputFocusBridge,
                        onSubmit: viewModel.send
                    )
                    .frame(height: 42)
                    .companionGlassField(radius: 21)

                    Button(action: viewModel.send) {
                        Label("发送", systemImage: "return")
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 70))
                    .disabled(viewModel.isSending || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送")
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .companionGlassSurface(radius: 30)
        }
        .padding(36)
        .padding(.top, 22)
        .frame(minWidth: 640, minHeight: 500)
        .background(CompanionLiquidWindowBackground())
        .background(CompanionWindowAccessor { window = $0 })
        .environment(\.companionWindow, window)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var toolbar: some View {
        HStack {
            CompanionTrafficLights()

            Text(viewModel.companionName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(height: 46)
        .companionGlassSurface(radius: 23)
    }
}

private struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    let focusBridge: ChatInputFocusBridge
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> ChatInputContainerView {
        let container = ChatInputContainerView()
        container.textView.delegate = context.coordinator
        container.textView.onSubmit = {
            context.coordinator.submit()
        }
        context.coordinator.container = container
        focusBridge.container = container
        return container
    }

    func updateNSView(_ container: ChatInputContainerView, context: Context) {
        if container.textView.string != text, !container.textView.hasMarkedText() {
            container.textView.string = text
        }

        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        container.updatePlaceholder()
        focusBridge.container = container
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        weak var container: ChatInputContainerView?

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

private final class ChatInputFocusBridge {
    weak var container: ChatInputContainerView?

    @discardableResult
    func focus(in window: NSWindow? = nil) -> Bool {
        guard let container else {
            return false
        }

        return container.focusTextView(in: window)
    }
}

private final class ChatInputContainerView: NSView {
    let textView = ChatInputTextView()
    private let scrollView = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "输入消息...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 21
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 15)
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
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .systemFont(ofSize: 15)
        placeholderLabel.isSelectable = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
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
            width: scrollView.contentView.bounds.width - 24,
            height: scrollView.contentView.bounds.height
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    @discardableResult
    func focusTextView(in requestedWindow: NSWindow? = nil) -> Bool {
        guard let targetWindow = requestedWindow ?? window else {
            return false
        }

        targetWindow.makeKey()
        targetWindow.initialFirstResponder = textView
        targetWindow.makeFirstResponder(textView)
        return targetWindow.firstResponder === textView
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
    }
}

private final class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() {
            window?.performClose(nil)
            return
        }

        if event.keyCode == 36,
           !hasMarkedText(),
           !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }
}

private struct ChatMessageBubble: View {
    let message: CompanionAIChatMessage
    let companionName: String
    let copyAction: () -> Void

    private var isUser: Bool {
        message.role == .user
    }

    private var displayName: String {
        if isUser {
            return "你"
        }

        let storedName = message.companionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedName?.isEmpty == false ? storedName! : companionName
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser {
                Spacer(minLength: 48)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: copyAction) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help("复制")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isUser ? XiaoHuaErTheme.tint.opacity(0.18) : Color.white.opacity(0.58))
                        .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.22), radius: 16, x: 0, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
                )
                .contextMenu {
                    Button("复制", action: copyAction)
                }
            }

            if !isUser {
                Spacer(minLength: 48)
            }
        }
    }
}
