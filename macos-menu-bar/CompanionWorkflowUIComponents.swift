import SwiftUI

// MARK: - Workflow Action Selection (多选支持)

struct WorkflowActionSelection: View {
    @Binding var selectedActions: Set<XiaoHuaErAIResultWorkflowAction>

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.tint)
                Text("结果操作")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            .padding(.horizontal, 2)

            actionCheckbox(.saveToJournal, tint: XiaoHuaErTheme.leaf)
            actionCheckbox(.createReminder, tint: XiaoHuaErTheme.amber)
            actionCheckbox(.startFocus, tint: XiaoHuaErTheme.sky)
        }
    }

    private func actionCheckbox(_ action: XiaoHuaErAIResultWorkflowAction, tint: Color) -> some View {
        Button {
            if selectedActions.contains(action) {
                selectedActions.remove(action)
            } else {
                selectedActions.insert(action)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selectedActions.contains(action) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selectedActions.contains(action) ? tint : Color.secondary)

                Label(action.displayName, systemImage: systemImage(for: action))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selectedActions.contains(action) ? Color.primary : Color.secondary)

                Spacer()
            }
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(
                selectedActions.contains(action) ? XiaoHuaErTheme.actionFill(tint) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selectedActions.contains(action) ? tint.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func systemImage(for action: XiaoHuaErAIResultWorkflowAction) -> String {
        switch action {
        case .saveToJournal:
            return "book.closed"
        case .createReminder:
            return "bell.badge"
        case .startFocus:
            return "timer"
        }
    }
}

// MARK: - Workflow Plan Preview (计划预览)

struct WorkflowPlanPreview: View {
    let actions: [XiaoHuaErAIResultWorkflowAction]
    let context: AIResultWorkflowContext
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.tint)
                Text("执行计划")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
            }

            Divider()

            // 步骤列表
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions, id: \.self) { action in
                    planStepRow(for: action)
                }
            }

            // 展开详情
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("内容预览")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    Text(context.resultText.prefix(120) + (context.resultText.count > 120 ? "..." : ""))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(3)
                }
            }

            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "收起" : "查看详情")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(XiaoHuaErTheme.tint)
            }
            .buttonStyle(.plain)

            Divider()

            // 操作按钮
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 30))

                Button(action: onConfirm) {
                    Text("确认执行")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .primary, size: 30))
            }
        }
        .padding(12)
        .background(
            XiaoHuaErTheme.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
        )
    }

    private func planStepRow(for action: XiaoHuaErAIResultWorkflowAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(tint(for: action))

            Label(stepDescription(for: action), systemImage: systemImage(for: action))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary)

            Spacer()
        }
    }

    private func stepDescription(for action: XiaoHuaErAIResultWorkflowAction) -> String {
        switch action {
        case .saveToJournal:
            return "追加到今日日记"
        case .createReminder:
            return "创建提醒"
        case .startFocus:
            return "开始番茄钟专注"
        }
    }

    private func systemImage(for action: XiaoHuaErAIResultWorkflowAction) -> String {
        switch action {
        case .saveToJournal:
            return "book.closed"
        case .createReminder:
            return "bell.badge"
        case .startFocus:
            return "timer"
        }
    }

    private func tint(for action: XiaoHuaErAIResultWorkflowAction) -> Color {
        switch action {
        case .saveToJournal:
            return XiaoHuaErTheme.leaf
        case .createReminder:
            return XiaoHuaErTheme.amber
        case .startFocus:
            return XiaoHuaErTheme.sky
        }
    }
}

// MARK: - Reminder Time Input (提醒时间补问)

struct ReminderTimeInputView: View {
    let taskTitle: String
    let onTimeSelected: (Date) -> Void
    let onCancel: () -> Void
    let onOpenDraft: () -> Void

    @State private var selectedPreset: TimePreset?
    @State private var customTime = Date()
    @State private var showCustomPicker = false

    enum TimePreset: String, CaseIterable {
        case tomorrow9am = "明早 9 点"
        case today3pm = "今天下午 3 点"
        case oneHourLater = "1 小时后"

        var date: Date {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .tomorrow9am:
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.day! += 1
                components.hour = 9
                components.minute = 0
                return calendar.date(from: components) ?? now
            case .today3pm:
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = 15
                components.minute = 0
                let target = calendar.date(from: components) ?? now
                return target > now ? target : calendar.date(byAdding: .day, value: 1, to: target) ?? now
            case .oneHourLater:
                return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.amber)
                Text("设置提醒时间")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
            }

            // 任务标题
            Text(taskTitle)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)

            Divider()

            // 快捷选项
            VStack(spacing: 7) {
                ForEach(TimePreset.allCases, id: \.rawValue) { preset in
                    presetButton(preset)
                }

                Button {
                    showCustomPicker.toggle()
                } label: {
                    HStack {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .medium))
                        Text("自定义时间")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: showCustomPicker ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.primary)
                    .frame(height: 32)
                    .padding(.horizontal, 10)
                    .background(
                        XiaoHuaErTheme.actionFill(XiaoHuaErTheme.tint),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                if showCustomPicker {
                    DatePicker("", selection: $customTime, in: Date()...)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.vertical, 4)

                    Button {
                        onTimeSelected(customTime)
                    } label: {
                        Text("使用此时间")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                    }
                    .buttonStyle(CompanionGlassIconButtonStyle(tone: .primary, size: 28))
                }
            }

            Divider()

            // 底部操作
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 30))

                Button(action: onOpenDraft) {
                    Text("打开草稿")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(CompanionGlassIconButtonStyle(tone: .neutral, size: 30))
            }
        }
        .padding(12)
        .background(
            XiaoHuaErTheme.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
        )
    }

    private func presetButton(_ preset: TimePreset) -> some View {
        Button {
            selectedPreset = preset
            onTimeSelected(preset.date)
        } label: {
            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .medium))
                Text(preset.rawValue)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(selectedPreset == preset ? Color.primary : Color.secondary)
            .frame(height: 32)
            .padding(.horizontal, 10)
            .background(
                selectedPreset == preset ? XiaoHuaErTheme.actionFill(XiaoHuaErTheme.amber) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        selectedPreset == preset ? XiaoHuaErTheme.amber.opacity(0.3) : XiaoHuaErTheme.glassHairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
