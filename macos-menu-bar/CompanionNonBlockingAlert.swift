import AppKit
import SwiftUI

enum CompanionNonBlockingAlert {
    private static var activePanels: [NSPanel] = []

    static func present(messageText: String, informativeText: String, tone: CompanionAlertTone = .info) {
        #if COMPANION_TESTING
        NSLog("Companion test suppressed alert: \(messageText) - \(informativeText)")
        #else
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = messageText
            alert.informativeText = informativeText
            alert.alertStyle = tone.alertStyle
            alert.addButton(withTitle: CompanionL10n.text("OK"))
            alert.buttons.first?.keyEquivalent = "\r"
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        #endif
    }

    static func choose(
        messageText: String,
        informativeText: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil,
        cancelButtonTitle: String = CompanionL10n.text("Cancel"),
        tone: CompanionAlertTone = .info
    ) -> CompanionAlertChoice {
        #if COMPANION_TESTING
        NSLog("Companion test suppressed choice alert: \(messageText) - \(informativeText)")
        return .cancel
        #else
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = tone.alertStyle
        alert.addButton(withTitle: primaryButtonTitle)
        if let secondaryButtonTitle {
            alert.addButton(withTitle: secondaryButtonTitle)
        }
        alert.addButton(withTitle: cancelButtonTitle)
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            return .primary
        case .alertSecondButtonReturn:
            return secondaryButtonTitle == nil ? .cancel : .secondary
        case .alertThirdButtonReturn:
            return .cancel
        default:
            return .cancel
        }
        #endif
    }

    static func confirm(
        messageText: String,
        informativeText: String,
        primaryButtonTitle: String,
        cancelButtonTitle: String = CompanionL10n.text("Cancel"),
        tone: CompanionAlertTone = .warning
    ) -> Bool {
        choose(
            messageText: messageText,
            informativeText: informativeText,
            primaryButtonTitle: primaryButtonTitle,
            cancelButtonTitle: cancelButtonTitle,
            tone: tone
        ) == .primary
    }

    static func promptText(
        messageText: String,
        informativeText: String,
        initialValue: String = "",
        placeholder: String = "",
        primaryButtonTitle: String = CompanionL10n.text("Save"),
        cancelButtonTitle: String = CompanionL10n.text("Cancel"),
        tone: CompanionAlertTone = .info
    ) -> String? {
        #if COMPANION_TESTING
        NSLog("Companion test suppressed text prompt: \(messageText) - \(informativeText)")
        return nil
        #else
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = tone.alertStyle
        alert.addButton(withTitle: primaryButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = initialValue
        input.placeholderString = placeholder
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.window.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
        #endif
    }

    private static func panelSize(messageText: String, informativeText: String) -> NSSize {
        let width: CGFloat = 460
        let estimatedLines = max(1, Int(ceil(Double(informativeText.count) / 56.0)))
        let messageHeight = min(CGFloat(estimatedLines) * 18, 126)
        let titleLines = max(1, Int(ceil(Double(messageText.count) / 24.0)))
        let titleHeight = CGFloat(titleLines) * 26
        return NSSize(width: width, height: max(178, 92 + titleHeight + messageHeight))
    }

    private static func installContent<Content: View>(_ rootView: Content, in panel: NSPanel, size: NSSize) {
        let hostingView = CompanionInteractiveHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(size)
    }
}

enum CompanionModalPanelStyle {
    static let whiteBackplateColor = NSColor(calibratedWhite: 1.0, alpha: 1.0)

    static func applyPopupWindowChrome(to window: NSWindow) {
        window.backgroundColor = .clear
        window.isOpaque = false
    }

    static func makePanel(contentRect: NSRect, title: String) -> NSPanel {
        let panel = CompanionModalPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        applyPopupWindowChrome(to: panel)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = {
            NSApp.stopModal(withCode: .cancel)
        }
        return panel
    }

    static func installModalCancelHandler(_ handler: @escaping () -> Void, in panel: NSPanel) {
        (panel as? CompanionModalPanel)?.onCancel = handler
    }

    static func installGlassContent(_ content: NSView, in panel: NSPanel, cornerRadius: CGFloat = 24) {
        let container = CompanionModalChromeView(cornerRadius: cornerRadius)
        let background = NSView()

        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.backgroundColor = whiteBackplateColor.cgColor
        container.addSubview(background)

        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        panel.contentView = container

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func styleModalButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    static func makeButtonRow(
        leadingButtons: [NSButton] = [],
        trailingButtons: [NSButton]
    ) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let allButtons = leadingButtons + trailingButtons
        allButtons.forEach { button in
            styleModalButton(button)
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        }

        let row = NSStackView(views: leadingButtons + [spacer] + trailingButtons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return row
    }
}

private final class CompanionModalPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func close() {
        onCancel = nil
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            close()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private final class CompanionModalChromeView: NSView {
    private let modalCornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.modalCornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = modalCornerRadius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerStyle()
    }

    private func updateLayerStyle() {
        layer?.backgroundColor = CompanionModalPanelStyle.whiteBackplateColor.cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.08).cgColor
    }
}

private struct CompanionFloatingTextInputAlertView: View {
    let title: String
    let message: String
    let initialValue: String
    let placeholder: String
    let tone: CompanionAlertTone
    let primaryButtonTitle: String
    let cancelButtonTitle: String
    let submitAction: (String) -> Void
    let cancelAction: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        message: String,
        initialValue: String,
        placeholder: String,
        tone: CompanionAlertTone,
        primaryButtonTitle: String,
        cancelButtonTitle: String,
        submitAction: @escaping (String) -> Void,
        cancelAction: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.initialValue = initialValue
        self.placeholder = placeholder
        self.tone = tone
        self.primaryButtonTitle = primaryButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
        self.submitAction = submitAction
        self.cancelAction = cancelAction
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tone.accent.opacity(0.16))
                    Image(systemName: tone.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tone.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 1)
                )
                .focused($isFocused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button(cancelButtonTitle, action: cancelAction)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 78, height: 34))
                    .keyboardShortcut(.cancelAction)
                Button(primaryButtonTitle, action: submit)
                    .buttonStyle(CompanionGlassButtonStyle(tone: tone.primaryButtonTone, minWidth: 88, height: 34))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedText.isEmpty)
                    .opacity(trimmedText.isEmpty ? 0.55 : 1)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .companionGlassPanel(radius: 28, liquidOpacity: 0.20, shadowRadius: 28, shadowOpacity: 0.36)
        .onAppear {
            isFocused = true
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let value = trimmedText
        guard !value.isEmpty else { return }
        submitAction(value)
    }
}

private final class CompanionAlertPanel: NSPanel {
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func close() {
        onClose?()
        onClose = nil
        onCancel = nil
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            close()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc func closeFromButton(_ sender: Any?) {
        close()
    }
}

enum CompanionAlertChoice {
    case primary
    case secondary
    case cancel

    fileprivate var modalResponse: NSApplication.ModalResponse {
        switch self {
        case .primary:
            return .OK
        case .secondary:
            return .continue
        case .cancel:
            return .cancel
        }
    }
}

enum CompanionAlertTone {
    case info
    case success
    case warning
    case danger

    var alertStyle: NSAlert.Style {
        switch self {
        case .info, .success:
            return .informational
        case .warning:
            return .warning
        case .danger:
            return .critical
        }
    }

    var accent: Color {
        switch self {
        case .info:
            return XiaoHuaErTheme.tint
        case .success:
            return XiaoHuaErTheme.leaf
        case .warning:
            return XiaoHuaErTheme.amber
        case .danger:
            return XiaoHuaErTheme.coral
        }
    }

    var symbolName: String {
        switch self {
        case .info:
            return "sparkles"
        case .success:
            return "checkmark"
        case .warning:
            return "exclamationmark"
        case .danger:
            return "xmark"
        }
    }

    var primaryButtonTone: CompanionGlassButtonTone {
        switch self {
        case .warning:
            return .amber
        case .danger:
            return .danger
        case .info, .success:
            return .primary
        }
    }
}

private struct CompanionFloatingAlertView: View {
    let title: String
    let message: String
    let tone: CompanionAlertTone
    var closeAction: (() -> Void)?
    var primaryButtonTitle: String?
    var secondaryButtonTitle: String?
    var cancelButtonTitle: String?
    var chooseAction: ((CompanionAlertChoice) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tone.accent.opacity(0.16))
                    Image(systemName: tone.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tone.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if message.count > 260 {
                        ScrollView(.vertical) {
                            Text(message)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 126, alignment: .top)
                    } else {
                        Text(message)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack {
                Spacer()
                if let chooseAction {
                    Button(cancelButtonTitle ?? CompanionL10n.text("Cancel")) {
                        chooseAction(.cancel)
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 78, height: 34))
                    .keyboardShortcut(.cancelAction)

                    if let secondaryButtonTitle {
                        Button(secondaryButtonTitle) {
                            chooseAction(.secondary)
                        }
                        .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 112, height: 34))
                    }

                    Button(primaryButtonTitle ?? CompanionL10n.text("OK")) {
                        chooseAction(.primary)
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: tone.primaryButtonTone, minWidth: 88, height: 34))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(CompanionL10n.text("OK"), action: closeAction ?? {})
                        .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 84, height: 34))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .companionGlassPanel(radius: 28, liquidOpacity: 0.20, shadowRadius: 28, shadowOpacity: 0.36)
    }
}
