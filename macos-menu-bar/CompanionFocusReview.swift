import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 单个任务的专注计数（出现轮次 + 累计时长）。
struct CompanionFocusTaskTally: Equatable {
    var title: String
    var rounds: Int
    var totalSeconds: Int
}

/// 一段时间窗口内的专注统计（7 / 30 天）。
struct CompanionFocusStats: Equatable {
    var windowDays: Int
    var roundCount: Int
    var totalSeconds: Int
    var topTasks: [CompanionFocusTaskTally]

    var totalMinutes: Int {
        Int((Double(max(0, totalSeconds)) / 60.0).rounded())
    }
}

/// 今日工作汇总：今日专注、今日完成提醒、今日 AI 动作数、是否已有今日记录。
struct CompanionTodaySummary: Equatable {
    var focusRounds: Int
    var focusSeconds: Int
    var completedReminders: [String]
    var aiActionCount: Int
    var hasJournalToday: Bool

    var focusMinutes: Int {
        Int((Double(max(0, focusSeconds)) / 60.0).rounded())
    }
}

/// Journal 侧提供给 Focus Review 的轻量快照，避免窗口直接理解日记内部结构。
struct CompanionFocusReviewJournalSnapshot: Equatable {
    var aiActionCount: Int
    var hasJournalToday: Bool

    static let empty = CompanionFocusReviewJournalSnapshot(aiActionCount: 0, hasJournalToday: false)
}

/// Focus Review 窗口一次刷新使用的完整本地快照。
struct CompanionFocusReviewSnapshot: Equatable {
    var generatedAt: Date
    var today: CompanionTodaySummary
    var sevenDayStats: CompanionFocusStats
    var thirtyDayStats: CompanionFocusStats
    var weeklyReportMarkdown: String

    static func make(
        focusRecords: [PetFocusRecord],
        reminders: [PetReminder],
        journal: CompanionFocusReviewJournalSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CompanionFocusReviewSnapshot {
        let today = CompanionFocusReview.todaySummary(
            focusRecords: focusRecords,
            reminders: reminders,
            aiActionCount: journal.aiActionCount,
            hasJournalToday: journal.hasJournalToday,
            now: now,
            calendar: calendar
        )
        let sevenDayStats = CompanionFocusReview.focusStats(
            from: focusRecords,
            days: 7,
            now: now,
            calendar: calendar
        )
        let thirtyDayStats = CompanionFocusReview.focusStats(
            from: focusRecords,
            days: 30,
            now: now,
            calendar: calendar
        )
        return CompanionFocusReviewSnapshot(
            generatedAt: now,
            today: today,
            sevenDayStats: sevenDayStats,
            thirtyDayStats: thirtyDayStats,
            weeklyReportMarkdown: CompanionFocusReview.weeklyReportMarkdown(
                stats: sevenDayStats,
                generatedAt: now,
                calendar: calendar
            )
        )
    }

    var providerContextMarkdown: String {
        var lines: [String] = []
        lines.append("# 今日专注复盘素材")
        lines.append("")
        lines.append("- 今日专注轮次：\(today.focusRounds)")
        lines.append("- 今日专注时长：\(today.focusMinutes) 分钟")
        lines.append("- 今日完成提醒数：\(today.completedReminders.count)")
        lines.append("- 今日 AI 动作数：\(today.aiActionCount)")
        lines.append("- 今日是否已有日记：\(today.hasJournalToday ? "是" : "否")")
        if !today.completedReminders.isEmpty {
            lines.append("")
            lines.append("## 今日完成提醒")
            for title in today.completedReminders.prefix(12) {
                lines.append("- \(sanitize(title))")
            }
        }
        lines.append("")
        lines.append("## 近 7 天")
        lines.append("- 专注轮次：\(sevenDayStats.roundCount)")
        lines.append("- 专注时长：\(sevenDayStats.totalMinutes) 分钟")
        for task in sevenDayStats.topTasks {
            let minutes = Int((Double(max(0, task.totalSeconds)) / 60.0).rounded())
            lines.append("- \(sanitize(task.title))：\(task.rounds) 轮 / \(minutes) 分钟")
        }
        return lines.joined(separator: "\n")
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Focus Review 复盘的纯聚合逻辑（无 UI / 无网络），便于单元测试。2.4.0 新增。
///
/// 说明：重复提醒在“完成”时会推进到下一次而不写 `completedAt`，因此今日完成提醒列表只统计
/// 非重复提醒的完成；重复提醒的逐次完成目前不作为离散事件记录。专注统计基于 `PetFocusRecord`。
enum CompanionFocusReview {
    /// 在 `[startOfDay(now) - (days-1), now]` 窗口内聚合专注统计。
    static func focusStats(
        from records: [PetFocusRecord],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        topTaskLimit: Int = 5
    ) -> CompanionFocusStats {
        let span = max(0, days - 1)
        let windowStart = calendar.date(byAdding: .day, value: -span, to: calendar.startOfDay(for: now)) ?? now
        let inWindow = records.filter { $0.completedAt >= windowStart && $0.completedAt <= now }

        var totalSeconds = 0
        var tallies: [String: CompanionFocusTaskTally] = [:]
        for record in inWindow {
            totalSeconds += max(0, record.durationSeconds)
            let key = record.displayTaskTitle
            if var tally = tallies[key] {
                tally.rounds += 1
                tally.totalSeconds += max(0, record.durationSeconds)
                tallies[key] = tally
            } else {
                tallies[key] = CompanionFocusTaskTally(title: key, rounds: 1, totalSeconds: max(0, record.durationSeconds))
            }
        }

        let topTasks = tallies.values
            .sorted { lhs, rhs in
                if lhs.rounds != rhs.rounds { return lhs.rounds > rhs.rounds }
                if lhs.totalSeconds != rhs.totalSeconds { return lhs.totalSeconds > rhs.totalSeconds }
                return lhs.title < rhs.title
            }
            .prefix(max(0, topTaskLimit))

        return CompanionFocusStats(
            windowDays: days,
            roundCount: inWindow.count,
            totalSeconds: totalSeconds,
            topTasks: Array(topTasks)
        )
    }

    /// 今日工作汇总。`aiActionCount` 与 `hasJournalToday` 由调用方从各自的 store 提供。
    static func todaySummary(
        focusRecords: [PetFocusRecord],
        reminders: [PetReminder],
        aiActionCount: Int,
        hasJournalToday: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CompanionTodaySummary {
        let todayFocus = focusRecords.filter { calendar.isDate($0.completedAt, inSameDayAs: now) }
        let focusSeconds = todayFocus.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let completed = reminders
            .filter { reminder in
                guard let completedAt = reminder.completedAt else { return false }
                return calendar.isDate(completedAt, inSameDayAs: now)
            }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            .map { $0.title }

        return CompanionTodaySummary(
            focusRounds: todayFocus.count,
            focusSeconds: focusSeconds,
            completedReminders: completed,
            aiActionCount: max(0, aiActionCount),
            hasJournalToday: hasJournalToday
        )
    }

    /// 周报 Markdown：仅含本地专注统计，不含任何 API Key / provider secret / 原始日志。
    static func weeklyReportMarkdown(
        stats: CompanionFocusStats,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var lines: [String] = []
        lines.append("# 专注周报")
        lines.append("")
        lines.append("- 统计区间：近 \(stats.windowDays) 天")
        lines.append("- 完成专注轮次：\(stats.roundCount)")
        lines.append("- 专注总时长：\(stats.totalMinutes) 分钟")
        lines.append("")

        if stats.topTasks.isEmpty {
            lines.append("这段时间还没有完成的专注。")
        } else {
            lines.append("## 常见任务")
            lines.append("")
            for task in stats.topTasks {
                let minutes = Int((Double(max(0, task.totalSeconds)) / 60.0).rounded())
                lines.append("- \(sanitize(task.title))：\(task.rounds) 轮 / \(minutes) 分钟")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func weeklyReportFilename(
        generatedAt: Date = Date(),
        windowDays: Int = 7,
        calendar: Calendar = .current
    ) -> String {
        let span = max(0, windowDays - 1)
        let end = calendar.startOfDay(for: generatedAt)
        let start = calendar.date(byAdding: .day, value: -span, to: end) ?? end
        let formatter = filenameDateFormatter(timeZone: calendar.timeZone)
        let raw = "focus-review-\(formatter.string(from: start))-\(formatter.string(from: end)).md"
        return safeFilename(raw, fallback: "focus-review.md")
    }

    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func filenameDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

final class CompanionFocusReviewWindowController {
    typealias SnapshotProvider = () -> CompanionFocusReviewSnapshot
    typealias SummaryProvider = (CompanionFocusReviewSnapshot) async throws -> String
    typealias JournalAppender = (_ section: String, _ lines: [String]) -> Void

    private let snapshotProvider: SnapshotProvider
    private let summaryProvider: SummaryProvider?
    private let journalAppender: JournalAppender?
    private var window: NSWindow?
    private var model: CompanionFocusReviewViewModel?

    init(
        snapshotProvider: @escaping SnapshotProvider,
        summaryProvider: SummaryProvider?,
        journalAppender: JournalAppender? = nil
    ) {
        self.snapshotProvider = snapshotProvider
        self.summaryProvider = summaryProvider
        self.journalAppender = journalAppender
    }

    func show() {
        let window = existingOrNewWindow()
        model?.refresh()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window {
            return window
        }

        let model = CompanionFocusReviewViewModel(
            snapshotProvider: snapshotProvider,
            summaryProvider: summaryProvider,
            journalAppender: journalAppender
        )
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "专注复盘"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = CompanionInteractiveHostingView(rootView: CompanionFocusReviewWindowView(model: model))
        self.window = window
        return window
    }
}

private final class CompanionFocusReviewViewModel: ObservableObject {
    @Published var snapshot: CompanionFocusReviewSnapshot
    @Published var generatedSummary = ""
    @Published var isGeneratingSummary = false
    @Published var errorMessage: String?
    @Published var copiedReport = false
    @Published var exportedReport = false
    @Published var journalNote: String?

    private let snapshotProvider: CompanionFocusReviewWindowController.SnapshotProvider
    private let summaryProvider: CompanionFocusReviewWindowController.SummaryProvider?
    private let journalAppender: CompanionFocusReviewWindowController.JournalAppender?
    // 递增令牌：刷新或重新生成会作废在途的旧 summary 请求，避免旧结果写回新快照。
    private var summaryRequestID = 0

    var canSaveToJournal: Bool {
        journalAppender != nil
    }

    init(
        snapshotProvider: @escaping CompanionFocusReviewWindowController.SnapshotProvider,
        summaryProvider: CompanionFocusReviewWindowController.SummaryProvider?,
        journalAppender: CompanionFocusReviewWindowController.JournalAppender? = nil
    ) {
        self.snapshotProvider = snapshotProvider
        self.summaryProvider = summaryProvider
        self.journalAppender = journalAppender
        self.snapshot = snapshotProvider()
    }

    func refresh() {
        snapshot = snapshotProvider()
        // 统计已更新，旧的 AI 总结对应的是上一份快照，清空避免新统计配旧总结。
        // 同时作废任何在途请求并复位生成状态，防止旧请求返回后把旧总结写回。
        summaryRequestID += 1
        generatedSummary = ""
        isGeneratingSummary = false
        copiedReport = false
        exportedReport = false
        errorMessage = nil
        journalNote = nil
    }

    /// 把（可编辑后的）今日总结写入今日 Journal 的“今日总结”分节。
    func saveSummaryToJournal() {
        guard let journalAppender else { return }
        let lines = generatedSummary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        journalAppender("今日总结", lines)
        journalNote = "已保存到今日记录"
    }

    /// 把今日完成的提醒补记到今日 Journal 的“已完成提醒”分节。
    func logCompletedRemindersToJournal() {
        guard let journalAppender else { return }
        let titles = snapshot.today.completedReminders
        guard !titles.isEmpty else { return }
        journalAppender("已完成提醒", titles)
        journalNote = "已补记 \(titles.count) 条完成提醒到今日记录"
    }

    func generateSummary() {
        guard !isGeneratingSummary else { return }
        guard let summaryProvider else {
            errorMessage = "当前没有可用的 AI provider。请先在 AI Settings 里配置一个可用 provider。"
            return
        }

        let currentSnapshot = snapshot
        summaryRequestID += 1
        let requestID = summaryRequestID
        isGeneratingSummary = true
        errorMessage = nil

        Task {
            do {
                let summary = try await summaryProvider(currentSnapshot)
                await MainActor.run {
                    guard self.summaryRequestID == requestID else { return }
                    self.generatedSummary = summary
                    self.isGeneratingSummary = false
                }
            } catch {
                await MainActor.run {
                    guard self.summaryRequestID == requestID else { return }
                    self.errorMessage = error.localizedDescription
                    self.isGeneratingSummary = false
                }
            }
        }
    }

    func copyWeeklyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.weeklyReportMarkdown, forType: .string)
        copiedReport = true
    }

    func exportWeeklyReport() {
        let panel = NSSavePanel()
        panel.title = "导出周报 Markdown"
        panel.nameFieldStringValue = CompanionFocusReview.weeklyReportFilename(
            generatedAt: snapshot.generatedAt,
            windowDays: snapshot.sevenDayStats.windowDays
        )
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try snapshot.weeklyReportMarkdown.write(to: url, atomically: true, encoding: .utf8)
            exportedReport = true
            errorMessage = nil
        } catch {
            errorMessage = "周报导出失败：\(error.localizedDescription)"
        }
    }
}

private struct CompanionFocusReviewWindowView: View {
    @ObservedObject var model: CompanionFocusReviewViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                todayGrid
                statsGrid
                topTasksSection
                summarySection
                weeklyReportSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CompanionLiquidWindowBackground())
        .toolbar {
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Button {
                model.copyWeeklyReport()
            } label: {
                Label("复制周报", systemImage: "doc.on.doc")
            }
            Button {
                model.exportWeeklyReport()
            } label: {
                Label("导出周报", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("专注复盘")
                    .font(.system(size: 30, weight: .semibold))
                Text("今日工作、近 7/30 天专注趋势，以及可复制的本地周报。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                CompanionStatusTag(title: "本地统计", tint: XiaoHuaErTheme.tint)
                Text("更新于 \(CompanionFocusReviewFormatters.dateTime.string(from: model.snapshot.generatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var todayGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日")
                .font(.system(size: 17, weight: .semibold))
            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                CompanionFocusMetricCard(title: "专注", value: "\(model.snapshot.today.focusRounds)", detail: "\(model.snapshot.today.focusMinutes) 分钟", tint: XiaoHuaErTheme.tint)
                CompanionFocusMetricCard(title: "完成提醒", value: "\(model.snapshot.today.completedReminders.count)", detail: completedReminderDetail, tint: XiaoHuaErTheme.leaf)
                CompanionFocusMetricCard(title: "AI 动作", value: "\(model.snapshot.today.aiActionCount)", detail: model.snapshot.today.hasJournalToday ? "已写入今日记录" : "还没有今日记录", tint: XiaoHuaErTheme.sky)
            }

            if !model.snapshot.today.completedReminders.isEmpty, model.canSaveToJournal {
                Button {
                    model.logCompletedRemindersToJournal()
                } label: {
                    Label("把完成提醒补记到今日记录", systemImage: "text.badge.plus")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 200, height: 30))
            }
        }
        .padding(18)
        .companionGlassSurface(radius: 22)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
            CompanionFocusStatsCard(title: "近 7 天", stats: model.snapshot.sevenDayStats, tint: XiaoHuaErTheme.plum)
            CompanionFocusStatsCard(title: "近 30 天", stats: model.snapshot.thirtyDayStats, tint: XiaoHuaErTheme.amber)
        }
    }

    private var topTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高频任务")
                .font(.system(size: 17, weight: .semibold))
            if model.snapshot.sevenDayStats.topTasks.isEmpty {
                Text("近 7 天还没有完成的专注。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.snapshot.sevenDayStats.topTasks.enumerated()), id: \.element.title) { index, task in
                    CompanionFocusTaskRow(index: index + 1, task: task, maxSeconds: topTaskMaxSeconds)
                }
            }
        }
        .padding(18)
        .companionGlassSurface(radius: 22)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日总结")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if !model.generatedSummary.isEmpty, model.canSaveToJournal {
                    Button {
                        model.saveSummaryToJournal()
                    } label: {
                        Label("保存到今日记录", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 120, height: 32))
                }
                Button {
                    model.generateSummary()
                } label: {
                    if model.isGeneratingSummary {
                        Label("生成中", systemImage: "hourglass")
                    } else {
                        Label("生成总结", systemImage: "sparkles")
                    }
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 96, height: 32))
                .disabled(model.isGeneratingSummary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(XiaoHuaErTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let journalNote = model.journalNote {
                Text(journalNote)
                    .font(.system(size: 12))
                    .foregroundStyle(XiaoHuaErTheme.leaf)
            }

            if model.generatedSummary.isEmpty {
                Text(summaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(XiaoHuaErTheme.glassWhitewash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // 生成后可编辑：用户可调整文字再保存到今日记录。
                TextEditor(text: $model.generatedSummary)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(minHeight: 132)
                    .padding(10)
                    .background(XiaoHuaErTheme.glassWhitewash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(18)
        .companionGlassSurface(radius: 22)
    }

    private var weeklyReportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("周报 Markdown")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.copiedReport {
                    CompanionStatusTag(title: "已复制", tint: XiaoHuaErTheme.leaf)
                }
                if model.exportedReport {
                    CompanionStatusTag(title: "已导出", tint: XiaoHuaErTheme.sky)
                }
            }
            Text(model.snapshot.weeklyReportMarkdown)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(XiaoHuaErTheme.recessedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .companionGlassSurface(radius: 22)
    }

    private var completedReminderDetail: String {
        guard let first = model.snapshot.today.completedReminders.first else {
            return "暂无完成项"
        }
        if model.snapshot.today.completedReminders.count == 1 {
            return first
        }
        return "\(first) 等 \(model.snapshot.today.completedReminders.count) 项"
    }

    private var summaryText: String {
        if !model.generatedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.generatedSummary
        }
        if model.isGeneratingSummary {
            return "正在根据今日专注、提醒、日记和近 7 天统计生成总结..."
        }
        return "点击“生成总结”后，会把本地聚合出的复盘素材发送给当前 AI provider，生成一段今日总结。"
    }

    private var topTaskMaxSeconds: Int {
        max(model.snapshot.sevenDayStats.topTasks.map(\.totalSeconds).max() ?? 1, 1)
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12, alignment: .top)
        ]
    }
}

private struct CompanionFocusMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 32, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
    }
}

private struct CompanionFocusStatsCard: View {
    let title: String
    let stats: CompanionFocusStats
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                CompanionStatusTag(title: "\(stats.windowDays) 天", tint: tint)
            }
            HStack(spacing: 18) {
                statValue(value: "\(stats.roundCount)", label: "轮次")
                statValue(value: "\(stats.totalMinutes)", label: "分钟")
                statValue(value: "\(stats.topTasks.count)", label: "任务")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionGlassSurface(radius: 22)
    }

    private func statValue(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CompanionFocusTaskRow: View {
    let index: Int
    let task: CompanionFocusTaskTally
    let maxSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.onTint)
                    .frame(width: 22, height: 22)
                    .background(XiaoHuaErTheme.tint, in: Circle())
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(task.rounds) 轮 / \(minutes) 分钟")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(XiaoHuaErTheme.recessedSurface.opacity(0.9))
                    Capsule(style: .continuous)
                        .fill(XiaoHuaErTheme.tint.opacity(0.72))
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 7)
        }
        .padding(.vertical, 5)
    }

    private var minutes: Int {
        Int((Double(max(0, task.totalSeconds)) / 60.0).rounded())
    }

    private var ratio: CGFloat {
        CGFloat(min(max(Double(task.totalSeconds) / Double(max(maxSeconds, 1)), 0), 1))
    }
}

private enum CompanionFocusReviewFormatters {
    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
