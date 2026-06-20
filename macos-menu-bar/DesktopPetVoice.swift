import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum PetVoiceEvent: String, CaseIterable {
    case launch
    case focusStart
    case focusEnd
    case breakStart
    case reminderDue
    case translationDone

    var title: String {
        switch self {
        case .launch:
            return "启动问候"
        case .focusStart:
            return "开始专注"
        case .focusEnd:
            return "专注完成"
        case .breakStart:
            return "休息开始"
        case .reminderDue:
            return "提醒到期"
        case .translationDone:
            return "AI 完成"
        }
    }
}

enum DesktopPetPresenceIntensity: String, CaseIterable {
    case quiet
    case standard
    case active

    var title: String {
        switch self {
        case .quiet:
            return "安静"
        case .standard:
            return "标准"
        case .active:
            return "活跃"
        }
    }

    var edgeIdleDelay: TimeInterval {
        switch self {
        case .quiet:
            return 240
        case .standard:
            return 75
        case .active:
            return 35
        }
    }
}

struct DesktopPetQuietHours: Equatable {
    var isEnabled: Bool
    var startHour: Int
    var endHour: Int

    init(isEnabled: Bool = false, startHour: Int = 22, endHour: Int = 8) {
        self.isEnabled = isEnabled
        self.startHour = Self.clampedHour(startHour)
        self.endHour = Self.clampedHour(endHour)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }

    var title: String {
        isEnabled ? "\(Self.hourTitle(startHour))-\(Self.hourTitle(endHour))" : "关"
    }

    private static func clampedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    static func hourTitle(_ hour: Int) -> String {
        String(format: "%02d:00", clampedHour(hour))
    }
}

final class DesktopPetBehaviorSettingsStore: NSObject {
    var onChange: (() -> Void)?

    private static let quietHoursEnabledKey = "CompanionXiaoHuaErQuietHoursEnabled"
    private static let quietHoursStartKey = "CompanionXiaoHuaErQuietHoursStart"
    private static let quietHoursEndKey = "CompanionXiaoHuaErQuietHoursEnd"
    private static let presenceIntensityKey = "CompanionXiaoHuaErPresenceIntensity"
    private static let restPromptEnabledKey = "CompanionXiaoHuaErRestPromptEnabled"
    private static let voiceOverridePrefix = "CompanionXiaoHuaErVoiceOverride."
    private static let audioExtensions = Set(["mp3", "m4a", "aiff", "aif", "wav"])

    private let defaults: UserDefaults
    private(set) var quietHours: DesktopPetQuietHours
    private(set) var presenceIntensity: DesktopPetPresenceIntensity
    private(set) var restPromptEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let start = defaults.object(forKey: Self.quietHoursStartKey) as? Int ?? 22
        let end = defaults.object(forKey: Self.quietHoursEndKey) as? Int ?? 8
        quietHours = DesktopPetQuietHours(
            isEnabled: defaults.bool(forKey: Self.quietHoursEnabledKey),
            startHour: start,
            endHour: end
        )
        let rawIntensity = defaults.string(forKey: Self.presenceIntensityKey) ?? DesktopPetPresenceIntensity.standard.rawValue
        presenceIntensity = DesktopPetPresenceIntensity(rawValue: rawIntensity) ?? .standard
        if defaults.object(forKey: Self.restPromptEnabledKey) == nil {
            restPromptEnabled = true
        } else {
            restPromptEnabled = defaults.bool(forKey: Self.restPromptEnabledKey)
        }
        super.init()
    }

    func makeMenuItems() -> [NSMenuItem] {
        let quietItem = NSMenuItem(title: "勿扰时段：\(quietHours.title)", action: nil, keyEquivalent: "")
        let quietMenu = NSMenu()
        quietMenu.addItem(menuItem(
            title: "关闭勿扰",
            action: #selector(disableQuietHours),
            state: quietHours.isEnabled ? .off : .on
        ))
        quietMenu.addItem(menuItem(
            title: "22:00-08:00",
            action: #selector(selectQuietHoursPreset(_:)),
            representedObject: "22-8",
            state: quietHours == DesktopPetQuietHours(isEnabled: true, startHour: 22, endHour: 8) ? .on : .off
        ))
        quietMenu.addItem(menuItem(
            title: "23:00-07:00",
            action: #selector(selectQuietHoursPreset(_:)),
            representedObject: "23-7",
            state: quietHours == DesktopPetQuietHours(isEnabled: true, startHour: 23, endHour: 7) ? .on : .off
        ))
        quietMenu.addItem(menuItem(title: "自定义", action: #selector(showQuietHoursPanel)))
        quietItem.submenu = quietMenu

        let intensityItem = NSMenuItem(title: "状态强度：\(presenceIntensity.title)", action: nil, keyEquivalent: "")
        let intensityMenu = NSMenu()
        for intensity in DesktopPetPresenceIntensity.allCases {
            intensityMenu.addItem(menuItem(
                title: intensity.title,
                action: #selector(selectPresenceIntensity(_:)),
                representedObject: intensity.rawValue,
                state: intensity == presenceIntensity ? .on : .off
            ))
        }
        intensityItem.submenu = intensityMenu

        let restItem = menuItem(
            title: "休息提示：\(restPromptEnabled ? "开" : "关")",
            action: #selector(toggleRestPrompt),
            state: restPromptEnabled ? .on : .off
        )

        return [quietItem, intensityItem, restItem]
    }

    func isQuietTime(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        quietHours.contains(date, calendar: calendar)
    }

    func allowsVoice(event: PetVoiceEvent, force: Bool = false, now: Date = Date()) -> Bool {
        if force {
            return true
        }
        if isQuietTime(now) {
            return false
        }
        if presenceIntensity == .quiet {
            return event == .reminderDue
        }
        return true
    }

    func customVoiceURL(for event: PetVoiceEvent) -> URL? {
        guard let path = defaults.string(forKey: Self.voiceOverridePrefix + event.rawValue), !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCustomVoice(sourceURL: URL, for event: PetVoiceEvent) throws {
        guard Self.audioExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw PetVoiceOverrideError.unsupportedFile
        }
        let directory = CompanionDataRoot.currentURL()
            .appendingPathComponent("voice-overrides", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "\(event.rawValue)-\(Self.safeFilename(sourceURL.lastPathComponent, fallback: "voice.\(sourceURL.pathExtension)"))"
        let destination = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        defaults.set(destination.path, forKey: Self.voiceOverridePrefix + event.rawValue)
        notifyChanged()
    }

    func removeCustomVoice(for event: PetVoiceEvent) {
        defaults.removeObject(forKey: Self.voiceOverridePrefix + event.rawValue)
        notifyChanged()
    }

    @objc private func disableQuietHours() {
        quietHours.isEnabled = false
        saveQuietHours()
    }

    @objc private func selectQuietHoursPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        switch raw {
        case "22-8":
            quietHours = DesktopPetQuietHours(isEnabled: true, startHour: 22, endHour: 8)
        case "23-7":
            quietHours = DesktopPetQuietHours(isEnabled: true, startHour: 23, endHour: 7)
        default:
            return
        }
        saveQuietHours()
    }

    @objc private func showQuietHoursPanel() {
        var saved: (start: Int, end: Int)?

        CompanionGlassModalHost.runModal(width: 440, fallbackHeight: 320, title: "小花儿勿扰时段") {
            QuietHoursFormView(
                initialStart: quietHours.startHour,
                initialEnd: quietHours.endHour,
                onSave: { start, end in
                    saved = (start, end)
                    NSApp.stopModal(withCode: .OK)
                },
                onCancel: {
                    NSApp.stopModal(withCode: .cancel)
                }
            )
        }

        guard let saved else { return }
        quietHours = DesktopPetQuietHours(isEnabled: true, startHour: saved.start, endHour: saved.end)
        saveQuietHours()
    }

    @objc private func selectPresenceIntensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let intensity = DesktopPetPresenceIntensity(rawValue: raw) else {
            return
        }
        presenceIntensity = intensity
        defaults.set(intensity.rawValue, forKey: Self.presenceIntensityKey)
        notifyChanged()
    }

    @objc private func toggleRestPrompt() {
        restPromptEnabled.toggle()
        defaults.set(restPromptEnabled, forKey: Self.restPromptEnabledKey)
        notifyChanged()
    }

    private func saveQuietHours() {
        defaults.set(quietHours.isEnabled, forKey: Self.quietHoursEnabledKey)
        defaults.set(quietHours.startHour, forKey: Self.quietHoursStartKey)
        defaults.set(quietHours.endHour, forKey: Self.quietHoursEndKey)
        notifyChanged()
    }

    private func menuItem(
        title: String,
        action: Selector,
        representedObject: Any? = nil,
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = state
        return item
    }

    private func notifyChanged() {
        onChange?()
    }

    private static func safeFilename(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? fallback : cleaned
    }
}

enum PetVoiceOverrideError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "请选择 mp3、m4a、aiff 或 wav 音频文件。"
        }
    }
}

final class DesktopPetVoiceFeature: NSObject {
    var onMenuNeedsUpdate: (() -> Void)?

    private static let enabledDefaultsKey = "CompanionXiaoHuaErVoiceEnabled"
    private static let volumeDefaultsKey = "CompanionXiaoHuaErVoiceVolume"
    private static let defaultVolume = 0.8
    private static let volumeOptions = [0.2, 0.4, 0.6, 0.8, 1.0]

    private let defaults: UserDefaults
    private let settingsStore: DesktopPetBehaviorSettingsStore
    private let player = PetVoicePlayer()
    private(set) var isEnabled: Bool
    private(set) var volume: Double
    private var hasPlayedLaunchWelcome = false

    init(settingsStore: DesktopPetBehaviorSettingsStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settingsStore = settingsStore
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        let storedVolume = (defaults.object(forKey: Self.volumeDefaultsKey) as? NSNumber)?.doubleValue
        volume = Self.clampedVolume(storedVolume ?? Self.defaultVolume)
        super.init()
    }

    func makeMenuItems() -> [NSMenuItem] {
        let toggleItem = NSMenuItem(
            title: "小花儿语音：\(isEnabled ? "开" : "关")",
            action: #selector(toggleVoice),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = isEnabled ? .on : .off

        let volumeItem = NSMenuItem(
            title: "小花儿语音音量：\(Self.volumeTitle(volume))",
            action: nil,
            keyEquivalent: ""
        )
        let volumeMenu = NSMenu()
        for option in Self.volumeOptions {
            let item = NSMenuItem(
                title: Self.volumeTitle(option),
                action: #selector(selectVolume(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: option)
            item.state = abs(volume - option) < 0.001 ? .on : .off
            volumeMenu.addItem(item)
        }
        volumeItem.submenu = volumeMenu

        let previewItem = NSMenuItem(title: "语音预览", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for event in PetVoiceEvent.allCases {
            let item = NSMenuItem(title: event.title, action: #selector(previewVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = event.rawValue
            previewMenu.addItem(item)
        }
        previewItem.submenu = previewMenu

        let overrideItem = NSMenuItem(title: "本地语音替换", action: nil, keyEquivalent: "")
        let overrideMenu = NSMenu()
        for event in PetVoiceEvent.allCases {
            let eventItem = NSMenuItem(title: event.title, action: nil, keyEquivalent: "")
            let eventMenu = NSMenu()
            let selectItem = NSMenuItem(title: "选择音频", action: #selector(selectCustomVoice(_:)), keyEquivalent: "")
            selectItem.target = self
            selectItem.representedObject = event.rawValue
            eventMenu.addItem(selectItem)
            let resetItem = NSMenuItem(title: "恢复内置语音", action: #selector(resetCustomVoice(_:)), keyEquivalent: "")
            resetItem.target = self
            resetItem.representedObject = event.rawValue
            resetItem.isEnabled = settingsStore.customVoiceURL(for: event) != nil
            eventMenu.addItem(resetItem)
            eventItem.submenu = eventMenu
            overrideMenu.addItem(eventItem)
        }
        overrideItem.submenu = overrideMenu

        return [toggleItem, volumeItem, previewItem, overrideItem]
    }

    func playLaunchWelcomeIfNeeded(isPetVisible: Bool) {
        guard isPetVisible, !hasPlayedLaunchWelcome else {
            return
        }

        hasPlayedLaunchWelcome = true
        play(.launch)
    }

    func play(_ event: PetVoiceEvent, force: Bool = false) {
        guard isEnabled else {
            return
        }

        guard settingsStore.allowsVoice(event: event, force: force) else {
            return
        }

        player.play(event, volume: volume, overrideURL: settingsStore.customVoiceURL(for: event))
    }

    @objc private func toggleVoice() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
        if !isEnabled {
            player.stop()
        }
        onMenuNeedsUpdate?()
    }

    @objc private func selectVolume(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else {
            return
        }

        volume = Self.clampedVolume(number.doubleValue)
        defaults.set(volume, forKey: Self.volumeDefaultsKey)
        player.updateVolume(volume)
        onMenuNeedsUpdate?()
    }

    @objc private func previewVoice(_ sender: NSMenuItem) {
        guard let event = event(from: sender) else { return }
        play(event, force: true)
    }

    @objc private func selectCustomVoice(_ sender: NSMenuItem) {
        guard let event = event(from: sender) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择\(event.title)语音"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try settingsStore.setCustomVoice(sourceURL: url, for: event)
            onMenuNeedsUpdate?()
        } catch {
            CompanionNonBlockingAlert.present(
                messageText: "语音替换失败",
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    @objc private func resetCustomVoice(_ sender: NSMenuItem) {
        guard let event = event(from: sender) else { return }
        settingsStore.removeCustomVoice(for: event)
        onMenuNeedsUpdate?()
    }

    private func event(from sender: NSMenuItem) -> PetVoiceEvent? {
        guard let raw = sender.representedObject as? String else { return nil }
        return PetVoiceEvent(rawValue: raw)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func volumeTitle(_ value: Double) -> String {
        "\(Int((clampedVolume(value) * 100).rounded()))%"
    }
}

private final class PetVoicePlayer {
    private let manifestStore = PetVoiceManifestStore()
    private let loadQueue = DispatchQueue(label: "com.crazyjal.companion.voice.audio", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var pendingRequestID: UUID?
    private var volume: Float = 0.8

    func updateVolume(_ value: Double) {
        volume = Float(min(max(value, 0), 1))
        player?.volume = volume
    }

    func play(_ event: PetVoiceEvent, volume value: Double, overrideURL: URL? = nil) {
        updateVolume(value)
        guard volume > 0 else {
            stop()
            return
        }

        guard let url = overrideURL ?? manifestStore.audioURL(for: event) else {
            stop()
            return
        }

        let requestID = UUID()
        pendingRequestID = requestID
        let targetVolume = volume
        loadQueue.async { [weak self] in
            let loadedPlayer: AVAudioPlayer?
            do {
                loadedPlayer = try AVAudioPlayer(contentsOf: url)
            } catch {
                NSLog("Companion XiaoHuaEr voice failed to load \(url.lastPathComponent): \(error.localizedDescription)")
                loadedPlayer = nil
            }

            DispatchQueue.main.async {
                guard let self, self.pendingRequestID == requestID else {
                    return
                }

                guard let loadedPlayer else {
                    self.stop()
                    return
                }

                loadedPlayer.numberOfLoops = 0
                loadedPlayer.volume = targetVolume
                loadedPlayer.prepareToPlay()
                guard loadedPlayer.play() else {
                    NSLog("Companion XiaoHuaEr voice failed to play: \(url.lastPathComponent)")
                    self.stop()
                    return
                }

                self.player = loadedPlayer
            }
        }
    }

    func stop() {
        pendingRequestID = nil
        player?.stop()
        player = nil
    }
}

private final class PetVoiceManifestStore {
    private struct VoicePack {
        let rootURL: URL
        let events: [PetVoiceEvent: [String]]
    }

    private static let manifestFilename = "voice-manifest.json"
    private static let supportedExtensions = Set(["mp3", "m4a", "aiff", "aif", "wav"])

    private let fileManager = FileManager.default
    private var cachedPack: VoicePack?
    private var didLoad = false
    private var loggedMessages = Set<String>()

    func audioURL(for event: PetVoiceEvent) -> URL? {
        guard let pack = loadPackIfNeeded() else {
            logOnce("missing-pack", "Companion XiaoHuaEr voice manifest not found; event \(event.rawValue) will be silent")
            return nil
        }

        guard let filenames = pack.events[event], !filenames.isEmpty else {
            logOnce("missing-event-\(event.rawValue)", "Companion XiaoHuaEr voice event has no files: \(event.rawValue)")
            return nil
        }

        let validFilenames = filenames.filter(Self.isSupportedManifestFilename)
        guard let filename = validFilenames.randomElement() else {
            logOnce("invalid-event-\(event.rawValue)", "Companion XiaoHuaEr voice event has no valid audio files: \(event.rawValue)")
            return nil
        }

        let url = pack.rootURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else {
            logOnce("missing-file-\(filename)", "Companion XiaoHuaEr voice file missing: \(filename)")
            return nil
        }

        return url
    }

    private func loadPackIfNeeded() -> VoicePack? {
        if didLoad {
            return cachedPack
        }

        didLoad = true
        for root in voiceRoots() {
            let manifestURL = root.appendingPathComponent(Self.manifestFilename)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: manifestURL)
                let payload = try JSONDecoder().decode([String: [String]].self, from: data)
                var events: [PetVoiceEvent: [String]] = [:]
                for event in PetVoiceEvent.allCases {
                    events[event] = payload[event.rawValue] ?? []
                }
                cachedPack = VoicePack(rootURL: root, events: events)
                return cachedPack
            } catch {
                logOnce(
                    "decode-\(manifestURL.path)",
                    "Companion XiaoHuaEr voice manifest failed to decode: \(error.localizedDescription)"
                )
            }
        }

        return nil
    }

    private func voiceRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(
                resourceURL
                    .appendingPathComponent("Sounds", isDirectory: true)
                    .appendingPathComponent("XiaoHuaEr", isDirectory: true)
            )
        }

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        roots.append(
            workingDirectory
                .appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("XiaoHuaEr", isDirectory: true)
        )

        return roots
    }

    private func logOnce(_ key: String, _ message: String) {
        guard !loggedMessages.contains(key) else {
            return
        }

        loggedMessages.insert(key)
        NSLog("%@", message)
    }

    private static func isSupportedManifestFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename == URL(fileURLWithPath: filename).lastPathComponent
        else {
            return false
        }

        return supportedExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased())
    }
}

// 小花儿勿扰时段弹窗:统一的玻璃风格 SwiftUI 表单(校验改为内联,不再另弹警告)。
private struct QuietHoursFormView: View {
    let onSave: (Int, Int) -> Void
    let onCancel: () -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var statusText: String = ""
    @FocusState private var startFocused: Bool

    init(
        initialStart: Int,
        initialEnd: Int,
        onSave: @escaping (Int, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _startText = State(initialValue: "\(initialStart)")
        _endText = State(initialValue: "\(initialEnd)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CompanionModalHeader(
                icon: "moon.zzz.fill",
                title: "小花儿勿扰时段",
                message: "设置勿扰时段（0-23 点）。开启后不播放小花儿语音。"
            )

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    CompanionModalFieldLabel(text: "开始小时")
                    TextField("22", text: $startText)
                        .companionModalFieldChrome()
                        .focused($startFocused)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    CompanionModalFieldLabel(text: "结束小时")
                    TextField("8", text: $endText)
                        .companionModalFieldChrome()
                        .onSubmit(save)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(statusText.isEmpty ? " " : statusText)
                .font(.system(size: 12))
                .foregroundStyle(XiaoHuaErTheme.coral)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 16, alignment: .leading)

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 78, height: 34))
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 88, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .companionModalFormBody()
        .onAppear { startFocused = true }
    }

    private func save() {
        guard let start = Int(startText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(endText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...23).contains(start), (0...23).contains(end), start != end else {
            statusText = "请输入 0-23 之间且不同的开始 / 结束小时。"
            return
        }
        onSave(start, end)
    }
}
