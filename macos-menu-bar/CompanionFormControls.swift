import AppKit

enum CompanionFormEditMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
        return menu
    }
}

final class FormTextFieldCell: NSTextFieldCell {
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 6

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let inset = rect.insetBy(dx: horizontalPadding, dy: verticalPadding)
        let height = cellSize(forBounds: rect).height
        let y = inset.origin.y + max(0, (inset.height - height) / 2)
        return NSRect(x: inset.origin.x, y: y, width: inset.width, height: height)
    }

    // 让 placeholder / 文本 / field editor 三者使用完全相同的绘制矩形,
    // 聚焦进入编辑态时文字不再跳动。
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        drawingRect(forBounds: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

final class FormTextField: NSTextField {
    private var showsFocusStyle = false

    init(placeholder: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 496, height: 40))
        let formCell = FormTextFieldCell(textCell: "")
        formCell.isScrollable = true
        formCell.wraps = false
        formCell.usesSingleLineMode = true
        formCell.lineBreakMode = .byClipping
        cell = formCell
        placeholderString = placeholder
        font = .systemFont(ofSize: 14)
        isEditable = true
        isSelectable = true
        isEnabled = true
        // 不用系统 .roundedBezel(在 40pt 高度下既丑又会和自定义 padding 打架),
        // 改为自绘圆角背景 + 边框,聚焦时高亮边框代替系统 focus ring。
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        menu = CompanionFormEditMenu.make()
        refusesFirstResponder = false
        isAutomaticTextCompletionEnabled = false
        applyStyle(focused: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 40)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 9
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            applyStyle(focused: true)
        }
        return didBecome
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        applyStyle(focused: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle(focused: showsFocusStyle)
    }

    private func applyStyle(focused: Bool) {
        showsFocusStyle = focused
        wantsLayer = true
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.cornerRadius = 9
        layer?.borderWidth = focused ? 2 : 1
        layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.06)
            : NSColor(calibratedWhite: 1.0, alpha: 0.90)
        ).cgColor
        layer?.borderColor = focused
            ? NSColor.controlAccentColor.cgColor
            : (isDark
                ? NSColor(calibratedWhite: 1.0, alpha: 0.18)
                : NSColor(calibratedWhite: 0.0, alpha: 0.14)
            ).cgColor
    }
}
