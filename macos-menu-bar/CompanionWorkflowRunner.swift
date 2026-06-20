import Foundation

// MARK: - Template Definition

struct CompanionWorkflowTemplate {
    var id: String
    var title: String
    var steps: [CompanionWorkflowTemplateStep]

    struct Step {
        var id: String
        var title: String
        var toolID: String?
        var required: Bool
        var isDryRun: Bool
        var isLocal: Bool  // local瞬时步骤可合并显示

        init(
            id: String,
            title: String,
            toolID: String? = nil,
            required: Bool = true,
            isDryRun: Bool = false,
            isLocal: Bool = false
        ) {
            self.id = id
            self.title = title
            self.toolID = toolID
            self.required = required
            self.isDryRun = isDryRun
            self.isLocal = isLocal
        }
    }
}

typealias CompanionWorkflowTemplateStep = CompanionWorkflowTemplate.Step

// MARK: - Runtime Snapshots

struct CompanionWorkflowRunSnapshot {
    var id: UUID
    var templateID: String
    var title: String
    var status: CompanionWorkflowRunStatus
    var steps: [CompanionWorkflowStepSnapshot]
    var startedAt: Date
    var finishedAt: Date?
    var inputSummary: String
    var outputSummary: String
    var errorSummary: String?
    var followUpActions: [CompanionWorkflowFollowUpAction]

    // 跨事件续接字段（用于 reminder-focus-journal routine）
    var reminderID: UUID?
    var pomodoroSessionID: UUID?
    var continuationToken: String?
    var waitingReason: String?
    var lastEventAt: Date?
}

struct CompanionWorkflowStepSnapshot {
    var id: UUID
    var templateStepID: String
    var title: String
    var toolID: String?
    var status: CompanionWorkflowStepStatus
    var required: Bool
    var inputSummary: String
    var outputSummary: String
    var errorSummary: String?
    var startedAt: Date?
    var finishedAt: Date?
}

extension CompanionWorkflowRunRecord {
    func workflowSnapshot(template: CompanionWorkflowTemplate? = nil) -> CompanionWorkflowRunSnapshot {
        CompanionWorkflowRunSnapshot(
            id: id,
            templateID: templateID ?? "",
            title: title,
            status: status,
            steps: steps.enumerated().map { index, step in
                let templateStep: CompanionWorkflowTemplateStep? = {
                    guard let template, template.steps.indices.contains(index) else {
                        return nil
                    }
                    return template.steps[index]
                }()
                return CompanionWorkflowStepSnapshot(
                    id: step.id,
                    templateStepID: step.templateStepID ?? templateStep?.id ?? step.toolID ?? step.title,
                    title: step.title,
                    toolID: step.toolID,
                    status: step.status,
                    required: step.required ?? templateStep?.required ?? Self.defaultRequiredFlag(toolID: step.toolID, title: step.title),
                    inputSummary: step.inputSummary,
                    outputSummary: step.outputSummary,
                    errorSummary: step.errorSummary,
                    startedAt: step.startedAt,
                    finishedAt: step.finishedAt
                )
            },
            startedAt: startedAt,
            finishedAt: finishedAt,
            inputSummary: inputSummary,
            outputSummary: outputSummary,
            errorSummary: errorSummary,
            followUpActions: followUpActions,
            reminderID: reminderID,
            pomodoroSessionID: pomodoroSessionID,
            continuationToken: continuationToken,
            waitingReason: waitingReason,
            lastEventAt: lastEventAt
        )
    }

    private static func defaultRequiredFlag(toolID: String?, title: String) -> Bool {
        switch toolID {
        case "companion.journal.appendToday",
             "companion.reminder.create",
             "companion.reminder.createBatch",
             "companion.pomodoro.startFocus",
             "companion.asset.upload":
            return true
        case "companion.reminder.parseDraft",
             "companion.focusReview.generate":
            return false
        case nil:
            let normalizedTitle = title.lowercased()
            return !normalizedTitle.contains("present")
                && !normalizedTitle.contains("clipboard")
                && !normalizedTitle.contains("preview")
                && !normalizedTitle.contains("展示")
                && !normalizedTitle.contains("复制")
        default:
            return true
        }
    }
}

// MARK: - Workflow Runner

final class CompanionWorkflowRunner {
    private let runStore: CompanionWorkflowRunStore
    private let template: CompanionWorkflowTemplate
    private var snapshot: CompanionWorkflowRunSnapshot
    private var pendingPersistWorkItem: DispatchWorkItem?
    private static let persistDebounceInterval: TimeInterval = 0.25

    // 步骤执行器闭包类型（同步：hero 链路全在主线程同步执行）
    typealias StepExecutor = (
        _ templateStep: CompanionWorkflowTemplateStep,
        _ inputContext: [String: Any]
    ) throws -> StepExecutionResult

    struct StepExecutionResult {
        var status: CompanionWorkflowStepStatus
        var outputSummary: String
        var errorSummary: String?
        var output: [String: Any]

        static func succeeded(outputSummary: String, output: [String: Any] = [:]) -> StepExecutionResult {
            StepExecutionResult(
                status: .succeeded,
                outputSummary: outputSummary,
                errorSummary: nil,
                output: output
            )
        }

        static func failed(errorSummary: String) -> StepExecutionResult {
            StepExecutionResult(
                status: .failed,
                outputSummary: "",
                errorSummary: errorSummary,
                output: [:]
            )
        }

        static func awaitingInput(reason: String) -> StepExecutionResult {
            StepExecutionResult(
                status: .awaitingInput,
                outputSummary: reason,
                errorSummary: nil,
                output: [:]
            )
        }

        static func cancelled() -> StepExecutionResult {
            StepExecutionResult(
                status: .cancelled,
                outputSummary: "Cancelled by user",
                errorSummary: nil,
                output: [:]
            )
        }

        static func skipped(outputSummary: String = "") -> StepExecutionResult {
            StepExecutionResult(
                status: .skipped,
                outputSummary: outputSummary,
                errorSummary: nil,
                output: [:]
            )
        }
    }

    init(
        template: CompanionWorkflowTemplate,
        inputSummary: String,
        runStore: CompanionWorkflowRunStore
    ) {
        self.template = template
        self.runStore = runStore

        let runID = UUID()
        let now = Date()

        self.snapshot = CompanionWorkflowRunSnapshot(
            id: runID,
            templateID: template.id,
            title: template.title,
            status: .pending,
            steps: template.steps.map { templateStep in
                CompanionWorkflowStepSnapshot(
                    id: UUID(),
                    templateStepID: templateStep.id,
                    title: templateStep.title,
                    toolID: templateStep.toolID,
                    status: .pending,
                    required: templateStep.required,
                    inputSummary: "",
                    outputSummary: "",
                    errorSummary: nil,
                    startedAt: nil,
                    finishedAt: nil
                )
            },
            startedAt: now,
            finishedAt: nil,
            inputSummary: inputSummary,
            outputSummary: "",
            errorSummary: nil,
            followUpActions: []
        )
    }

    var currentSnapshot: CompanionWorkflowRunSnapshot {
        snapshot
    }

    @discardableResult
    func run(executor: StepExecutor) -> CompanionWorkflowRunSnapshot {
        snapshot.status = .running
        persistSnapshot(debounced: false)

        var context: [String: Any] = [:]

        for (index, templateStep) in template.steps.enumerated() {
            // 跳过 dryRun 步骤的真正执行
            if templateStep.isDryRun {
                snapshot.steps[index].status = .skipped
                snapshot.steps[index].outputSummary = "Dry run completed"
                continue
            }

            snapshot.steps[index].status = .running
            snapshot.steps[index].startedAt = Date()
            persistSnapshot()

            do {
                let result = try executor(templateStep, context)

                snapshot.steps[index].status = result.status
                snapshot.steps[index].outputSummary = result.outputSummary
                snapshot.steps[index].errorSummary = result.errorSummary
                snapshot.steps[index].finishedAt = Date()

                // 合并输出到上下文供后续步骤使用
                context.merge(result.output) { _, new in new }

                // 处理不同的步骤结果
                switch result.status {
                case .succeeded:
                    // 继续下一步
                    break

                case .awaitingInput:
                    snapshot.status = .awaitingInput
                    snapshot.errorSummary = result.outputSummary
                    persistSnapshot(debounced: false)
                    return snapshot

                case .cancelled:
                    snapshot.status = .cancelled
                    snapshot.finishedAt = Date()
                    persistSnapshot(debounced: false)
                    return snapshot

                case .failed:
                    // 失败不回滚，标记后继续
                    if templateStep.required {
                        snapshot.status = .failed
                        snapshot.errorSummary = result.errorSummary
                        snapshot.finishedAt = Date()
                        persistSnapshot(debounced: false)
                        return snapshot
                    }
                    // 非必需步骤失败，继续执行
                    break

                default:
                    break
                }

                persistSnapshot()

            } catch {
                snapshot.steps[index].status = .failed
                snapshot.steps[index].errorSummary = error.localizedDescription
                snapshot.steps[index].finishedAt = Date()

                if templateStep.required {
                    snapshot.status = .failed
                    snapshot.errorSummary = error.localizedDescription
                    snapshot.finishedAt = Date()
                    persistSnapshot(debounced: false)
                    return snapshot
                }

                persistSnapshot()
            }
        }

        // 所有步骤完成：可选步骤失败不阻断整个 workflow。
        let requiredFailures = snapshot.steps.filter { $0.required && $0.status == .failed }
        snapshot.status = requiredFailures.isEmpty ? .completed : .failed
        snapshot.errorSummary = requiredFailures.first?.errorSummary
        snapshot.finishedAt = Date()

        // 收集 outputSummary
        let successfulOutputs = snapshot.steps
            .filter { $0.status == .succeeded && !$0.outputSummary.isEmpty }
            .map { $0.outputSummary }
        snapshot.outputSummary = successfulOutputs.joined(separator: "; ")

        persistSnapshot(debounced: false)
        return snapshot
    }

    func updateStatus(_ status: CompanionWorkflowRunStatus) {
        snapshot.status = status
        if status == .completed || status == .cancelled || status == .failed {
            snapshot.finishedAt = Date()
        }
        persistSnapshot(debounced: status != .completed && status != .cancelled && status != .failed && status != .awaitingInput)
    }

    func addFollowUpAction(_ action: CompanionWorkflowFollowUpAction) {
        if !snapshot.followUpActions.contains(action) {
            snapshot.followUpActions.append(action)
            persistSnapshot()
        }
    }

    func updateWaitingState(
        reminderID: UUID? = nil,
        pomodoroSessionID: UUID? = nil,
        continuationToken: String? = nil,
        waitingReason: String? = nil
    ) {
        if let reminderID = reminderID {
            snapshot.reminderID = reminderID
        }
        if let pomodoroSessionID = pomodoroSessionID {
            snapshot.pomodoroSessionID = pomodoroSessionID
        }
        if let continuationToken = continuationToken {
            snapshot.continuationToken = continuationToken
        }
        if let waitingReason = waitingReason {
            snapshot.waitingReason = waitingReason
        }
        snapshot.lastEventAt = Date()
        persistSnapshot()
    }

    private func persistSnapshot(debounced: Bool = true) {
        let record = CompanionWorkflowRunRecord(
            id: snapshot.id,
            kind: .internalWorkflow,
            source: "xiaohuaer",
            templateID: snapshot.templateID,
            toolID: nil,
            title: snapshot.title,
            status: snapshot.status,
            risk: nil,
            inputSummary: snapshot.inputSummary,
            outputSummary: snapshot.outputSummary,
            errorSummary: snapshot.errorSummary,
            followUpActions: snapshot.followUpActions,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            steps: snapshot.steps.map { stepSnapshot in
                CompanionWorkflowStepRecord(
                    id: stepSnapshot.id,
                    templateStepID: stepSnapshot.templateStepID,
                    toolID: stepSnapshot.toolID,
                    title: stepSnapshot.title,
                    status: stepSnapshot.status,
                    required: stepSnapshot.required,
                    inputSummary: stepSnapshot.inputSummary,
                    outputSummary: stepSnapshot.outputSummary,
                    errorSummary: stepSnapshot.errorSummary,
                    startedAt: stepSnapshot.startedAt,
                    finishedAt: stepSnapshot.finishedAt
                )
            },
            reminderID: snapshot.reminderID,
            pomodoroSessionID: snapshot.pomodoroSessionID,
            continuationToken: snapshot.continuationToken,
            waitingReason: snapshot.waitingReason,
            lastEventAt: snapshot.lastEventAt
        )

        if !debounced {
            pendingPersistWorkItem?.cancel()
            pendingPersistWorkItem = nil
            runStore.append(record)
            return
        }

        pendingPersistWorkItem?.cancel()
        let runStore = self.runStore
        let workItem = DispatchWorkItem {
            runStore.append(record)
        }
        pendingPersistWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.persistDebounceInterval,
            execute: workItem
        )
    }
}
