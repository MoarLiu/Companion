import Foundation

enum CompanionRestrictedNLRouteConfidence: String, Equatable, Codable {
    case high
    case medium
    case low
}

enum CompanionRestrictedNLRouteAction: String, Equatable, Codable {
    case saveToJournal
    case createReminder
    case startFocus
}

struct CompanionRestrictedNLCommand: Equatable {
    var templateID: String
    var confidence: CompanionRestrictedNLRouteConfidence
    var missingInputs: [String]
    var contextSummary: String
    var privacyFlags: [String]
    var action: CompanionRestrictedNLRouteAction?
    var reminderTitle: String?
    var reminderTime: Date?
}

enum CompanionRestrictedNLRouteResolution: Equatable {
    case command(CompanionRestrictedNLCommand)
    case clarification(CompanionRestrictedNLCommand, message: String)
    case supportedRoutines(CompanionRestrictedNLCommand?, message: String)
    case noRoute

    var command: CompanionRestrictedNLCommand? {
        switch self {
        case .command(let command), .clarification(let command, _):
            return command
        case .supportedRoutines(let command, _):
            return command
        case .noRoute:
            return nil
        }
    }
}

struct CompanionRestrictedNLRouteContext: Equatable {
    var hasAIResult: Bool

    init(hasAIResult: Bool = false) {
        self.hasAIResult = hasAIResult
    }
}

struct CompanionRestrictedNLRouteResolver {
    var now: Date
    var calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    func resolve(_ text: String, context: CompanionRestrictedNLRouteContext) -> CompanionRestrictedNLRouteResolution {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .noRoute
        }

        let normalized = Self.normalized(trimmed)
        let wantsReminder = containsAny(normalized, ["提醒", "remind"])
        let wantsFocus = containsAny(normalized, ["专注", "番茄", "focus", "pomodoro"])
        let wantsJournal = containsAny(normalized, ["日记", "journal"])

        if wantsReminder && wantsFocus && wantsJournal {
            return reminderFocusJournalResolution(for: trimmed)
        }

        if looksLikeLowConfidenceReminder(normalized, originalText: trimmed) {
            return lowConfidenceReminderResolution(for: trimmed, context: context)
        }

        if let action = aiResultAction(for: normalized) {
            return aiResultResolution(for: action, text: trimmed, context: context)
        }

        if looksLikeWorkflowRequest(normalized) {
            return .supportedRoutines(nil, message: Self.supportedRoutineMessage)
        }

        return .noRoute
    }

    static var supportedRoutineMessage: String {
        [
            "我现在只走已注册的本地 routine，不会自由猜 workflow。",
            "我能帮你：",
            "• 把 AI Quick Actions 结果存到日记",
            "• 基于 AI 结果创建提醒或开始专注",
            "• 创建“提醒 → 专注 → 日记”计划",
            "也可以先选中文本或复制内容，点“翻译”处理内容。"
        ].joined(separator: "\n")
    }

    static var missingAIResultMessage: String {
        [
            "我需要先有一条 AI Quick Actions 结果，才能把“这个结果”交给 workflow。",
            "先选中文本或复制内容，点“翻译”处理内容；结果出来后再说“把这个结果存到日记”。"
        ].joined(separator: "\n")
    }

    static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private func reminderFocusJournalResolution(for text: String) -> CompanionRestrictedNLRouteResolution {
        let parsed = PetReminderRuleParser.parse(text, now: now, calendar: calendar)
        let command = CompanionRestrictedNLCommand(
            templateID: "reminder-focus-journal",
            confidence: .medium,
            missingInputs: parsed == nil ? ["time"] : [],
            contextSummary: parsed.map { "task=\(Self.safeSummary($0.title)); hasTime=true" } ?? "hasTime=false",
            privacyFlags: ["local-only", "no-ai-generation", "local-write"],
            action: nil,
            reminderTitle: parsed?.title,
            reminderTime: parsed?.fireDate
        )

        guard parsed != nil else {
            return .clarification(command, message: [
                "好的，要在什么时候提醒你开始这条“提醒 → 专注 → 日记”计划？",
                "• 明早 9 点",
                "• 明天下午 3 点",
                "• 或直接说：30分钟后写周报，提醒我专注并结束后记日记"
            ].joined(separator: "\n"))
        }

        return .command(command)
    }

    private func aiResultResolution(
        for action: CompanionRestrictedNLRouteAction,
        text: String,
        context: CompanionRestrictedNLRouteContext
    ) -> CompanionRestrictedNLRouteResolution {
        var missingInputs: [String] = []
        if !context.hasAIResult {
            missingInputs.append("ai_result")
        }

        let parsedReminder = action == .createReminder
            ? PetReminderRuleParser.parse(text, now: now, calendar: calendar)
            : nil
        if action == .createReminder,
           parsedReminder == nil,
           mentionsDateWithoutSpecificTime(Self.normalized(text)) {
            missingInputs.append("time")
        }

        let command = CompanionRestrictedNLCommand(
            templateID: "ai-result-dispatch",
            confidence: missingInputs.isEmpty ? .high : .medium,
            missingInputs: missingInputs,
            contextSummary: context.hasAIResult ? "ai_result=available" : "ai_result=missing",
            privacyFlags: privacyFlags(for: action),
            action: action,
            reminderTitle: parsedReminder?.title,
            reminderTime: parsedReminder?.fireDate
        )

        if !context.hasAIResult {
            return .clarification(command, message: Self.missingAIResultMessage)
        }

        if missingInputs.contains("time") {
            return .clarification(command, message: [
                "好的，要在什么时候提醒你？",
                "• 明早 9 点",
                "• 明天下午 3 点",
                "• 自定义时间"
            ].joined(separator: "\n"))
        }

        return .command(command)
    }

    private func lowConfidenceReminderResolution(
        for text: String,
        context: CompanionRestrictedNLRouteContext
    ) -> CompanionRestrictedNLRouteResolution {
        let normalized = Self.normalized(text)
        var missingInputs: [String] = context.hasAIResult ? [] : ["ai_result"]
        if mentionsDateWithoutSpecificTime(normalized) || PetReminderRuleParser.parse(text, now: now, calendar: calendar) == nil {
            missingInputs.append("time")
        }

        let command = CompanionRestrictedNLCommand(
            templateID: "ai-result-dispatch",
            confidence: .low,
            missingInputs: Array(Set(missingInputs)).sorted(),
            contextSummary: "low_confidence=reminder",
            privacyFlags: ["local-only", "no-ai-generation", "local-write"],
            action: .createReminder,
            reminderTitle: nil,
            reminderTime: nil
        )
        return .clarification(command, message: [
            "你是想基于当前 AI 结果创建提醒，还是创建“提醒 → 专注 → 日记”计划？",
            "如果只是提醒，请告诉我具体时间，比如“明早 9 点提醒我写周报”。"
        ].joined(separator: "\n"))
    }

    private func aiResultAction(for normalized: String) -> CompanionRestrictedNLRouteAction? {
        let journalWords = [
            "存到日记", "存日记", "保存到日记", "写入日记", "记到日记", "写到日记",
            "savetojournal", "addtojournal"
        ]
        if containsAny(normalized, journalWords) {
            return .saveToJournal
        }

        let reminderWords = [
            "落成提醒", "创建提醒", "设置提醒", "提醒我", "加提醒",
            "remindme", "createreminder", "setreminder"
        ]
        if containsAny(normalized, reminderWords) {
            return .createReminder
        }

        let focusWords = ["开始专注", "开专注", "开启专注", "番茄钟", "startfocus", "pomodoro"]
        if containsAny(normalized, focusWords) {
            return .startFocus
        }

        return nil
    }

    private func looksLikeLowConfidenceReminder(_ normalized: String, originalText: String) -> Bool {
        containsAny(normalized, ["提醒", "remind"]) &&
            containsAny(normalized, ["明天", "明早", "今晚", "今天", "tomorrow", "today"]) &&
            (mentionsDateWithoutSpecificTime(normalized) || PetReminderRuleParser.parse(originalText, now: now, calendar: calendar) == nil)
    }

    private func looksLikeWorkflowRequest(_ normalized: String) -> Bool {
        let domainWords = [
            "工作流", "workflow", "routine", "流程", "日记", "journal", "提醒", "remind",
            "专注", "focus", "番茄", "总结", "翻译", "整理", "AI Actions", "小花儿"
        ]
        let actionWords = [
            "帮我", "帮忙", "请", "想", "要", "把", "将", "这个", "结果", "创建",
            "设置", "开始", "保存", "存", "整理", "总结", "翻译", "执行"
        ]
        return containsAny(normalized, domainWords) && containsAny(normalized, actionWords)
    }

    private func mentionsDateWithoutSpecificTime(_ normalized: String) -> Bool {
        containsAny(normalized, ["明天", "明早", "明晚", "今天", "今晚", "tomorrow", "today"]) &&
            normalized.range(of: #"\d{1,2}([:：点]|\s?(am|pm))"#, options: .regularExpression) == nil
    }

    private func privacyFlags(for action: CompanionRestrictedNLRouteAction) -> [String] {
        switch action {
        case .saveToJournal, .createReminder:
            return ["local-only", "no-ai-generation", "local-write"]
        case .startFocus:
            return ["local-only", "no-ai-generation", "local-session"]
        }
    }

    private func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0.lowercased()) }
    }

    private static func safeSummary(_ text: String, maxLength: Int = 60) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed
        }
        return String(collapsed.prefix(maxLength - 1)) + "..."
    }
}
