import Combine
import Foundation

struct TranslationHistoryRecord: Identifiable, Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case actionID
        case actionTitle
        case actionResultTitle
        case actionPrompt
        case actionIsCustom
        case sourceText
        case translatedText
        case providerName
        case sourceLanguageLabel
        case inputSource
        case createdAt
    }

    let id: UUID
    let actionID: String?
    let actionTitle: String?
    let actionResultTitle: String?
    let actionPrompt: String?
    let actionIsCustom: Bool?
    let sourceText: String
    let translatedText: String
    let providerName: String
    let sourceLanguageLabel: String
    let inputSource: CompanionAIInputSource
    let createdAt: Date

    init(
        id: UUID = UUID(),
        action: CompanionAIQuickAction = .translate,
        sourceText: String,
        translatedText: String,
        providerName: String,
        sourceLanguageLabel: String,
        inputSource: CompanionAIInputSource = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.actionID = action.id
        self.actionTitle = action.title
        self.actionResultTitle = action.resultTitle
        self.actionPrompt = action.isCustom ? action.systemPrompt : nil
        self.actionIsCustom = action.isCustom
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.providerName = providerName
        self.sourceLanguageLabel = sourceLanguageLabel
        self.inputSource = inputSource
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        actionID = try container.decodeIfPresent(String.self, forKey: .actionID)
        actionTitle = try container.decodeIfPresent(String.self, forKey: .actionTitle)
        actionResultTitle = try container.decodeIfPresent(String.self, forKey: .actionResultTitle)
        actionPrompt = try container.decodeIfPresent(String.self, forKey: .actionPrompt)
        actionIsCustom = try container.decodeIfPresent(Bool.self, forKey: .actionIsCustom)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        translatedText = try container.decode(String.self, forKey: .translatedText)
        providerName = try container.decode(String.self, forKey: .providerName)
        sourceLanguageLabel = try container.decode(String.self, forKey: .sourceLanguageLabel)
        inputSource = try container.decodeIfPresent(CompanionAIInputSource.self, forKey: .inputSource) ?? .manual
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var displayActionTitle: String {
        actionTitle ?? CompanionAIQuickAction.builtInAction(id: actionID)?.title ?? "翻译"
    }

    var displayResultTitle: String {
        actionResultTitle ?? CompanionAIQuickAction.builtInAction(id: actionID)?.resultTitle ?? "结果"
    }

    var replayAction: CompanionAIQuickAction? {
        if actionIsCustom == true, let actionID, let actionTitle, let actionPrompt {
            return CompanionAIQuickAction(
                id: actionID,
                title: actionTitle,
                resultTitle: displayResultTitle,
                systemPrompt: actionPrompt,
                isCustom: true
            )
        }

        return CompanionAIQuickAction.builtInAction(id: actionID)
    }
}

final class TranslationHistoryStore {
    private struct Payload: Codable {
        var records: [TranslationHistoryRecord]
    }

    private let maxStoredRecords = 300
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "companion.translation-history", qos: .utility)

    private var historyURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("translation_history.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [TranslationHistoryRecord] {
        guard
            fileManager.fileExists(atPath: historyURL.path),
            let data = try? Data(contentsOf: historyURL),
            !data.isEmpty
        else {
            return []
        }

        if let payload = try? decoder.decode(Payload.self, from: data) {
            return Array(payload.records.prefix(maxStoredRecords))
        }

        if let records = try? decoder.decode([TranslationHistoryRecord].self, from: data) {
            return Array(records.prefix(maxStoredRecords))
        }

        return []
    }

    func save(_ records: [TranslationHistoryRecord]) {
        let storedRecords = Array(records.prefix(maxStoredRecords))
        let targetURL = historyURL
        saveQueue.async { [fileManager, targetURL, encoder] in
            do {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try encoder.encode(Payload(records: storedRecords))
                try data.write(to: targetURL, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            } catch {
                CompanionPersistenceAlert.reportSaveFailure(context: "AI 动作历史", error: error)
            }
        }
    }
}

final class CompanionAIQuickActionStore: ObservableObject {
    private struct Payload: Codable {
        var actions: [CompanionAIQuickAction]
    }

    enum ImportError: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty:
                return CompanionL10n.text("The template file does not contain any custom actions.")
            }
        }
    }

    @Published private(set) var customActions: [CompanionAIQuickAction]

    private let maxCustomActions = 20
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "companion.ai-actions", qos: .utility)

    private var storeURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("ai_actions.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        customActions = []
        customActions = load()
    }

    var allActions: [CompanionAIQuickAction] {
        let pinned = customActions.filter(\.isPinned)
        let unpinned = customActions.filter { !$0.isPinned }
        return pinned + CompanionAIQuickAction.builtInActions + unpinned
    }

    func addCustomAction(title: String, prompt: String) {
        let title = Self.limited(title, maxLength: 18)
        let prompt = Self.limited(prompt, maxLength: 2000)
        guard !title.isEmpty, !prompt.isEmpty else { return }

        var action = CompanionAIQuickAction.custom(title: title, prompt: prompt)
        action.sortIndex = 0
        action.updatedAt = Date()
        customActions.insert(action, at: 0)
        normalizeSortIndexes()
        customActions = Array(customActions.prefix(maxCustomActions))
        save()
    }

    func updateCustomAction(id: String, title: String, prompt: String) {
        let title = Self.limited(title, maxLength: 18)
        let prompt = Self.limited(prompt, maxLength: 2000)
        guard !title.isEmpty, !prompt.isEmpty,
              let index = customActions.firstIndex(where: { $0.id == id && $0.isCustom })
        else { return }

        customActions[index].title = title
        customActions[index].systemPrompt = prompt
        customActions[index].updatedAt = Date()
        save()
    }

    func togglePinned(id: String) {
        guard let index = customActions.firstIndex(where: { $0.id == id && $0.isCustom }) else { return }
        customActions[index].isPinned.toggle()
        customActions[index].updatedAt = Date()
        normalizeSortIndexes()
        save()
    }

    func moveCustomAction(id: String, direction: Int) {
        guard direction != 0,
              let index = customActions.firstIndex(where: { $0.id == id && $0.isCustom })
        else { return }

        let newIndex = max(0, min(customActions.count - 1, index + direction))
        guard newIndex != index else { return }
        let action = customActions.remove(at: index)
        customActions.insert(action, at: newIndex)
        normalizeSortIndexes()
        save()
    }

    func exportCustomActions() throws -> Data {
        let actions = customActions.map { action in
            CompanionAIQuickAction(
                id: "template-\(UUID().uuidString)",
                title: action.title,
                resultTitle: action.resultTitle,
                systemPrompt: action.systemPrompt,
                isCustom: true,
                isPinned: action.isPinned,
                sortIndex: action.sortIndex,
                updatedAt: action.updatedAt
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Payload(actions: actions))
    }

    @discardableResult
    func importCustomActions(from data: Data) throws -> Int {
        let decodedActions: [CompanionAIQuickAction]
        if let payload = try? decoder.decode(Payload.self, from: data) {
            decodedActions = payload.actions
        } else {
            decodedActions = try decoder.decode([CompanionAIQuickAction].self, from: data)
        }

        let imported = decodedActions.enumerated().compactMap { offset, action -> (offset: Int, action: CompanionAIQuickAction)? in
            let title = Self.limited(action.title, maxLength: 18)
            let prompt = Self.limited(action.systemPrompt, maxLength: 2000)
            guard !title.isEmpty, !prompt.isEmpty else { return nil }
            var copy = CompanionAIQuickAction.custom(title: title, prompt: prompt)
            copy.isPinned = action.isPinned
            copy.sortIndex = action.sortIndex
            copy.updatedAt = Date()
            return (offset, copy)
        }

        guard !imported.isEmpty else {
            throw ImportError.empty
        }

        var seenKeys = Set(customActions.map { Self.templateKey(title: $0.title, prompt: $0.systemPrompt) })
        var importedActions: [CompanionAIQuickAction] = []
        var insertedCount = 0
        let orderedImports = imported.sorted { lhs, rhs in
            if lhs.action.isPinned != rhs.action.isPinned {
                return lhs.action.isPinned && !rhs.action.isPinned
            }
            if lhs.action.sortIndex != rhs.action.sortIndex {
                return lhs.action.sortIndex < rhs.action.sortIndex
            }
            return lhs.offset < rhs.offset
        }

        for item in orderedImports {
            let action = item.action
            let key = Self.templateKey(title: action.title, prompt: action.systemPrompt)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            importedActions.append(action)
            insertedCount += 1
        }

        guard insertedCount > 0 else {
            throw ImportError.empty
        }

        customActions = Array((importedActions + customActions).prefix(maxCustomActions))
        normalizeSortIndexes()
        save()
        return insertedCount
    }

    func replaceCustomActionsForTesting(_ actions: [CompanionAIQuickAction]) {
        customActions = Array(actions.filter(\.isCustom).prefix(maxCustomActions))
        normalizeSortIndexes()
        save()
    }

    func deleteCustomAction(id: String) {
        customActions.removeAll { $0.id == id }
        normalizeSortIndexes()
        customActions = Array(customActions.prefix(maxCustomActions))
        save()
    }

    func action(for id: String?) -> CompanionAIQuickAction? {
        guard let id else { return nil }
        return allActions.first { $0.id == id }
    }

    private func load() -> [CompanionAIQuickAction] {
        guard
            fileManager.fileExists(atPath: storeURL.path),
            let data = try? Data(contentsOf: storeURL),
            !data.isEmpty
        else {
            return []
        }

        let actions: [CompanionAIQuickAction]
        if let payload = try? decoder.decode(Payload.self, from: data) {
            actions = payload.actions
        } else {
            actions = (try? decoder.decode([CompanionAIQuickAction].self, from: data)) ?? []
        }

        var custom = Array(actions.filter { $0.isCustom && !$0.title.isEmpty && !$0.systemPrompt.isEmpty }.prefix(maxCustomActions))
        for index in custom.indices {
            if custom[index].sortIndex == 0 {
                custom[index].sortIndex = index
            }
        }
        return custom.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func save() {
        let actions = customActions
        let targetURL = storeURL
        saveQueue.async { [fileManager, targetURL, encoder] in
            do {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try encoder.encode(Payload(actions: actions))
                try data.write(to: targetURL, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            } catch {
                CompanionPersistenceAlert.reportSaveFailure(context: "AI 自定义动作", error: error)
            }
        }
    }

    private static func limited(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSortIndexes() {
        for index in customActions.indices {
            customActions[index].sortIndex = index
        }
    }

    private static func templateKey(title: String, prompt: String) -> String {
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\n\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
