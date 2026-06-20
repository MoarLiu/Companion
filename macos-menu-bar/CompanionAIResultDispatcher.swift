import Foundation

/// 把 AI 结果派发为 workflow。
/// - 单选：复用 `DesktopPetFeature.handleAIResultWorkflow` 的同步快路径，保持紧凑体验、不分叉逻辑。
/// - 多选：用 `CompanionWorkflowRunner` 多步管线编排（计划预览已在 AI 结果页 `WorkflowPlanPreview` 确认过一次），
///   写多 step run；任一步失败不回滚已成功步骤，完成页区分“已完成 / 未完成”。
///
/// 真正的写入操作委托给 `DesktopPetFeature` 暴露的 internal step 方法（封装对 private feature 的访问），
/// Dispatcher 本身不持有任何 UI/feature 细节，只负责编排与 run 记录。
final class CompanionAIResultDispatcher {
    private let runStore: CompanionWorkflowRunStore
    private weak var pet: DesktopPetFeature?

    /// 最近一次多选执行的 run 快照（供 Workflow Console 展示）。
    private(set) var lastRunSnapshot: CompanionWorkflowRunSnapshot?

    init(runStore: CompanionWorkflowRunStore, pet: DesktopPetFeature?) {
        self.runStore = runStore
        self.pet = pet
    }

    @discardableResult
    func dispatch(request: XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome {
        lastRunSnapshot = nil
        guard let pet = pet else {
            return .cancelled("小花儿暂时不可用")
        }

        // 单选快路径：复用 DesktopPetFeature 现有完整实现
        if request.actions.count <= 1 {
            return pet.handleAIResultWorkflow(request)
        }

        // 多选：Runner 多步管线
        return executeMultipleActions(context: AIResultWorkflowContext(from: request), pet: pet)
    }

    // MARK: - Multiple Actions

    private func executeMultipleActions(
        context: AIResultWorkflowContext,
        pet: DesktopPetFeature
    ) -> XiaoHuaErAIResultWorkflowOutcome {
        let runner = CompanionWorkflowRunner(
            template: CompanionWorkflowTemplates.aiResultDispatch,
            inputSummary: context.inputSummary(),
            runStore: runStore
        )

        _ = runner.run { [weak self] templateStep, _ in
            guard let self = self else {
                return .failed(errorSummary: "Dispatcher unavailable")
            }
            return self.executeStep(templateStep: templateStep, context: context, pet: pet)
        }

        // 完成页后续入口：依据用户选中的动作补充（addFollowUpAction 会持久化进 run，Dashboard 亦可见）
        if context.actions.contains(.saveToJournal) { runner.addFollowUpAction(.openJournal) }
        if context.actions.contains(.createReminder) { runner.addFollowUpAction(.openReminders) }
        if context.actions.contains(.startFocus) { runner.addFollowUpAction(.openPomodoro) }
        runner.addFollowUpAction(.copyResult)

        let snapshot = runner.currentSnapshot
        lastRunSnapshot = snapshot

        let succeeded = snapshot.steps
            .filter { $0.status == .succeeded && !$0.outputSummary.isEmpty }
            .map { $0.outputSummary }
        let failed = snapshot.steps
            .filter { $0.status == .failed && !($0.errorSummary ?? "").isEmpty }
            .map { $0.errorSummary ?? "" }

        switch snapshot.status {
        case .completed:
            return .accepted(succeeded.isEmpty ? "已完成" : succeeded.joined(separator: "；"))
        case .failed:
            // 失败不回滚：已成功步骤仍生效，给“部分完成”提示
            var parts: [String] = []
            if !succeeded.isEmpty { parts.append("已完成：" + succeeded.joined(separator: "、")) }
            if !failed.isEmpty { parts.append("未完成：" + failed.joined(separator: "、")) }
            return .accepted(parts.isEmpty ? "部分步骤未完成" : parts.joined(separator: "；"))
        case .cancelled:
            return .cancelled(snapshot.errorSummary ?? "已取消")
        default:
            return .cancelled("未完成")
        }
    }

    private func executeStep(
        templateStep: CompanionWorkflowTemplateStep,
        context: AIResultWorkflowContext,
        pet: DesktopPetFeature
    ) -> CompanionWorkflowRunner.StepExecutionResult {
        switch templateStep.id {
        case "ai.result.snapshot":
            return .succeeded(outputSummary: "已准备内容")

        case "workflow.input.collect":
            // 单选提醒由 ReminderTimeInputView 补齐时间；多选路径使用 request 中
            // 已补齐的 reminderTime，或在 reminder.create step 内解析/降级到草稿。
            return .succeeded(outputSummary: "参数已就绪")

        case "workflow.plan.preview":
            // dryRun，Runner 自动跳过，不会进入 executor；保留兜底分支
            return .succeeded(outputSummary: "已确认计划")

        case "journal.appendToday":
            guard context.actions.contains(.saveToJournal) else {
                return .skipped()
            }
            pet.workflowAppendToJournal(context)
            return .succeeded(outputSummary: "已存到日记")

        case "reminder.create":
            guard context.actions.contains(.createReminder) else {
                return .skipped()
            }
            let title = context.reminderTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? context.reminderTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
                : extractTaskTitle(from: context.resultText, fallback: context.resultTitle, maxLength: 60)

            // 快捷补问已经给出明确时间：直接创建真实提醒。
            if let reminderTime = context.reminderTime {
                if pet.workflowCreateTimedReminder(title: title, fireDate: reminderTime) != nil {
                    return .succeeded(outputSummary: "已创建提醒：\(title)")
                }
                return .failed(errorSummary: "创建提醒失败")
            } else if let parsed = PetReminderRuleParser.parse(title, now: Date(), calendar: .current) {
                // 有时间：真正创建提醒
                if pet.workflowCreateTimedReminder(title: parsed.title, fireDate: parsed.fireDate) != nil {
                    return .succeeded(outputSummary: "已创建提醒：\(parsed.title)")
                } else {
                    return .failed(errorSummary: "创建提醒失败")
                }
            } else {
                // 无时间：打开草稿作为降级
                return pet.workflowCreateReminderDraft(title: title)
                    ? .succeeded(outputSummary: "已打开提醒草稿（需补充时间）")
                    : .failed(errorSummary: "打开提醒草稿失败")
            }

        case "pomodoro.startFocus":
            guard context.actions.contains(.startFocus) else {
                return .skipped()
            }
            let title = extractTaskTitle(from: context.resultText, fallback: context.resultTitle, maxLength: 40)
            guard !pet.workflowHasActiveFocus else {
                pet.workflowShowPomodoroCenter()
                return .failed(errorSummary: "已有番茄钟正在运行")
            }
            pet.workflowStartFocus(title: title)
            return .succeeded(outputSummary: "已开始专注")

        case "workflow.result.present":
            return .succeeded(outputSummary: "已完成")

        default:
            return .failed(errorSummary: "Unknown step: \(templateStep.id)")
        }
    }

    // MARK: - Helpers

    private func extractTaskTitle(from text: String, fallback: String, maxLength: Int) -> String {
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let firstLine = lines.first(where: { !$0.isEmpty && $0.count <= maxLength * 2 }) ?? fallback
        return String(firstLine.prefix(maxLength))
    }
}
