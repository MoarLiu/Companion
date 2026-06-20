import Foundation

// MARK: - Template Registry

struct CompanionWorkflowTemplates {
    static let aiResultDispatch = CompanionWorkflowTemplate(
        id: "ai-result-dispatch",
        title: "AI 结果派发",
        steps: [
            // 1. 快照 AI 结果（本地瞬时）
            CompanionWorkflowTemplateStep(
                id: "ai.result.snapshot",
                title: "准备内容",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 2. 参数补齐（如提醒缺时间）
            CompanionWorkflowTemplateStep(
                id: "workflow.input.collect",
                title: "补充信息",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 3. DryRun 计划预览
            CompanionWorkflowTemplateStep(
                id: "workflow.plan.preview",
                title: "计划预览",
                required: true,
                isDryRun: true,
                isLocal: true
            ),
            // 4. 写入 Journal（真实执行）
            CompanionWorkflowTemplateStep(
                id: "journal.appendToday",
                title: "存到日记",
                toolID: "companion.journal.appendToday",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            // 5. 创建提醒（真实执行）
            CompanionWorkflowTemplateStep(
                id: "reminder.create",
                title: "创建提醒",
                toolID: "companion.reminder.create",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            // 6. 开始专注（真实执行）
            CompanionWorkflowTemplateStep(
                id: "pomodoro.startFocus",
                title: "开始专注",
                toolID: "companion.pomodoro.startFocus",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            // 7. 结果展示
            CompanionWorkflowTemplateStep(
                id: "workflow.result.present",
                title: "完成",
                required: false,
                isDryRun: false,
                isLocal: true
            )
        ]
    )

    static let reminderFocusJournal = CompanionWorkflowTemplate(
        id: "reminder-focus-journal",
        title: "提醒 → 专注 → 日记",
        steps: [
            // 1. 解析提醒时间和任务
            CompanionWorkflowTemplateStep(
                id: "reminder.parse",
                title: "解析提醒",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 2. 创建提醒
            CompanionWorkflowTemplateStep(
                id: "reminder.create",
                title: "创建提醒",
                toolID: "companion.reminder.create",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 3. 等待提醒到期（跨事件）
            CompanionWorkflowTemplateStep(
                id: "reminder.await",
                title: "等待提醒到期",
                required: true,
                isDryRun: false,
                isLocal: false
            ),
            // 4. 确认开始番茄钟
            CompanionWorkflowTemplateStep(
                id: "pomodoro.confirm",
                title: "确认开始专注",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 5. 开始番茄钟
            CompanionWorkflowTemplateStep(
                id: "pomodoro.startFocus",
                title: "开始专注",
                toolID: "companion.pomodoro.startFocus",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 6. 等待番茄钟结束（跨事件）
            CompanionWorkflowTemplateStep(
                id: "pomodoro.await",
                title: "等待专注结束",
                required: true,
                isDryRun: false,
                isLocal: false
            ),
            // 7. 生成 Journal 草稿
            CompanionWorkflowTemplateStep(
                id: "journal.generateDraft",
                title: "生成日记草稿",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 8. 确认保存 Journal
            CompanionWorkflowTemplateStep(
                id: "journal.confirmSave",
                title: "确认保存",
                required: true,
                isDryRun: false,
                isLocal: true
            ),
            // 9. 保存到 Journal
            CompanionWorkflowTemplateStep(
                id: "journal.appendToday",
                title: "存到日记",
                toolID: "companion.journal.appendToday",
                required: true,
                isDryRun: false,
                isLocal: true
            )
        ]
    )

    static let assetUploadDispatch = CompanionWorkflowTemplate(
        id: "asset-upload-dispatch",
        title: "资产上传",
        steps: [
            CompanionWorkflowTemplateStep(
                id: "asset.inspect",
                title: "检查文件",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            CompanionWorkflowTemplateStep(
                id: "asset.upload.dryRun",
                title: "预览上传",
                toolID: "companion.asset.upload",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            CompanionWorkflowTemplateStep(
                id: "workflow.approval.request",
                title: "上传确认",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            CompanionWorkflowTemplateStep(
                id: "asset.upload",
                title: "上传资产",
                toolID: "companion.asset.upload",
                required: true,
                isDryRun: false,
                isLocal: false
            ),
            CompanionWorkflowTemplateStep(
                id: "workflow.result.present",
                title: "展示结果",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            CompanionWorkflowTemplateStep(
                id: "journal.appendToday",
                title: "插入日记",
                toolID: "companion.journal.appendToday",
                required: false,
                isDryRun: false,
                isLocal: true
            ),
            CompanionWorkflowTemplateStep(
                id: "clipboard.write",
                title: "复制链接",
                required: false,
                isDryRun: false,
                isLocal: true
            )
        ]
    )

    static func template(forID id: String) -> CompanionWorkflowTemplate? {
        switch id {
        case "ai-result-dispatch":
            return aiResultDispatch
        case "reminder-focus-journal":
            return reminderFocusJournal
        case "asset-upload-dispatch", "finder-asset-upload":
            return assetUploadDispatch
        default:
            return nil
        }
    }
}

// MARK: - AI Result Workflow Context

struct AIResultWorkflowContext {
    var actions: Set<XiaoHuaErAIResultWorkflowAction>
    var actionTitle: String
    var resultTitle: String
    var providerName: String
    var sourceText: String
    var resultText: String
    var createdAt: Date

    // 提醒相关
    var reminderTitle: String?
    var reminderTime: Date?

    // 专注相关
    var focusTaskTitle: String?
    var focusDurationMinutes: Int?

    init(
        actions: Set<XiaoHuaErAIResultWorkflowAction>,
        actionTitle: String,
        resultTitle: String,
        providerName: String,
        sourceText: String,
        resultText: String,
        createdAt: Date = Date()
    ) {
        self.actions = actions
        self.actionTitle = actionTitle
        self.resultTitle = resultTitle
        self.providerName = providerName
        self.sourceText = sourceText
        self.resultText = resultText
        self.createdAt = createdAt
        self.reminderTitle = nil
        self.reminderTime = nil
        self.focusTaskTitle = nil
        self.focusDurationMinutes = nil
    }

    init(from request: XiaoHuaErAIResultWorkflowRequest) {
        // 优先使用 actions 集合（支持单选和多选），如果为空则回退到单个 action
        self.actions = request.actions.isEmpty ? [request.action] : request.actions
        self.actionTitle = request.actionTitle
        self.resultTitle = request.resultTitle
        self.providerName = request.providerName
        self.sourceText = request.sourceText
        self.resultText = request.resultText
        self.createdAt = request.createdAt
        self.reminderTitle = request.reminderTitle
        self.reminderTime = request.reminderTime
        self.focusTaskTitle = nil
        self.focusDurationMinutes = nil
    }

    init(from requests: [XiaoHuaErAIResultWorkflowRequest]) {
        guard let first = requests.first else {
            self.actions = []
            self.actionTitle = ""
            self.resultTitle = ""
            self.providerName = ""
            self.sourceText = ""
            self.resultText = ""
            self.createdAt = Date()
            self.reminderTitle = nil
            self.reminderTime = nil
            self.focusTaskTitle = nil
            self.focusDurationMinutes = nil
            return
        }

        self.actions = Set(requests.flatMap { request in
            request.actions.isEmpty ? [request.action] : Array(request.actions)
        })
        self.actionTitle = first.actionTitle
        self.resultTitle = first.resultTitle
        self.providerName = first.providerName
        self.sourceText = first.sourceText
        self.resultText = first.resultText
        self.createdAt = first.createdAt
        self.reminderTitle = requests.compactMap(\.reminderTitle).first
        self.reminderTime = requests.compactMap(\.reminderTime).first
        self.focusTaskTitle = nil
        self.focusDurationMinutes = nil
    }

    func inputSummary() -> String {
        let actionNames = actions.sorted(by: { $0.rawValue < $1.rawValue })
            .map { action in
                switch action {
                case .saveToJournal: return "存日记"
                case .createReminder: return "创建提醒"
                case .startFocus: return "开始专注"
                }
            }
        return "[\(actionNames.joined(separator: " + "))] \(resultTitle)"
    }
}
