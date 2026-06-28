import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

struct PetPomodoroSound: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var filename: String?

    static let none = PetPomodoroSound(id: "none", title: "关闭", filename: nil)

    init(id: String, title: String, filename: String?) {
        self.id = id
        self.title = title
        self.filename = filename
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawValue = try? container.decode(String.self) {
            id = rawValue
            if rawValue == Self.none.id {
                title = Self.none.title
                filename = nil
            } else {
                title = PetPomodoroSoundLibrary.displayName(for: rawValue)
                let ext = URL(fileURLWithPath: rawValue).pathExtension.lowercased()
                filename = PetPomodoroSoundLibrary.supportedExtensions.contains(ext) ? rawValue : nil
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
    }

    var isNone: Bool {
        id == Self.none.id
    }
}

enum PetPomodoroSoundLibrary {
    static let supportedExtensions = Set(["mp3", "m4a", "aiff", "aif", "wav"])

    // 缓存：首次访问时枚举一次目录，避免每次打开 Picker / setSound 都重复 stat 文件系统。
    private static var cachedOptions: [PetPomodoroSound]?

    static var options: [PetPomodoroSound] {
        if let cachedOptions {
            return cachedOptions
        }
        var sounds = bundledSounds()
        if sounds.isEmpty {
            sounds = legacyFallbackSounds()
        }
        let result = [.none] + sounds
        cachedOptions = result
        return result
    }

    static func sound(for stored: PetPomodoroSound?) -> PetPomodoroSound {
        let allOptions = options
        guard let stored else {
            return defaultSound(from: allOptions)
        }
        if stored == .none || stored.id == PetPomodoroSound.none.id {
            return .none
        }

        if let match = allOptions.first(where: { option in
            option.id == stored.id
                || (stored.filename != nil && option.filename == stored.filename)
                || option.title == stored.title
        }) {
            return match
        }

        if let legacy = legacySound(from: stored) {
            return legacy
        }

        return defaultSound(from: allOptions)
    }

    static func displayName(for filename: String) -> String {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func url(for sound: PetPomodoroSound) -> URL? {
        guard let filename = sound.filename else {
            return nil
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledURL = resourceURL
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("Pomodoro", isDirectory: true)
                .appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: bundledURL.path) {
                return bundledURL
            }
        }

        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
            .appendingPathComponent("Pomodoro", isDirectory: true)
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }

        return nil
    }

    private static func bundledSounds() -> [PetPomodoroSound] {
        let roots = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("Pomodoro", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("Pomodoro", isDirectory: true)
        ].compactMap { $0 }

        var found: [String: PetPomodoroSound] = [:]
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in entries {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }

                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }

                let filename = url.lastPathComponent
                found[filename] = PetPomodoroSound(
                    id: filename,
                    title: displayName(for: filename),
                    filename: filename
                )
            }
        }

        return found.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func legacyFallbackSounds() -> [PetPomodoroSound] {
        [
            PetPomodoroSound(id: "flowing-water.wav", title: "Flowing Water", filename: "flowing-water.wav"),
            PetPomodoroSound(id: "ocean-waves.wav", title: "Ocean Waves", filename: "ocean-waves.wav"),
            PetPomodoroSound(id: "rain-drops.wav", title: "Rain Drops", filename: "rain-drops.wav")
        ].filter { sound in
            url(for: sound) != nil
        }
    }

    private static func legacySound(from sound: PetPomodoroSound) -> PetPomodoroSound? {
        let legacyMap = [
            "flowingWater": "flowing-water.wav",
            "oceanWaves": "ocean-waves.wav",
            "rainDrops": "rain-drops.wav"
        ]
        guard let filename = legacyMap[sound.id] else {
            return nil
        }
        return options.first { $0.filename == filename }
    }

    private static func defaultSound(from options: [PetPomodoroSound]) -> PetPomodoroSound {
        let ambientKeywords = ["ocean", "rain", "river", "mountain", "wind", "woods", "hill", "atmosphere", "duskfall"]
        for keyword in ambientKeywords {
            if let ambient = options.first(where: { sound in
                !sound.isNone && sound.title.lowercased().contains(keyword)
            }) {
                return ambient
            }
        }

        return options.first(where: { !$0.isNone }) ?? .none
    }
}

enum PetPomodoroMode: String, Codable, Equatable {
    case focus
    case shortBreak

    var title: String {
        switch self {
        case .focus:
            return "专注"
        case .shortBreak:
            return "休息"
        }
    }

    var completionTitle: String {
        switch self {
        case .focus:
            return "该休息一下了"
        case .shortBreak:
            return "休息结束"
        }
    }

    var completionMessage: String {
        switch self {
        case .focus:
            return "番茄闹钟已结束，站起来活动一下吧。"
        case .shortBreak:
            return "短休息结束了，可以开始下一轮专注。"
        }
    }
}

enum PetPomodoroRunState: String, Codable, Equatable {
    case idle
    case running
    case paused

    var title: String {
        switch self {
        case .idle:
            return "待开始"
        case .running:
            return "进行中"
        case .paused:
            return "已暂停"
        }
    }
}

struct PetPomodoroCompletion {
    let mode: PetPomodoroMode
    let completedAt: Date
    let taskTitle: String?
    let durationSeconds: Int
    let startedAt: Date?
    let focusRecord: PetFocusRecord?
}

struct PetFocusRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var taskTitle: String
    var durationSeconds: Int
    var startedAt: Date
    var completedAt: Date
    var sourceReminderTitle: String?

    init(
        id: UUID = UUID(),
        taskTitle: String,
        durationSeconds: Int,
        startedAt: Date,
        completedAt: Date,
        sourceReminderTitle: String? = nil
    ) {
        self.id = id
        self.taskTitle = taskTitle
        self.durationSeconds = max(durationSeconds, 1)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.sourceReminderTitle = sourceReminderTitle
    }

    var displayTaskTitle: String {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名专注" : trimmed
    }
}

final class PetPomodoroController: ObservableObject {
    private static let maxTaskTitleLength = 100

    private struct Payload: Codable {
        var version: Int
        var focusMinutes: Int
        var shortBreakMinutes: Int
        var mode: PetPomodoroMode
        var state: PetPomodoroRunState
        var durationSeconds: Int
        var remainingSeconds: Int
        var startedAt: Date?
        var endDate: Date?
        var sound: PetPomodoroSound?
        var volume: Double?
        var taskTitle: String?
        var focusRecords: [PetFocusRecord]?
        var countdownInMenuBarEnabled: Bool?
    }

    @Published private(set) var focusMinutes: Int
    @Published private(set) var shortBreakMinutes: Int
    @Published private(set) var mode: PetPomodoroMode
    @Published private(set) var state: PetPomodoroRunState
    @Published private(set) var durationSeconds: Int
    @Published private(set) var remainingSeconds: Int
    @Published private(set) var sound: PetPomodoroSound
    @Published private(set) var volume: Double
    @Published var taskTitle: String
    @Published private(set) var focusRecords: [PetFocusRecord]
    @Published private(set) var countdownInMenuBarEnabled: Bool

    var onSessionStarted: ((PetPomodoroMode) -> Void)?
    var onSessionCompleted: ((PetPomodoroCompletion) -> Void)?

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let soundPlayer = PetPomodoroSoundPlayer()
    private let timerQueue = DispatchQueue(label: "com.crazyjal.companion.pomodoro.timer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var timerActivity: NSObjectProtocol?
    private var startedAt: Date?
    private var endDate: Date?
    private var isCompleting = false
    private var systemObservers: [NSObjectProtocol] = []
    private var loadFailed = false
    private var pendingSaveWorkItem: DispatchWorkItem?

    private var stateURL: URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("pomodoro.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let initialStateURL = CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("pomodoro.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601

        CompanionDataBackup.dailyBackup(of: initialStateURL)
        let loaded = Self.loadPayload(from: initialStateURL, decoder: decoder, fileManager: fileManager, environment: environment)
        let payload = loaded.payload
        self.loadFailed = loaded.loadFailed
        let focusMinutes = Self.clampedMinutes(payload?.focusMinutes ?? 25, range: 1...180)
        let shortBreakMinutes = Self.clampedMinutes(payload?.shortBreakMinutes ?? 5, range: 1...60)
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        let loadedState = payload?.state ?? .idle
        self.mode = loadedState == .idle ? .focus : (payload?.mode ?? .focus)
        self.state = loadedState
        self.durationSeconds = max(payload?.durationSeconds ?? focusMinutes * 60, 1)
        self.remainingSeconds = max(payload?.remainingSeconds ?? focusMinutes * 60, 0)
        self.sound = PetPomodoroSoundLibrary.sound(for: payload?.sound)
        self.volume = min(max(payload?.volume ?? 0.38, 0), 1)
        self.taskTitle = payload?.taskTitle ?? ""
        self.focusRecords = Self.filteredFocusRecords(payload?.focusRecords ?? [])
        self.countdownInMenuBarEnabled = payload?.countdownInMenuBarEnabled ?? false
        self.startedAt = payload?.startedAt
        self.endDate = payload?.endDate

        if state == .running, let endDate {
            remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSince(Date()))))
            if remainingSeconds <= 0 {
                finishElapsedOfflineSession()
            }
        } else if state == .running {
            state = .idle
            remainingSeconds = defaultDurationSeconds(for: mode)
            durationSeconds = remainingSeconds
        } else if state == .idle {
            durationSeconds = defaultDurationSeconds(for: mode)
            remainingSeconds = durationSeconds
        }

        registerSystemObservers()
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: CompanionDataRoot.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadFromDataRoot()
            }
        )
        // 防抖窗口内退出会丢最后一次改动；长生命周期对象的 deinit 不保证执行，必须靠通知 flush。
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushPendingSave()
            }
        )
    }

    deinit {
        flushPendingSave()
        stopTimer()
        soundPlayer.stop()
        for token in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
    }

    // 睡眠唤醒 / 系统时钟 / 时区变化后，基于绝对 endDate 的倒计时可能与预期不符，
    // 立即用 endDate 重算一次剩余时间，并在仍运行时重排计时器。
    private func registerSystemObservers() {
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.handleSystemTimeShift()
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

    func handleSystemTimeShift() {
        guard state == .running else { return }
        tick()
        if state == .running {
            scheduleTimerIfNeeded()
        }
    }

    /// 数据根切换后重新读取番茄钟数据。运行 / 暂停中只刷新已落盘的 focusRecords（不打断当前计时与会话）；
    /// 空闲时按新数据根完整恢复设置与状态。这样 Focus Review 不会读到旧统计，下次保存也不会用旧内存覆盖新数据根。
    func reloadFromDataRoot() {
        flushPendingSave()
        let loaded = Self.loadPayload(from: stateURL, decoder: decoder, fileManager: fileManager, environment: environment)
        guard !loaded.loadFailed else {
            loadFailed = true
            return
        }

        loadFailed = false
        let payload = loaded.payload
        focusRecords = Self.filteredFocusRecords(payload?.focusRecords ?? [])

        guard state == .idle else { return }

        stopTimer()
        soundPlayer.stop()

        let focusMinutes = Self.clampedMinutes(payload?.focusMinutes ?? 25, range: 1...180)
        let shortBreakMinutes = Self.clampedMinutes(payload?.shortBreakMinutes ?? 5, range: 1...60)
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.sound = PetPomodoroSoundLibrary.sound(for: payload?.sound)
        self.volume = min(max(payload?.volume ?? 0.38, 0), 1)
        self.taskTitle = payload?.taskTitle ?? ""
        self.countdownInMenuBarEnabled = payload?.countdownInMenuBarEnabled ?? false

        let loadedState = payload?.state ?? .idle
        self.mode = loadedState == .idle ? .focus : (payload?.mode ?? .focus)
        self.state = loadedState
        self.durationSeconds = max(payload?.durationSeconds ?? focusMinutes * 60, 1)
        self.remainingSeconds = max(payload?.remainingSeconds ?? focusMinutes * 60, 0)
        self.startedAt = payload?.startedAt
        self.endDate = payload?.endDate

        if state == .running, let endDate {
            remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSince(Date()))))
            if remainingSeconds <= 0 {
                finishElapsedOfflineSession()
            }
        } else if state == .running {
            state = .idle
            remainingSeconds = defaultDurationSeconds(for: mode)
            durationSeconds = remainingSeconds
        } else if state == .idle {
            durationSeconds = defaultDurationSeconds(for: mode)
            remainingSeconds = durationSeconds
            startedAt = nil
            endDate = nil
        } else if state == .paused {
            endDate = nil
        }

        if state == .running {
            tick()
            if state == .running {
                scheduleTimerIfNeeded()
                updateSoundPlayback()
            }
        }
    }

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        let completed = max(0, durationSeconds - remainingSeconds)
        return min(max(Double(completed) / Double(durationSeconds), 0), 1)
    }

    var isFocusActive: Bool {
        state == .running && mode == .focus
    }

    func start() {
        tick()
        scheduleTimerIfNeeded()
        updateSoundPlayback()
    }

    func startFocus() {
        startSession(mode: .focus, seconds: focusMinutes * 60)
    }

    func startFocus(taskTitle: String, sourceReminderTitle: String? = nil) {
        setTaskTitle(taskTitle)
        startSession(mode: .focus, seconds: focusMinutes * 60, sourceReminderTitle: sourceReminderTitle)
    }

    func startFocus(taskTitle: String, durationMinutes: Int?) {
        let minutes = durationMinutes.map { Self.clampedMinutes($0, range: 1...180) } ?? focusMinutes
        setTaskTitle(taskTitle)
        startSession(mode: .focus, seconds: minutes * 60)
    }

    func startShortBreak() {
        startSession(mode: .shortBreak, seconds: shortBreakMinutes * 60)
    }

    func pause() {
        guard state == .running else { return }
        updateRemainingFromEndDate()
        state = .paused
        endDate = nil
        stopTimer()
        soundPlayer.stop()
        save()
    }

    func resume() {
        guard state == .paused, remainingSeconds > 0 else { return }
        if startedAt == nil {
            startedAt = Date()
        }
        endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        state = .running
        save()
        scheduleTimerIfNeeded()
        updateSoundPlayback()
        onSessionStarted?(mode)
    }

    func reset() {
        stopTimer()
        soundPlayer.stop()
        mode = .focus
        state = .idle
        startedAt = nil
        endDate = nil
        durationSeconds = defaultDurationSeconds(for: mode)
        remainingSeconds = durationSeconds
        save()
    }

    func stop() {
        reset()
    }

    func setSound(_ value: PetPomodoroSound) {
        sound = PetPomodoroSoundLibrary.sound(for: value)
        scheduleSave()
        updateSoundPlayback()
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        soundPlayer.updateVolume(volume)
        scheduleSave()
    }

    func setTaskTitle(_ value: String) {
        let trimmed = Self.limitedTaskTitle(value)
        guard taskTitle != trimmed else { return }
        taskTitle = trimmed
        scheduleSave()
    }

    func toggleCountdownInMenuBar() {
        countdownInMenuBarEnabled.toggle()
        scheduleSave()
    }

    func setFocusMinutes(_ value: Int) {
        focusMinutes = Self.clampedMinutes(value, range: 1...180)
        if state == .idle, mode == .focus {
            durationSeconds = focusMinutes * 60
            remainingSeconds = durationSeconds
        }
        scheduleSave()
    }

    func setShortBreakMinutes(_ value: Int) {
        shortBreakMinutes = Self.clampedMinutes(value, range: 1...60)
        if state == .idle, mode == .shortBreak {
            durationSeconds = shortBreakMinutes * 60
            remainingSeconds = durationSeconds
        }
        scheduleSave()
    }

    private func startSession(mode: PetPomodoroMode, seconds: Int, sourceReminderTitle: String? = nil) {
        let seconds = max(seconds, 1)
        stopTimer()
        self.mode = mode
        state = .running
        durationSeconds = seconds
        remainingSeconds = seconds
        startedAt = Date()
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        if mode == .focus, let sourceReminderTitle {
            taskTitle = sourceReminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        save()
        scheduleTimerIfNeeded()
        updateSoundPlayback()
        onSessionStarted?(mode)
    }

    private func scheduleTimerIfNeeded() {
        stopTimer()
        guard state == .running else {
            return
        }
        beginTimerActivityIfNeeded()

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        endTimerActivity()
    }

    private func beginTimerActivityIfNeeded() {
        guard timerActivity == nil else {
            return
        }

        timerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Companion Pomodoro timer is running"
        )
    }

    private func endTimerActivity() {
        guard let timerActivity else {
            return
        }

        ProcessInfo.processInfo.endActivity(timerActivity)
        self.timerActivity = nil
    }

    private func tick() {
        guard state == .running else { return }
        updateRemainingFromEndDate()
        if remainingSeconds <= 0 {
            completeCurrentSession()
        }
    }

    private func updateRemainingFromEndDate() {
        guard let endDate else { return }
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSince(Date()))))
    }

    private func completeCurrentSession() {
        guard !isCompleting else { return }
        isCompleting = true
        stopTimer()
        soundPlayer.stop()

        let completedMode = mode
        let completedAt = Date()
        let completedStartedAt = startedAt ?? completedAt.addingTimeInterval(-TimeInterval(durationSeconds))
        let completedTaskTitle = taskTitle
        let completedDurationSeconds = durationSeconds
        let focusRecord: PetFocusRecord?
        if completedMode == .focus {
            let record = PetFocusRecord(
                taskTitle: completedTaskTitle,
                durationSeconds: completedDurationSeconds,
                startedAt: completedStartedAt,
                completedAt: completedAt
            )
            focusRecords.insert(record, at: 0)
            focusRecords = Self.filteredFocusRecords(focusRecords)
            focusRecord = record
        } else {
            focusRecord = nil
        }
        let nextMode: PetPomodoroMode = completedMode == .focus ? .shortBreak : .focus
        mode = nextMode
        state = .idle
        startedAt = nil
        endDate = nil
        durationSeconds = defaultDurationSeconds(for: nextMode)
        remainingSeconds = durationSeconds
        save()
        onSessionCompleted?(PetPomodoroCompletion(
            mode: completedMode,
            completedAt: completedAt,
            taskTitle: completedTaskTitle,
            durationSeconds: completedDurationSeconds,
            startedAt: completedStartedAt,
            focusRecord: focusRecord
        ))
        isCompleting = false
    }

    private func finishElapsedOfflineSession() {
        let nextMode: PetPomodoroMode = mode == .focus ? .shortBreak : .focus
        mode = nextMode
        state = .idle
        startedAt = nil
        endDate = nil
        durationSeconds = defaultDurationSeconds(for: nextMode)
        remainingSeconds = durationSeconds
        save()
    }

    private func defaultDurationSeconds(for mode: PetPomodoroMode) -> Int {
        switch mode {
        case .focus:
            return focusMinutes * 60
        case .shortBreak:
            return shortBreakMinutes * 60
        }
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.save()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func flushPendingSave() {
        guard pendingSaveWorkItem != nil else { return }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        save()
    }

    private func save() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard !loadFailed else {
            CompanionPersistenceAlert.reportSaveBlocked(context: "番茄闹钟")
            return
        }

        do {
            try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = Payload(
                version: 1,
                focusMinutes: focusMinutes,
                shortBreakMinutes: shortBreakMinutes,
                mode: mode,
                state: state,
                durationSeconds: durationSeconds,
                remainingSeconds: remainingSeconds,
                startedAt: startedAt,
                endDate: endDate,
                sound: sound,
                volume: volume,
                taskTitle: taskTitle,
                focusRecords: focusRecords,
                countdownInMenuBarEnabled: countdownInMenuBarEnabled
            )
            let data = try encoder.encode(payload)
            try data.write(to: stateURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            CompanionPersistenceAlert.reportSaveFailure(context: "番茄闹钟", error: error)
        }
    }

    private static func loadPayload(
        from url: URL,
        decoder: JSONDecoder,
        fileManager: FileManager,
        environment: [String: String]
    ) -> (payload: Payload?, loadFailed: Bool) {
        let candidates = CompanionDataRoot.recoveryURLs(forFileNamed: "pomodoro.json", environment: environment)
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return (nil, false)
        }

        var primaryError: Error?
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                let payload = try loadPayloadFile(from: candidate, decoder: decoder)
                if candidate.standardizedFileURL.path != url.standardizedFileURL.path {
                    try CompanionDataBackup.restoreRecoveredFile(from: candidate, to: url, fileManager: fileManager)
                    NSLog("Companion recovered pomodoro.json from \(candidate.path)")
                }
                return (payload, false)
            } catch {
                if candidate.standardizedFileURL.path == url.standardizedFileURL.path {
                    primaryError = error
                }
            }
        }

        reportLoadFailure(for: url, fileManager: fileManager, error: primaryError ?? persistenceError("pomodoro.json is unreadable."))
        return (nil, true)
    }

    private static func loadPayloadFile(from url: URL, decoder: JSONDecoder) throws -> Payload {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw persistenceError("pomodoro.json is empty.")
        }
        return try decoder.decode(Payload.self, from: data)
    }

    private static func reportLoadFailure(for url: URL, fileManager: FileManager, error: Error) {
        CompanionDataBackup.backupUnreadableFile(at: url, fileManager: fileManager)
        CompanionPersistenceAlert.reportLoadFailure(context: "番茄闹钟", error: error)
    }

    private static func persistenceError(_ message: String) -> Error {
        NSError(domain: "CompanionPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func clampedMinutes(_ value: Int, range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func filteredFocusRecords(_ records: [PetFocusRecord], now: Date = Date()) -> [PetFocusRecord] {
        let calendar = Calendar.current
        let recentRecords = records.filter { record in
            guard let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else {
                return true
            }
            return record.completedAt >= cutoff
        }
        return Array(recentRecords.sorted { $0.completedAt > $1.completedAt }.prefix(300))
    }

    private static func limitedTaskTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTaskTitleLength else {
            return trimmed
        }

        let index = trimmed.index(trimmed.startIndex, offsetBy: maxTaskTitleLength)
        return String(trimmed[..<index])
    }

    private func updateSoundPlayback() {
        soundPlayer.updateVolume(volume)
        guard state == .running else {
            soundPlayer.stop()
            return
        }

        soundPlayer.play(PetPomodoroSoundLibrary.sound(for: sound))
    }
}

private final class PetPomodoroSoundPlayer {
    private var player: AVAudioPlayer?
    private var playingSound: PetPomodoroSound = .none
    private var pendingSound: PetPomodoroSound = .none
    private var volume: Float = 0.38
    private let loadQueue = DispatchQueue(label: "com.crazyjal.companion.pomodoro.audio", qos: .userInitiated)

    func updateVolume(_ value: Double) {
        volume = Float(min(max(value, 0), 1))
        player?.volume = volume
    }

    func play(_ sound: PetPomodoroSound) {
        guard !sound.isNone else {
            stop()
            return
        }

        if playingSound == sound, player?.isPlaying == true {
            player?.volume = volume
            return
        }

        guard
            let url = PetPomodoroSoundLibrary.url(for: sound)
        else {
            NSLog("Companion pomodoro sound missing: \(sound.id)")
            stop()
            return
        }

        // 异步加载，避免大音频文件（数 MB）在主线程同步 init 造成卡顿。
        pendingSound = sound
        let targetVolume = volume
        loadQueue.async { [weak self] in
            let loaded = try? AVAudioPlayer(contentsOf: url)
            DispatchQueue.main.async {
                guard let self, self.pendingSound == sound else { return }
                guard let loaded else {
                    NSLog("Companion pomodoro sound failed to load: \(sound.id)")
                    self.stop()
                    CompanionPersistenceAlert.reportPlaybackFailure(sound: sound.title)
                    return
                }
                loaded.numberOfLoops = -1
                loaded.volume = targetVolume
                loaded.prepareToPlay()
                loaded.play()
                self.player = loaded
                self.playingSound = sound
            }
        }
    }

    func stop() {
        pendingSound = .none
        player?.stop()
        player = nil
        playingSound = .none
    }
}

final class DesktopPetPomodoroFeature: NSObject {
    var onMenuNeedsUpdate: (() -> Void)?
    // 专注（focus 且 running）开始/结束时回调，让桌宠在专注期间暂停自动爬墙。
    var onFocusActiveChanged: ((Bool) -> Void)?
    var onPomodoroStateChanged: ((PetPomodoroMode, PetPomodoroRunState) -> Void)?
    var onFocusStarted: (() -> Void)?
    var onFocusEnded: (() -> Void)?
    var onBreakStarted: (() -> Void)?
    var onMenuBarCountdownChanged: ((String?) -> Void)?
    var onFocusRecordCompleted: ((PetFocusRecord) -> Void)?
    var onFocusRecordSaveRequested: ((PetFocusRecord) -> Void)?
    private var lastFocusActive = false
    private var lastMenuSignature = ""

    private let controller = PetPomodoroController()
    private lazy var bubbleController = PetPomodoroBubbleController(controller: controller)
    private let centerWindowDelegate = PetPomodoroCenterWindowDelegate()
    private var anchorWindowProvider: (() -> NSWindow?)?
    private var centerWindow: NSWindow?
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        controller.onSessionCompleted = { [weak self] completion in
            guard let self else { return }
            self.bubbleController.show(completion: completion, anchorWindow: self.anchorWindowProvider?())
            if completion.mode == .focus {
                if self.lastFocusActive {
                    self.lastFocusActive = false
                    self.onFocusActiveChanged?(false)
                }
                self.onFocusEnded?()
                if let record = completion.focusRecord {
                    self.onFocusRecordCompleted?(record)
                }
            }
        }
        controller.onSessionStarted = { [weak self] mode in
            if mode == .focus {
                self?.onFocusStarted?()
            } else {
                self?.onBreakStarted?()
            }
        }

        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.onPomodoroStateChanged?(self.controller.mode, self.controller.state)
                    let focusing = self.controller.state == .running && self.controller.mode == .focus
                    if focusing != self.lastFocusActive {
                        self.lastFocusActive = focusing
                        self.onFocusActiveChanged?(focusing)
                    }
                    self.emitMenuUpdateIfNeeded()
                    self.emitMenuBarCountdown()
                }
            }
    }

    func start(anchorWindowProvider: @escaping () -> NSWindow?) {
        self.anchorWindowProvider = anchorWindowProvider
        bubbleController.saveFocusRecordAction = { [weak self] record in
            self?.onFocusRecordSaveRequested?(record)
        }
        controller.start()
        lastFocusActive = controller.isFocusActive
        onPomodoroStateChanged?(controller.mode, controller.state)
        onFocusActiveChanged?(lastFocusActive)
        emitMenuUpdateIfNeeded(force: true)
        emitMenuBarCountdown()
    }

    func startFocus(taskTitle: String) {
        controller.startFocus(taskTitle: taskTitle)
    }

    func startFocus(taskTitle: String, durationMinutes: Int?) {
        controller.startFocus(taskTitle: taskTitle, durationMinutes: durationMinutes)
    }

    var hasActiveSession: Bool {
        controller.state != .idle
    }

    var focusMinutes: Int {
        controller.focusMinutes
    }

    func focusRecordsSnapshot() -> [PetFocusRecord] {
        controller.focusRecords
    }

    func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let centerItem = NSMenuItem(title: "番茄闹钟", action: #selector(showPomodoroAction), keyEquivalent: "")
        centerItem.target = self
        items.append(centerItem)

        switch controller.state {
        case .idle:
            let focusItem = NSMenuItem(title: "开始专注 \(controller.focusMinutes) 分钟", action: #selector(startFocusAction), keyEquivalent: "")
            focusItem.target = self
            items.append(focusItem)

            let breakItem = NSMenuItem(title: "开始休息 \(controller.shortBreakMinutes) 分钟", action: #selector(startShortBreakAction), keyEquivalent: "")
            breakItem.target = self
            items.append(breakItem)
        case .running:
            items.append(statusItem(title: "\(controller.mode.title) \(Self.timeString(controller.remainingSeconds))"))
            let pauseItem = NSMenuItem(title: "暂停番茄闹钟", action: #selector(pauseAction), keyEquivalent: "")
            pauseItem.target = self
            items.append(pauseItem)

            let stopItem = NSMenuItem(title: "停止番茄闹钟", action: #selector(stopAction), keyEquivalent: "")
            stopItem.target = self
            items.append(stopItem)
        case .paused:
            items.append(statusItem(title: "已暂停 \(Self.timeString(controller.remainingSeconds))"))
            let resumeItem = NSMenuItem(title: "继续番茄闹钟", action: #selector(resumeAction), keyEquivalent: "")
            resumeItem.target = self
            items.append(resumeItem)

            let stopItem = NSMenuItem(title: "停止番茄闹钟", action: #selector(stopAction), keyEquivalent: "")
            stopItem.target = self
            items.append(stopItem)
        }

        let countdownItem = NSMenuItem(title: "菜单栏倒计时：\(controller.countdownInMenuBarEnabled ? "开" : "关")", action: #selector(toggleCountdownAction), keyEquivalent: "")
        countdownItem.target = self
        countdownItem.state = controller.countdownInMenuBarEnabled ? .on : .off
        items.append(countdownItem)

        return items
    }

    func makeMainMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        switch controller.state {
        case .idle:
            let focusItem = NSMenuItem(title: "开始专注 \(controller.focusMinutes) 分钟", action: #selector(startFocusAction), keyEquivalent: "")
            focusItem.target = self
            items.append(focusItem)

            let breakItem = NSMenuItem(title: "开始休息 \(controller.shortBreakMinutes) 分钟", action: #selector(startShortBreakAction), keyEquivalent: "")
            breakItem.target = self
            items.append(breakItem)
        case .running:
            items.append(statusItem(title: "\(controller.mode.title) \(Self.timeString(controller.remainingSeconds))"))

            let pauseItem = NSMenuItem(title: "暂停番茄闹钟", action: #selector(pauseAction), keyEquivalent: "")
            pauseItem.target = self
            items.append(pauseItem)

            let stopItem = NSMenuItem(title: "停止番茄闹钟", action: #selector(stopAction), keyEquivalent: "")
            stopItem.target = self
            items.append(stopItem)
        case .paused:
            items.append(statusItem(title: "已暂停 \(Self.timeString(controller.remainingSeconds))"))

            let resumeItem = NSMenuItem(title: "继续番茄闹钟", action: #selector(resumeAction), keyEquivalent: "")
            resumeItem.target = self
            items.append(resumeItem)

            let stopItem = NSMenuItem(title: "停止番茄闹钟", action: #selector(stopAction), keyEquivalent: "")
            stopItem.target = self
            items.append(stopItem)
        }

        return items
    }

    @objc private func showPomodoroAction() {
        showPomodoroCenter()
    }

    @objc private func startFocusAction() {
        controller.startFocus()
    }

    @objc private func startShortBreakAction() {
        controller.startShortBreak()
    }

    @objc private func pauseAction() {
        controller.pause()
    }

    @objc private func resumeAction() {
        controller.resume()
    }

    @objc private func stopAction() {
        controller.stop()
    }

    @objc private func toggleCountdownAction() {
        controller.toggleCountdownInMenuBar()
        emitMenuBarCountdown()
        emitMenuUpdateIfNeeded(force: true)
    }

    func showPomodoroCenter() {
        if centerWindow == nil {
            let view = PetPomodoroCenterView(controller: controller)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.contentMinSize = NSSize(width: 620, height: 520)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = CompanionInteractiveHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.delegate = centerWindowDelegate
            window.title = "小花儿番茄闹钟"
            centerWindow = window
        }

        centerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func statusItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func timeString(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let seconds = max(seconds, 0) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func emitMenuBarCountdown() {
        guard controller.countdownInMenuBarEnabled,
              controller.mode == .focus,
              controller.state != .idle else {
            onMenuBarCountdownChanged?(nil)
            return
        }

        let prefix = controller.state == .paused ? "专注暂停" : "专注"
        onMenuBarCountdownChanged?("\(prefix) \(Self.timeString(controller.remainingSeconds))")
    }

    private func emitMenuUpdateIfNeeded(force: Bool = false) {
        let signature = [
            controller.mode.rawValue,
            controller.state.rawValue,
            "\(controller.focusMinutes)",
            "\(controller.shortBreakMinutes)",
            controller.countdownInMenuBarEnabled ? "countdown-on" : "countdown-off"
        ].joined(separator: "|")
        guard force || signature != lastMenuSignature else { return }
        lastMenuSignature = signature
        onMenuNeedsUpdate?()
    }
}

private final class PetPomodoroCenterWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private final class PetPomodoroBubblePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class PetPomodoroBubbleController {
    private static let bubbleWidth: CGFloat = 368
    private static let fallbackFocusBubbleHeight: CGFloat = 172
    private static let fallbackBreakBubbleHeight: CGFloat = 148

    private let controller: PetPomodoroController
    var saveFocusRecordAction: ((PetFocusRecord) -> Void)?
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    init(controller: PetPomodoroController) {
        self.controller = controller
        // 完成气泡弹出后，若用户在别处又开始了新的专注/休息，关闭过期的完成气泡。
        cancellable = controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if state == .running {
                    self?.close()
                }
            }
    }

    func show(completion: PetPomodoroCompletion, anchorWindow: NSWindow?) {
        close()

        let view = PetPomodoroBubbleView(
            completion: completion,
            startFocusAction: { [weak self] in
                self?.controller.startFocus()
                self?.close()
            },
            startBreakAction: { [weak self] in
                self?.controller.startShortBreak()
                self?.close()
            },
            saveToJournalAction: { [weak self] record in
                self?.saveFocusRecordAction?(record)
                self?.close()
            },
            closeAction: { [weak self] in
                self?.close()
            }
        )
        let hostingView = PetPomodoroBubbleHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let size = Self.fittingSize(
            for: hostingView,
            width: Self.bubbleWidth,
            fallbackHeight: completion.mode == .focus ? Self.fallbackFocusBubbleHeight : Self.fallbackBreakBubbleHeight
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        let panel = PetPomodoroBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "小花儿番茄闹钟"
        panel.contentView = hostingView
        panel.setFrameOrigin(Self.origin(for: size, anchorWindow: anchorWindow))
        panel.orderFrontRegardless()
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
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

    private static func fittingSize<Content: View>(
        for hostingView: NSHostingView<Content>,
        width: CGFloat,
        fallbackHeight: CGFloat
    ) -> NSSize {
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = hostingView.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        hostingView.layoutSubtreeIfNeeded()
        let measuredHeight = ceil(hostingView.fittingSize.height)
        widthConstraint.isActive = false
        hostingView.translatesAutoresizingMaskIntoConstraints = true

        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        let height = min(max(measuredHeight > 1 ? measuredHeight : fallbackHeight, 120), maxHeight)
        return NSSize(width: width, height: height)
    }
}

private final class PetPomodoroBubbleHostingView<Content: View>: CompanionInteractiveHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        true
    }
}

private struct PetPomodoroCenterView: View {
    @ObservedObject var controller: PetPomodoroController
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 26) {
            toolbar

            HStack(spacing: 30) {
                timerPanel
                sidePanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(34)
        .padding(.top, 24)
        .frame(width: 720, height: 620)
        .background(CompanionLiquidWindowBackground())
        .background(CompanionWindowAccessor { window = $0 })
        .environment(\.companionWindow, window)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var toolbar: some View {
        HStack {
            CompanionTrafficLights()

            Text("番茄闹钟")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(height: 46)
        .companionGlassSurface(radius: 23)
    }

    private var timerPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Text(controller.state == .running ? "专注中" : controller.state.title)
                    .font(.system(size: 26, weight: .semibold))
                CompanionStatusTag(title: controller.mode.title, tint: controller.mode == .focus ? XiaoHuaErTheme.amber : XiaoHuaErTheme.leaf)
                Spacer()
            }

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.46), lineWidth: 40)
                Circle()
                    .trim(from: 0, to: controller.progress)
                    .stroke(
                        controller.mode == .focus ? XiaoHuaErTheme.amber.opacity(0.55) : XiaoHuaErTheme.leaf.opacity(0.5),
                        style: StrokeStyle(lineWidth: 40, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill((controller.mode == .focus ? XiaoHuaErTheme.amber : XiaoHuaErTheme.leaf).opacity(0.18))
                    .frame(width: 196, height: 196)

                VStack(spacing: 8) {
                    Text(Self.timeString(controller.remainingSeconds))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    Text(controller.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "深度工作" : controller.taskTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 160)
                }
            }
            .frame(width: 276, height: 276)
            .frame(maxWidth: .infinity)

            actionButtons
                .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .companionGlassSurface(radius: 36)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("任务队列")
                .font(.system(size: 22, weight: .semibold))
            taskNameField
            todayFocusRecords
            Divider()
            Divider().opacity(0.55)
            soundPicker
            volumeControl
            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: focusMinutesBinding, in: 1...180) {
                    HStack {
                        Text("专注时长")
                        Spacer()
                        Text("\(controller.focusMinutes) 分钟")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(controller.state == .running)

                Stepper(value: shortBreakMinutesBinding, in: 1...60) {
                    HStack {
                        Text("休息时长")
                        Spacer()
                        Text("\(controller.shortBreakMinutes) 分钟")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(controller.state == .running)
            }
        }
        .padding(28)
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .companionGlassSurface(radius: 28)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 16) {
            switch controller.state {
            case .idle:
                Button(action: controller.startShortBreak) {
                    Text("休息")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 96))

                Button(action: controller.startFocus) {
                    Label("开始专注", systemImage: "play.fill")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 126))
            case .running:
                Button(action: controller.pause) {
                    Text("暂停")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 96))

                Button(action: controller.stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 96))
            case .paused:
                Button(action: controller.stop) {
                    Text("停止")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 96))

                Button(action: controller.resume) {
                    Label("继续", systemImage: "play.fill")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 126))
            }
        }
    }

    private var taskNameField: some View {
        TextField("这轮要完成什么？", text: taskTitleBinding)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .companionGlassField(radius: 18)
            .disabled(controller.state == .running)
    }

    private var todayFocusRecords: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("今日专注", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(todayRecords.count) 轮")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if todayRecords.isEmpty {
                Text("还没有完成的专注轮次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(todayRecords.prefix(3)) { record in
                        HStack(spacing: 6) {
                            Text(record.displayTaskTitle)
                                .lineLimit(1)
                            Spacer()
                            Text("\(max(1, record.durationSeconds / 60)) 分钟")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .background(XiaoHuaErTheme.recessedSurface, in: RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous))
    }

    private var todayRecords: [PetFocusRecord] {
        let calendar = Calendar.current
        return controller.focusRecords.filter { calendar.isDateInToday($0.completedAt) }
    }

    private var soundPicker: some View {
        HStack(spacing: 10) {
            Label("声音", systemImage: controller.sound.isNone ? "speaker.slash" : "speaker.wave.2")
                .frame(width: 92, alignment: .leading)

            Picker("", selection: soundBinding) {
                ForEach(PetPomodoroSoundLibrary.options) { sound in
                    Text(sound.title).tag(sound)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Label("音量", systemImage: "speaker.wave.1")
                .frame(width: 92, alignment: .leading)

            Slider(value: volumeBinding, in: 0...1)
                .disabled(controller.sound.isNone)

            Text("\(Int((controller.volume * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { controller.volume },
            set: { controller.setVolume($0) }
        )
    }

    private var taskTitleBinding: Binding<String> {
        Binding(
            get: { controller.taskTitle },
            set: { controller.setTaskTitle($0) }
        )
    }

    private var focusMinutesBinding: Binding<Int> {
        Binding(
            get: { controller.focusMinutes },
            set: { controller.setFocusMinutes($0) }
        )
    }

    private var shortBreakMinutesBinding: Binding<Int> {
        Binding(
            get: { controller.shortBreakMinutes },
            set: { controller.setShortBreakMinutes($0) }
        )
    }

    private var soundBinding: Binding<PetPomodoroSound> {
        Binding(
            get: { controller.sound },
            set: { controller.setSound($0) }
        )
    }

    private static func timeString(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let seconds = max(seconds, 0) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct PetPomodoroBubbleView: View {
    let completion: PetPomodoroCompletion
    let startFocusAction: () -> Void
    let startBreakAction: () -> Void
    let saveToJournalAction: (PetFocusRecord) -> Void
    let closeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 8) {
                    Text(completion.mode.completionTitle)
                        .font(.system(size: 20, weight: .semibold))

                    Text(completion.mode.completionMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                if completion.mode == .focus {
                    Button("休息一下", action: startBreakAction)
                        .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 76))
                    Button("再专注一轮", action: startFocusAction)
                        .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 106))
                    if let record = completion.focusRecord {
                        Button("写入日记") {
                            saveToJournalAction(record)
                        }
                        .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 86))
                    }
                } else {
                    Button("开始专注", action: startFocusAction)
                        .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 106))
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .companionGlassPanel(radius: 32)
        .padding(1)
    }

    private var accent: Color {
        completion.mode == .focus ? XiaoHuaErTheme.coral : XiaoHuaErTheme.leaf
    }
}
