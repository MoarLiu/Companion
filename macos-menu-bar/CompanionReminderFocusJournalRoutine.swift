import Foundation

/// 旗舰 routine：提醒 → 专注 → Journal 的跨事件编排器。
///
/// 设计原则：
/// - 不自建后台计划器；依赖现有 **reminder due** 与 **pomodoro end** 事件驱动续接（需求 P0-3）。
/// - 纯逻辑 + 闭包 I/O，便于单测；真正的提醒创建 / 开专注 / 写 Journal 由 Companion 注入闭包连接 `DesktopPetFeature`。
/// - 关联事实来源是 `workflow-runs.json` 里的 reminderID / waitingReason / continuationToken（跨重启可恢复）。
/// - 番茄钟开始时没有稳定的 sessionID（`PetFocusRecord` 在结束时才生成），因此番茄结束事件先尝试
///   `pomodoroSessionID` 精确匹配，再退到“任务标题匹配的 waitingFocus routine run”，避免普通番茄误续接。
final class CompanionReminderFocusJournalRoutine {
    static let templateID = "reminder-focus-journal"
    static let waitingReminderReason = "等待提醒到期"
    static let waitingFocusReason = "等待专注结束"
    static let journalSection = "专注复盘"

    private let runStore: CompanionWorkflowRunStore

    // MARK: - 注入的 I/O 闭包（Companion 连接 pet feature；nil 时安全降级）

    /// 创建一个定时提醒，返回提醒 id（失败返回 nil）。
    var createReminder: ((_ title: String, _ fireDate: Date) -> UUID?)?
    /// 提醒到期后询问用户是否开始专注。
    var confirmStartFocus: ((_ taskTitle: String) -> Bool)?
    /// 当前是否已有番茄钟/专注会话在运行或暂停。
    var hasActiveFocusSession: (() -> Bool)?
    /// 开始番茄钟专注。
    var startFocus: ((_ taskTitle: String) -> Void)?
    /// 番茄结束后询问用户是否把生成的 Journal 草稿存入今日记录。
    var confirmSaveJournal: ((_ taskTitle: String, _ draft: String) -> Bool)?
    /// 把内容追加到今日 Journal 指定分节。
    var appendJournal: ((_ section: String, _ lines: [String]) -> Void)?
    /// 轻量提示（message, info, isError）。
    var notify: ((_ message: String, _ info: String, _ isError: Bool) -> Void)?

    init(runStore: CompanionWorkflowRunStore) {
        self.runStore = runStore
    }

    // MARK: - 1. 启动

    /// 创建提醒并登记一个等待到期的 routine run。返回 run id。
    @discardableResult
    func start(taskTitle: String, fireDate: Date, now: Date = Date()) -> UUID? {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notify?("任务名为空", "请先填写要提醒的任务。", true)
            return nil
        }
        guard fireDate > now else {
            notify?("提醒时间无效", "请选择一个将来的时间。", true)
            return nil
        }
        guard let reminderID = createReminder?(trimmed, fireDate) else {
            notify?("无法创建提醒", "提醒创建失败，routine 未启动。", true)
            return nil
        }

        let runID = UUID()
        let record = CompanionWorkflowRunRecord(
            id: runID,
            kind: .internalWorkflow,
            source: "xiaohuaer",
            templateID: Self.templateID,
            toolID: nil,
            title: Self.runTitle(taskTitle: trimmed),
            status: .awaitingInput,
            risk: .localWrite,
            inputSummary: Self.inputSummary(taskTitle: trimmed),
            outputSummary: "",
            errorSummary: nil,
            followUpActions: [],
            startedAt: now,
            finishedAt: nil,
            steps: steps(succeededUpTo: 2, runningAt: 2, now: now),
            reminderID: reminderID,
            pomodoroSessionID: nil,
            continuationToken: UUID().uuidString,
            waitingReason: Self.waitingReminderReason,
            lastEventAt: now
        )
        runStore.append(record)
        return runID
    }

    // MARK: - 2. 提醒到期续接

    /// 提醒到期事件：反查等待该提醒的 routine run，确认后开专注、推进到等待番茄结束。
    /// 同一事件可能携带多个 reminderID；每个最多续接一个 run（冲突时取最近 lastEventAt）。
    func handleReminderDue(reminderIDs: [UUID], now: Date = Date()) {
        for reminderID in reminderIDs {
            guard let run = waitingRun(reminderID: reminderID, reason: Self.waitingReminderReason) else {
                continue
            }
            let taskTitle = Self.taskTitle(from: run)
            let confirmed = confirmStartFocus?(taskTitle) ?? false
            guard confirmed else {
                // 用户暂不开专注：保持 awaitingInput，可稍后从提醒或 Console 再处理。
                continue
            }
            guard !(hasActiveFocusSession?() ?? false) else {
                blockFocusStart(run: run, reason: "已有番茄钟正在运行，请结束当前计时后重新开始 routine。", now: now)
                notify?("已有番茄钟正在运行", "当前计时不会被覆盖。请在番茄闹钟里处理后重新开始 routine。", true)
                continue
            }
            startFocus?(taskTitle)
            advanceToFocusWaiting(run: run, now: now)
        }
    }

    // MARK: - 3. 番茄结束续接

    /// 番茄结束事件：优先用 focusRecordID 匹配 pomodoroSessionID，找不到则回退到任务标题匹配的等待 run。
    /// 与 Focus Review 的 onFocusRecordSaveRequested 共存——本方法只处理匹配到的 routine run，
    /// 找不到则直接返回（不影响普通番茄）。
    func handlePomodoroEnd(focusRecordID: UUID?, fallbackTaskTitle: String, now: Date = Date()) {
        // 优先精确匹配：用 pomodoroSessionID 找等待专注结束的 run
        var run: CompanionWorkflowRunRecord?
        if let sessionID = focusRecordID {
            run = routineRuns().first {
                $0.status == .awaitingInput &&
                $0.waitingReason == Self.waitingFocusReason &&
                $0.pomodoroSessionID == sessionID
            }
        }

        // 回退：开始番茄时没有可保存的 focus record id，只能用结束事件里的任务标题缩窄匹配。
        // 不再盲目接最近 run，避免普通番茄或并发 routine 串线。
        if run == nil {
            run = mostRecentWaitingRun(reason: Self.waitingFocusReason, matchingTaskTitle: fallbackTaskTitle)
        }

        guard let run else {
            return
        }

        let taskTitle = Self.taskTitle(from: run, fallback: fallbackTaskTitle)
        let draft = Self.journalDraft(taskTitle: taskTitle, now: now)

        let confirmed = confirmSaveJournal?(taskTitle, draft) ?? false
        if confirmed {
            appendJournal?(Self.journalSection, [draft])
            complete(run: run, focusRecordID: focusRecordID, now: now)
            notify?("已记录专注复盘", "「\(taskTitle)」的专注已存入今日日记。", false)
        } else {
            cancelRun(run, reason: "用户取消保存日记", now: now)
        }
    }

    // MARK: - 4. 跨重启恢复

    /// app 重启后，把没有可续接事件、卡在 running 的 routine run 标为 blocked，给可解释状态。
    /// 等待提醒/番茄事件的 run 保持等待态（其关联对象可能仍存在）。
    func recoverInterruptedRuns(now: Date = Date()) {
        for run in routineRuns() where run.status == .running {
            var next = run
            next.status = .blocked
            next.errorSummary = "上次执行中断，请在 Workflow Console 查看或重新开始。"
            next.lastEventAt = now
            runStore.append(next)
        }
    }

    // MARK: - Private: 反查

    private func routineRuns() -> [CompanionWorkflowRunRecord] {
        runStore.runs(limit: 200).filter { $0.templateID == Self.templateID }
    }

    private func waitingRun(reminderID: UUID, reason: String) -> CompanionWorkflowRunRecord? {
        routineRuns()
            .filter { $0.status == .awaitingInput && $0.waitingReason == reason && $0.reminderID == reminderID }
            .max(by: { ($0.lastEventAt ?? $0.startedAt) < ($1.lastEventAt ?? $1.startedAt) })
    }

    private func mostRecentWaitingRun(reason: String, matchingTaskTitle taskTitle: String? = nil) -> CompanionWorkflowRunRecord? {
        let trimmedTaskTitle = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return routineRuns()
            .filter { $0.status == .awaitingInput && $0.waitingReason == reason }
            .filter { run in
                guard let trimmedTaskTitle, !trimmedTaskTitle.isEmpty else { return true }
                return Self.normalizedFocusTaskTitle(Self.taskTitle(from: run)) == Self.normalizedFocusTaskTitle(trimmedTaskTitle)
            }
            .max(by: { ($0.lastEventAt ?? $0.startedAt) < ($1.lastEventAt ?? $1.startedAt) })
    }

    // MARK: - Private: 状态推进

    private func advanceToFocusWaiting(run: CompanionWorkflowRunRecord, now: Date) {
        var next = run
        next.status = .awaitingInput
        next.waitingReason = Self.waitingFocusReason
        next.lastEventAt = now
        // reminder.await + pomodoro.confirm + pomodoro.startFocus 完成（前 5 步），pomodoro.await 进行中
        next.steps = steps(succeededUpTo: 5, runningAt: 5, now: now)
        runStore.append(next)
    }

    private func complete(run: CompanionWorkflowRunRecord, focusRecordID: UUID?, now: Date) {
        var next = run
        next.status = .completed
        next.waitingReason = nil
        next.pomodoroSessionID = focusRecordID
        next.finishedAt = now
        next.lastEventAt = now
        next.outputSummary = "已完成：提醒 → 专注 → 日记"
        next.followUpActions = [.openJournal, .openPomodoro]
        next.steps = steps(succeededUpTo: 9, runningAt: nil, now: now)
        runStore.append(next)
    }

    private func cancelRun(_ run: CompanionWorkflowRunRecord, reason: String, now: Date) {
        var next = run
        next.status = .cancelled
        next.waitingReason = nil
        next.finishedAt = now
        next.lastEventAt = now
        next.errorSummary = reason
        runStore.append(next)
    }

    private func blockFocusStart(run: CompanionWorkflowRunRecord, reason: String, now: Date) {
        var next = run
        next.status = .blocked
        next.waitingReason = nil
        next.finishedAt = now
        next.lastEventAt = now
        next.errorSummary = reason
        next.followUpActions = [.openPomodoro]

        var stepRecords = steps(succeededUpTo: 4, runningAt: nil, now: now)
        if stepRecords.indices.contains(4) {
            stepRecords[4].status = .failed
            stepRecords[4].startedAt = now
            stepRecords[4].finishedAt = now
            stepRecords[4].errorSummary = reason
        }
        next.steps = stepRecords

        runStore.append(next)
    }

    // MARK: - Private: 构建 steps / 文案

    /// 用 template 的步骤定义构建 step 记录：index < succeededUpTo 标 succeeded，
    /// index == runningAt 标 running，其余 pending。
    private func steps(succeededUpTo: Int, runningAt: Int?, now: Date) -> [CompanionWorkflowStepRecord] {
        let template = CompanionWorkflowTemplates.reminderFocusJournal
        return template.steps.enumerated().map { index, step in
            let status: CompanionWorkflowStepStatus
            if index < succeededUpTo {
                status = .succeeded
            } else if let runningAt = runningAt, index == runningAt {
                status = .running
            } else {
                status = .pending
            }
            return CompanionWorkflowStepRecord(
                toolID: step.toolID,
                title: step.title,
                status: status,
                startedAt: index <= (runningAt ?? succeededUpTo) ? now : nil,
                finishedAt: index < succeededUpTo ? now : nil
            )
        }
    }

    private static func runTitle(taskTitle: String) -> String {
        "提醒 → 专注 → 日记：\(taskTitle)"
    }

    private static func inputSummary(taskTitle: String) -> String {
        "[提醒→专注→日记] \(taskTitle)"
    }

    private static func taskTitle(from run: CompanionWorkflowRunRecord, fallback: String = "专注任务") -> String {
        let prefix = "提醒 → 专注 → 日记："
        if run.title.hasPrefix(prefix) {
            let stripped = String(run.title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return stripped }
        }
        return fallback
    }

    private static func normalizedFocusTaskTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(100))
    }

    private static func journalDraft(taskTitle: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)
        return "\(time) 完成了一次专注：\(taskTitle)。"
    }
}
