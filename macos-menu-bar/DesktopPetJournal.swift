import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PetJournalOutlineItem: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var level: Int
    var isExpanded: Bool

    init(id: UUID = UUID(), text: String, level: Int = 0, isExpanded: Bool = true) {
        self.id = id
        self.text = text
        self.level = min(max(level, 0), 5)
        self.isExpanded = isExpanded
    }
}

struct PetJournalDocument: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var items: [PetJournalOutlineItem]
    let createdAt: Date
    var modifiedAt: Date
    // 用户是否显式重命名过：为 true 时不再用第一行内容自动覆盖标题。
    // Optional 以兼容旧 journal-documents.json（缺该字段时解码为 nil）。
    var hasCustomTitle: Bool?
    var isFavorite: Bool?

    init(
        id: UUID = UUID(),
        title: String = "Untitled",
        items: [PetJournalOutlineItem] = [PetJournalOutlineItem(text: "")],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        hasCustomTitle: Bool? = nil,
        isFavorite: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.hasCustomTitle = hasCustomTitle
        self.isFavorite = isFavorite
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    func hasChildren(_ item: PetJournalOutlineItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        let nextIndex = items.index(after: index)
        guard nextIndex < items.endIndex else { return false }
        return items[nextIndex].level > item.level
    }

    var visibleItems: [PetJournalOutlineItem] {
        var hiddenAncestorLevel: Int?
        var visible: [PetJournalOutlineItem] = []

        for item in items {
            if let hiddenLevel = hiddenAncestorLevel {
                if item.level > hiddenLevel {
                    continue
                }
                hiddenAncestorLevel = nil
            }

            visible.append(item)

            if !item.isExpanded {
                hiddenAncestorLevel = item.level
            }
        }

        return visible
    }
}

struct PetJournalAIActionEntry {
    var actionTitle: String
    var resultTitle: String
    var providerName: String
    var sourceText: String
    var resultText: String
    var createdAt: Date = Date()
}

/// 全量导出时单个文档的产物（文件名 + Markdown 内容）。2.4.0 新增。
struct PetJournalExportFile: Equatable {
    var filename: String
    var markdown: String
}

/// 由 Journal 条目“转提醒”时生成的提醒草稿。2.4.0 新增。
struct PetJournalReminderDraft: Equatable {
    var title: String
    var fireDate: Date
    var recurrence: PetReminderRecurrence?
}

final class PetJournalStore: ObservableObject {
    private struct Payload: Codable {
        var version: Int
        var selectedDocumentID: UUID?
        var documents: [PetJournalDocument]
    }

    @Published private(set) var documents: [PetJournalDocument] = []
    @Published private(set) var selectedDocumentID: UUID? {
        didSet {
            guard oldValue != selectedDocumentID else { return }
            clearUndoHistory()
        }
    }

    /// 文档级撤销/重做：覆盖跨行结构操作（增/删条目、缩进/反缩进、删除子树、拖拽重排）。
    /// 行内打字仍由各自 NSTextView 的原生撤销负责；切换文档会清空历史。
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [[PetJournalOutlineItem]] = []
    private var redoStack: [[PetJournalOutlineItem]] = []
    private static let maxUndoDepth = 100
    private static let maxStoredDocuments = 5_000

    /// 由外部（DesktopPet）注入：把一条 Journal 条目转成提醒。未注入时”转提醒”菜单项隐藏。
    var onConvertToReminder: ((PetJournalReminderDraft) -> Void)?
    /// 由外部注入：选择本地图片上传并把 Markdown 链接插入今日记录。
    var onInsertUploadedAssetFromFile: (() -> Void)?
    /// 由外部注入：上传剪贴板图片并把 Markdown 链接插入今日记录。
    var onInsertUploadedAssetFromClipboard: (() -> Void)?

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "com.crazyjal.companion.pet-journal.save")
    private static let textSaveDebounceInterval: TimeInterval = 0.75
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var sortedDocumentsCache: [PetJournalDocument]?
    private var terminationObserver: NSObjectProtocol?
    private var dataRootObserver: NSObjectProtocol?
    private var dataRootWillChangeObserver: NSObjectProtocol?
    private var loadFailed = false

    private var journalURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("journal-documents.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601

        CompanionDataBackup.dailyBackup(of: journalURL)
        load()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSave()
        }
        dataRootObserver = NotificationCenter.default.addObserver(
            forName: CompanionDataRoot.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        dataRootWillChangeObserver = NotificationCenter.default.addObserver(
            forName: CompanionDataRoot.willChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // queue:nil → 在 post 的线程（主线程）同步执行；切换数据根前把待写编辑刷到当前（旧）数据根，
            // 确保进 rollback / 旧根，不丢失最后一次 debounce 内的编辑。
            self?.flushPendingSave()
        }
    }

    deinit {
        flushPendingSave()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let dataRootObserver {
            NotificationCenter.default.removeObserver(dataRootObserver)
        }
        if let dataRootWillChangeObserver {
            NotificationCenter.default.removeObserver(dataRootWillChangeObserver)
        }
    }

    /// 数据根切换后重新从当前数据根读取日记。先取消未落盘的旧数据写入，避免把旧内容写进新数据根。
    func reload() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        documents = []
        sortedDocumentsCache = nil
        selectedDocumentID = nil
        load()
    }

    var selectedDocument: PetJournalDocument? {
        guard let selectedDocumentID else { return documents.first }
        return documents.first { $0.id == selectedDocumentID }
    }

    var sortedDocuments: [PetJournalDocument] {
        if let sortedDocumentsCache {
            return sortedDocumentsCache
        }
        let sorted = documents.sorted {
            if ($0.isFavorite == true) != ($1.isFavorite == true) {
                return $0.isFavorite == true
            }
            if $0.modifiedAt == $1.modifiedAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.modifiedAt > $1.modifiedAt
        }
        sortedDocumentsCache = sorted
        return sorted
    }

    func filteredDocuments(matching query: String) -> [PetJournalDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return sortedDocuments
        }

        let lowercasedQuery = trimmed.localizedLowercase
        return sortedDocuments.filter { document in
            document.displayTitle.localizedLowercase.contains(lowercasedQuery)
                || document.items.contains { item in
                    item.text.localizedLowercase.contains(lowercasedQuery)
                }
        }
    }

    func selectDocument(id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedDocumentID = id
        save()
    }

    @discardableResult
    func createDocument() -> PetJournalDocument {
        guard canCreateMoreDocuments() else {
            return selectedDocument ?? sortedDocuments.first ?? Self.defaultDocument()
        }
        let document = PetJournalDocument(
            items: [
                PetJournalOutlineItem(text: "新的日记", level: 0),
                PetJournalOutlineItem(text: "", level: 1)
            ]
        )
        documents.append(document)
        selectedDocumentID = document.id
        save()
        return document
    }

    func deleteDocument(id: UUID) {
        let countBefore = documents.count
        documents.removeAll { $0.id == id }
        guard documents.count != countBefore else { return }
        sortedDocumentsCache = nil
        // 被删的是当前文档时，回退到排序后的第一篇；全部删空则交给空状态视图（重开时 load() 会补默认文档）。
        if selectedDocumentID == id {
            selectedDocumentID = sortedDocuments.first?.id
        }
        save()
    }

    func renameDocument(id: UUID, title: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, documents[index].title != trimmed else { return }
        documents[index].title = trimmed
        documents[index].hasCustomTitle = true
        documents[index].modifiedAt = Date()
        save()
    }

    func toggleFavorite(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].isFavorite = documents[index].isFavorite != true
        documents[index].modifiedAt = Date()
        save()
    }

    @discardableResult
    func openTodayDocument() -> PetJournalDocument {
        let title = Self.todayDocumentTitle()
        if let existing = documents.first(where: { $0.title == title }) {
            selectedDocumentID = existing.id
            save()
            return existing
        }
        guard canCreateMoreDocuments() else {
            return selectedDocument ?? sortedDocuments.first ?? Self.defaultDocument()
        }

        let document = PetJournalDocument(
            title: title,
            items: [
                PetJournalOutlineItem(text: title, level: 0),
                PetJournalOutlineItem(text: "专注记录", level: 0),
                PetJournalOutlineItem(text: "AI 动作", level: 0),
                PetJournalOutlineItem(text: "随手记", level: 0)
            ],
            hasCustomTitle: true
        )
        documents.append(document)
        selectedDocumentID = document.id
        save()
        return document
    }

    func appendFocusRecord(_ record: PetFocusRecord) {
        let document = openTodayDocument()
        appendItemsUnderSection(
            "专注记录",
            items: [
                PetJournalOutlineItem(text: "完成专注：\(record.displayTaskTitle)", level: 1),
                PetJournalOutlineItem(text: "时长：\(Self.minutesTitle(record.durationSeconds))", level: 2),
                PetJournalOutlineItem(text: "完成时间：\(PetJournalFormatters.timeOnly.string(from: record.completedAt))", level: 2)
            ],
            toDocumentID: document.id
        )
    }

    /// 把若干行文本追加到今日记录的指定分节（Focus Review 保存每日总结 / 补记完成提醒用）。
    func appendToTodaySection(_ section: String, lines: [String]) {
        let trimmedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return }
        let document = openTodayDocument()
        // 记录追加前快照，使“保存到今日记录 / 补记”可被 Journal 撤销恢复。
        if document.id == selectedDocumentID, let index = documents.firstIndex(where: { $0.id == document.id }) {
            pushUndoSnapshot(documents[index].items)
        }
        appendItemsUnderSection(
            section,
            items: trimmedLines.map { PetJournalOutlineItem(text: $0, level: 1) },
            toDocumentID: document.id
        )
    }

    func appendAIAction(_ entry: PetJournalAIActionEntry) {
        let document = openTodayDocument()
        appendItemsUnderSection(
            "AI 动作",
            items: [
                PetJournalOutlineItem(text: "AI 动作：\(entry.actionTitle)", level: 1),
                PetJournalOutlineItem(text: "来源：\(entry.providerName) · \(entry.resultTitle)", level: 2),
                PetJournalOutlineItem(text: "原文：\(Self.singleLine(entry.sourceText))", level: 2),
                PetJournalOutlineItem(text: "\(entry.resultTitle)：\(Self.singleLine(entry.resultText))", level: 2)
            ],
            toDocumentID: document.id
        )
    }

    func focusReviewSnapshot(now: Date = Date()) -> CompanionFocusReviewJournalSnapshot {
        let title = Self.todayDocumentTitle(now: now)
        guard let document = documents.first(where: {
            $0.title == title || Calendar.current.isDate($0.createdAt, inSameDayAs: now)
        }) else {
            return .empty
        }
        let aiActionCount = document.items.filter { item in
            item.level == 1
                && item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("AI 动作：")
        }.count
        return CompanionFocusReviewJournalSnapshot(
            aiActionCount: aiActionCount,
            hasJournalToday: true
        )
    }

    private func appendItemsUnderSection(_ sectionTitle: String, items: [PetJournalOutlineItem], toDocumentID documentID: UUID) {
        guard !items.isEmpty, let index = documents.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        if let sectionIndex = documents[index].items.firstIndex(where: { item in
            item.level == 0 && item.text.trimmingCharacters(in: .whitespacesAndNewlines) == sectionTitle
        }) {
            let insertionIndex = Self.subtreeEndIndex(in: documents[index].items, from: sectionIndex)
            documents[index].items.insert(contentsOf: items, at: insertionIndex)
        } else {
            documents[index].items.append(PetJournalOutlineItem(text: sectionTitle, level: 0))
            documents[index].items.append(contentsOf: items)
        }
        documents[index].modifiedAt = Date()
        selectedDocumentID = documentID
        save()
    }

    func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            guard canCreateMoreDocuments() else { return }
            let document = PetJournalMarkdownImporter.document(fromMarkdown: markdown, fallbackTitle: url.deletingPathExtension().lastPathComponent)
            documents.append(document)
            selectedDocumentID = document.id
            save()
        } catch {
            CompanionNonBlockingAlert.present(
                messageText: "导入失败",
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    func insertUploadedAssetFromFile() {
        onInsertUploadedAssetFromFile?()
    }

    func insertUploadedAssetFromClipboard() {
        onInsertUploadedAssetFromClipboard?()
    }

    func updateText(itemID: UUID, text: String) {
        mutateSelectedDocument(debouncedSave: true) { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }) else { return }
            document.items[index].text = text
        }
    }

    @discardableResult
    func addItem(after itemID: UUID) -> UUID? {
        var newItemID: UUID?

        mutateSelectedDocument(recordUndo: true) { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }) else { return }
            let level = document.items[index].level
            let item = PetJournalOutlineItem(text: "", level: level)
            let insertionIndex = Self.subtreeEndIndex(in: document.items, from: index)
            document.items.insert(item, at: insertionIndex)
            newItemID = item.id
        }

        return newItemID
    }

    func indent(itemID: UUID) {
        mutateSelectedDocument(recordUndo: true) { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }), index > 0 else { return }
            let previousLevel = document.items[document.items.index(before: index)].level
            let subtreeEndIndex = Self.subtreeEndIndex(in: document.items, from: index)
            let subtreeRange = index..<subtreeEndIndex
            let maxSubtreeLevel = subtreeRange
                .map { document.items[$0].level }
                .max() ?? document.items[index].level
            let currentLevel = document.items[index].level
            let allowedDelta = max(0, 5 - maxSubtreeLevel)
            let nextLevel = min(currentLevel + 1, previousLevel + 1, currentLevel + allowedDelta)
            let delta = nextLevel - currentLevel

            guard delta > 0 else { return }

            for itemIndex in subtreeRange {
                document.items[itemIndex].level += delta
            }
        }
    }

    func outdent(itemID: UUID) {
        mutateSelectedDocument(recordUndo: true) { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }) else { return }
            let currentLevel = document.items[index].level
            guard currentLevel > 0 else { return }

            let subtreeEndIndex = Self.subtreeEndIndex(in: document.items, from: index)
            for itemIndex in index..<subtreeEndIndex {
                document.items[itemIndex].level = max(document.items[itemIndex].level - 1, 0)
            }
        }
    }

    func delete(itemID: UUID) {
        mutateSelectedDocument(recordUndo: true) { document in
            guard document.items.count > 1 else {
                document.items[0].text = ""
                document.items[0].level = 0
                return
            }
            document.items.removeAll { $0.id == itemID }
        }
    }

    func toggleExpanded(itemID: UUID) {
        mutateSelectedDocument(markModified: false) { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }) else { return }
            document.items[index].isExpanded.toggle()
        }
    }

    /// 复制单个条目文本（用于“复制条目”右键菜单）。
    func itemText(itemID: UUID) -> String? {
        selectedDocument?.items.first(where: { $0.id == itemID })?.text
    }

    /// 是否已注入“转提醒”能力（决定菜单项是否显示）。
    var canConvertToReminder: Bool {
        onConvertToReminder != nil
    }

    /// 把一条 Journal 条目转成提醒：用条目文本走提醒自然语言解析（解析不出时间则默认 1 小时后）。
    func convertItemToReminder(itemID: UUID, now: Date = Date()) {
        guard let onConvertToReminder,
              let text = itemText(itemID: itemID),
              let draft = Self.reminderDraft(forItemText: text, now: now)
        else {
            return
        }
        onConvertToReminder(draft)
    }

    /// 复制条目及其所有后代为缩进文本（用于“复制子树”右键菜单）。
    func subtreeText(itemID: UUID) -> String? {
        guard let document = selectedDocument else { return nil }
        return Self.subtreeText(in: document.items, itemID: itemID)
    }

    /// 删除条目及其所有后代（用于“删除子树”右键菜单）。
    func deleteSubtree(itemID: UUID) {
        mutateSelectedDocument(recordUndo: true) { document in
            document.items = Self.removingSubtree(in: document.items, itemID: itemID)
        }
    }

    /// 将条目子树拖动到目标条目子树之前 / 之后，子树根 level 对齐目标，后代相对层级保持（用于拖拽排序）。
    func moveSubtree(itemID: UUID, toTargetID targetID: UUID, placeAfter: Bool) {
        mutateSelectedDocument(recordUndo: true) { document in
            document.items = Self.movingSubtree(
                in: document.items,
                itemID: itemID,
                toTargetID: targetID,
                placeAfter: placeAfter
            )
        }
    }

    func exportSelectedDocument() {
        guard let document = selectedDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(Self.safeFilename(document.displayTitle)).pdf"
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = PetJournalPDFExporter.pdfData(for: document)
            try data.write(to: url, options: .atomic)
        } catch {
            CompanionNonBlockingAlert.present(
                messageText: "导出失败",
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    func exportSelectedDocumentAsMarkdown() {
        guard let document = selectedDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(Self.safeFilename(document.displayTitle)).md"
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let markdown = PetJournalMarkdownExporter.markdown(for: document)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            CompanionNonBlockingAlert.present(
                messageText: "导出失败",
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    /// 全量导出：把所有日记文档作为 Markdown 文件写入用户选择的文件夹（文件名去重 + 安全化）。
    func exportAllDocumentsAsMarkdown() {
        let exports = Self.bulkMarkdownExports(for: documents)
        guard !exports.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此文件夹"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            for file in exports {
                let url = directory.appendingPathComponent(file.filename)
                try file.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            CompanionNonBlockingAlert.present(
                messageText: "导出失败",
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    private func load() {
        loadFailed = false
        defer {
            if documents.isEmpty {
                documents = [Self.defaultDocument()]
                sortedDocumentsCache = nil
                selectedDocumentID = documents.first?.id
                if !loadFailed {
                    save(waitUntilFinished: true)
                }
            } else if selectedDocumentID == nil || !documents.contains(where: { $0.id == selectedDocumentID }) {
                selectedDocumentID = sortedDocuments.first?.id
                if !loadFailed {
                    save(waitUntilFinished: true)
                }
            }
        }

        let primaryURL = journalURL
        let candidates = CompanionDataRoot.recoveryURLs(forFileNamed: "journal-documents.json", environment: environment)
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }

        var primaryError: Error?
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                let payload = try loadPayload(from: candidate)
                if candidate.standardizedFileURL.path != primaryURL.standardizedFileURL.path {
                    try CompanionDataBackup.restoreRecoveredFile(from: candidate, to: primaryURL, fileManager: fileManager)
                    NSLog("Companion recovered journal-documents.json from \(candidate.path)")
                }
                documents = payload.documents
                sortedDocumentsCache = nil
                selectedDocumentID = payload.selectedDocumentID
                return
            } catch {
                if candidate.standardizedFileURL.path == primaryURL.standardizedFileURL.path {
                    primaryError = error
                }
            }
        }

        markLoadFailure(primaryError ?? Self.persistenceError("journal-documents.json is unreadable."))
    }

    private func loadPayload(from url: URL) throws -> Payload {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw Self.persistenceError("journal-documents.json is empty.")
        }
        return try decoder.decode(Payload.self, from: data)
    }

    private func mutateSelectedDocument(
        markModified: Bool = true,
        debouncedSave: Bool = false,
        recordUndo: Bool = false,
        _ mutation: (inout PetJournalDocument) -> Void
    ) {
        guard let selectedDocumentID, let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else {
            return
        }

        let originalDocument = documents[index]
        mutation(&documents[index])

        if documents[index].items.isEmpty {
            documents[index].items = [PetJournalOutlineItem(text: "")]
        }

        guard documents[index] != originalDocument else {
            return
        }

        if recordUndo {
            pushUndoSnapshot(originalDocument.items)
        }

        if markModified {
            documents[index].modifiedAt = Date()
            if documents[index].hasCustomTitle != true {
                documents[index].title = Self.title(from: documents[index].items)
            }
        }

        if debouncedSave {
            scheduleSave()
        } else {
            save()
        }
    }

    /// 撤销最近一次结构操作（恢复到操作前的条目状态）。
    func undo() {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(documents[index].items)
        documents[index].items = previous
        finalizeUndoRedo(at: index)
    }

    /// 重做最近一次被撤销的结构操作。
    func redo() {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              let next = redoStack.popLast() else {
            return
        }
        undoStack.append(documents[index].items)
        documents[index].items = next
        finalizeUndoRedo(at: index)
    }

    private func finalizeUndoRedo(at index: Int) {
        if documents[index].items.isEmpty {
            documents[index].items = [PetJournalOutlineItem(text: "")]
        }
        documents[index].modifiedAt = Date()
        if documents[index].hasCustomTitle != true {
            documents[index].title = Self.title(from: documents[index].items)
        }
        updateUndoFlags()
        save()
    }

    private func pushUndoSnapshot(_ items: [PetJournalOutlineItem]) {
        undoStack.append(items)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.save()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.textSaveDebounceInterval, execute: workItem)
    }

    private func flushPendingSave() {
        guard pendingSaveWorkItem != nil else {
            saveQueue.sync {}
            return
        }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        save(waitUntilFinished: true)
    }

    private func save(waitUntilFinished: Bool = false) {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        sortedDocumentsCache = nil
        guard !loadFailed else {
            CompanionPersistenceAlert.reportSaveBlocked(context: "日记")
            return
        }

        let url = journalURL
        let payload = Payload(version: 1, selectedDocumentID: selectedDocumentID, documents: documents)
        let encoder = self.encoder
        let fileManager = self.fileManager
        let write = {
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try encoder.encode(payload)
                try data.write(to: url, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                DispatchQueue.main.async {
                    CompanionPersistenceAlert.reportSaveFailure(context: "日记", error: error)
                }
            }
        }

        if waitUntilFinished {
            saveQueue.sync(execute: write)
        } else {
            saveQueue.async(execute: write)
        }
    }

    private func canCreateMoreDocuments() -> Bool {
        guard documents.count < Self.maxStoredDocuments else {
            CompanionNonBlockingAlert.present(
                messageText: "日记数量已达上限",
                informativeText: "请先导出或删除旧日记，再创建新的日记。",
                tone: .warning
            )
            return false
        }
        return true
    }

    private func markLoadFailure(_ error: Error) {
        loadFailed = true
        CompanionDataBackup.backupUnreadableFile(at: journalURL, fileManager: fileManager)
        CompanionPersistenceAlert.reportLoadFailure(context: "日记", error: error)
    }

    private static func persistenceError(_ message: String) -> Error {
        NSError(domain: "CompanionPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func title(from items: [PetJournalOutlineItem]) -> String {
        let firstText = items
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstText, !firstText.isEmpty else {
            return "Untitled"
        }

        if firstText.count <= 28 {
            return firstText
        }

        let index = firstText.index(firstText.startIndex, offsetBy: 28)
        return "\(firstText[..<index])..."
    }

    private static func safeFilename(_ title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters)
        let components = title.components(separatedBy: unsafe)
        let filename = components
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let limitedFilename = String(filename.prefix(64))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limitedFilename.isEmpty ? "Untitled" : limitedFilename
    }

    private static func subtreeEndIndex(in items: [PetJournalOutlineItem], from index: Int) -> Int {
        guard items.indices.contains(index) else {
            return index
        }

        let level = items[index].level
        var cursor = items.index(after: index)
        while cursor < items.endIndex, items[cursor].level > level {
            cursor = items.index(after: cursor)
        }
        return cursor
    }

    /// 条目及其后代的缩进文本，子树根作为第 0 级（用于复制子树）。internal 以便测试。
    static func subtreeText(in items: [PetJournalOutlineItem], itemID: UUID) -> String? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let end = subtreeEndIndex(in: items, from: index)
        let baseLevel = items[index].level
        let lines = items[index..<end].map { item -> String in
            let relativeLevel = max(0, item.level - baseLevel)
            return String(repeating: "  ", count: relativeLevel) + item.text
        }
        return lines.joined(separator: "\n")
    }

    /// 返回移除条目及其后代后的 items（用于删除子树）。internal 以便测试。
    static func removingSubtree(in items: [PetJournalOutlineItem], itemID: UUID) -> [PetJournalOutlineItem] {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return items }
        let end = subtreeEndIndex(in: items, from: index)
        var result = items
        result.removeSubrange(index..<end)
        return result
    }

    /// 把条目子树移动到目标条目子树之前 / 之后；子树根 level 对齐目标，后代相对层级保持。internal 以便测试。
    static func movingSubtree(
        in items: [PetJournalOutlineItem],
        itemID: UUID,
        toTargetID targetID: UUID,
        placeAfter: Bool
    ) -> [PetJournalOutlineItem] {
        guard itemID != targetID,
              let srcIndex = items.firstIndex(where: { $0.id == itemID }),
              let dstIndex = items.firstIndex(where: { $0.id == targetID })
        else {
            return items
        }

        let srcEnd = subtreeEndIndex(in: items, from: srcIndex)
        // 不能把子树拖进它自己的范围（会破坏结构）。
        if dstIndex >= srcIndex && dstIndex < srcEnd {
            return items
        }

        let movedSlice = Array(items[srcIndex..<srcEnd])
        guard let movedRoot = movedSlice.first else { return items }
        let delta = items[dstIndex].level - movedRoot.level
        let releveled = movedSlice.map { item -> PetJournalOutlineItem in
            var copy = item
            copy.level = min(max(item.level + delta, 0), 5)
            return copy
        }

        var remaining = items
        remaining.removeSubrange(srcIndex..<srcEnd)

        guard let newDst = remaining.firstIndex(where: { $0.id == targetID }) else { return items }
        let insertionIndex = placeAfter ? subtreeEndIndex(in: remaining, from: newDst) : newDst
        remaining.insert(contentsOf: releveled, at: insertionIndex)
        return remaining
    }

    /// 把所有文档组装成 Markdown 导出产物，文件名安全化并去重（用于全量导出）。internal 以便测试。
    static func bulkMarkdownExports(for documents: [PetJournalDocument]) -> [PetJournalExportFile] {
        var usedNames: Set<String> = []
        var files: [PetJournalExportFile] = []
        for document in documents {
            let base = safeFilename(document.displayTitle)
            var name = base
            var counter = 2
            while usedNames.contains(name.lowercased()) {
                name = "\(base)-\(counter)"
                counter += 1
            }
            usedNames.insert(name.lowercased())
            files.append(
                PetJournalExportFile(
                    filename: "\(name).md",
                    markdown: PetJournalMarkdownExporter.markdown(for: document)
                )
            )
        }
        return files
    }

    /// 由条目文本生成提醒草稿：能解析时间表达式则用解析结果，否则默认 1 小时后。internal 以便测试。
    static func reminderDraft(
        forItemText text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PetJournalReminderDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = PetReminderRuleParser.parse(trimmed, now: now, calendar: calendar) {
            return PetJournalReminderDraft(
                title: parsed.title,
                fireDate: parsed.fireDate,
                recurrence: parsed.recurrence
            )
        }

        return PetJournalReminderDraft(
            title: trimmed,
            fireDate: now.addingTimeInterval(3600),
            recurrence: nil
        )
    }

    private static func defaultDocument() -> PetJournalDocument {
        PetJournalDocument(
            title: "Untitled",
            items: [
                PetJournalOutlineItem(text: "这是一级菜单", level: 0),
                PetJournalOutlineItem(text: "这是二级菜单", level: 1),
                PetJournalOutlineItem(text: "这是三级菜单", level: 2),
                PetJournalOutlineItem(text: "这是四级菜单", level: 3)
            ],
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    private static func todayDocumentTitle(now: Date = Date()) -> String {
        "今日记录 \(PetJournalFormatters.dayOnly.string(from: now))"
    }

    private static func minutesTitle(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(max(seconds, 0)) / 60.0).rounded()))
        return "\(minutes) 分钟"
    }

    private static func singleLine(_ text: String, limit: Int = 180) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        guard collapsed.count > limit else {
            return collapsed
        }

        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return "\(collapsed[..<index])..."
    }


}

final class DesktopPetJournalFeature: NSObject {
    private let store = PetJournalStore()
    private var journalWindow: NSWindow?

    /// 注入“转提醒”能力，转发到内部 store（由 DesktopPet 接到共享的提醒 store）。
    var onConvertToReminder: ((PetJournalReminderDraft) -> Void)? {
        get { store.onConvertToReminder }
        set { store.onConvertToReminder = newValue }
    }

    var onInsertUploadedAssetFromFile: (() -> Void)? {
        get { store.onInsertUploadedAssetFromFile }
        set { store.onInsertUploadedAssetFromFile = newValue }
    }

    var onInsertUploadedAssetFromClipboard: (() -> Void)? {
        get { store.onInsertUploadedAssetFromClipboard }
        set { store.onInsertUploadedAssetFromClipboard = newValue }
    }

    func makeMenuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "日记", action: #selector(showJournalAction), keyEquivalent: "")
        item.target = self
        let todayItem = NSMenuItem(title: "今日记录", action: #selector(openTodayAction), keyEquivalent: "")
        todayItem.target = self
        return [item, todayItem]
    }

    func makeMainMenuItems() -> [NSMenuItem] {
        let newItem = NSMenuItem(title: "创建新日记", action: #selector(createJournalAction), keyEquivalent: "")
        newItem.target = self

        let viewItem = NSMenuItem(title: "查看日记", action: #selector(showJournalAction), keyEquivalent: "")
        viewItem.target = self

        return [newItem, viewItem]
    }

    @objc private func showJournalAction() {
        showJournalWindow()
    }

    @objc private func createJournalAction() {
        _ = store.createDocument()
        showJournalWindow()
    }

    @objc private func openTodayAction() {
        openTodayDocument()
    }

    func openTodayDocument() {
        _ = store.openTodayDocument()
        showJournalWindow()
    }

    func appendFocusRecord(_ record: PetFocusRecord, showWindow: Bool = false) {
        store.appendFocusRecord(record)
        if showWindow {
            showJournalWindow()
        }
    }

    func appendAIAction(_ entry: PetJournalAIActionEntry, showWindow: Bool = false) {
        store.appendAIAction(entry)
        if showWindow {
            showJournalWindow()
        }
    }

    func focusReviewSnapshot(now: Date = Date()) -> CompanionFocusReviewJournalSnapshot {
        store.focusReviewSnapshot(now: now)
    }

    /// 把若干行追加到今日记录的指定分节（Focus Review 保存总结 / 补记完成提醒）。
    func appendToToday(section: String, lines: [String]) {
        store.appendToTodaySection(section, lines: lines)
    }

    func reloadFromDataRoot(showWindow: Bool = false) {
        store.reload()
        if showWindow {
            showJournalWindow()
        }
    }

    func showJournalWindow() {
        if journalWindow == nil {
            let initialSize = Self.initialJournalWindowSize()
            let view = PetJournalWindowView(store: store)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.contentMinSize = NSSize(width: 840, height: 720)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = CompanionInteractiveHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.title = store.selectedDocument?.displayTitle ?? "Untitled"
            journalWindow = window
        }

        journalWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func initialJournalWindowSize() -> NSSize {
        let desired = NSSize(width: 1040, height: 960)
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return desired
        }

        return NSSize(
            width: min(desired.width, max(840, visibleFrame.width - 80)),
            height: min(desired.height, max(720, visibleFrame.height - 64))
        )
    }
}

private struct PetJournalWindowView: View {
    @ObservedObject var store: PetJournalStore
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 26) {
            toolbar

            HStack(spacing: 28) {
                PetJournalDocumentSidebar(store: store)

                if let document = store.selectedDocument {
                    editorSurface(for: document)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(28)
        .padding(.top, 24)
        .background(CompanionLiquidWindowBackground())
        .background(CompanionWindowAccessor { window = $0 })
        .background(PetJournalWindowTitleUpdater(title: store.selectedDocument?.displayTitle ?? "Untitled"))
        .environment(\.companionWindow, window)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            CompanionTrafficLights()

            Text("日记大纲")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Spacer()

            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 44))
            .disabled(!store.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销结构修改")

            Button {
                store.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 44))
            .disabled(!store.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做")

            Button("导出PDF") {
                store.exportSelectedDocument()
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 86))

            Button("导出MD") {
                store.exportSelectedDocumentAsMarkdown()
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 82))

            Button("导出全部") {
                store.exportAllDocumentsAsMarkdown()
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 86))

            Menu {
                Button {
                    store.insertUploadedAssetFromFile()
                } label: {
                    Label("选择图片", systemImage: "photo")
                }

                Button {
                    store.insertUploadedAssetFromClipboard()
                } label: {
                    Label("剪贴板图片", systemImage: "doc.on.clipboard")
                }
            } label: {
                Label("上传图片", systemImage: "arrow.up.doc")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 104))

            Button {
                _ = store.createDocument()
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 82))
        }
        .padding(.horizontal, 28)
        .frame(height: 46)
        .companionGlassSurface(radius: 23)
    }

    private func editorSurface(for document: PetJournalDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PetJournalFormatters.longDate.string(from: document.modifiedAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(document.displayTitle)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 14)

            Rectangle()
                .fill(Color.white.opacity(0.52))
                .frame(height: 1)
                .padding(.top, 22)

            PetJournalOutlineView(document: document, store: store)
                .padding(.top, 18)

            statusBar(for: document)
        }
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .companionGlassSurface(radius: 32)
    }

    private func statusBar(for document: PetJournalDocument) -> some View {
        HStack {
            Text("已保存 · \(document.items.count) 行 · \(levelCount(for: document)) 层级")
                .foregroundStyle(XiaoHuaErTheme.tint)
            Spacer()
            Text("Enter 新行 · Tab 缩进 · / 命令")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(characterCount(for: document)) 字")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .companionGlassField(radius: 17)
    }

    private func levelCount(for document: PetJournalDocument) -> Int {
        (document.items.map(\.level).max() ?? 0) + 1
    }

    private func characterCount(for document: PetJournalDocument) -> Int {
        document.items.reduce(0) { $0 + $1.text.count }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("还没有日记")
                .font(.headline)
            Button("新建文档") {
                _ = store.createDocument()
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 96))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .companionGlassSurface(radius: 32)
    }
}

private struct PetJournalWindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}

private struct PetJournalOutlineView: View {
    let document: PetJournalDocument
    @ObservedObject var store: PetJournalStore
    @State private var hoveredItemID: UUID?
    @State private var focusedItemID: UUID?
    @State private var draggedItemID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.visibleItems) { item in
                        PetJournalOutlineRow(
                            item: item,
                            hasChildren: document.hasChildren(item),
                            isHovered: hoveredItemID == item.id,
                            focusedItemID: $focusedItemID,
                            textBinding: Binding(
                                get: { currentText(for: item.id) },
                                set: { store.updateText(itemID: item.id, text: $0) }
                            ),
                            toggleAction: {
                                store.toggleExpanded(itemID: item.id)
                            },
                            addAction: {
                                addItem(after: item.id)
                            },
                            indentAction: {
                                indentItem(item.id)
                            },
                            outdentAction: {
                                outdentItem(item.id)
                            },
                            deleteAction: {
                                store.delete(itemID: item.id)
                            },
                            moveUpAction: {
                                moveFocus(from: item.id, offset: -1)
                            },
                            moveDownAction: {
                                moveFocus(from: item.id, offset: 1)
                            },
                            copyItemAction: {
                                copyToPasteboard(store.itemText(itemID: item.id))
                            },
                            copySubtreeAction: {
                                copyToPasteboard(store.subtreeText(itemID: item.id))
                            },
                            deleteSubtreeAction: {
                                store.deleteSubtree(itemID: item.id)
                            },
                            convertToReminderAction: store.canConvertToReminder ? {
                                store.convertItemToReminder(itemID: item.id)
                            } : nil
                        )
                        .id(item.id)
                        .onHover { isHovering in
                            hoveredItemID = isHovering ? item.id : nil
                        }
                        .onDrag {
                            draggedItemID = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
                            handleDrop(onto: item.id)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: focusedItemID) { itemID in
                guard let itemID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
        .background(Color.clear)
    }

    private func currentText(for itemID: UUID) -> String {
        store.selectedDocument?.items.first(where: { $0.id == itemID })?.text ?? ""
    }

    private func addItem(after itemID: UUID) {
        guard let newItemID = store.addItem(after: itemID) else {
            return
        }
        focusedItemID = newItemID
    }

    private func indentItem(_ itemID: UUID) {
        store.indent(itemID: itemID)
        focusedItemID = itemID
    }

    private func outdentItem(_ itemID: UUID) {
        store.outdent(itemID: itemID)
        focusedItemID = itemID
    }

    private func moveFocus(from itemID: UUID, offset: Int) {
        guard let visibleItems = store.selectedDocument?.visibleItems,
              let currentIndex = visibleItems.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let targetIndex = currentIndex + offset
        guard visibleItems.indices.contains(targetIndex) else {
            return
        }

        focusedItemID = visibleItems[targetIndex].id
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func handleDrop(onto targetID: UUID) -> Bool {
        defer { draggedItemID = nil }
        guard let draggedID = draggedItemID, draggedID != targetID else { return false }
        store.moveSubtree(itemID: draggedID, toTargetID: targetID, placeAfter: true)
        return true
    }
}

private struct PetJournalOutlineRow: View {
    let item: PetJournalOutlineItem
    let hasChildren: Bool
    let isHovered: Bool
    @Binding var focusedItemID: UUID?
    let textBinding: Binding<String>
    let toggleAction: () -> Void
    let addAction: () -> Void
    let indentAction: () -> Void
    let outdentAction: () -> Void
    let deleteAction: () -> Void
    let moveUpAction: () -> Void
    let moveDownAction: () -> Void
    let copyItemAction: () -> Void
    let copySubtreeAction: () -> Void
    let deleteSubtreeAction: () -> Void
    let convertToReminderAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            indentationGuides

            Button(action: toggleAction) {
                Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hasChildren ? Color.secondary.opacity(0.42) : Color.secondary.opacity(0.16))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!hasChildren)

            PetJournalOutlineTextField(
                text: textBinding,
                focusedItemID: $focusedItemID,
                itemID: item.id,
                level: item.level,
                submitAction: addAction,
                indentAction: indentAction,
                outdentAction: outdentAction,
                moveUpAction: moveUpAction,
                moveDownAction: moveDownAction
            )
            .frame(minWidth: 120, maxWidth: .infinity, minHeight: 20, maxHeight: 20)

            if isHovered {
                rowControls
                    .transition(.opacity)
            }
        }
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var indentationGuides: some View {
        HStack(spacing: 0) {
            ForEach(0..<item.level, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 1)
                    .frame(width: 28, height: 24, alignment: .center)
            }
        }
    }

    private var rowControls: some View {
        HStack(spacing: 5) {
            Button(action: addAction) {
                Image(systemName: "plus")
            }
            .help("新增同级")

            Button(action: outdentAction) {
                Image(systemName: "decrease.indent")
            }
            .disabled(item.level == 0)
            .help("减少缩进")

            Button(action: indentAction) {
                Image(systemName: "increase.indent")
            }
            .help("增加缩进")

            Button(action: deleteAction) {
                Image(systemName: "trash")
            }
            .help("删除")

            Menu {
                Button("复制条目") { copyItemAction() }
                Button("复制子树") { copySubtreeAction() }
                if let convertToReminderAction {
                    Button("转提醒") { convertToReminderAction() }
                }
                Button("删除子树", role: .destructive) { deleteSubtreeAction() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("更多操作")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.secondary.opacity(0.72))
        .padding(.leading, 8)
    }
}

private struct PetJournalOutlineTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusedItemID: UUID?
    let itemID: UUID
    let level: Int
    let submitAction: () -> Void
    let indentAction: () -> Void
    let outdentAction: () -> Void
    let moveUpAction: () -> Void
    let moveDownAction: () -> Void

    func makeNSView(context: Context) -> PetJournalOutlineNSTextView {
        let textView = PetJournalOutlineNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font(for: level)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
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

        textView.onFocus = {
            context.coordinator.focusedItemID.wrappedValue = context.coordinator.itemID
        }
        textView.onSubmit = { [weak textView] in
            guard let textView else { return }
            context.coordinator.submit(from: textView)
        }
        textView.onIndent = { [weak textView] in
            guard let textView else { return }
            context.coordinator.indent(from: textView)
        }
        textView.onOutdent = { [weak textView] in
            guard let textView else { return }
            context.coordinator.outdent(from: textView)
        }
        textView.onMoveUp = { [weak textView] in
            guard let textView else { return }
            context.coordinator.moveUp(from: textView)
        }
        textView.onMoveDown = { [weak textView] in
            guard let textView else { return }
            context.coordinator.moveDown(from: textView)
        }

        return textView
    }

    func updateNSView(_ textView: PetJournalOutlineNSTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusedItemID = $focusedItemID
        context.coordinator.itemID = itemID
        context.coordinator.submitAction = submitAction
        context.coordinator.indentAction = indentAction
        context.coordinator.outdentAction = outdentAction
        context.coordinator.moveUpAction = moveUpAction
        context.coordinator.moveDownAction = moveDownAction

        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.needsDisplay = true
        }

        textView.font = Self.font(for: level)
        textView.needsDisplay = true

        if focusedItemID == itemID {
            textView.requestFocus()
        } else {
            textView.cancelFocusRequest()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusedItemID: $focusedItemID,
            itemID: itemID,
            submitAction: submitAction,
            indentAction: indentAction,
            outdentAction: outdentAction,
            moveUpAction: moveUpAction,
            moveDownAction: moveDownAction
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusedItemID: Binding<UUID?>
        var itemID: UUID
        var submitAction: () -> Void
        var indentAction: () -> Void
        var outdentAction: () -> Void
        var moveUpAction: () -> Void
        var moveDownAction: () -> Void

        init(
            text: Binding<String>,
            focusedItemID: Binding<UUID?>,
            itemID: UUID,
            submitAction: @escaping () -> Void,
            indentAction: @escaping () -> Void,
            outdentAction: @escaping () -> Void,
            moveUpAction: @escaping () -> Void,
            moveDownAction: @escaping () -> Void
        ) {
            self.text = text
            self.focusedItemID = focusedItemID
            self.itemID = itemID
            self.submitAction = submitAction
            self.indentAction = indentAction
            self.outdentAction = outdentAction
            self.moveUpAction = moveUpAction
            self.moveDownAction = moveDownAction
        }

        func textDidBeginEditing(_ notification: Notification) {
            focusedItemID.wrappedValue = itemID
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }

        func submit(from textView: NSTextView) {
            sync(from: textView)
            submitAction()
        }

        func indent(from textView: NSTextView) {
            sync(from: textView)
            indentAction()
        }

        func outdent(from textView: NSTextView) {
            sync(from: textView)
            outdentAction()
        }

        func moveUp(from textView: NSTextView) {
            sync(from: textView)
            moveUpAction()
        }

        func moveDown(from textView: NSTextView) {
            sync(from: textView)
            moveDownAction()
        }

        private func sync(from textView: NSTextView) {
            text.wrappedValue = textView.string
        }
    }

    private static func font(for level: Int) -> NSFont {
        .systemFont(ofSize: 14, weight: level == 0 ? .semibold : .regular)
    }

}

private final class PetJournalOutlineNSTextView: NSTextView {
    private static let placeholder = "输入主题"

    var onFocus: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    private var shouldFocusWhenReady = false
    private var isFocusAttemptScheduled = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocus?()
            needsDisplay = true
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            needsDisplay = true
        }
        return didResignFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if shouldFocusWhenReady {
            scheduleFocusAttempt()
        }
    }

    func requestFocus() {
        shouldFocusWhenReady = true
        scheduleFocusAttempt()
    }

    func cancelFocusRequest() {
        shouldFocusWhenReady = false
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onSubmit?()
        case 48:
            if event.modifierFlags.contains(.shift) {
                onOutdent?()
            } else {
                onIndent?()
            }
        case 126:
            onMoveUp?()
        case 125:
            onMoveDown?()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, window?.firstResponder !== self else {
            return
        }

        let font = font ?? NSFont.systemFont(ofSize: 14)
        let linePadding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: textContainerInset.width + linePadding,
            y: textContainerInset.height,
            width: max(0, bounds.width - textContainerInset.width - linePadding),
            height: bounds.height
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor.withAlphaComponent(0.72)
        ]
        (Self.placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func scheduleFocusAttempt() {
        guard !isFocusAttemptScheduled else {
            return
        }

        isFocusAttemptScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFocusAttemptScheduled = false
            self.attemptFocusIfReady()
        }
    }

    private func attemptFocusIfReady() {
        guard shouldFocusWhenReady else {
            return
        }

        guard let window else {
            return
        }

        if window.firstResponder !== self {
            window.makeKey()
            window.makeFirstResponder(self)
        }

        selectedRange = NSRange(location: (string as NSString).length, length: 0)
        shouldFocusWhenReady = false
    }
}

private struct PetJournalDocumentSidebar: View {
    @ObservedObject var store: PetJournalStore
    @Environment(\.journalSearchText) private var searchText

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("我的文档")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button(action: {
                    _ = store.createDocument()
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 30))
                .help("新建文档")
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.filteredDocuments(matching: searchText)) { document in
                        PetJournalDocumentCard(
                            document: document,
                            isSelected: document.id == store.selectedDocumentID,
                            selectAction: {
                                store.selectDocument(id: document.id)
                            },
                            favoriteAction: {
                                store.toggleFavorite(id: document.id)
                            },
                            renameAction: {
                                promptRename(document)
                            },
                            deleteAction: {
                                confirmDelete(document)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(width: 230)
        .companionGlassSurface(radius: 28)
    }

    private func promptRename(_ document: PetJournalDocument) {
        if let title = CompanionNonBlockingAlert.promptText(
            messageText: "重命名文档",
            informativeText: "为这篇日记输入新的标题。",
            initialValue: document.displayTitle,
            placeholder: "文档标题",
            primaryButtonTitle: "保存",
            cancelButtonTitle: "取消"
        ) {
            store.renameDocument(id: document.id, title: title)
        }
    }

    private func confirmDelete(_ document: PetJournalDocument) {
        if CompanionNonBlockingAlert.confirm(
            messageText: "删除「\(document.displayTitle)」？",
            informativeText: "此操作不可撤销，文档将被永久删除。",
            primaryButtonTitle: "删除",
            cancelButtonTitle: "取消",
            tone: .danger
        ) {
            store.deleteDocument(id: document.id)
        }
    }
}

private struct JournalSearchTextKey: EnvironmentKey {
    static let defaultValue = ""
}

private extension EnvironmentValues {
    var journalSearchText: String {
        get { self[JournalSearchTextKey.self] }
        set { self[JournalSearchTextKey.self] = newValue }
    }
}

private struct PetJournalDocumentCard: View {
    let document: PetJournalDocument
    let isSelected: Bool
    let selectAction: () -> Void
    let favoriteAction: () -> Void
    let renameAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        Button(action: selectAction) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if document.isFavorite == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(XiaoHuaErTheme.amber)
                    }
                    Text(document.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }

                Text("\(document.items.count) 行 · \(levelCount) 层级")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.58) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? XiaoHuaErTheme.glassHairline : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(document.isFavorite == true ? "取消收藏" : "收藏") { favoriteAction() }
            Button("重命名") { renameAction() }
            Button("删除", role: .destructive) { deleteAction() }
        }
    }

    private var levelCount: Int {
        (document.items.map(\.level).max() ?? 0) + 1
    }
}

private enum PetJournalMarkdownExporter {
    static func markdown(for document: PetJournalDocument) -> String {
        var lines: [String] = ["# \(escapedInline(document.displayTitle))", ""]

        for item in document.items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let indentation = String(repeating: "  ", count: item.level)
            lines.append("\(indentation)- \(escapedInline(text))")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func escapedInline(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

private enum PetJournalPDFExporter {
    static func pdfData(for document: PetJournalDocument) -> Data {
        let pageSize = CGSize(width: 612, height: 792)
        let contentRect = CGRect(x: 54, y: 54, width: pageSize.width - 108, height: pageSize.height - 118)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        draw(document: document, context: context, pageSize: pageSize, contentRect: contentRect)
        context.closePDF()

        return data as Data
    }

    private static func draw(
        document: PetJournalDocument,
        context: CGContext,
        pageSize: CGSize,
        contentRect: CGRect
    ) {
        let attributedDocument = attributedString(for: document)
        let textStorage = NSTextStorage(attributedString: attributedDocument)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        textStorage.addLayoutManager(layoutManager)

        if layoutManager.numberOfGlyphs == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
            return
        }

        var renderedGlyphLocation = 0
        while renderedGlyphLocation < layoutManager.numberOfGlyphs {
            let textContainer = NSTextContainer(size: contentRect.size)
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else {
                break
            }

            context.beginPDFPage(nil)
            drawPage(
                context: context,
                pageSize: pageSize,
                contentRect: contentRect,
                layoutManager: layoutManager,
                glyphRange: glyphRange
            )
            context.endPDFPage()

            renderedGlyphLocation = NSMaxRange(glyphRange)
        }
    }

    private static func drawPage(
        context: CGContext,
        pageSize: CGSize,
        contentRect: CGRect,
        layoutManager: NSLayoutManager,
        glyphRange: NSRange
    ) {
        NSGraphicsContext.saveGraphicsState()
        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)

        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: contentRect.origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: contentRect.origin)

        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func attributedString(for document: PetJournalDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 18
        output.append(NSAttributedString(
            string: "\(document.displayTitle)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: titleParagraph
            ]
        ))

        for item in document.items {
            let indent = CGFloat(item.level) * 22
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.lineSpacing = 1.5
            paragraph.paragraphSpacing = 4

            output.append(NSAttributedString(
                string: "\(item.text.isEmpty ? " " : item.text)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: item.level == 0 ? .semibold : .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            ))
        }

        return output
    }
}

private enum PetJournalFormatters {
    static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 M 月 d 日 EEEE"
        return formatter
    }()

    static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
