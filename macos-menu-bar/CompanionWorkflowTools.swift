import Foundation

enum CompanionJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CompanionJSONValue])
    case array([CompanionJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CompanionJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CompanionJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if let intValue = Self.exactInt(from: value) {
                try container.encode(intValue)
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if let intValue = Self.exactInt(from: value) {
                return intValue
            }
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .null:
            return NSNull()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Self.roundedInt(from: value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(normalized) { return true }
            if ["0", "false", "no"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    var objectValue: [String: CompanionJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CompanionJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    static func fromAny(_ value: Any) -> CompanionJSONValue {
        switch value {
        case let value as CompanionJSONValue:
            return value
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.map(CompanionJSONValue.fromAny))
        case let value as [String: Any]:
            return .object(value.mapValues(CompanionJSONValue.fromAny))
        default:
            return .null
        }
    }

    private static func exactInt(from value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded == value else { return nil }
        return Int(exactly: rounded)
    }

    private static func roundedInt(from value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }
}

typealias CompanionJSONObject = [String: CompanionJSONValue]

struct CompanionReminderBatchApprovalPreview: Equatable {
    var prompt: String
    var invalidCount: Int
}

enum CompanionReminderBatchInitialApprovalAction: Equatable {
    case allowBatch
    case editItems
    case createValid
    case deny
}

enum CompanionReminderBatchItemApprovalAction: Equatable {
    case edit
    case skip
    case denyBatch
}

struct CompanionReminderBatchApprovalDecision: Equatable {
    var approved: Bool
    var arguments: CompanionJSONObject
}

protocol CompanionReminderBatchApprovalPrompting {
    func preview(for arguments: CompanionJSONObject) -> CompanionReminderBatchApprovalPreview
    func invalidIndexes(for arguments: CompanionJSONObject) -> [Int]
    func initialAction(for preview: CompanionReminderBatchApprovalPreview) -> CompanionReminderBatchInitialApprovalAction
    func actionForInvalidItem(_ item: CompanionJSONValue, index: Int) -> CompanionReminderBatchItemApprovalAction
    func editedItem(_ item: CompanionJSONValue, index: Int) -> CompanionJSONValue?
    func confirmCreateValid(for preview: CompanionReminderBatchApprovalPreview) -> Bool
}

struct CompanionReminderBatchApprovalClosurePrompter: CompanionReminderBatchApprovalPrompting {
    var previewProvider: (CompanionJSONObject) -> CompanionReminderBatchApprovalPreview
    var invalidIndexProvider: (CompanionJSONObject) -> [Int]
    var initialActionProvider: (CompanionReminderBatchApprovalPreview) -> CompanionReminderBatchInitialApprovalAction
    var itemActionProvider: (CompanionJSONValue, Int) -> CompanionReminderBatchItemApprovalAction
    var editedItemProvider: (CompanionJSONValue, Int) -> CompanionJSONValue?
    var createValidConfirmationProvider: (CompanionReminderBatchApprovalPreview) -> Bool

    func preview(for arguments: CompanionJSONObject) -> CompanionReminderBatchApprovalPreview {
        previewProvider(arguments)
    }

    func invalidIndexes(for arguments: CompanionJSONObject) -> [Int] {
        invalidIndexProvider(arguments)
    }

    func initialAction(for preview: CompanionReminderBatchApprovalPreview) -> CompanionReminderBatchInitialApprovalAction {
        initialActionProvider(preview)
    }

    func actionForInvalidItem(_ item: CompanionJSONValue, index: Int) -> CompanionReminderBatchItemApprovalAction {
        itemActionProvider(item, index)
    }

    func editedItem(_ item: CompanionJSONValue, index: Int) -> CompanionJSONValue? {
        editedItemProvider(item, index)
    }

    func confirmCreateValid(for preview: CompanionReminderBatchApprovalPreview) -> Bool {
        createValidConfirmationProvider(preview)
    }
}

struct CompanionReminderBatchApprovalResolver {
    var prompter: CompanionReminderBatchApprovalPrompting

    func resolve(arguments: CompanionJSONObject) -> CompanionReminderBatchApprovalDecision {
        let preview = prompter.preview(for: arguments)
        switch prompter.initialAction(for: preview) {
        case .deny:
            return CompanionReminderBatchApprovalDecision(approved: false, arguments: arguments)
        case .allowBatch:
            return CompanionReminderBatchApprovalDecision(approved: true, arguments: arguments)
        case .createValid:
            var updatedArguments = arguments
            updatedArguments["allowPartial"] = .bool(true)
            return CompanionReminderBatchApprovalDecision(approved: true, arguments: updatedArguments)
        case .editItems:
            return resolveEditedArguments(arguments)
        }
    }

    private func resolveEditedArguments(_ arguments: CompanionJSONObject) -> CompanionReminderBatchApprovalDecision {
        guard var items = arguments["items"]?.arrayValue else {
            return CompanionReminderBatchApprovalDecision(approved: true, arguments: arguments)
        }

        var updatedArguments = arguments
        var skippedIndexes = Set(arguments["skippedItemIndexes"]?.arrayValue?.compactMap(\.intValue) ?? [])
        let invalidIndexes = uniqueIndexes(prompter.invalidIndexes(for: arguments))
        for index in invalidIndexes {
            guard items.indices.contains(index) else { continue }
            let item = items[index]
            switch prompter.actionForInvalidItem(item, index: index) {
            case .edit:
                if let edited = prompter.editedItem(item, index: index) {
                    items[index] = edited
                    skippedIndexes.remove(index)
                } else {
                    skippedIndexes.insert(index)
                }
            case .skip:
                skippedIndexes.insert(index)
            case .denyBatch:
                return CompanionReminderBatchApprovalDecision(approved: false, arguments: arguments)
            }
        }

        updatedArguments["items"] = .array(items)
        if skippedIndexes.isEmpty {
            updatedArguments.removeValue(forKey: "skippedItemIndexes")
        } else {
            updatedArguments["skippedItemIndexes"] = .array(skippedIndexes.sorted().map { .number(Double($0)) })
        }

        let updatedPreview = prompter.preview(for: updatedArguments)
        if updatedPreview.invalidCount > 0 {
            guard prompter.confirmCreateValid(for: updatedPreview) else {
                return CompanionReminderBatchApprovalDecision(approved: false, arguments: arguments)
            }
            updatedArguments["allowPartial"] = .bool(true)
        }
        return CompanionReminderBatchApprovalDecision(approved: true, arguments: updatedArguments)
    }

    private func uniqueIndexes(_ indexes: [Int]) -> [Int] {
        var seen = Set<Int>()
        return indexes.filter { seen.insert($0).inserted }
    }
}

enum CompanionWorkflowToolRisk: String, Codable, Equatable {
    case readOnly
    case localWrite
    case localSession
    case externalWrite
    case destructive
}

enum CompanionWorkflowApprovalMode: String, Codable, Equatable {
    case none
    case firstUse
    case perRun
    case always
}

struct CompanionWorkflowToolDescriptor: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var description: String
    var risk: CompanionWorkflowToolRisk
    var approvalMode: CompanionWorkflowApprovalMode
    var rememberableApproval: Bool
    var inputSchema: CompanionJSONObject
    var outputSchema: CompanionJSONObject
}

struct CompanionWorkflowToolInvocation: Codable, Equatable, Identifiable {
    var id: UUID
    var runID: UUID?
    var stepID: UUID?
    var toolID: String
    var arguments: CompanionJSONObject
    var dryRun: Bool
    var requestedAt: Date
    var caller: String?

    init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        stepID: UUID? = nil,
        toolID: String,
        arguments: CompanionJSONObject,
        dryRun: Bool = false,
        requestedAt: Date = Date(),
        caller: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.stepID = stepID
        self.toolID = toolID
        self.arguments = arguments
        self.dryRun = dryRun
        self.requestedAt = requestedAt
        self.caller = caller
    }
}

struct CompanionWorkflowMissingInput: Codable, Equatable {
    var key: String
    var title: String
    var message: String
}

struct CompanionWorkflowToolError: Codable, Equatable {
    var code: String
    var message: String
    var recoverySuggestion: String?
}

struct CompanionWorkflowToolResult: Codable, Equatable {
    enum Status: String, Codable {
        case succeeded
        case needsInput
        case blocked
        case denied
        case failed
    }

    var status: Status
    var output: CompanionJSONObject
    var outputSummary: String
    var userMessage: String?
    var missingInputs: [CompanionWorkflowMissingInput]
    var error: CompanionWorkflowToolError?

    static func succeeded(
        output: CompanionJSONObject,
        outputSummary: String,
        userMessage: String? = nil
    ) -> CompanionWorkflowToolResult {
        CompanionWorkflowToolResult(
            status: .succeeded,
            output: output,
            outputSummary: outputSummary,
            userMessage: userMessage,
            missingInputs: [],
            error: nil
        )
    }

    static func needsInput(
        _ missingInputs: [CompanionWorkflowMissingInput],
        output: CompanionJSONObject,
        outputSummary: String,
        userMessage: String
    ) -> CompanionWorkflowToolResult {
        CompanionWorkflowToolResult(
            status: .needsInput,
            output: output,
            outputSummary: outputSummary,
            userMessage: userMessage,
            missingInputs: missingInputs,
            error: nil
        )
    }

    static func blocked(code: String, message: String, output: CompanionJSONObject = [:]) -> CompanionWorkflowToolResult {
        CompanionWorkflowToolResult(
            status: .blocked,
            output: output,
            outputSummary: message,
            userMessage: message,
            missingInputs: [],
            error: CompanionWorkflowToolError(code: code, message: message, recoverySuggestion: nil)
        )
    }

    static func denied(code: String, message: String, output: CompanionJSONObject = [:]) -> CompanionWorkflowToolResult {
        CompanionWorkflowToolResult(
            status: .denied,
            output: output,
            outputSummary: message,
            userMessage: message,
            missingInputs: [],
            error: CompanionWorkflowToolError(code: code, message: message, recoverySuggestion: nil)
        )
    }

    static func failed(code: String, message: String, recoverySuggestion: String? = nil) -> CompanionWorkflowToolResult {
        CompanionWorkflowToolResult(
            status: .failed,
            output: [:],
            outputSummary: message,
            userMessage: message,
            missingInputs: [],
            error: CompanionWorkflowToolError(code: code, message: message, recoverySuggestion: recoverySuggestion)
        )
    }
}

protocol CompanionWorkflowTool {
    var descriptor: CompanionWorkflowToolDescriptor { get }
    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult
}

final class CompanionWorkflowToolRegistry {
    private var tools: [String: CompanionWorkflowTool] = [:]

    func register(_ tool: CompanionWorkflowTool) {
        tools[tool.descriptor.id] = tool
    }

    func descriptor(for toolID: String) -> CompanionWorkflowToolDescriptor? {
        tools[toolID]?.descriptor
    }

    func descriptors() -> [CompanionWorkflowToolDescriptor] {
        tools.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        guard let tool = tools[invocation.toolID] else {
            return .failed(code: "tool_not_found", message: "Companion tool not found: \(invocation.toolID)")
        }
        var normalizedInvocation = invocation
        let dryRun = invocation.dryRun
            || invocation.arguments["dryRun"]?.boolValue == true
            || invocation.arguments["dry_run"]?.boolValue == true
        normalizedInvocation.dryRun = dryRun
        normalizedInvocation.arguments["dryRun"] = .bool(dryRun)
        let isPrivilegedWrite = tool.descriptor.risk == .externalWrite || tool.descriptor.risk == .destructive
        let approved = normalizedInvocation.arguments["__companionApproved"]?.boolValue == true
        normalizedInvocation.arguments.removeValue(forKey: "__companionApproved")
        guard dryRun || !isPrivilegedWrite || approved else {
            return .blocked(
                code: "approval_required",
                message: "This Companion tool requires local approval before it can perform external writes."
            )
        }
        return tool.invoke(normalizedInvocation)
    }

    static func defaultRegistry(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CompanionWorkflowToolRegistry {
        let registry = CompanionWorkflowToolRegistry()
        registry.register(CompanionReminderParseDraftTool())
        registry.register(CompanionReminderCreateTool(environment: environment))
        registry.register(CompanionReminderCreateBatchTool(environment: environment))
        registry.register(CompanionJournalAppendTodayTool(environment: environment))
        registry.register(CompanionPomodoroStartFocusTool(environment: environment))
        registry.register(CompanionAssetUploadTool(environment: environment))
        registry.register(CompanionFocusReviewGenerateTool(environment: environment))
        return registry
    }
}

private enum CompanionWorkflowSchemas {
    static func object(properties: [String: CompanionJSONValue], required: [String] = []) -> CompanionJSONObject {
        var schema: CompanionJSONObject = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(CompanionJSONValue.string))
        }
        return schema
    }

    static func string(description: String? = nil, enumValues: [String]? = nil) -> CompanionJSONValue {
        var schema: CompanionJSONObject = ["type": .string("string")]
        if let description {
            schema["description"] = .string(description)
        }
        if let enumValues {
            schema["enum"] = .array(enumValues.map(CompanionJSONValue.string))
        }
        return .object(schema)
    }

    static func integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> CompanionJSONValue {
        var schema: CompanionJSONObject = ["type": .string("integer")]
        if let description {
            schema["description"] = .string(description)
        }
        if let minimum {
            schema["minimum"] = .number(Double(minimum))
        }
        if let maximum {
            schema["maximum"] = .number(Double(maximum))
        }
        return .object(schema)
    }

    static func boolean(description: String? = nil) -> CompanionJSONValue {
        var schema: CompanionJSONObject = ["type": .string("boolean")]
        if let description {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }

    static func stringArray(description: String? = nil) -> CompanionJSONValue {
        var schema: CompanionJSONObject = [
            "type": .string("array"),
            "items": .object(["type": .string("string")])
        ]
        if let description {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }

    static func recurrence() -> CompanionJSONValue {
        .object([
            "oneOf": .array([
                .object([
                    "type": .string("string"),
                    "enum": .array(["daily", "weekdays", "weekly"].map(CompanionJSONValue.string))
                ]),
                .object(object(properties: [
                    "frequency": string(enumValues: ["daily", "weekdays", "weekly", "custom"]),
                    "intervalDays": integer(minimum: 1, maximum: 365)
                ], required: ["frequency"]))
            ])
        ])
    }
}

private struct CompanionWorkflowArguments {
    var values: CompanionJSONObject

    func string(_ key: String) -> String? {
        values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw CompanionWorkflowArgumentError.missing(key)
        }
        return value
    }

    func int(_ key: String) -> Int? {
        values[key]?.intValue
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }

    func strings(_ key: String) -> [String]? {
        values[key]?.stringArrayValue
    }

    func date(_ key: String) throws -> Date {
        let raw = try requiredString(key)
        if let date = CompanionWorkflowFormatters.iso8601.date(from: raw)
            ?? CompanionWorkflowFormatters.iso8601WithFractionalSeconds.date(from: raw)
        {
            return date
        }
        throw CompanionWorkflowArgumentError.invalid(key, "Expected ISO-8601 date string.")
    }
}

private enum CompanionWorkflowArgumentError: Error {
    case missing(String)
    case invalid(String, String)

    var toolResult: CompanionWorkflowToolResult {
        switch self {
        case .missing(let key):
            return .needsInput(
                [CompanionWorkflowMissingInput(key: key, title: key, message: "Missing required input: \(key)")],
                output: [:],
                outputSummary: "Missing required input: \(key)",
                userMessage: "Missing required input: \(key)"
            )
        case .invalid(let key, let message):
            return .failed(code: "invalid_argument", message: "\(key): \(message)")
        }
    }
}

private enum CompanionWorkflowFormatters {
    static let iso8601 = ISO8601DateFormatter()
    static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        iso8601.string(from: date)
    }

    static func dayString(from date: Date) -> String {
        day.string(from: date)
    }

    static func dayRange(start: Date, end: Date) -> (startKey: String, endKey: String, dayCount: Int) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: min(start, end))
        let endOfDay = calendar.startOfDay(for: max(start, end))
        let dayCount = (calendar.dateComponents([.day], from: startOfDay, to: endOfDay).day ?? 0) + 1
        return (dayString(from: startOfDay), dayString(from: endOfDay), max(1, dayCount))
    }

    static func dateFromDayOrISO(_ raw: String) -> Date? {
        if let date = day.date(from: raw) {
            return date
        }
        return iso8601.date(from: raw) ?? iso8601WithFractionalSeconds.date(from: raw)
    }

    static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private extension PetReminderRecurrence {
    var companionWorkflowSummary: String {
        switch frequency {
        case .daily:
            return "daily"
        case .weekdays:
            return "weekdays"
        case .weekly:
            return "weekly"
        case .custom:
            return "every \(intervalDays) days"
        }
    }

    var companionWorkflowJSON: CompanionJSONValue {
        .object([
            "frequency": .string(frequency.rawValue),
            "intervalDays": .number(Double(intervalDays))
        ])
    }

    static func companionWorkflowParse(_ value: CompanionJSONValue?) throws -> PetReminderRecurrence? {
        guard let value, value != .null else { return nil }
        if let raw = value.stringValue {
            return try recurrence(frequency: raw, intervalDays: 1)
        }
        guard let object = value.objectValue,
              let frequency = object["frequency"]?.stringValue
        else {
            throw CompanionWorkflowArgumentError.invalid("recurrence", "Expected recurrence string or object.")
        }
        return try recurrence(frequency: frequency, intervalDays: object["intervalDays"]?.intValue ?? 1)
    }

    private static func recurrence(frequency: String, intervalDays: Int) throws -> PetReminderRecurrence {
        switch frequency {
        case "daily":
            return .daily
        case "weekdays":
            return .weekdays
        case "weekly":
            return .weekly
        case "custom":
            return .everyDays(intervalDays)
        default:
            throw CompanionWorkflowArgumentError.invalid("recurrence", "Unsupported recurrence frequency: \(frequency)")
        }
    }
}

private final class CompanionReminderParseDraftTool: CompanionWorkflowTool {
    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.reminder.parseDraft",
        title: "Parse Reminder Draft",
        description: "Parse a local reminder title, fire date, and recurrence from natural-language text.",
        risk: .readOnly,
        approvalMode: .none,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "text": CompanionWorkflowSchemas.string(description: "Natural-language reminder text."),
            "fallbackTitle": CompanionWorkflowSchemas.string(description: "Title to use when the text only provides scheduling context.")
        ], required: ["text"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "title": CompanionWorkflowSchemas.string(),
            "fireDate": CompanionWorkflowSchemas.string(description: "ISO-8601 fire date, when parsed."),
            "recurrence": CompanionWorkflowSchemas.recurrence(),
            "missing": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        ])
    )

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let text = try args.requiredString("text")
            let fallbackTitle = args.string("fallbackTitle") ?? text
            if let parsed = PetReminderRuleParser.parse(text) {
                return .succeeded(
                    output: reminderDraftOutput(
                        title: parsed.title,
                        fireDate: parsed.fireDate,
                        recurrence: parsed.recurrence,
                        missing: []
                    ),
                    outputSummary: "Parsed reminder \"\(parsed.title)\" for \(CompanionWorkflowFormatters.string(from: parsed.fireDate))."
                )
            }

            let title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = reminderDraftOutput(title: title, fireDate: nil, recurrence: nil, missing: ["fireDate"])
            return .needsInput(
                [CompanionWorkflowMissingInput(key: "fireDate", title: "Reminder time", message: "When should Companion remind you?")],
                output: output,
                outputSummary: "Reminder time is missing.",
                userMessage: "When should Companion remind you?"
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "parse_failed", message: error.localizedDescription)
        }
    }

    private func reminderDraftOutput(
        title: String,
        fireDate: Date?,
        recurrence: PetReminderRecurrence?,
        missing: [String]
    ) -> CompanionJSONObject {
        [
            "title": .string(title),
            "fireDate": fireDate.map { .string(CompanionWorkflowFormatters.string(from: $0)) } ?? .null,
            "recurrence": recurrence?.companionWorkflowJSON ?? .null,
            "missing": .array(missing.map(CompanionJSONValue.string))
        ]
    }
}

private final class CompanionReminderCreateTool: CompanionWorkflowTool {
    private let environment: [String: String]

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.reminder.create",
        title: "Create Reminder",
        description: "Create a local Companion reminder after local user approval.",
        risk: .localWrite,
        approvalMode: .perRun,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "title": CompanionWorkflowSchemas.string(description: "Reminder title."),
            "fireDate": CompanionWorkflowSchemas.string(description: "ISO-8601 reminder time."),
            "recurrence": CompanionWorkflowSchemas.recurrence(),
            "dryRun": CompanionWorkflowSchemas.boolean(description: "Preview the write without changing local data.")
        ], required: ["title", "fireDate"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "reminderID": CompanionWorkflowSchemas.string(),
            "title": CompanionWorkflowSchemas.string(),
            "fireDate": CompanionWorkflowSchemas.string(),
            "recurrence": CompanionWorkflowSchemas.recurrence(),
            "dryRun": CompanionWorkflowSchemas.boolean()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let title = try args.requiredString("title")
            let fireDate = try args.date("fireDate")
            let recurrence = try PetReminderRecurrence.companionWorkflowParse(invocation.arguments["recurrence"])
            try validate(title: title, fireDate: fireDate)

            if invocation.dryRun {
                return .succeeded(
                    output: reminderOutput(id: nil, title: title, fireDate: fireDate, recurrence: recurrence, dryRun: true),
                    outputSummary: "Reminder preview: \"\(title)\" at \(CompanionWorkflowFormatters.string(from: fireDate))."
                )
            }

            let store = PetReminderStore(environment: environment)
            let reminder = try store.addReminder(title: title, fireDate: fireDate, recurrence: recurrence)
            return .succeeded(
                output: reminderOutput(
                    id: reminder.id,
                    title: reminder.title,
                    fireDate: reminder.fireDate,
                    recurrence: reminder.recurrence,
                    dryRun: false
                ),
                outputSummary: "Created reminder \"\(reminder.title)\"."
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "reminder_create_failed", message: error.localizedDescription)
        }
    }

    private func validate(title: String, fireDate: Date) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PetReminderStoreError.emptyTitle
        }
        guard fireDate > Date().addingTimeInterval(-2) else {
            throw PetReminderStoreError.pastDate
        }
        guard fireDate <= PetReminderStore.maximumFireDate() else {
            throw PetReminderStoreError.tooFarInFuture
        }
    }

    private func reminderOutput(
        id: UUID?,
        title: String,
        fireDate: Date,
        recurrence: PetReminderRecurrence?,
        dryRun: Bool
    ) -> CompanionJSONObject {
        [
            "reminderID": id.map { .string($0.uuidString) } ?? .null,
            "title": .string(title),
            "fireDate": .string(CompanionWorkflowFormatters.string(from: fireDate)),
            "recurrence": recurrence?.companionWorkflowJSON ?? .null,
            "recurrenceSummary": recurrence.map { .string($0.companionWorkflowSummary) } ?? .null,
            "dryRun": .bool(dryRun)
        ]
    }
}

private final class CompanionReminderCreateBatchTool: CompanionWorkflowTool {
    private struct BatchItem {
        var index: Int
        var title: String
        var fireDate: Date?
        var recurrence: PetReminderRecurrence?
        var sourceNote: String?
        var error: String?

        var isValid: Bool {
            error == nil && fireDate != nil
        }
    }

    private let environment: [String: String]
    private let maxItems = 20

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.reminder.createBatch",
        title: "Create Reminder Batch",
        description: "Create multiple local Companion reminders after local user approval.",
        risk: .localWrite,
        approvalMode: .perRun,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "items": .object([
                "type": .string("array"),
                "items": .object(CompanionWorkflowSchemas.object(properties: [
                    "title": CompanionWorkflowSchemas.string(description: "Reminder title."),
                    "fireDate": CompanionWorkflowSchemas.string(description: "ISO-8601 reminder time."),
                    "recurrence": CompanionWorkflowSchemas.recurrence(),
                    "sourceNote": CompanionWorkflowSchemas.string(description: "Optional agent-side source note.")
                ], required: ["title", "fireDate"]))
            ]),
            "dryRun": CompanionWorkflowSchemas.boolean(description: "Preview validation without changing local data."),
            "showWindow": CompanionWorkflowSchemas.boolean(description: "Ask Companion to show the reminder center after writing."),
            "allowPartial": CompanionWorkflowSchemas.boolean(description: "Create valid items when some items are invalid."),
            "skippedItemIndexes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")]),
                "description": .string("Indexes skipped by the local approval UI.")
            ])
        ], required: ["items"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "requestedCount": CompanionWorkflowSchemas.integer(),
            "validCount": CompanionWorkflowSchemas.integer(),
            "invalidCount": CompanionWorkflowSchemas.integer(),
            "createdCount": CompanionWorkflowSchemas.integer(),
            "skippedCount": CompanionWorkflowSchemas.integer(),
            "failedCount": CompanionWorkflowSchemas.integer(),
            "dryRun": CompanionWorkflowSchemas.boolean()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let allowPartial = args.bool("allowPartial") ?? false
            let items = try parseItems(invocation.arguments["items"])
            let skippedIndexes = skippedItemIndexes(invocation.arguments["skippedItemIndexes"])
            let explicitlySkippedItems = items.filter { skippedIndexes.contains($0.index) }
            let candidateItems = items.filter { !skippedIndexes.contains($0.index) }
            let validItems = candidateItems.filter(\.isValid)
            let invalidItems = candidateItems.filter { !$0.isValid }

            if invocation.dryRun {
                return .succeeded(
                    output: batchOutput(
                        requestedItems: items,
                        created: [],
                        failed: [],
                        skipped: explicitlySkippedItems,
                        invalid: invalidItems,
                        dryRun: true,
                        showWindowRequested: args.bool("showWindow") ?? false
                    ),
                    outputSummary: "Reminder batch preview: \(validItems.count) valid, \(invalidItems.count) invalid."
                )
            }

            guard invalidItems.isEmpty || allowPartial else {
                return .needsInput(
                    invalidItems.map { item in
                        CompanionWorkflowMissingInput(
                            key: "items[\(item.index)]",
                            title: "Invalid reminder",
                            message: item.error ?? "Reminder item is invalid."
                        )
                    },
                    output: batchOutput(
                        requestedItems: items,
                        created: [],
                        failed: [],
                        skipped: explicitlySkippedItems,
                        invalid: invalidItems,
                        dryRun: false,
                        showWindowRequested: args.bool("showWindow") ?? false
                    ),
                    outputSummary: "Reminder batch has invalid items.",
                    userMessage: "Some reminder items need edits before Companion can create the batch."
                )
            }

            let store = PetReminderStore(environment: environment)
            var created: [(BatchItem, PetReminder)] = []
            var failed: [(BatchItem, String)] = []
            for item in validItems {
                guard let fireDate = item.fireDate else { continue }
                do {
                    let reminder = try store.addReminder(
                        title: item.title,
                        fireDate: fireDate,
                        recurrence: item.recurrence
                    )
                    created.append((item, reminder))
                } catch {
                    failed.append((item, error.localizedDescription))
                }
            }

            let output = batchOutput(
                requestedItems: items,
                created: created,
                failed: failed,
                skipped: explicitlySkippedItems + invalidItems,
                invalid: [],
                dryRun: false,
                showWindowRequested: args.bool("showWindow") ?? false
            )
            if failed.isEmpty {
                return .succeeded(
                    output: output,
                    outputSummary: "Created \(created.count) reminder(s)."
                )
            }
            return .blocked(
                code: "reminder_batch_partial_failure",
                message: "Created \(created.count) reminder(s); \(failed.count) failed.",
                output: output
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "reminder_batch_failed", message: error.localizedDescription)
        }
    }

    private func skippedItemIndexes(_ value: CompanionJSONValue?) -> Set<Int> {
        guard case .array(let values) = value else { return [] }
        return Set(values.compactMap(\.intValue).filter { $0 >= 0 && $0 < maxItems })
    }

    private func parseItems(_ value: CompanionJSONValue?) throws -> [BatchItem] {
        guard case .array(let rawItems) = value else {
            throw CompanionWorkflowArgumentError.missing("items")
        }
        guard !rawItems.isEmpty else {
            throw CompanionWorkflowArgumentError.invalid("items", "At least one reminder item is required.")
        }
        guard rawItems.count <= maxItems else {
            throw CompanionWorkflowArgumentError.invalid("items", "At most \(maxItems) reminder items are supported per call.")
        }
        return rawItems.enumerated().map { offset, value in
            guard let object = value.objectValue else {
                return BatchItem(index: offset, title: "", fireDate: nil, recurrence: nil, sourceNote: nil, error: "Expected object item.")
            }
            let title = object["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fireDateRaw = object["fireDate"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recurrence: PetReminderRecurrence?
            do {
                recurrence = try PetReminderRecurrence.companionWorkflowParse(object["recurrence"])
            } catch {
                return BatchItem(index: offset, title: title, fireDate: nil, recurrence: nil, sourceNote: nil, error: error.localizedDescription)
            }
            guard !title.isEmpty else {
                return BatchItem(index: offset, title: title, fireDate: nil, recurrence: recurrence, sourceNote: nil, error: "Title is required.")
            }
            guard let fireDateRaw, let fireDate = CompanionWorkflowFormatters.dateFromDayOrISO(fireDateRaw) else {
                return BatchItem(index: offset, title: title, fireDate: nil, recurrence: recurrence, sourceNote: nil, error: "Valid fireDate is required.")
            }
            guard fireDate > Date().addingTimeInterval(-2) else {
                return BatchItem(index: offset, title: title, fireDate: fireDate, recurrence: recurrence, sourceNote: nil, error: PetReminderStoreError.pastDate.localizedDescription)
            }
            guard fireDate <= PetReminderStore.maximumFireDate() else {
                return BatchItem(index: offset, title: title, fireDate: fireDate, recurrence: recurrence, sourceNote: nil, error: PetReminderStoreError.tooFarInFuture.localizedDescription)
            }
            return BatchItem(
                index: offset,
                title: title,
                fireDate: fireDate,
                recurrence: recurrence,
                sourceNote: object["sourceNote"]?.stringValue,
                error: nil
            )
        }
    }

    private func batchOutput(
        requestedItems: [BatchItem],
        created: [(BatchItem, PetReminder)],
        failed: [(BatchItem, String)],
        skipped: [BatchItem],
        invalid: [BatchItem],
        dryRun: Bool,
        showWindowRequested: Bool
    ) -> CompanionJSONObject {
        [
            "requestedCount": .number(Double(requestedItems.count)),
            "validCount": .number(Double(requestedItems.filter { $0.isValid && !skipped.map(\.index).contains($0.index) }.count)),
            "invalidCount": .number(Double(invalid.count)),
            "createdCount": .number(Double(created.count)),
            "skippedCount": .number(Double(skipped.count)),
            "failedCount": .number(Double(failed.count)),
            "createdReminderIDs": .array(created.map { .string($0.1.id.uuidString) }),
            "dryRun": .bool(dryRun),
            "showWindowRequested": .bool(showWindowRequested),
            "itemResults": .array(itemResults(requestedItems: requestedItems, created: created, failed: failed, skipped: skipped))
        ]
    }

    private func itemResults(
        requestedItems: [BatchItem],
        created: [(BatchItem, PetReminder)],
        failed: [(BatchItem, String)],
        skipped: [BatchItem]
    ) -> [CompanionJSONValue] {
        let skippedIndexes = Set(skipped.map(\.index))
        return requestedItems.map { item in
            if let createdItem = created.first(where: { $0.0.index == item.index }) {
                let reminder = createdItem.1
                return .object([
                    "index": .number(Double(item.index)),
                    "title": .string(reminder.title),
                    "fireDate": .string(CompanionWorkflowFormatters.string(from: reminder.fireDate)),
                    "status": .string("created"),
                    "reminderID": .string(reminder.id.uuidString)
                ])
            }
            if let failure = failed.first(where: { $0.0.index == item.index }) {
                return .object([
                    "index": .number(Double(item.index)),
                    "title": .string(item.title),
                    "fireDate": item.fireDate.map { .string(CompanionWorkflowFormatters.string(from: $0)) } ?? .null,
                    "status": .string("failed"),
                    "error": .string(failure.1)
                ])
            }
            if skippedIndexes.contains(item.index) {
                return .object([
                    "index": .number(Double(item.index)),
                    "title": .string(item.title),
                    "fireDate": item.fireDate.map { .string(CompanionWorkflowFormatters.string(from: $0)) } ?? .null,
                    "status": .string("skipped"),
                    "error": item.error.map(CompanionJSONValue.string) ?? .null
                ])
            }
            return .object([
                "index": .number(Double(item.index)),
                "title": .string(item.title),
                "fireDate": item.fireDate.map { .string(CompanionWorkflowFormatters.string(from: $0)) } ?? .null,
                "status": .string(item.isValid ? "valid" : "invalid"),
                "error": item.error.map(CompanionJSONValue.string) ?? .null
            ])
        }
    }
}

private final class CompanionJournalAppendTodayTool: CompanionWorkflowTool {
    private let environment: [String: String]

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.journal.appendToday",
        title: "Append Today Journal",
        description: "Append lines to a section in today's local Companion Journal after local user approval.",
        risk: .localWrite,
        approvalMode: .perRun,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "section": CompanionWorkflowSchemas.string(description: "Today Journal section title."),
            "lines": CompanionWorkflowSchemas.stringArray(description: "Lines to append."),
            "showWindow": CompanionWorkflowSchemas.boolean(description: "Ask Companion to show the Journal window after writing."),
            "dryRun": CompanionWorkflowSchemas.boolean(description: "Preview the write without changing local data.")
        ], required: ["section", "lines"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "section": CompanionWorkflowSchemas.string(),
            "appendedLineCount": CompanionWorkflowSchemas.integer(),
            "documentDate": CompanionWorkflowSchemas.string(),
            "documentTitle": CompanionWorkflowSchemas.string(),
            "showWindowRequested": CompanionWorkflowSchemas.boolean(),
            "dryRun": CompanionWorkflowSchemas.boolean()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let section = try args.requiredString("section")
            let lines = (args.strings("lines") ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else {
                throw CompanionWorkflowArgumentError.invalid("lines", "At least one non-empty line is required.")
            }
            let showWindow = args.bool("showWindow") ?? false

            if invocation.dryRun {
                return .succeeded(
                    output: journalOutput(
                        section: section,
                        lineCount: lines.count,
                        documentTitle: nil,
                        dryRun: true,
                        showWindowRequested: showWindow
                    ),
                    outputSummary: "Journal preview: append \(lines.count) line(s) to \(section)."
                )
            }

            let store = PetJournalStore(environment: environment)
            store.appendToTodaySection(section, lines: lines)
            let documentTitle = store.selectedDocument?.displayTitle
            return .succeeded(
                output: journalOutput(
                    section: section,
                    lineCount: lines.count,
                    documentTitle: documentTitle,
                    dryRun: false,
                    showWindowRequested: showWindow
                ),
                outputSummary: "Appended \(lines.count) line(s) to today's Journal."
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "journal_append_failed", message: error.localizedDescription)
        }
    }

    static func output(
        section: String,
        lineCount: Int,
        documentTitle: String?,
        dryRun: Bool,
        showWindowRequested: Bool,
        now: Date = Date()
    ) -> CompanionJSONObject {
        [
            "section": .string(section),
            "appendedLineCount": .number(Double(lineCount)),
            "documentDate": .string(CompanionWorkflowFormatters.dayString(from: now)),
            "documentTitle": documentTitle.map(CompanionJSONValue.string) ?? .null,
            "showWindowRequested": .bool(showWindowRequested),
            "dryRun": .bool(dryRun)
        ]
    }

    private func journalOutput(
        section: String,
        lineCount: Int,
        documentTitle: String?,
        dryRun: Bool,
        showWindowRequested: Bool
    ) -> CompanionJSONObject {
        Self.output(
            section: section,
            lineCount: lineCount,
            documentTitle: documentTitle,
            dryRun: dryRun,
            showWindowRequested: showWindowRequested
        )
    }
}

private final class CompanionPomodoroStartFocusTool: CompanionWorkflowTool {
    private let environment: [String: String]

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.pomodoro.startFocus",
        title: "Start Focus",
        description: "Start a local Companion Pomodoro focus session after local user approval.",
        risk: .localSession,
        approvalMode: .perRun,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "taskTitle": CompanionWorkflowSchemas.string(description: "Focus task title."),
            "durationMinutes": CompanionWorkflowSchemas.integer(description: "Optional one-off focus duration.", minimum: 1, maximum: 180),
            "dryRun": CompanionWorkflowSchemas.boolean(description: "Preview the session without changing local state.")
        ], required: ["taskTitle"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "taskTitle": CompanionWorkflowSchemas.string(),
            "durationMinutes": CompanionWorkflowSchemas.integer(),
            "started": CompanionWorkflowSchemas.boolean(),
            "blockedReason": CompanionWorkflowSchemas.string(),
            "dryRun": CompanionWorkflowSchemas.boolean()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let taskTitle = try args.requiredString("taskTitle")
            let duration = args.int("durationMinutes").map { min(max($0, 1), 180) }

            if invocation.dryRun {
                let state = CompanionPomodoroStateReader.state(environment: environment)
                if state.isActive {
                    return .blocked(
                        code: "pomodoro_active",
                        message: "A Pomodoro session is already active.",
                        output: pomodoroOutput(
                            taskTitle: taskTitle,
                            durationMinutes: duration ?? state.focusMinutes,
                            started: false,
                            blockedReason: "pomodoro_active",
                            dryRun: true
                        )
                    )
                }
                return .succeeded(
                    output: pomodoroOutput(
                        taskTitle: taskTitle,
                        durationMinutes: duration ?? state.focusMinutes,
                        started: false,
                        blockedReason: nil,
                        dryRun: true
                    ),
                    outputSummary: "Focus preview: \(duration ?? state.focusMinutes) minute(s) for \"\(taskTitle)\"."
                )
            }

            let controller = PetPomodoroController(environment: environment)
            guard controller.state == .idle else {
                return .blocked(
                    code: "pomodoro_active",
                    message: "A Pomodoro session is already active.",
                    output: pomodoroOutput(
                        taskTitle: taskTitle,
                        durationMinutes: duration ?? controller.focusMinutes,
                        started: false,
                        blockedReason: "pomodoro_active",
                        dryRun: false
                    )
                )
            }
            controller.startFocus(taskTitle: taskTitle, durationMinutes: duration)
            return .succeeded(
                output: pomodoroOutput(
                    taskTitle: taskTitle,
                    durationMinutes: duration ?? controller.focusMinutes,
                    started: true,
                    blockedReason: nil,
                    dryRun: false
                ),
                outputSummary: "Started focus session for \"\(taskTitle)\"."
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "pomodoro_start_failed", message: error.localizedDescription)
        }
    }

    private func pomodoroOutput(
        taskTitle: String,
        durationMinutes: Int,
        started: Bool,
        blockedReason: String?,
        dryRun: Bool
    ) -> CompanionJSONObject {
        [
            "taskTitle": .string(taskTitle),
            "durationMinutes": .number(Double(durationMinutes)),
            "started": .bool(started),
            "blockedReason": blockedReason.map(CompanionJSONValue.string) ?? .null,
            "dryRun": .bool(dryRun)
        ]
    }
}

private enum CompanionPomodoroStateReader {
    struct Snapshot {
        var focusMinutes: Int
        var isActive: Bool
    }

    static func state(environment: [String: String]) -> Snapshot {
        let url = CompanionDataRoot.currentURL(environment: environment).appendingPathComponent("pomodoro.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Snapshot(focusMinutes: 25, isActive: false)
        }
        let focusMinutes = min(max(object["focusMinutes"] as? Int ?? 25, 1), 180)
        let state = object["state"] as? String ?? "idle"
        return Snapshot(focusMinutes: focusMinutes, isActive: state != "idle")
    }
}

private final class CompanionAssetUploadTool: CompanionWorkflowTool {
    private let environment: [String: String]

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.asset.upload",
        title: "Upload Asset",
        description: "Upload a user-approved local asset to a configured target and return URL, Markdown, or HTML.",
        risk: .externalWrite,
        approvalMode: .perRun,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "sourceType": CompanionWorkflowSchemas.string(description: "Asset source.", enumValues: ["filePath", "clipboardImage", "temporaryFile"]),
            "filePath": CompanionWorkflowSchemas.string(description: "Local file path when sourceType is filePath or temporaryFile."),
            "profileID": CompanionWorkflowSchemas.string(description: "Optional asset upload profile id. Defaults to the configured default profile."),
            "outputFormat": CompanionWorkflowSchemas.string(description: "Returned link format.", enumValues: ["url", "markdown", "html"]),
            "altText": CompanionWorkflowSchemas.string(description: "Optional Markdown/HTML alt text."),
            "objectKey": CompanionWorkflowSchemas.string(description: "Optional S3 object key, usually reused from a previous dry-run preview."),
            "showInConsole": CompanionWorkflowSchemas.boolean(description: "Ask Companion to show the Workflow Console for this upload."),
            "dryRun": CompanionWorkflowSchemas.boolean(description: "Validate and preview without network upload.")
        ], required: ["sourceType"]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "assetID": CompanionWorkflowSchemas.string(),
            "url": CompanionWorkflowSchemas.string(),
            "formatted": CompanionWorkflowSchemas.string(),
            "format": CompanionWorkflowSchemas.string(enumValues: ["url", "markdown", "html"]),
            "fileNameSummary": CompanionWorkflowSchemas.string(),
            "mimeType": CompanionWorkflowSchemas.string(),
            "sizeBytes": CompanionWorkflowSchemas.integer(),
            "profileSummary": CompanionWorkflowSchemas.string(),
            "profileID": CompanionWorkflowSchemas.string(),
            "uploadedAt": CompanionWorkflowSchemas.string(),
            "objectKey": CompanionWorkflowSchemas.string(),
            "dryRun": CompanionWorkflowSchemas.boolean()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        do {
            let request = try uploadRequest(args: args, dryRun: invocation.dryRun)
            let store = CompanionAssetUploadProfileStore(environment: environment)
            let service = CompanionAssetUploadService(profileStore: store)
            let result = try service.upload(request)
            if !result.dryRun {
                CompanionAssetUploadHistoryStore(environment: environment).appendSuccess(
                    result,
                    runID: invocation.runID,
                    source: invocation.caller ?? "tool-registry"
                )
            }
            let summaryPrefix = result.dryRun ? "Asset upload preview" : "Uploaded asset"
            return .succeeded(
                output: output(for: result),
                outputSummary: "\(summaryPrefix): \(result.fileNameSummary) as \(result.format.rawValue) via \(result.profileSummary)."
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch let error as CompanionAssetUploadError {
            if case .uploadCancelled = error {
                return .failed(code: "asset_upload_cancelled", message: error.localizedDescription)
            }
            return .failed(code: "asset_upload_failed", message: error.localizedDescription)
        } catch let error as CompanionAssetUploadProfileStoreError {
            return .blocked(code: "asset_upload_profile_unavailable", message: error.localizedDescription)
        } catch {
            return .failed(code: "asset_upload_failed", message: error.localizedDescription)
        }
    }

    private func uploadRequest(args: CompanionWorkflowArguments, dryRun: Bool) throws -> CompanionAssetUploadRequest {
        let sourceTypeRaw = try args.requiredString("sourceType")
        guard let sourceType = CompanionAssetUploadSourceType(rawValue: sourceTypeRaw) else {
            throw CompanionWorkflowArgumentError.invalid("sourceType", "Expected filePath, clipboardImage, or temporaryFile.")
        }
        let outputFormatRaw = args.string("outputFormat") ?? CompanionAssetUploadOutputFormat.url.rawValue
        guard let outputFormat = CompanionAssetUploadOutputFormat(rawValue: outputFormatRaw) else {
            throw CompanionWorkflowArgumentError.invalid("outputFormat", "Expected url, markdown, or html.")
        }
        let fileURL: URL?
        switch sourceType {
        case .filePath, .temporaryFile:
            let path = try args.requiredString("filePath")
            fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        case .clipboardImage:
            fileURL = nil
        }
        return CompanionAssetUploadRequest(
            sourceType: sourceType,
            fileURL: fileURL,
            profileID: args.string("profileID"),
            outputFormat: outputFormat,
            altText: args.string("altText"),
            dryRun: dryRun,
            objectKey: args.string("objectKey")
        )
    }

    private func output(for result: CompanionAssetUploadResult) -> CompanionJSONObject {
        [
            "assetID": .string(result.assetID),
            "url": result.url.map(CompanionJSONValue.string) ?? .null,
            "formatted": result.formatted.map(CompanionJSONValue.string) ?? .null,
            "format": .string(result.format.rawValue),
            "fileNameSummary": .string(result.fileNameSummary),
            "mimeType": .string(result.mimeType),
            "sizeBytes": .number(Double(result.sizeBytes)),
            "profileSummary": .string(result.profileSummary),
            "profileID": .string(result.profileID),
            "uploadedAt": .string(CompanionWorkflowFormatters.string(from: result.uploadedAt)),
            "objectKey": result.objectKey.map(CompanionJSONValue.string) ?? .null,
            "dryRun": .bool(result.dryRun)
        ]
    }
}

private final class CompanionFocusReviewGenerateTool: CompanionWorkflowTool {
    private let environment: [String: String]

    let descriptor = CompanionWorkflowToolDescriptor(
        id: "companion.focusReview.generate",
        title: "Generate Focus Review",
        description: "Generate local Focus Review aggregate statistics and markdown without reading raw agent sessions.",
        risk: .readOnly,
        approvalMode: .none,
        rememberableApproval: false,
        inputSchema: CompanionWorkflowSchemas.object(properties: [
            "date": CompanionWorkflowSchemas.string(description: "Optional yyyy-MM-dd date, default today."),
            "format": CompanionWorkflowSchemas.string(description: "Optional report format.", enumValues: ["summary", "markdown"])
        ]),
        outputSchema: CompanionWorkflowSchemas.object(properties: [
            "generatedAt": CompanionWorkflowSchemas.string(),
            "date": CompanionWorkflowSchemas.string(),
            "todayFocusRounds": CompanionWorkflowSchemas.integer(),
            "todayFocusMinutes": CompanionWorkflowSchemas.integer(),
            "completedReminderCount": CompanionWorkflowSchemas.integer(),
            "journalExists": CompanionWorkflowSchemas.boolean(),
            "sevenDayFocusMinutes": CompanionWorkflowSchemas.integer(),
            "thirtyDayFocusMinutes": CompanionWorkflowSchemas.integer(),
            "commonTasks": .object([
                "type": .string("array"),
                "items": .object(CompanionWorkflowSchemas.object(properties: [
                    "title": CompanionWorkflowSchemas.string(),
                    "rounds": CompanionWorkflowSchemas.integer(),
                    "minutes": CompanionWorkflowSchemas.integer()
                ]))
            ]),
            "completedReminderSummary": CompanionWorkflowSchemas.stringArray(),
            "weeklyMarkdown": CompanionWorkflowSchemas.string(),
            "markdown": CompanionWorkflowSchemas.string()
        ])
    )

    init(environment: [String: String]) {
        self.environment = environment
    }

    func invoke(_ invocation: CompanionWorkflowToolInvocation) -> CompanionWorkflowToolResult {
        let args = CompanionWorkflowArguments(values: invocation.arguments)
        let generatedAt = Date()
        do {
            let requestedDate = try reportDate(args.string("date"), now: generatedAt)
            let reportCutoff = cutoff(for: requestedDate, now: generatedAt)
            let reminders = CompanionFocusReviewReaders.reminders(environment: environment)
            let focusRecords = CompanionFocusReviewReaders.focusRecords(environment: environment)
            let journal = CompanionFocusReviewReaders.journalSnapshot(
                environment: environment,
                date: requestedDate
            )
            let snapshot = CompanionFocusReviewSnapshot.make(
                focusRecords: focusRecords,
                reminders: reminders,
                journal: journal,
                now: reportCutoff
            )
            var output = focusOutput(
                snapshot: snapshot,
                reportDate: requestedDate,
                generatedAt: generatedAt
            )
            if args.string("format") == "markdown" {
                output["markdown"] = .string(markdown(snapshot: snapshot, reportDate: requestedDate, generatedAt: generatedAt))
            }
            return .succeeded(
                output: output,
                outputSummary: "Focus Review: \(snapshot.today.focusRounds) focus round(s), \(snapshot.today.completedReminders.count) completed reminder(s)."
            )
        } catch let error as CompanionWorkflowArgumentError {
            return error.toolResult
        } catch {
            return .failed(code: "focus_review_failed", message: error.localizedDescription)
        }
    }

    private func reportDate(_ raw: String?, now: Date) throws -> Date {
        guard let raw, !raw.isEmpty else {
            return now
        }
        guard let date = CompanionWorkflowFormatters.dateFromDayOrISO(raw) else {
            throw CompanionWorkflowArgumentError.invalid("date", "Expected yyyy-MM-dd or ISO-8601 date.")
        }
        let calendar = Calendar.current
        guard calendar.startOfDay(for: date) <= calendar.startOfDay(for: now) else {
            throw CompanionWorkflowArgumentError.invalid("date", "Future Focus Review dates are not supported.")
        }
        return date
    }

    private func cutoff(for date: Date, now: Date) -> Date {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return now
        }
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    private func focusOutput(
        snapshot: CompanionFocusReviewSnapshot,
        reportDate: Date,
        generatedAt: Date
    ) -> CompanionJSONObject {
        [
            "generatedAt": .string(CompanionWorkflowFormatters.string(from: generatedAt)),
            "date": .string(CompanionWorkflowFormatters.dayString(from: reportDate)),
            "todayFocusRounds": .number(Double(snapshot.today.focusRounds)),
            "todayFocusMinutes": .number(Double(snapshot.today.focusMinutes)),
            "completedReminderCount": .number(Double(snapshot.today.completedReminders.count)),
            "completedReminderSummary": .array(snapshot.today.completedReminders.prefix(12).map { .string(CompanionWorkflowRunStore.safeSummary($0, maxLength: 80)) }),
            "journalExists": .bool(snapshot.today.hasJournalToday),
            "aiActionCount": .number(Double(snapshot.today.aiActionCount)),
            "sevenDayFocusRounds": .number(Double(snapshot.sevenDayStats.roundCount)),
            "sevenDayFocusMinutes": .number(Double(snapshot.sevenDayStats.totalMinutes)),
            "thirtyDayFocusRounds": .number(Double(snapshot.thirtyDayStats.roundCount)),
            "thirtyDayFocusMinutes": .number(Double(snapshot.thirtyDayStats.totalMinutes)),
            "commonTasks": .array(snapshot.sevenDayStats.topTasks.map { task in
                .object([
                    "title": .string(CompanionWorkflowRunStore.safeSummary(task.title, maxLength: 80)),
                    "rounds": .number(Double(task.rounds)),
                    "minutes": .number(Double(Int((Double(max(0, task.totalSeconds)) / 60.0).rounded())))
                ])
            }),
            "weeklyMarkdown": .string(snapshot.weeklyReportMarkdown)
        ]
    }

    private func markdown(snapshot: CompanionFocusReviewSnapshot, reportDate: Date, generatedAt: Date) -> String {
        var lines: [String] = []
        lines.append("# Focus Review \(CompanionWorkflowFormatters.dayString(from: reportDate))")
        lines.append("")
        lines.append("- Generated: \(CompanionWorkflowFormatters.string(from: generatedAt))")
        lines.append("- Focus rounds: \(snapshot.today.focusRounds)")
        lines.append("- Focus minutes: \(snapshot.today.focusMinutes)")
        lines.append("- Completed reminders: \(snapshot.today.completedReminders.count)")
        lines.append("- Journal exists: \(snapshot.today.hasJournalToday ? "yes" : "no")")
        lines.append("")
        lines.append(snapshot.weeklyReportMarkdown)
        return lines.joined(separator: "\n")
    }
}

private enum CompanionFocusReviewReaders {
    private struct ReminderPayload: Codable {
        var reminders: [PetReminder]
    }

    private struct PomodoroPayload: Codable {
        var focusRecords: [PetFocusRecord]?
    }

    private struct JournalPayload: Codable {
        var documents: [PetJournalDocument]
    }

    static func reminders(environment: [String: String]) -> [PetReminder] {
        let url = CompanionDataRoot.currentURL(environment: environment).appendingPathComponent("reminders.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(ReminderPayload.self, from: data) {
            return payload.reminders
        }
        return (try? decoder.decode([PetReminder].self, from: data)) ?? []
    }

    static func focusRecords(environment: [String: String]) -> [PetFocusRecord] {
        let url = CompanionDataRoot.currentURL(environment: environment).appendingPathComponent("pomodoro.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PomodoroPayload.self, from: data).focusRecords) ?? []
    }

    static func journalSnapshot(environment: [String: String], date: Date) -> CompanionFocusReviewJournalSnapshot {
        let url = CompanionDataRoot.currentURL(environment: environment).appendingPathComponent("journal-documents.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(JournalPayload.self, from: data) else { return .empty }
        let title = "今日记录 \(CompanionWorkflowFormatters.dayString(from: date))"
        let calendar = Calendar.current
        guard let document = payload.documents.first(where: {
            $0.title == title || calendar.isDate($0.createdAt, inSameDayAs: date)
        }) else {
            return .empty
        }
        let aiActionCount = document.items.filter { item in
            item.level == 1
                && item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("AI 动作：")
        }.count
        return CompanionFocusReviewJournalSnapshot(
            aiActionCount: aiActionCount,
            hasJournalToday: true
        )
    }
}
