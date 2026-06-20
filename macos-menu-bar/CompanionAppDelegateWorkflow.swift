import AppKit
import Foundation
import SwiftUI

extension AppDelegate {
    func handleAIResultWorkflowRequest(_ request: XiaoHuaErAIResultWorkflowRequest) -> XiaoHuaErAIResultWorkflowOutcome {
        // 多选组合：走多步 Workflow Runner 管线（Runner 自行写多 step run）。
        // 计划预览已在 AI 结果页 WorkflowPlanPreview 确认过一次；任一步失败不回滚已成功步骤。
        if request.actions.count > 1 {
            let dispatcher = CompanionAIResultDispatcher(runStore: workflowRunStore, pet: desktopPet)
            let outcome = dispatcher.dispatch(request: request)
            if let snapshot = dispatcher.lastRunSnapshot {
                lastAIWorkflowRunID = snapshot.id
                lastAIWorkflowRequest = request
                // 多步执行完成后打开 Workflow Console 展示 step 时间线与完成页后续入口
                presentWorkflowConsole(snapshot)
            }
            return outcome
        }

        let toolID = workflowToolID(for: request.action)
        let runID = workflowRunStore.startWorkflowRun(
            kind: .aiResultWorkflow,
            source: "ai-quick-actions",
            templateID: "ai-result-dispatch",
            toolID: toolID,
            title: request.action.statusTitle,
            risk: workflowRisk(for: request.action),
            inputSummary: CompanionWorkflowRunStore.argumentSummary([
                "action": .string(request.action.rawValue),
                "provider": .string(request.providerName),
                "resultTitle": .string(request.resultTitle),
                "sourceText": .string(request.sourceText),
                "resultText": .string(request.resultText)
            ]),
            status: .running
        )
        let outcome = desktopPet.handleAIResultWorkflow(request)
        switch outcome {
        case .accepted(let message):
            workflowRunStore.finish(
                id: runID,
                result: .succeeded(
                    output: [
                        "templateID": .string("ai-result-dispatch"),
                        "action": .string(request.action.rawValue)
                    ],
                    outputSummary: message
                )
            )
        case .cancelled(let message):
            workflowRunStore.cancel(
                id: runID,
                status: .cancelled,
                message: "AI result workflow cancelled. messageLength=\(message.count)"
            )
        }
        return outcome
    }

    func presentWorkflowConsole(_ snapshot: CompanionWorkflowRunSnapshot) {
        CompanionWorkflowConsoleWindowController.shared.present(
            snapshot: snapshot,
            onRetry: { [weak self] stepID in
                self?.retryWorkflowStep(runID: snapshot.id, stepID: stepID)
            },
            onSkip: { [weak self] stepID in
                self?.skipWorkflowStep(runID: snapshot.id, stepID: stepID)
            },
            onCancel: { [weak self] in
                self?.cancelWorkflowRunFromConsole(runID: snapshot.id)
            },
            onOpenJournal: { [weak self] in self?.desktopPet.showJournalFromWorkflowRun() },
            onOpenReminders: { [weak self] in self?.desktopPet.showReminderCenterFromWorkflowRun() },
            onOpenPomodoro: { [weak self] in self?.desktopPet.workflowShowPomodoroCenter() }
        )
    }

    func refreshWorkflowConsole(runID: UUID) {
        guard let run = workflowRunStore.run(id: runID) else {
            return
        }
        let template = run.templateID.flatMap { CompanionWorkflowTemplates.template(forID: $0) }
        let snapshot = run.workflowSnapshot(template: template)
        presentWorkflowConsole(snapshot)
    }

    func retryWorkflowStep(runID: UUID, stepID: UUID) {
        guard let run = workflowRunStore.run(id: runID),
              let step = run.steps.first(where: { $0.id == stepID })
        else {
            return
        }
        workflowRunStore.markStepRetryStarted(id: runID, stepID: stepID)
        refreshWorkflowConsole(runID: runID)

        if retryAssetUploadStep(runID: runID, stepID: stepID, run: run) {
            return
        }

        guard run.templateID == "ai-result-dispatch",
              runID == lastAIWorkflowRunID,
              let request = lastAIWorkflowRequest,
              let action = workflowAction(forTemplateStepID: step.templateStepID, toolID: step.toolID)
        else {
            workflowRunStore.markStepRetryUnavailable(
                id: runID,
                stepID: stepID,
                message: "This workflow step cannot be retried automatically yet."
            )
            refreshWorkflowConsole(runID: runID)
            return
        }

        let retryRequest = XiaoHuaErAIResultWorkflowRequest(
            action: action,
            actionTitle: request.actionTitle,
            resultTitle: request.resultTitle,
            providerName: request.providerName,
            sourceText: request.sourceText,
            resultText: request.resultText,
            createdAt: request.createdAt
        )
        let outcome = desktopPet.handleAIResultWorkflow(retryRequest)
        switch outcome {
        case .accepted(let message):
            workflowRunStore.markStepRetryFinished(
                id: runID,
                stepID: stepID,
                result: .succeeded(
                    output: [
                        "templateID": .string(run.templateID ?? ""),
                        "retriedStep": .string(step.templateStepID ?? step.title),
                        "action": .string(action.rawValue)
                    ],
                    outputSummary: message
                )
            )
        case .cancelled(let message):
            workflowRunStore.markStepRetryUnavailable(
                id: runID,
                stepID: stepID,
                message: message
            )
        }
        refreshWorkflowConsole(runID: runID)
    }

    func retryAssetUploadStep(runID: UUID, stepID: UUID, run: CompanionWorkflowRunRecord) -> Bool {
        assetUploadWorkflowCoordinator.retryAssetUploadStep(runID: runID, stepID: stepID, run: run)
    }

    func skipWorkflowStep(runID: UUID, stepID: UUID) {
        if !workflowRunStore.skipStep(id: runID, stepID: stepID) {
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Step cannot be skipped"),
                informativeText: CompanionL10n.text("Required workflow steps must succeed or the run must be cancelled."),
                tone: .warning
            )
        }
        refreshWorkflowConsole(runID: runID)
    }

    func cancelWorkflowRunFromConsole(runID: UUID) {
        assetUploadWorkflowCoordinator.cancelRun(runID)
        workflowRunStore.cancelInteractively(id: runID)
        refreshWorkflowConsole(runID: runID)
    }

    func workflowAction(forTemplateStepID templateStepID: String?, toolID: String?) -> XiaoHuaErAIResultWorkflowAction? {
        switch templateStepID ?? toolID ?? "" {
        case "journal.appendToday", "companion.journal.appendToday":
            return .saveToJournal
        case "reminder.create", "companion.reminder.create":
            return .createReminder
        case "pomodoro.startFocus", "companion.pomodoro.startFocus":
            return .startFocus
        default:
            return nil
        }
    }

    func workflowToolID(for action: XiaoHuaErAIResultWorkflowAction) -> String {
        switch action {
        case .saveToJournal:
            return "companion.journal.appendToday"
        case .createReminder:
            return "companion.reminder.create"
        case .startFocus:
            return "companion.pomodoro.startFocus"
        }
    }

    func workflowRisk(for action: XiaoHuaErAIResultWorkflowAction) -> CompanionWorkflowToolRisk? {
        switch action {
        case .saveToJournal, .createReminder:
            return .localWrite
        case .startFocus:
            return .localSession
        }
    }
}
