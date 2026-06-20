import SwiftUI
import AppKit

// MARK: - Workflow Console

struct WorkflowConsoleView: View {
    let snapshot: CompanionWorkflowRunSnapshot
    let onRetry: ((UUID) -> Void)?
    let onSkip: ((UUID) -> Void)?
    let onCancel: (() -> Void)?
    let onClose: (() -> Void)?
    let onOpenJournal: (() -> Void)?
    let onOpenReminders: (() -> Void)?
    let onOpenPomodoro: (() -> Void)?

    @State private var expandedStepID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：标题 + 整体进度
            headerSection

            Divider()
                .padding(.vertical, 8)

            // 主体：Step 时间线
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shouldShowCompactProgress {
                        compactProgressView
                    } else {
                        stepTimelineView
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: .infinity)

            // 底部：操作按钮
            if !isCompleted || hasFollowUpActions {
                Divider()
                    .padding(.vertical, 8)

                actionButtonsSection
            }
        }
        .padding(.vertical, 16)
        .frame(width: 480, height: 520)
        .background(XiaoHuaErTheme.elevatedSurface)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    if !snapshot.templateID.isEmpty {
                        Text(snapshot.templateID)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary)
                    }
                }

                Spacer()

                if let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 整体进度条
            if !isCompleted {
                ProgressView(value: overallProgress)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
            }

            // 状态文字
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 16)
    }

    private var statusIcon: some View {
        Group {
            switch snapshot.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(XiaoHuaErTheme.leaf)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(XiaoHuaErTheme.coral)
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(Color.secondary)
            case .awaitingInput:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(XiaoHuaErTheme.amber)
            case .blocked:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(XiaoHuaErTheme.amber)
            default:
                Image(systemName: "circle")
                    .foregroundStyle(Color.secondary)
            }
        }
        .font(.system(size: 20, weight: .regular))
    }

    // MARK: - Step Timeline

    private var shouldShowCompactProgress: Bool {
        snapshot.status != .failed && snapshot.steps.count <= 2
    }

    private var compactProgressView: some View {
        HStack(spacing: 12) {
            ForEach(snapshot.steps, id: \.id) { step in
                compactStepIndicator(step)
            }
        }
        .padding(.vertical, 20)
    }

    private func compactStepIndicator(_ step: CompanionWorkflowStepSnapshot) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(stepBackgroundColor(step.status))
                    .frame(width: 32, height: 32)

                stepStatusIcon(step.status)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(stepForegroundColor(step.status))
            }

            Text(step.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var stepTimelineView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, isLast: index == snapshot.steps.count - 1)
            }
        }
    }

    private func stepRow(_ step: CompanionWorkflowStepSnapshot, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // 左侧：状态指示器 + 连接线
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(stepBackgroundColor(step.status))
                            .frame(width: 24, height: 24)

                        stepStatusIcon(step.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(stepForegroundColor(step.status))
                    }

                    if !isLast {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 2)
                            .frame(minHeight: 40)
                    }
                }

                // 右侧：Step 信息
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(step.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)

                        Spacer()

                        if let duration = stepDuration(step) {
                            Text(duration)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(Color.secondary)
                        }
                    }

                    if !step.outputSummary.isEmpty {
                        Text(step.outputSummary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(expandedStepID == step.id ? nil : 2)
                    }

                    if let error = step.errorSummary, !error.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(error)
                                .font(.system(size: 11, weight: .regular))
                        }
                        .foregroundStyle(XiaoHuaErTheme.coral)
                        .lineLimit(expandedStepID == step.id ? nil : 2)
                    }

                    // 失败步骤的恢复操作
                    if step.status == .failed {
                        stepRecoveryActions(step)
                    }

                    // 展开/收起按钮
                    if shouldShowExpandButton(step) {
                        Button {
                            withAnimation {
                                expandedStepID = expandedStepID == step.id ? nil : step.id
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(expandedStepID == step.id ? "收起" : "展开")
                                Image(systemName: expandedStepID == step.id ? "chevron.up" : "chevron.down")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(XiaoHuaErTheme.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, isLast ? 0 : 12)
            }
        }
    }

    private func stepRecoveryActions(_ step: CompanionWorkflowStepSnapshot) -> some View {
        HStack(spacing: 8) {
            if let onRetry = onRetry {
                Button {
                    onRetry(step.id)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(XiaoHuaErTheme.actionFill(XiaoHuaErTheme.tint), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !step.required, let onSkip = onSkip {
                Button {
                    onSkip(step.id)
                } label: {
                    Label("跳过", systemImage: "forward.fill")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtonsSection: some View {
        HStack(spacing: 10) {
            if !isCompleted, let onCancel = onCancel {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 32))
            }

            if hasFollowUpActions {
                followUpActionsButtons
            }

            if isCompleted {
                Button(action: { onClose?() }) {
                    Text("关闭")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .primary, size: 32))
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var followUpActionsButtons: some View {
        ForEach(snapshot.followUpActions, id: \.self) { action in
            Button {
                handleFollowUpAction(action)
            } label: {
                Label(followUpActionTitle(action), systemImage: followUpActionIcon(action))
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 32))
        }
    }

    // MARK: - Helpers

    private var isCompleted: Bool {
        snapshot.status == .completed || snapshot.status == .cancelled || snapshot.status == .failed
    }

    private var hasFollowUpActions: Bool {
        !snapshot.followUpActions.isEmpty
    }

    private var overallProgress: Double {
        let completedSteps = snapshot.steps.filter { $0.status == .succeeded || $0.status == .skipped }.count
        return Double(completedSteps) / Double(max(snapshot.steps.count, 1))
    }

    private var progressTint: Color {
        switch snapshot.status {
        case .failed:
            return XiaoHuaErTheme.coral
        case .blocked, .awaitingInput:
            return XiaoHuaErTheme.amber
        default:
            return XiaoHuaErTheme.tint
        }
    }

    private var statusText: String {
        switch snapshot.status {
        case .completed:
            return "已完成"
        case .running:
            let completedCount = snapshot.steps.filter { $0.status == .succeeded || $0.status == .skipped }.count
            return "执行中 (\(completedCount)/\(snapshot.steps.count))"
        case .failed:
            return snapshot.errorSummary ?? "执行失败"
        case .cancelled:
            return "已取消"
        case .awaitingInput:
            return snapshot.errorSummary ?? "需要补充信息"
        case .blocked:
            return snapshot.errorSummary ?? "执行被阻塞"
        default:
            return "准备中"
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .completed:
            return XiaoHuaErTheme.leaf
        case .failed:
            return XiaoHuaErTheme.coral
        case .cancelled:
            return Color.secondary
        case .awaitingInput, .blocked:
            return XiaoHuaErTheme.amber
        default:
            return XiaoHuaErTheme.tint
        }
    }

    private func stepBackgroundColor(_ status: CompanionWorkflowStepStatus) -> Color {
        switch status {
        case .succeeded:
            return XiaoHuaErTheme.leaf.opacity(0.2)
        case .failed:
            return XiaoHuaErTheme.coral.opacity(0.2)
        case .running:
            return XiaoHuaErTheme.tint.opacity(0.2)
        case .awaitingInput, .awaitingApproval:
            return XiaoHuaErTheme.amber.opacity(0.2)
        case .cancelled, .skipped:
            return Color.secondary.opacity(0.1)
        default:
            return Color.secondary.opacity(0.1)
        }
    }

    private func stepForegroundColor(_ status: CompanionWorkflowStepStatus) -> Color {
        switch status {
        case .succeeded:
            return XiaoHuaErTheme.leaf
        case .failed:
            return XiaoHuaErTheme.coral
        case .running:
            return XiaoHuaErTheme.tint
        case .awaitingInput, .awaitingApproval:
            return XiaoHuaErTheme.amber
        default:
            return Color.secondary
        }
    }

    private func stepStatusIcon(_ status: CompanionWorkflowStepStatus) -> some View {
        Group {
            switch status {
            case .succeeded:
                Image(systemName: "checkmark")
            case .failed:
                Image(systemName: "xmark")
            case .running:
                Image(systemName: "arrow.right")
            case .awaitingInput, .awaitingApproval:
                Image(systemName: "questionmark")
            case .cancelled, .skipped:
                Image(systemName: "minus")
            default:
                Image(systemName: "circle")
            }
        }
    }

    private func shouldShowExpandButton(_ step: CompanionWorkflowStepSnapshot) -> Bool {
        let hasLongOutput = step.outputSummary.count > 100
        let hasError = step.errorSummary != nil && !step.errorSummary!.isEmpty
        return hasLongOutput || hasError
    }

    private func stepDuration(_ step: CompanionWorkflowStepSnapshot) -> String? {
        guard let start = step.startedAt, let end = step.finishedAt else {
            return nil
        }
        let duration = end.timeIntervalSince(start)
        if duration < 1 {
            return "<1s"
        } else if duration < 60 {
            return String(format: "%.0fs", duration)
        } else {
            return String(format: "%.1fm", duration / 60)
        }
    }

    private func handleFollowUpAction(_ action: CompanionWorkflowFollowUpAction) {
        switch action {
        case .openJournal:
            onOpenJournal?()
        case .openReminders:
            onOpenReminders?()
        case .openPomodoro:
            onOpenPomodoro?()
        case .copyResult:
            if !snapshot.outputSummary.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snapshot.outputSummary, forType: .string)
            }
        }
    }

    private func followUpActionTitle(_ action: CompanionWorkflowFollowUpAction) -> String {
        switch action {
        case .openJournal:
            return "打开日记"
        case .openReminders:
            return "查看提醒"
        case .openPomodoro:
            return "打开番茄钟"
        case .copyResult:
            return "复制结果"
        }
    }

    private func followUpActionIcon(_ action: CompanionWorkflowFollowUpAction) -> String {
        switch action {
        case .openJournal:
            return "book.closed"
        case .openReminders:
            return "bell"
        case .openPomodoro:
            return "timer"
        case .copyResult:
            return "doc.on.doc"
        }
    }
}

// MARK: - Workflow Console Window Controller

/// 把 `WorkflowConsoleView` 托管进独立窗口。多选 Hero workflow 执行完成后由 Companion 调用 `present(...)`
/// 展示 run 的 step 时间线与完成页后续入口。固定 480×520，关闭即释放。
final class CompanionWorkflowConsoleWindowController {
    static let shared = CompanionWorkflowConsoleWindowController()
    private var window: NSWindow?

    func present(
        snapshot: CompanionWorkflowRunSnapshot,
        onRetry: ((UUID) -> Void)? = nil,
        onSkip: ((UUID) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onOpenJournal: (() -> Void)? = nil,
        onOpenReminders: (() -> Void)? = nil,
        onOpenPomodoro: (() -> Void)? = nil
    ) {
        let view = WorkflowConsoleView(
            snapshot: snapshot,
            onRetry: onRetry,
            onSkip: onSkip,
            onCancel: onCancel,
            onClose: { [weak self] in self?.closeConsole() },
            onOpenJournal: onOpenJournal,
            onOpenReminders: onOpenReminders,
            onOpenPomodoro: onOpenPomodoro
        )

        let hosting = CompanionInteractiveHostingView(rootView: view)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        let panel: NSWindow
        if let existing = window {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Workflow Console"
            panel.contentView = hosting
            panel.isReleasedWhenClosed = false
            panel.center()
            window = panel
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeConsole() {
        window?.close()
        window = nil
    }
}
