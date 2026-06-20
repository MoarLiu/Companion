import AppKit
import ApplicationServices
import Foundation

enum CompanionAccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func request() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}

struct CompanionSelectionSnapshot: Equatable {
    let text: String
    let anchor: CGPoint
    let appName: String?
}

private struct CompanionSelectionReadAnchor {
    let panelAnchor: CGPoint
    let accessibilityHitPoint: CGPoint
}

final class CompanionSelectionMonitor {
    var onSelectionChanged: ((CompanionSelectionSnapshot?) -> Void)?
    var shouldIgnoreMouseDown: ((CGPoint) -> Bool)?

    private let reader = CompanionSelectionReader()
    private let readQueue = DispatchQueue(label: "com.crazyjal.companion.selection-read", qos: .userInitiated)
    private var monitors: [Any] = []
    private var pendingRead: DispatchWorkItem?
    private var pendingReadID = UUID()
    private var mouseDownLocation: CGPoint?
    private var draggedSinceMouseDown = false
    private static let readRetryDelays: [TimeInterval] = [0.12, 0.18, 0.28]

    var isRunning: Bool {
        !monitors.isEmpty
    }

    func start() {
        guard monitors.isEmpty else {
            return
        }

        guard CompanionAccessibilityPermission.isTrusted else {
            return
        }

        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .keyUp
        ]

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        pendingRead?.cancel()
        pendingRead = nil
        pendingReadID = UUID()

        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }

        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let mouseLocation = NSEvent.mouseLocation
            if shouldIgnoreMouseDown?(mouseLocation) == true {
                return
            }

            mouseDownLocation = mouseLocation
            draggedSinceMouseDown = false
            onSelectionChanged?(nil)

        case .leftMouseDragged:
            draggedSinceMouseDown = true

        case .leftMouseUp:
            let shouldRead = draggedSinceMouseDown || event.clickCount >= 2 || mouseMovedEnough()
            mouseDownLocation = nil
            draggedSinceMouseDown = false

            if shouldRead {
                scheduleRead(anchor: currentReadAnchor())
            }

        case .rightMouseDown:
            onSelectionChanged?(nil)

        case .keyUp:
            if shouldReadAfterKeyUp(event) {
                scheduleRead(anchor: currentReadAnchor())
            }

        default:
            break
        }
    }

    private func mouseMovedEnough() -> Bool {
        guard let mouseDownLocation else {
            return false
        }

        let mouseLocation = NSEvent.mouseLocation
        let distance = hypot(mouseLocation.x - mouseDownLocation.x, mouseLocation.y - mouseDownLocation.y)
        return distance > 4
    }

    private func shouldReadAfterKeyUp(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .command, .option])
        let keyCode = event.keyCode
        if flags.contains(.command), keyCode == 0 { // Command-A
            return true
        }
        if flags.contains(.shift), [123, 124, 125, 126].contains(keyCode) { // Arrow keys
            return true
        }
        return false
    }

    private func currentReadAnchor() -> CompanionSelectionReadAnchor {
        CompanionSelectionReadAnchor(
            panelAnchor: NSEvent.mouseLocation,
            accessibilityHitPoint: CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        )
    }

    private func scheduleRead(anchor: CompanionSelectionReadAnchor) {
        pendingRead?.cancel()
        let readID = UUID()
        pendingReadID = readID

        scheduleReadAttempt(anchor: anchor, readID: readID, attempt: 0)
    }

    private func scheduleReadAttempt(anchor: CompanionSelectionReadAnchor, readID: UUID, attempt: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard self.pendingReadID == readID else {
                return
            }

            self.readQueue.async { [weak self] in
                guard let self else {
                    return
                }
                let snapshot = self.reader.read(anchor: anchor)
                DispatchQueue.main.async {
                    guard self.pendingReadID == readID else {
                        return
                    }
                    if let snapshot {
                        self.pendingRead = nil
                        self.onSelectionChanged?(snapshot)
                        return
                    }

                    let nextAttempt = attempt + 1
                    if nextAttempt < Self.readRetryDelays.count {
                        self.scheduleReadAttempt(anchor: anchor, readID: readID, attempt: nextAttempt)
                    } else {
                        self.pendingRead = nil
                        self.onSelectionChanged?(nil)
                    }
                }
            }
        }

        pendingRead = workItem
        let delay = Self.readRetryDelays[min(attempt, Self.readRetryDelays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

private final class CompanionSelectionReader {
    private struct SelectedTextResult {
        let text: String
        let anchor: CGPoint?
    }

    private enum WebAccessibility {
        static let activeElement = "AXActiveElement" as CFString
        static let selectedTextMarkerRange = "AXSelectedTextMarkerRange" as CFString
        static let stringForTextMarkerRange = "AXStringForTextMarkerRange" as CFString
        static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange" as CFString
    }

    private let maxParentDepth = 8
    private let maxChildSearchDepth = 3
    private let maxChildSearchCount = 80
    private let messagingTimeout: Float = 0.25
    private let browserSelectionReader = CompanionBrowserSelectionReader()

    func read(anchor fallbackAnchor: CompanionSelectionReadAnchor) -> CompanionSelectionSnapshot? {
        guard CompanionAccessibilityPermission.isTrusted else {
            return nil
        }

        if let browserSelection = browserSelectionReader.read(anchor: fallbackAnchor.panelAnchor) {
            return browserSelection
        }

        let candidates = selectionCandidates(anchor: fallbackAnchor)
        for candidate in candidates {
            if let snapshot = snapshot(from: candidate, fallbackAnchor: fallbackAnchor) {
                return snapshot
            }
        }

        return nil
    }

    private func selectionCandidates(anchor fallbackAnchor: CompanionSelectionReadAnchor) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        if let focusedElement = focusedElement() {
            candidates.append(contentsOf: relatedCandidates(from: focusedElement))
        }

        if let pointedElement = element(at: fallbackAnchor.accessibilityHitPoint) {
            candidates.append(contentsOf: relatedCandidates(from: pointedElement))
        }

        return candidates
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        setMessagingTimeout(for: systemWideElement)
        var focusedElementValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
            let focusedElementValue,
            CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedElementValue as! AXUIElement)
    }

    private func relatedCandidates(from element: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []
        candidates.append(element)

        let parents = parentChain(from: element)
        candidates.append(contentsOf: parents)

        for base in [element] + parents {
            if let activeElement = activeElement(in: base) {
                candidates.append(activeElement)
                candidates.append(contentsOf: parentChain(from: activeElement))
            }
        }

        candidates.append(contentsOf: descendantCandidates(from: candidates))
        return candidates
    }

    private func snapshot(from element: AXUIElement, fallbackAnchor: CompanionSelectionReadAnchor) -> CompanionSelectionSnapshot? {
        setMessagingTimeout(for: element)
        guard let selectedText = selectedText(in: element) else {
            return nil
        }

        return CompanionSelectionSnapshot(
            text: selectedText.text,
            anchor: selectedText.anchor ?? selectedTextAnchor(in: element) ?? fallbackAnchor.panelAnchor,
            appName: appName(for: element)
        )
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        setMessagingTimeout(for: systemWideElement)
        var elementValue: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &elementValue
        ) == .success else {
            return nil
        }

        return elementValue
    }

    private func parentChain(from element: AXUIElement) -> [AXUIElement] {
        var parents: [AXUIElement] = []
        var currentElement = element

        for _ in 0..<maxParentDepth {
            guard let parent = parent(of: currentElement) else {
                break
            }

            parents.append(parent)
            currentElement = parent
        }

        return parents
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        setMessagingTimeout(for: element)
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        ) == .success,
            let parentValue,
            CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func activeElement(in element: AXUIElement) -> AXUIElement? {
        setMessagingTimeout(for: element)
        var activeElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            WebAccessibility.activeElement,
            &activeElementValue
        ) == .success,
            let activeElementValue,
            CFGetTypeID(activeElementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (activeElementValue as! AXUIElement)
    }

    private func descendantCandidates(from roots: [AXUIElement]) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var queue = roots.map { (element: $0, depth: 0) }
        var visitedCount = 0

        while !queue.isEmpty,
              visitedCount < maxChildSearchCount {
            let item = queue.removeFirst()
            guard item.depth < maxChildSearchDepth else {
                continue
            }

            for child in children(of: item.element) {
                results.append(child)
                queue.append((element: child, depth: item.depth + 1))
                visitedCount += 1

                if visitedCount >= maxChildSearchCount {
                    break
                }
            }
        }

        return results
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        setMessagingTimeout(for: element)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
            let rawChildren = childrenValue as? [Any]
        else {
            return []
        }

        return rawChildren.compactMap { child in
            guard CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() else {
                return nil
            }

            return (child as! AXUIElement)
        }
    }

    private func selectedText(in element: AXUIElement) -> SelectedTextResult? {
        if let selectedText = selectedTextAttribute(in: element) {
            return SelectedTextResult(text: selectedText, anchor: nil)
        }

        if let selectedText = selectedTextFromRanges(in: element) {
            return selectedText
        }

        return selectedTextFromWebMarkerRange(in: element)
    }

    private func selectedTextAttribute(in element: AXUIElement) -> String? {
        setMessagingTimeout(for: element)
        var selectedTextValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
            let selectedText = string(from: selectedTextValue)
        else {
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : selectedText
    }

    private func selectedTextFromRanges(in element: AXUIElement) -> SelectedTextResult? {
        setMessagingTimeout(for: element)
        var rangesValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangesAttribute as CFString,
            &rangesValue
        ) == .success,
            let ranges = rangesValue as? [Any],
            !ranges.isEmpty
        else {
            return nil
        }

        var selectedStrings: [String] = []
        var anchor: CGPoint?

        for range in ranges {
            guard CFGetTypeID(range as CFTypeRef) == AXValueGetTypeID() else {
                continue
            }

            if anchor == nil {
                anchor = boundsAnchor(for: range as CFTypeRef, in: element, attribute: kAXBoundsForRangeParameterizedAttribute as CFString)
            }

            var stringValue: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                range as CFTypeRef,
                &stringValue
            ) == .success,
                let selectedString = stringValue as? String
            else {
                continue
            }

            let trimmed = selectedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                selectedStrings.append(selectedString)
            }
        }

        let text = selectedStrings.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return SelectedTextResult(text: text, anchor: anchor)
    }

    private func selectedTextFromWebMarkerRange(in element: AXUIElement) -> SelectedTextResult? {
        setMessagingTimeout(for: element)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            WebAccessibility.selectedTextMarkerRange,
            &rangeValue
        ) == .success,
            let rangeValue,
            CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID()
        else {
            return nil
        }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            WebAccessibility.stringForTextMarkerRange,
            rangeValue,
            &stringValue
        ) == .success,
            let selectedText = stringValue as? String
        else {
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let anchor = boundsAnchor(
            for: rangeValue,
            in: element,
            attribute: WebAccessibility.boundsForTextMarkerRange
        )
        return SelectedTextResult(text: selectedText, anchor: anchor)
    }

    private func string(from value: CFTypeRef?) -> String? {
        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func selectedTextAnchor(in element: AXUIElement) -> CGPoint? {
        setMessagingTimeout(for: element)
        var selectedRangeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
            let selectedRangeValue
        else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &boundsValue
        ) == .success,
            let boundsValue,
            CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let bounds = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(bounds, .cgRect, &rect), !rect.isNull, !rect.isEmpty else {
            return nil
        }

        return CGPoint(x: rect.midX, y: rect.maxY + 10)
    }

    private func boundsAnchor(for range: CFTypeRef, in element: AXUIElement, attribute: CFString) -> CGPoint? {
        setMessagingTimeout(for: element)
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            range,
            &boundsValue
        ) == .success,
            let boundsValue,
            let rect = rect(from: boundsValue),
            !rect.isNull,
            !rect.isEmpty
        else {
            return nil
        }

        return CGPoint(x: rect.midX, y: rect.maxY + 10)
    }

    private func rect(from value: CFTypeRef) -> CGRect? {
        if let nsValue = value as? NSValue {
            return nsValue.rectValue
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    private func appName(for element: AXUIElement) -> String? {
        setMessagingTimeout(for: element)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }

        return NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
    }

    private func setMessagingTimeout(for element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }
}

private final class CompanionBrowserSelectionReader {
    private static let chromeBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium"
    ]
    private static let automationTimeoutSeconds = 3
    private static let automationErrorCooldown: TimeInterval = 20

    private var chromeAutomationCooldownUntil: Date?

    func read(anchor fallbackAnchor: CGPoint) -> CompanionSelectionSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              Self.chromeBundleIdentifiers.contains(bundleIdentifier)
        else {
            return nil
        }

        guard !isChromeAutomationCoolingDown else {
            return nil
        }

        guard let selectedText = selectedTextInChrome(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        return CompanionSelectionSnapshot(
            text: selectedText,
            anchor: fallbackAnchor,
            appName: application.localizedName
        )
    }

    private func selectedTextInChrome(bundleIdentifier: String) -> String? {
        let source = chromeSelectionScript(bundleIdentifier: bundleIdentifier)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            startChromeAutomationCooldown(error: error)
            return nil
        }

        let output = script.executeAndReturnError(&error)
        guard error == nil, let selectedText = output.stringValue else {
            startChromeAutomationCooldown(error: error)
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : selectedText
    }

    private var isChromeAutomationCoolingDown: Bool {
        guard let chromeAutomationCooldownUntil else {
            return false
        }

        if Date() < chromeAutomationCooldownUntil {
            return true
        }

        self.chromeAutomationCooldownUntil = nil
        return false
    }

    private func startChromeAutomationCooldown(error: NSDictionary?) {
        guard error != nil else {
            return
        }

        chromeAutomationCooldownUntil = Date().addingTimeInterval(Self.automationErrorCooldown)
    }

    private func chromeSelectionScript(bundleIdentifier: String) -> String {
        #"""
        with timeout of \#(Self.automationTimeoutSeconds) seconds
            tell application id "\#(bundleIdentifier)"
                if not (exists front window) then return ""
                set selectedText to execute active tab of front window javascript "(() => { const selection = window.getSelection(); return selection ? selection.toString() : String(); })();"
                return selectedText
            end tell
        end timeout
        """#
    }
}
