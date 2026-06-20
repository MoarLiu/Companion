import AppKit
import Combine
import Foundation
import SwiftUI

/// 集中处理本地数据写入失败的用户提示：先 NSLog，再按 context 节流展示一次非阻塞提示，避免反复打扰。
/// 提醒 / 番茄闹钟 / 日记三个 store 的 save() 共用。
enum CompanionPersistenceAlert {
    private static var lastShown: [String: Date] = [:]
    private static var recentLoadFailureShownAt: [String: Date] = [:]
    private static var pendingLoadFailures: [String: String] = [:]
    private static var pendingLoadFailureWorkItem: DispatchWorkItem?
    private static let throttle: TimeInterval = 60
    private static let loadFailureCoalesceDelay: TimeInterval = 0.35

    static func reportSaveFailure(context: String, error: Error) {
        NSLog("Companion \(context) save failed: \(error.localizedDescription)")
        present(
            key: "save-\(context)",
            messageText: "Companion 无法保存\(context)",
            informativeText: "写入磁盘失败：\(error.localizedDescription)\n请检查磁盘剩余空间或 Companion 数据目录权限后重试。"
        )
    }

    static func reportLoadFailure(context: String, error: Error) {
        NSLog("Companion \(context) load failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            pendingLoadFailures[context] = error.localizedDescription
            guard pendingLoadFailureWorkItem == nil else { return }

            let workItem = DispatchWorkItem {
                showPendingLoadFailures()
            }
            pendingLoadFailureWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + loadFailureCoalesceDelay, execute: workItem)
        }
    }

    static func reportSaveBlocked(context: String) {
        NSLog("Companion \(context) save blocked after load failure")
        DispatchQueue.main.async {
            let now = Date()
            if pendingLoadFailures[context] != nil {
                return
            }
            if let last = recentLoadFailureShownAt[context], now.timeIntervalSince(last) < throttle {
                return
            }

            presentNow(
                key: "save-blocked-\(context)",
                messageText: "Companion 暂停保存\(context)",
                informativeText: "上次读取\(context)失败。为避免用空数据覆盖原文件，请先检查或恢复对应的数据文件。"
            )
        }
    }

    static func reportPlaybackFailure(sound: String) {
        NSLog("Companion pomodoro sound failed to play: \(sound)")
        present(
            key: "playback",
            messageText: "Companion 无法播放番茄闹钟音频",
            informativeText: "音频「\(sound)」加载失败，已切换为静音。可在番茄闹钟设置里更换音频。"
        )
    }

    private static func present(key: String, messageText: String, informativeText: String) {
        DispatchQueue.main.async {
            presentNow(key: key, messageText: messageText, informativeText: informativeText)
        }
    }

    private static func showPendingLoadFailures() {
        let failures = pendingLoadFailures
        pendingLoadFailures.removeAll()
        pendingLoadFailureWorkItem = nil
        guard !failures.isEmpty else { return }

        let now = Date()
        failures.keys.forEach { recentLoadFailureShownAt[$0] = now }

        if failures.count == 1, let entry = failures.first {
            presentNow(
                key: "load-failure-batch",
                messageText: "Companion 无法读取\(entry.key)",
                informativeText: "原文件已保留并复制为 .bad 备份。为避免覆盖数据，Companion 暂停保存\(entry.key)，请检查或恢复数据文件后重试。\n\(entry.value)"
            )
            return
        }

        let details = failures
            .sorted { $0.key < $1.key }
            .map { context, error in "• \(context)：\(error)" }
            .joined(separator: "\n")
        presentNow(
            key: "load-failure-batch",
            messageText: "Companion 无法读取部分本地数据",
            informativeText: "原文件已保留并复制为 .bad 备份。为避免覆盖数据，Companion 暂停保存对应数据，请检查或恢复数据文件后重试。\n\(details)"
        )
    }

    private static func presentNow(key: String, messageText: String, informativeText: String) {
        let now = Date()
        if let last = lastShown[key], now.timeIntervalSince(last) < throttle {
            return
        }
        lastShown[key] = now

        CompanionNonBlockingAlert.present(messageText: messageText, informativeText: informativeText, tone: .warning)
    }
}

/// 本地数据轻量滚动备份：每天首次启动时把 reminders/pomodoro/journal 的 json 复制一份带日期的副本，
/// 仅保留最近 maxBackups 份。即使主文件损坏被重置，也能从备份恢复最近几天的数据。
enum CompanionDataBackup {
    private static let maxBackups = 7

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dailyBackup(of url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let backupDirectory = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let stamp = dateFormatter.string(from: Date())
        let backupURL = backupDirectory.appendingPathComponent("\(base).backup-\(stamp).\(ext)")

        if !fileManager.fileExists(atPath: backupURL.path) {
            do {
                try fileManager.copyItem(at: url, to: backupURL)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            } catch {
                NSLog("Companion backup failed for \(base): \(error.localizedDescription)")
            }
        }

        pruneBackups(in: backupDirectory, base: base, ext: ext, fileManager: fileManager)
    }

    static func backupUnreadableFile(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let filename = ext.isEmpty
            ? "\(base).bad-\(timestamp)"
            : "\(base).bad-\(timestamp).\(ext)"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(filename)

        do {
            try fileManager.copyItem(at: url, to: backupURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        } catch {
            NSLog("Companion bad-file backup failed for \(base): \(error.localizedDescription)")
        }
    }

    static func restoreRecoveredFile(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            return
        }
        let data = try Data(contentsOf: source)
        if fileManager.fileExists(atPath: destination.path) {
            backupUnreadableFile(at: destination, fileManager: fileManager)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func pruneBackups(in directory: URL, base: String, ext: String, fileManager: FileManager) {
        let prefix = "\(base).backup-"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == ext }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        guard backups.count > maxBackups else { return }
        for url in backups.dropFirst(maxBackups) {
            try? fileManager.removeItem(at: url)
        }
    }
}

/// 重复提醒规则。2.4.0 新增；旧 reminders.json 无 `recurrence` 字段时解码为 nil（不重复）。
struct PetReminderRecurrence: Codable, Equatable {
    enum Frequency: String, Codable {
        case daily      // 每天
        case weekdays   // 工作日（周一至周五）
        case weekly     // 每周（与首次相同星期）
        case custom     // 自定义间隔（每 intervalDays 天）
    }

    var frequency: Frequency
    var intervalDays: Int

    init(frequency: Frequency, intervalDays: Int = 1) {
        self.frequency = frequency
        self.intervalDays = max(1, intervalDays)
    }

    static let daily = PetReminderRecurrence(frequency: .daily)
    static let weekdays = PetReminderRecurrence(frequency: .weekdays)
    static let weekly = PetReminderRecurrence(frequency: .weekly)
    static func everyDays(_ days: Int) -> PetReminderRecurrence {
        PetReminderRecurrence(frequency: .custom, intervalDays: days)
    }
}

extension PetReminderRecurrence {
    /// 从 `date` 起按规则推进到严格晚于 `reference` 的下一次触发时间。
    /// 合盖唤醒或长时间未处理时会连续推进，只保留第一个未来时刻，避免堆积或错乱。
    func nextOccurrence(after date: Date, reference: Date, calendar: Calendar = .current) -> Date {
        var candidate = date
        var guardCount = 0
        while candidate <= reference && guardCount < 4000 {
            candidate = advance(from: candidate, calendar: calendar)
            guardCount += 1
        }
        // 若 date 本身已晚于 reference（例如提前完成），仍至少推进一步表示“下一次”。
        if candidate == date {
            candidate = advance(from: candidate, calendar: calendar)
        }
        return candidate
    }

    private func advance(from date: Date, calendar: Calendar) -> Date {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        case .custom:
            let step = max(1, intervalDays)
            return calendar.date(byAdding: .day, value: step, to: date) ?? date.addingTimeInterval(Double(step) * 86_400)
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(7 * 86_400)
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
            while PetReminderRecurrence.isWeekend(next, calendar: calendar) {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400)
            }
            return next
        }
    }

    static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // Gregorian: 1 = 周日, 7 = 周六
        return weekday == 1 || weekday == 7
    }
}

struct PetReminder: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var fireDate: Date
    let createdAt: Date
    var completedAt: Date?
    var deliveredAt: Date?
    var lastSnoozedAt: Date?
    var recurrence: PetReminderRecurrence?
    /// 重复提醒的锚点时间（原始计划触发时刻）。下一次重复从锚点推算，使「稍后」只影响本次、不漂移重复时间。
    /// Optional 以兼容旧数据；非重复提醒为 nil。
    var recurrenceAnchor: Date?

    init(
        id: UUID = UUID(),
        title: String,
        fireDate: Date,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        deliveredAt: Date? = nil,
        lastSnoozedAt: Date? = nil,
        recurrence: PetReminderRecurrence? = nil,
        recurrenceAnchor: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.fireDate = fireDate
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.deliveredAt = deliveredAt
        self.lastSnoozedAt = lastSnoozedAt
        self.recurrence = recurrence
        self.recurrenceAnchor = recurrenceAnchor
    }

    var isRecurring: Bool {
        recurrence != nil
    }

    var isCompleted: Bool {
        !isRecurring && completedAt != nil
    }

    var hasAlerted: Bool {
        deliveredAt != nil && !isCompleted
    }
}

struct PetReminderDelivery: Identifiable {
    let id = UUID()
    let reminders: [PetReminder]
    let deliveredAt: Date
}

enum PetReminderStoreError: LocalizedError {
    case emptyTitle
    case pastDate
    case tooFarInFuture
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "请输入提醒事项名称。"
        case .pastDate:
            return "请选择一个还没过去的时间。"
        case .tooFarInFuture:
            return "提醒时间太远了，Companion 目前支持创建约 5 年内的提醒。请选近一点的时间。"
        case .notFound:
            return "找不到这条提醒，可能已被删除。"
        }
    }
}

final class PetReminderStore: ObservableObject {
    private struct Payload: Codable {
        var version: Int
        var reminders: [PetReminder]
    }

    @Published private(set) var reminders: [PetReminder] = []

    private let maxStoredReminders = 500
    // 上限 ~5 年：拦截明显误输入（如 2099 年），避免给 Timer 设置近乎无限的 interval；
    // 同时足够宽松，不影响正常的远期提醒。
    private static let maxFutureInterval: TimeInterval = 5 * 365 * 24 * 60 * 60
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var dataRootObserver: NSObjectProtocol?
    private var loadFailed = false

    private var remindersURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("reminders.json")
    }

    static func maximumFireDate(from date: Date = Date()) -> Date {
        date.addingTimeInterval(maxFutureInterval)
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601

        CompanionDataBackup.dailyBackup(of: remindersURL)
        reminders = load()

        dataRootObserver = NotificationCenter.default.addObserver(
            forName: CompanionDataRoot.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let dataRootObserver {
            NotificationCenter.default.removeObserver(dataRootObserver)
        }
    }

    /// 数据根切换后重新从当前数据根读取提醒，刷新已打开的提醒中心。
    func reload() {
        reminders = load()
    }

    func activeReminders(now: Date = Date()) -> [PetReminder] {
        reminders
            .filter { !$0.isCompleted }
            .sorted(by: reminderSort)
    }

    func nextPendingReminder(now: Date = Date()) -> PetReminder? {
        reminders
            .filter { !$0.isCompleted && $0.deliveredAt == nil && $0.fireDate > now }
            .sorted(by: reminderSort)
            .first
    }

    func pendingDueReminders(now: Date = Date()) -> [PetReminder] {
        reminders
            .filter { !$0.isCompleted && $0.deliveredAt == nil && $0.fireDate <= now }
            .sorted(by: reminderSort)
    }

    @discardableResult
    func addReminder(title: String, fireDate: Date, recurrence: PetReminderRecurrence? = nil) throws -> PetReminder {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw PetReminderStoreError.emptyTitle
        }
        guard fireDate > Date().addingTimeInterval(-2) else {
            throw PetReminderStoreError.pastDate
        }
        guard fireDate <= Date().addingTimeInterval(Self.maxFutureInterval) else {
            throw PetReminderStoreError.tooFarInFuture
        }

        let reminder = PetReminder(
            title: trimmedTitle,
            fireDate: fireDate,
            recurrence: recurrence,
            recurrenceAnchor: recurrence != nil ? fireDate : nil
        )
        reminders.append(reminder)
        normalizeAndSave()
        return reminder
    }

    /// 编辑已存在的提醒：修改标题、时间和重复规则，保留 id / createdAt。
    /// 编辑后视为一条全新的待触发提醒：清除已送达 / 稍后 / 完成标记。
    @discardableResult
    func updateReminder(
        id: UUID,
        title: String,
        fireDate: Date,
        recurrence: PetReminderRecurrence?,
        now: Date = Date()
    ) throws -> PetReminder {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw PetReminderStoreError.emptyTitle
        }
        guard fireDate > now.addingTimeInterval(-2) else {
            throw PetReminderStoreError.pastDate
        }
        guard fireDate <= now.addingTimeInterval(Self.maxFutureInterval) else {
            throw PetReminderStoreError.tooFarInFuture
        }
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            throw PetReminderStoreError.notFound
        }

        reminders[index].title = trimmedTitle
        reminders[index].fireDate = fireDate
        reminders[index].recurrence = recurrence
        reminders[index].recurrenceAnchor = recurrence != nil ? fireDate : nil
        reminders[index].deliveredAt = nil
        reminders[index].lastSnoozedAt = nil
        reminders[index].completedAt = nil
        normalizeAndSave()
        return reminders[index]
    }

    func complete(ids: [UUID], at date: Date = Date()) {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }

        var didChange = false
        for index in reminders.indices where idSet.contains(reminders[index].id) {
            guard !reminders[index].isCompleted else { continue }
            if let recurrence = reminders[index].recurrence {
                guard reminders[index].deliveredAt != nil || reminders[index].fireDate <= date else {
                    continue
                }
                // 重复提醒：从锚点（原始计划时刻）推算下一次，使「稍后」只影响本次、不漂移重复时间。
                let anchor = reminders[index].recurrenceAnchor ?? reminders[index].fireDate
                let next = recurrence.nextOccurrence(after: anchor, reference: date)
                reminders[index].fireDate = next
                reminders[index].recurrenceAnchor = next
                reminders[index].deliveredAt = nil
                reminders[index].lastSnoozedAt = nil
                reminders[index].completedAt = date
            } else {
                reminders[index].completedAt = date
            }
            didChange = true
        }

        if didChange {
            normalizeAndSave()
        }
    }

    func snooze(ids: [UUID], minutes: Int, now: Date = Date()) {
        let idSet = Set(ids)
        guard !idSet.isEmpty, minutes > 0 else { return }

        var didChange = false
        let nextDate = now.addingTimeInterval(TimeInterval(minutes * 60))
        for index in reminders.indices where idSet.contains(reminders[index].id) {
            guard !reminders[index].isCompleted else { continue }
            reminders[index].fireDate = nextDate
            reminders[index].deliveredAt = nil
            reminders[index].lastSnoozedAt = now
            didChange = true
        }

        if didChange {
            normalizeAndSave()
        }
    }

    func delete(id: UUID) {
        let count = reminders.count
        reminders.removeAll { $0.id == id }
        if reminders.count != count {
            normalizeAndSave()
        }
    }

    @discardableResult
    func markDelivered(ids: [UUID], at date: Date = Date()) -> [PetReminder] {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return [] }

        var delivered: [PetReminder] = []
        for index in reminders.indices where idSet.contains(reminders[index].id) {
            guard !reminders[index].isCompleted, reminders[index].deliveredAt == nil else {
                continue
            }
            reminders[index].deliveredAt = date
            delivered.append(reminders[index])
        }

        if !delivered.isEmpty {
            normalizeAndSave()
        }

        return delivered.sorted(by: reminderSort)
    }

    private func load() -> [PetReminder] {
        loadFailed = false
        let primaryURL = remindersURL
        let candidates = CompanionDataRoot.recoveryURLs(forFileNamed: "reminders.json", environment: environment)
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        var primaryError: Error?
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                let reminders = try loadReminders(from: candidate)
                if candidate.standardizedFileURL.path != primaryURL.standardizedFileURL.path {
                    try CompanionDataBackup.restoreRecoveredFile(from: candidate, to: primaryURL, fileManager: fileManager)
                    NSLog("Companion recovered reminders.json from \(candidate.path)")
                }
                return retainedReminders(reminders)
            } catch {
                if candidate.standardizedFileURL.path == primaryURL.standardizedFileURL.path {
                    primaryError = error
                }
            }
        }

        markLoadFailure(primaryError ?? Self.persistenceError("reminders.json is unreadable."))
        return []
    }

    private func loadReminders(from url: URL) throws -> [PetReminder] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw Self.persistenceError("reminders.json is empty.")
        }

        do {
            let payload = try decoder.decode(Payload.self, from: data)
            return payload.reminders
        } catch {
            return try decoder.decode([PetReminder].self, from: data)
        }
    }

    private func markLoadFailure(_ error: Error) {
        loadFailed = true
        CompanionDataBackup.backupUnreadableFile(at: remindersURL, fileManager: fileManager)
        CompanionPersistenceAlert.reportLoadFailure(context: "提醒", error: error)
    }

    private static func persistenceError(_ message: String) -> Error {
        NSError(domain: "CompanionPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func normalizeAndSave() {
        reminders = retainedReminders(reminders)
        save()
    }

    private func retainedReminders(_ values: [PetReminder]) -> [PetReminder] {
        let active = values.filter { !$0.isCompleted }
        let completed = values
            .filter(\.isCompleted)
            .sorted { left, right in
                let leftCompleted = left.completedAt ?? .distantPast
                let rightCompleted = right.completedAt ?? .distantPast
                if leftCompleted == rightCompleted {
                    return reminderSort(left, right)
                }
                return leftCompleted > rightCompleted
            }
            .prefix(maxStoredReminders)
        return (active + Array(completed)).sorted(by: reminderSort)
    }

    private func save() {
        guard !loadFailed else {
            CompanionPersistenceAlert.reportSaveBlocked(context: "提醒")
            return
        }

        do {
            try fileManager.createDirectory(at: remindersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = Payload(version: 1, reminders: reminders)
            let data = try encoder.encode(payload)
            try data.write(to: remindersURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: remindersURL.path)
        } catch {
            CompanionPersistenceAlert.reportSaveFailure(context: "提醒", error: error)
        }
    }
}

private func reminderSort(_ left: PetReminder, _ right: PetReminder) -> Bool {
    if left.fireDate == right.fireDate {
        return left.createdAt < right.createdAt
    }
    return left.fireDate < right.fireDate
}

/// “明天上午”稍后选项：从现在到明天指定小时（默认 9 点）的分钟数，至少 1 分钟。
private func minutesUntilTomorrowMorning(now: Date = Date(), hour: Int = 9, calendar: Calendar = .current) -> Int {
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return 60 }
    var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
    components.hour = hour
    components.minute = 0
    components.second = 0
    guard let target = calendar.date(from: components) else { return 60 }
    let minutes = Int((target.timeIntervalSince(now) / 60).rounded())
    return max(1, minutes)
}

final class PetReminderScheduler {
    var onRemindersDue: ((PetReminderDelivery) -> Void)?

    private let store: PetReminderStore
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var systemObservers: [NSObjectProtocol] = []
    private var isCheckingDueReminders = false

    init(store: PetReminderStore) {
        self.store = store
        cancellable = store.$reminders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleNextCheck()
            }
        registerSystemObservers()
    }

    deinit {
        timer?.invalidate()
        for token in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
    }

    // 监听睡眠唤醒 / 系统时钟 / 时区变化：这些都会让基于 wall-clock 的 Timer 失准，
    // 发生后立即补检查一次过期提醒并重排下一次触发。
    private func registerSystemObservers() {
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.checkDueReminders()
        }
        systemObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)
        )
        for name in [Notification.Name.NSSystemClockDidChange, Notification.Name.NSSystemTimeZoneDidChange] {
            systemObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main, using: handler)
            )
        }
    }

    func start() {
        checkDueReminders()
        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        guard !isCheckingDueReminders else {
            return
        }

        timer?.invalidate()
        let now = Date()
        if !store.pendingDueReminders(now: now).isEmpty {
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.checkDueReminders()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return
        }

        guard let next = store.nextPendingReminder(now: now) else {
            timer = nil
            return
        }

        let interval = max(0.5, next.fireDate.timeIntervalSince(now))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.checkDueReminders()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkDueReminders() {
        guard !isCheckingDueReminders else { return }
        isCheckingDueReminders = true
        defer {
            isCheckingDueReminders = false
            scheduleNextCheck()
        }

        let now = Date()
        let due = store.pendingDueReminders(now: now)
        guard !due.isEmpty else {
            return
        }

        let delivered = store.markDelivered(ids: due.map(\.id), at: now)
        guard !delivered.isEmpty else {
            return
        }

        onRemindersDue?(PetReminderDelivery(reminders: delivered, deliveredAt: now))
    }
}

final class DesktopPetReminderFeature: NSObject {
    var onMenuNeedsUpdate: (() -> Void)?
    var onRemindersDue: ((PetReminderDelivery) -> Void)?
    var onStartFocusRequested: ((String) -> Void)?

    private let store: PetReminderStore
    private let scheduler: PetReminderScheduler
    private let bubbleController: PetReminderBubbleController
    private var anchorWindowProvider: (() -> NSWindow?)?
    private var centerWindow: NSWindow?
    private var quickAddPanel: NSPanel?
    private var cancellable: AnyCancellable?

    override init() {
        let store = PetReminderStore()
        self.store = store
        self.scheduler = PetReminderScheduler(store: store)
        self.bubbleController = PetReminderBubbleController(store: store)
        super.init()

        scheduler.onRemindersDue = { [weak self] delivery in
            guard let self else { return }
            self.bubbleController.show(
                delivery: delivery,
                anchorWindow: self.anchorWindowProvider?(),
                startFocusAction: { [weak self] title in
                    self?.onStartFocusRequested?(title)
                }
            )
            self.onRemindersDue?(delivery)
        }

        cancellable = store.$reminders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onMenuNeedsUpdate?()
            }
    }

    func start(anchorWindowProvider: @escaping () -> NSWindow?) {
        self.anchorWindowProvider = anchorWindowProvider
        scheduler.start()
    }

    func remindersSnapshot() -> [PetReminder] {
        store.reminders
    }

    func reloadFromDataRoot(showWindow: Bool = false) {
        store.reload()
        if showWindow {
            showReminderCenter()
        }
    }

    /// 由 Journal“转提醒”等外部入口创建提醒。静默失败：不打断来源流程（保存失败时 store 自身会弹告警）。
    func addReminder(from draft: PetJournalReminderDraft) {
        do {
            _ = try store.addReminder(title: draft.title, fireDate: draft.fireDate, recurrence: draft.recurrence)
        } catch {
            NSLog("Companion: convert-to-reminder failed: \(error.localizedDescription)")
        }
    }

    func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let addItem = NSMenuItem(title: "添加提醒", action: #selector(addReminderAction), keyEquivalent: "")
        addItem.target = self
        items.append(addItem)

        let centerItem = NSMenuItem(title: "提醒事项", action: #selector(showReminderCenterAction), keyEquivalent: "")
        centerItem.target = self
        items.append(centerItem)

        if let next = store.nextPendingReminder() {
            let nextItem = NSMenuItem(
                title: "下一条：\(Self.shortMenuTitle(next.title)) \(PetReminderFormatters.shortTime.string(from: next.fireDate))",
                action: nil,
                keyEquivalent: ""
            )
            nextItem.isEnabled = false
            items.append(nextItem)
        }

        return items
    }

    @objc func addReminderAction() {
        showQuickAddReminderPanel()
    }

    @objc func showReminderCenterAction() {
        showReminderCenter()
    }

    /// 直接创建一个定时提醒并返回其 id（供旗舰 routine reminder-focus-journal 用），失败返回 nil。
    func createTimedReminder(title: String, fireDate: Date) -> UUID? {
        (try? store.addReminder(title: title, fireDate: fireDate))?.id
    }

    @discardableResult
    func showQuickAddReminder(prefillTitle: String = "") -> Bool {
        showQuickAddReminderPanel(prefillTitle: prefillTitle)
    }

    func showReminderCenter() {
        if centerWindow == nil {
            let view = PetReminderCenterView(
                store: store,
                startFocusAction: { [weak self] title in
                    self?.onStartFocusRequested?(title)
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = CompanionInteractiveHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.title = "提醒事项"
            centerWindow = window
        }

        centerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func showQuickAddReminderPanel(prefillTitle: String = "") -> Bool {
        if let quickAddPanel {
            quickAddPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if !prefillTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CompanionNonBlockingAlert.present(
                    messageText: "已有提醒草稿",
                    informativeText: "小花儿没有替换正在编辑的提醒。请先保存或关闭当前草稿，再从 AI 结果生成提醒草稿。",
                    tone: .warning
                )
                return false
            }
            return true
        }

        let size = NSSize(width: 650, height: 176)
        let panel = PetReminderBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "快速添加提醒"

        let view = PetReminderQuickAddView(
            store: store,
            initialTitle: prefillTitle,
            closeAction: { [weak self] in
                self?.quickAddPanel?.orderOut(nil)
                self?.quickAddPanel = nil
            }
        )
        let hostingView = CompanionInteractiveHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setFrameOrigin(Self.quickPanelOrigin(for: size, anchorWindow: anchorWindowProvider?()))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        quickAddPanel = panel
        return true
    }

    private static func quickPanelOrigin(for size: NSSize, anchorWindow: NSWindow?) -> CGPoint {
        let visibleFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let anchorWindow, anchorWindow.isVisible {
            let anchor = anchorWindow.frame
            let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + 16), visibleFrame.maxX - size.width - 16)
            let y = min(max(anchor.maxY + 12, visibleFrame.minY + 16), visibleFrame.maxY - size.height - 16)
            return CGPoint(x: x, y: y)
        }

        return CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
    }

    private static func shortMenuTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 14 else {
            return trimmed
        }

        let index = trimmed.index(trimmed.startIndex, offsetBy: 14)
        return "\(trimmed[..<index])..."
    }
}

private final class PetReminderBubblePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class PetReminderBubbleController {
    private let store: PetReminderStore
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var shownReminderIDs: Set<UUID> = []

    init(store: PetReminderStore) {
        self.store = store
        // 气泡显示后，若其涉及的提醒在别处被完成/删除，自动关闭，避免显示过期内容。
        cancellable = store.$reminders
            .receive(on: RunLoop.main)
            .sink { [weak self] reminders in
                self?.reconcile(with: reminders)
            }
    }

    func show(delivery: PetReminderDelivery, anchorWindow: NSWindow?, startFocusAction: @escaping (String) -> Void) {
        close()

        let reminderIDs = delivery.reminders.map(\.id)
        shownReminderIDs = Set(reminderIDs)
        let size = NSSize(width: 420, height: Self.height(for: delivery.reminders.count))
        let panel = PetReminderBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = "小花儿提醒"

        let view = PetReminderBubbleView(
            delivery: delivery,
            completeAction: { [weak self] in
                self?.store.complete(ids: reminderIDs)
                self?.close()
            },
            snoozeAction: { [weak self] minutes in
                self?.store.snooze(ids: reminderIDs, minutes: minutes)
                self?.close()
            },
            startFocusAction: { [weak self] title in
                self?.store.complete(ids: reminderIDs)
                startFocusAction(title)
                self?.close()
            },
            closeAction: { [weak self] in
                self?.close()
            }
        )
        let hostingView = CompanionInteractiveHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setFrameOrigin(Self.origin(for: size, anchorWindow: anchorWindow))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        shownReminderIDs = []
    }

    // store 更新时检查：气泡内的提醒若已全部被完成或删除，则自动关闭。
    private func reconcile(with reminders: [PetReminder]) {
        guard panel != nil, !shownReminderIDs.isEmpty else { return }
        let stillRelevant = reminders.contains { reminder in
            shownReminderIDs.contains(reminder.id) && !reminder.isCompleted && reminder.deliveredAt != nil
        }
        if !stillRelevant {
            close()
        }
    }

    private static func height(for count: Int) -> CGFloat {
        let visibleRows = min(max(count, 1), 3)
        return CGFloat(176 + visibleRows * 42 + (count > 3 ? 20 : 0))
    }

    private static func origin(for size: NSSize, anchorWindow: NSWindow?) -> CGPoint {
        let visibleFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let anchorWindow, anchorWindow.isVisible {
            let anchor = anchorWindow.frame
            let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + 16), visibleFrame.maxX - size.width - 16)
            let aboveY = anchor.maxY + 10
            let y: CGFloat
            if aboveY + size.height <= visibleFrame.maxY {
                y = aboveY
            } else {
                y = max(visibleFrame.minY + 16, anchor.minY - size.height - 10)
            }
            return CGPoint(x: x, y: y)
        }

        return CGPoint(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.minY + 88
        )
    }
}

private struct PetReminderCenterView: View {
    @ObservedObject var store: PetReminderStore
    let startFocusAction: (String) -> Void
    @State private var title = ""
    @State private var fireDate = Self.defaultFireDate()
    @State private var minimumFireDate = Date()
    @State private var errorMessage = ""
    @State private var searchText = ""
    @State private var selectedFilter: ReminderFilter = .today
    @State private var window: NSWindow?
    @State private var recurrence: PetReminderRecurrence?
    @State private var editingReminderID: UUID?
    @State private var customIntervalDays = 2

    private enum ReminderFilter: String, CaseIterable {
        case today
        case upcoming
        case completed

        var title: String {
            switch self {
            case .today: return "今天"
            case .upcoming: return "即将到来"
            case .completed: return "已完成"
            }
        }
    }

    var body: some View {
        VStack(spacing: 26) {
            toolbar

            VStack(alignment: .leading, spacing: 22) {
                header
                filterBar
                addReminderCard
                reminderList
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .companionGlassSurface(radius: 32)
        }
        .padding(28)
        .padding(.top, 24)
        .frame(width: 820, height: 560)
        .background(CompanionLiquidWindowBackground())
        .background(CompanionWindowAccessor { window = $0 })
        .environment(\.companionWindow, window)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear(perform: refreshMinimumFireDate)
    }

    private var activeCount: Int {
        store.activeReminders().count
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("提醒事项")
                .font(.system(size: 30, weight: .semibold))
            Spacer()

            if editingReminderID != nil {
                Button("取消") { cancelEditing() }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 80))
            }

            Button(action: submitReminder) {
                Label(
                    editingReminderID == nil ? "添加提醒" : "保存修改",
                    systemImage: editingReminderID == nil ? "plus" : "checkmark"
                )
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 112))
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            CompanionTrafficLights()

            Text("提醒事项")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .frame(width: 194, height: 32)
            .companionGlassField(radius: 16)
        }
        .padding(.horizontal, 28)
        .frame(height: 46)
        .companionGlassSurface(radius: 23)
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(ReminderFilter.allCases, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 13, weight: selectedFilter == filter ? .semibold : .medium))
                        .foregroundStyle(selectedFilter == filter ? XiaoHuaErTheme.tint : .secondary)
                        .frame(width: 96, height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedFilter == filter ? Color.white.opacity(0.58) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .companionGlassField(radius: 19)
        .fixedSize()
    }

    private var addReminderCard: some View {
        HStack(spacing: 14) {
            TextField(editingReminderID == nil ? "快速添加提醒" : "编辑提醒内容", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 18)
                .frame(height: 36)
                .companionGlassField(radius: 18)
                .onSubmit(submitReminder)

            DatePicker(
                "",
                selection: fireDateSelection,
                in: minimumFireDate...maximumFireDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()

            Menu {
                Button("不重复") { recurrence = nil }
                Button("每天") { recurrence = .daily }
                Button("工作日") { recurrence = .weekdays }
                Button("每周") { recurrence = .weekly }
                Button("自定义间隔") { recurrence = .everyDays(customIntervalDays) }
            } label: {
                Label(recurrenceTitle, systemImage: "repeat")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(width: 104)

            if recurrence?.frequency == .custom {
                Stepper("每 \(customIntervalDays) 天", value: $customIntervalDays, in: 1...60)
                    .font(.system(size: 12))
                    .fixedSize()
                    .onChange(of: customIntervalDays) { newValue in
                        recurrence = .everyDays(newValue)
                    }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    private var recurrenceTitle: String {
        guard let recurrence else { return "不重复" }
        switch recurrence.frequency {
        case .daily: return "每天"
        case .weekdays: return "工作日"
        case .weekly: return "每周"
        case .custom: return "每 \(recurrence.intervalDays) 天"
        }
    }

    private var reminderList: some View {
        let reminders = filteredReminders

        return Group {
            if reminders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(reminders) { reminder in
                            PetReminderRow(
                                reminder: reminder,
                                completeAction: {
                                    store.complete(ids: [reminder.id])
                                },
                                snoozeAction: { minutes in
                                    store.snooze(ids: [reminder.id], minutes: minutes)
                                },
                                startFocusAction: {
                                    store.complete(ids: [reminder.id])
                                    startFocusAction(reminder.title)
                                },
                                editAction: {
                                    beginEditing(reminder)
                                },
                                deleteAction: {
                                    store.delete(id: reminder.id)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("暂无提醒事项")
                .font(.headline)
            Text("在上方添加一条，Companion 会在桌面帮你盯着。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredReminders: [PetReminder] {
        let now = Date()
        let calendar = Calendar.current
        let base: [PetReminder]
        switch selectedFilter {
        case .today:
            base = store.activeReminders().filter { $0.fireDate <= now || calendar.isDateInToday($0.fireDate) || $0.hasAlerted }
        case .upcoming:
            base = store.activeReminders().filter { $0.fireDate > now && !calendar.isDateInToday($0.fireDate) && !$0.hasAlerted }
        case .completed:
            base = store.reminders.filter(\.isCompleted).sorted(by: reminderSort)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else {
            return base
        }
        return base.filter { $0.title.localizedLowercase.contains(query) }
    }

    private var fireDateSelection: Binding<Date> {
        Binding(
            get: { fireDate },
            set: { fireDate = min(max($0, minimumFireDate), maximumFireDate) }
        )
    }

    private var maximumFireDate: Date {
        PetReminderStore.maximumFireDate(from: minimumFireDate)
    }

    private func submitReminder() {
        if editingReminderID != nil {
            saveEdit()
        } else {
            addReminder()
        }
    }

    private func addReminder() {
        do {
            refreshMinimumFireDate()
            _ = try store.addReminder(title: title, fireDate: fireDate, recurrence: recurrence)
            resetComposer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveEdit() {
        guard let id = editingReminderID else { return }
        do {
            refreshMinimumFireDate()
            _ = try store.updateReminder(id: id, title: title, fireDate: fireDate, recurrence: recurrence)
            resetComposer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginEditing(_ reminder: PetReminder) {
        minimumFireDate = Date()
        editingReminderID = reminder.id
        title = reminder.title
        fireDate = max(reminder.fireDate, minimumFireDate)
        recurrence = reminder.recurrence
        if let recurrence = reminder.recurrence, recurrence.frequency == .custom {
            customIntervalDays = recurrence.intervalDays
        }
        errorMessage = ""
    }

    private func cancelEditing() {
        resetComposer()
    }

    private func resetComposer() {
        title = ""
        fireDate = Self.defaultFireDate()
        recurrence = nil
        editingReminderID = nil
        customIntervalDays = 2
        errorMessage = ""
    }

    private func refreshMinimumFireDate() {
        minimumFireDate = Date()
        if fireDate < minimumFireDate {
            fireDate = Self.defaultFireDate(from: minimumFireDate)
        } else if fireDate > maximumFireDate {
            fireDate = maximumFireDate
        }
    }

    private static func defaultFireDate(from date: Date = Date()) -> Date {
        date.addingTimeInterval(15 * 60)
    }
}

private struct PetReminderRow: View {
    let reminder: PetReminder
    let completeAction: () -> Void
    let snoozeAction: (Int) -> Void
    let startFocusAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    @State private var isHovering = false

    private var accent: Color {
        reminder.hasAlerted ? XiaoHuaErTheme.amber : XiaoHuaErTheme.tint
    }

    var body: some View {
        HStack(spacing: 18) {
            Text(timeTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(XiaoHuaErTheme.tint)
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(reminder.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                CompanionStatusTag(title: statusTitle, tint: accent)
            }

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                if !reminder.isCompleted {
                    Button(action: { snoozeAction(5) }) {
                        Label("稍后", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 76))

                    Button(action: completeAction) {
                        Label("完成", systemImage: "checkmark")
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 76))
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 74)
        .companionGlassSurface(radius: 24)
        .onHover { isHovering = $0 }
        .contextMenu {
            if !reminder.isCompleted {
                Button("开始专注") { startFocusAction() }
                Button("编辑…") { editAction() }
                Menu("稍后") {
                    Button("5 分钟后") { snoozeAction(5) }
                    Button("15 分钟后") { snoozeAction(15) }
                    Button("1 小时后") { snoozeAction(60) }
                    Button("明天上午") { snoozeAction(minutesUntilTomorrowMorning()) }
                }
                Button("完成") { completeAction() }
            }
            Button("删除", role: .destructive) { deleteAction() }
        }
    }

    private var timeTitle: String {
        if Calendar.current.isDateInTomorrow(reminder.fireDate) {
            return "明天"
        }
        if Calendar.current.isDateInToday(reminder.fireDate) || reminder.fireDate <= Date() {
            return PetReminderFormatters.shortTime.string(from: reminder.fireDate)
        }
        return PetReminderFormatters.shortDate.string(from: reminder.fireDate)
    }

    private var statusTitle: String {
        if reminder.isCompleted { return "已完成" }
        if reminder.hasAlerted { return "已提醒" }
        if Calendar.current.isDateInToday(reminder.fireDate) { return "今天" }
        return PetReminderFormatters.relativeString(for: reminder.fireDate)
    }
}

private struct PetReminderBubbleView: View {
    let delivery: PetReminderDelivery
    let completeAction: () -> Void
    let snoozeAction: (Int) -> Void
    let startFocusAction: (String) -> Void
    let closeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(XiaoHuaErTheme.coral)
                .frame(height: 5)
                .padding(.horizontal, -14)
                .padding(.top, -14)

            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(XiaoHuaErTheme.coral)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 7) {
                    Text(delivery.reminders.count == 1 ? "提醒到了" : "提醒到了 \(delivery.reminders.count) 条")
                        .font(.system(size: 20, weight: .semibold))

                    ForEach(delivery.reminders.prefix(3)) { reminder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            Text(PetReminderFormatters.fullDate.string(from: reminder.fireDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }

            if delivery.reminders.count > 3 {
                Text("还有 \(delivery.reminders.count - 3) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 46)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Menu("稍后") {
                    Button("5 分钟后") { snoozeAction(5) }
                    Button("15 分钟后") { snoozeAction(15) }
                    Button("1 小时后") { snoozeAction(60) }
                    Button("明天上午") { snoozeAction(minutesUntilTomorrowMorning()) }
                }
                .frame(width: 96)

                Button("完成", action: completeAction)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 92))

                if let firstReminder = delivery.reminders.first {
                    Button("专注") {
                        startFocusAction(firstReminder.title)
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 78))
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .companionGlassPanel(radius: 32)
        .padding(1)
    }
}

private struct PetReminderQuickAddView: View {
    @ObservedObject var store: PetReminderStore
    let closeAction: () -> Void
    @State private var title: String
    @State private var fireDate = Date().addingTimeInterval(15 * 60)
    @State private var minimumFireDate = Date()
    @State private var errorMessage = ""

    init(store: PetReminderStore, initialTitle: String = "", closeAction: @escaping () -> Void) {
        self.store = store
        self.closeAction = closeAction
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("快速添加提醒")
                .font(.system(size: 22, weight: .semibold))

            HStack(spacing: 14) {
                TextField("例如：30分钟后 喝水", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .companionGlassField(radius: 18)
                    .onSubmit(save)

                DatePicker(
                    "",
                    selection: fireDateSelection,
                    in: minimumFireDate...maximumFireDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .frame(width: 140)

                Button("取消", action: closeAction)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 76))

                Button {
                    save()
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 76))
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(24)
        .frame(width: 650, height: 176, alignment: .topLeading)
        .companionGlassPanel(radius: 30, shadowRadius: 28)
        .padding(1)
        .onAppear {
            minimumFireDate = Date()
            if fireDate < minimumFireDate {
                fireDate = minimumFireDate.addingTimeInterval(15 * 60)
            } else if fireDate > maximumFireDate {
                fireDate = maximumFireDate
            }
        }
    }

    private var fireDateSelection: Binding<Date> {
        Binding(
            get: { fireDate },
            set: { fireDate = min(max($0, minimumFireDate), maximumFireDate) }
        )
    }

    private var maximumFireDate: Date {
        PetReminderStore.maximumFireDate(from: minimumFireDate)
    }

    private func save() {
        do {
            minimumFireDate = Date()
            let parsedInput = PetReminderRuleParser.parse(title, now: minimumFireDate)
            let reminderTitle = parsedInput?.title ?? title
            let reminderDate = parsedInput?.fireDate ?? fireDate
            _ = try store.addReminder(
                title: reminderTitle,
                fireDate: max(reminderDate, minimumFireDate),
                recurrence: parsedInput?.recurrence
            )
            closeAction()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum PetReminderFormatters {
    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func relativeString(for date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
